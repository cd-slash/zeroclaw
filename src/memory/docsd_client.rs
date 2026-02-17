use crate::memory::docsd::{DocsdRequest, DocsdResponse};
use crate::memory::managed_docs::{
    initialize_managed_docs, ManagedDocStore, ManagedDocsBootstrapReport,
};
use anyhow::Context;
use std::env;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

const DOCSD_SOCKET_ENV: &str = "DOCSD_SOCKET";

pub fn default_socket_path(workspace_dir: &Path) -> PathBuf {
    workspace_dir.join(".managed-docs").join("docsd.sock")
}

fn configured_socket_path(workspace_dir: &Path) -> Option<PathBuf> {
    env::var(DOCSD_SOCKET_ENV)
        .ok()
        .map(PathBuf::from)
        .or_else(|| {
            let default = default_socket_path(workspace_dir);
            default.exists().then_some(default)
        })
}

fn request_via_docsd(socket_path: &Path, request: &DocsdRequest) -> anyhow::Result<DocsdResponse> {
    let mut last_err = None;
    for _ in 0..40 {
        match UnixStream::connect(socket_path) {
            Ok(mut stream) => {
                stream.set_read_timeout(Some(Duration::from_secs(10))).ok();
                stream.set_write_timeout(Some(Duration::from_secs(10))).ok();
                let raw = serde_json::to_vec(request)?;
                stream.write_all(&raw)?;
                stream.shutdown(std::net::Shutdown::Write)?;

                let mut out = Vec::new();
                stream.read_to_end(&mut out)?;
                let response: DocsdResponse =
                    serde_json::from_slice(&out).context("invalid docsd response json")?;
                return Ok(response);
            }
            Err(e) => {
                last_err = Some(e);
                std::thread::sleep(Duration::from_millis(150));
            }
        }
    }

    Err(anyhow::anyhow!(
        "failed to connect to docsd socket {}: {}",
        socket_path.display(),
        last_err
            .map(|e| e.to_string())
            .unwrap_or_else(|| "unknown error".to_string())
    ))
}

pub fn init_managed_docs(
    workspace_dir: &Path,
    scaffold_dir: Option<&Path>,
) -> anyhow::Result<ManagedDocsBootstrapReport> {
    if let Some(socket) = configured_socket_path(workspace_dir) {
        let request = DocsdRequest {
            action: "init".to_string(),
            doc: None,
            section: None,
            content: None,
            actor: Some("runtime:init".to_string()),
            scaffold_dir: scaffold_dir.map(|p| p.display().to_string()),
        };
        let response = request_via_docsd(&socket, &request)?;
        if response.ok {
            return Ok(ManagedDocsBootstrapReport {
                seeded_docs: response.seeded_docs.unwrap_or(0),
                materialized_docs: response.materialized_docs.unwrap_or(0),
            });
        }
        return Err(anyhow::anyhow!(
            "docsd init failed: {}",
            response
                .message
                .unwrap_or_else(|| "unknown error".to_string())
        ));
    }

    initialize_managed_docs(workspace_dir, scaffold_dir)
}

pub fn list_docs(workspace_dir: &Path) -> anyhow::Result<Vec<String>> {
    if let Some(socket) = configured_socket_path(workspace_dir) {
        let response = request_via_docsd(
            &socket,
            &DocsdRequest {
                action: "list".to_string(),
                doc: None,
                section: None,
                content: None,
                actor: Some("runtime:list".to_string()),
                scaffold_dir: None,
            },
        )?;
        if response.ok {
            return Ok(response.docs.unwrap_or_default());
        }
        return Err(anyhow::anyhow!(
            "docsd list failed: {}",
            response
                .message
                .unwrap_or_else(|| "unknown error".to_string())
        ));
    }

    let store = ManagedDocStore::open(workspace_dir)?;
    store.list_doc_ids()
}

pub fn read_doc(workspace_dir: &Path, doc: &str) -> anyhow::Result<Option<String>> {
    if let Some(socket) = configured_socket_path(workspace_dir) {
        let response = request_via_docsd(
            &socket,
            &DocsdRequest {
                action: "read".to_string(),
                doc: Some(doc.to_string()),
                section: None,
                content: None,
                actor: Some("runtime:read".to_string()),
                scaffold_dir: None,
            },
        )?;
        if response.ok {
            return Ok(response.content);
        }
        return Err(anyhow::anyhow!(
            "docsd read failed: {}",
            response
                .message
                .unwrap_or_else(|| "unknown error".to_string())
        ));
    }

    let store = ManagedDocStore::open(workspace_dir)?;
    store.read_doc(doc)
}

pub fn append_doc(
    workspace_dir: &Path,
    doc: &str,
    section: Option<&str>,
    content: &str,
    actor: &str,
) -> anyhow::Result<()> {
    if let Some(socket) = configured_socket_path(workspace_dir) {
        let response = request_via_docsd(
            &socket,
            &DocsdRequest {
                action: "append".to_string(),
                doc: Some(doc.to_string()),
                section: section.map(|s| s.to_string()),
                content: Some(content.to_string()),
                actor: Some(actor.to_string()),
                scaffold_dir: None,
            },
        )?;
        if response.ok {
            return Ok(());
        }
        return Err(anyhow::anyhow!(
            "docsd append failed: {}",
            response
                .message
                .unwrap_or_else(|| "unknown error".to_string())
        ));
    }

    let mut store = ManagedDocStore::open(workspace_dir)?;
    store.append_block(doc, section, content, actor)
}

pub fn replace_doc_section(
    workspace_dir: &Path,
    doc: &str,
    section: &str,
    content: &str,
    actor: &str,
) -> anyhow::Result<()> {
    if let Some(socket) = configured_socket_path(workspace_dir) {
        let response = request_via_docsd(
            &socket,
            &DocsdRequest {
                action: "replace_section".to_string(),
                doc: Some(doc.to_string()),
                section: Some(section.to_string()),
                content: Some(content.to_string()),
                actor: Some(actor.to_string()),
                scaffold_dir: None,
            },
        )?;
        if response.ok {
            return Ok(());
        }
        return Err(anyhow::anyhow!(
            "docsd replace_section failed: {}",
            response
                .message
                .unwrap_or_else(|| "unknown error".to_string())
        ));
    }

    let mut store = ManagedDocStore::open(workspace_dir)?;
    store.replace_section(doc, section, content, actor)
}

pub fn materialize_docs(workspace_dir: &Path) -> anyhow::Result<usize> {
    if let Some(socket) = configured_socket_path(workspace_dir) {
        let response = request_via_docsd(
            &socket,
            &DocsdRequest {
                action: "materialize".to_string(),
                doc: None,
                section: None,
                content: None,
                actor: Some("runtime:materialize".to_string()),
                scaffold_dir: None,
            },
        )?;
        if response.ok {
            return Ok(response.materialized_docs.unwrap_or(0));
        }
        return Err(anyhow::anyhow!(
            "docsd materialize failed: {}",
            response
                .message
                .unwrap_or_else(|| "unknown error".to_string())
        ));
    }

    let store = ManagedDocStore::open(workspace_dir)?;
    store.materialize_all_docs()
}

pub fn probe_docsd(workspace_dir: &Path) -> anyhow::Result<String> {
    let socket = configured_socket_path(workspace_dir)
        .ok_or_else(|| anyhow::anyhow!("DOCSD socket is not configured or not present"))?;
    let response = request_via_docsd(
        &socket,
        &DocsdRequest {
            action: "health".to_string(),
            doc: None,
            section: None,
            content: None,
            actor: Some("runtime:probe".to_string()),
            scaffold_dir: None,
        },
    )?;
    if response.ok {
        let detail = response
            .socket_path
            .unwrap_or_else(|| socket.display().to_string());
        Ok(format!("docsd healthy via {}", detail))
    } else {
        Err(anyhow::anyhow!(
            "docsd health check failed: {}",
            response
                .message
                .unwrap_or_else(|| "unknown error".to_string())
        ))
    }
}
