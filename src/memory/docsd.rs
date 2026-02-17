use crate::memory::managed_docs::{initialize_managed_docs, normalize_doc_id, ManagedDocStore};
use anyhow::Context;
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::{Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};

#[derive(Debug, Serialize, Deserialize)]
pub struct DocsdRequest {
    pub action: String,
    pub doc: Option<String>,
    pub section: Option<String>,
    pub content: Option<String>,
    pub actor: Option<String>,
    pub scaffold_dir: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct DocsdResponse {
    pub ok: bool,
    pub message: Option<String>,
    pub content: Option<String>,
    pub docs: Option<Vec<String>>,
    pub seeded_docs: Option<usize>,
    pub materialized_docs: Option<usize>,
    pub socket_path: Option<String>,
}

impl DocsdResponse {
    fn ok_message(message: impl Into<String>) -> Self {
        Self {
            ok: true,
            message: Some(message.into()),
            content: None,
            docs: None,
            seeded_docs: None,
            materialized_docs: None,
            socket_path: None,
        }
    }

    fn error(message: impl Into<String>) -> Self {
        Self {
            ok: false,
            message: Some(message.into()),
            content: None,
            docs: None,
            seeded_docs: None,
            materialized_docs: None,
            socket_path: None,
        }
    }
}

pub fn serve(
    socket_path: &Path,
    workspace_dir: &Path,
    scaffold_dir: Option<&Path>,
) -> anyhow::Result<()> {
    if let Some(parent) = socket_path.parent() {
        fs::create_dir_all(parent)?;
    }

    let init = initialize_managed_docs(workspace_dir, scaffold_dir)?;
    tracing::info!(
        socket = %socket_path.display(),
        seeded = init.seeded_docs,
        materialized = init.materialized_docs,
        "docsd initialized managed docs"
    );

    if socket_path.exists() {
        fs::remove_file(socket_path)
            .with_context(|| format!("failed to remove stale socket {}", socket_path.display()))?;
    }

    let listener = UnixListener::bind(socket_path)
        .with_context(|| format!("failed to bind docsd socket at {}", socket_path.display()))?;
    fs::set_permissions(socket_path, fs::Permissions::from_mode(0o660))?;

    tracing::info!(socket = %socket_path.display(), "docsd listening");

    for stream in listener.incoming() {
        match stream {
            Ok(mut stream) => {
                if let Err(e) = handle_client(&mut stream, workspace_dir, scaffold_dir) {
                    let fallback = DocsdResponse::error(format!("docsd request failed: {e}"));
                    let _ = write_response(&mut stream, &fallback);
                    tracing::warn!(error = %e, "docsd request failed");
                }
            }
            Err(e) => tracing::warn!(error = %e, "docsd socket accept failed"),
        }
    }

    Ok(())
}

fn handle_client(
    stream: &mut UnixStream,
    workspace_dir: &Path,
    default_scaffold_dir: Option<&Path>,
) -> anyhow::Result<()> {
    let mut buf = Vec::new();
    stream.read_to_end(&mut buf)?;
    let raw = String::from_utf8(buf).context("docsd request was not utf8")?;
    let req: DocsdRequest = serde_json::from_str(&raw).context("docsd invalid request json")?;

    let mut store = ManagedDocStore::open(workspace_dir)?;
    let resp = match req.action.as_str() {
        "init" => {
            let scaffold = req
                .scaffold_dir
                .as_deref()
                .map(PathBuf::from)
                .or_else(|| default_scaffold_dir.map(Path::to_path_buf));
            let report = store.seed_and_materialize(scaffold.as_deref())?;
            DocsdResponse {
                ok: true,
                message: Some("managed docs initialized".to_string()),
                content: None,
                docs: None,
                seeded_docs: Some(report.seeded_docs),
                materialized_docs: Some(report.materialized_docs),
                socket_path: None,
            }
        }
        "health" => DocsdResponse {
            ok: true,
            message: Some("docsd healthy".to_string()),
            content: None,
            docs: None,
            seeded_docs: None,
            materialized_docs: None,
            socket_path: Some(
                std::env::var("DOCSD_SOCKET").unwrap_or_else(|_| "(default)".to_string()),
            ),
        },
        "list" => DocsdResponse {
            ok: true,
            message: None,
            content: None,
            docs: Some(store.list_doc_ids()?),
            seeded_docs: None,
            materialized_docs: None,
            socket_path: None,
        },
        "read" => {
            let doc = req.doc.unwrap_or_default();
            let doc_id = match normalize_doc_id(&doc) {
                Some(id) => id,
                None => {
                    return write_response(
                        stream,
                        &DocsdResponse::error(format!("unsupported managed document: {doc}")),
                    )
                }
            };
            match store.read_doc(&doc_id)? {
                Some(content) => DocsdResponse {
                    ok: true,
                    message: None,
                    content: Some(content),
                    docs: None,
                    seeded_docs: None,
                    materialized_docs: None,
                    socket_path: None,
                },
                None => DocsdResponse::error(format!("managed document not initialized: {doc_id}")),
            }
        }
        "append" => {
            let doc = req.doc.unwrap_or_default();
            let doc_id = match normalize_doc_id(&doc) {
                Some(id) => id,
                None => {
                    return write_response(
                        stream,
                        &DocsdResponse::error(format!("unsupported managed document: {doc}")),
                    )
                }
            };
            let content = req.content.unwrap_or_default();
            let actor = req.actor.unwrap_or_else(|| "docsd:unknown".to_string());
            store.append_block(&doc_id, req.section.as_deref(), &content, &actor)?;
            DocsdResponse::ok_message(format!("appended content to {doc_id}"))
        }
        "replace_section" => {
            let doc = req.doc.unwrap_or_default();
            let doc_id = match normalize_doc_id(&doc) {
                Some(id) => id,
                None => {
                    return write_response(
                        stream,
                        &DocsdResponse::error(format!("unsupported managed document: {doc}")),
                    )
                }
            };
            let section = req.section.unwrap_or_default();
            let content = req.content.unwrap_or_default();
            let actor = req.actor.unwrap_or_else(|| "docsd:unknown".to_string());
            if section.trim().is_empty() {
                DocsdResponse::error("replace_section requires non-empty section")
            } else {
                store.replace_section(&doc_id, &section, &content, &actor)?;
                DocsdResponse::ok_message(format!("updated section '{section}' in {doc_id}"))
            }
        }
        "materialize" => {
            let count = store.materialize_all_docs()?;
            DocsdResponse {
                ok: true,
                message: Some(format!("materialized {count} managed docs")),
                content: None,
                docs: None,
                seeded_docs: None,
                materialized_docs: Some(count),
                socket_path: None,
            }
        }
        other => DocsdResponse::error(format!("unsupported action: {other}")),
    };

    write_response(stream, &resp)
}

fn write_response(stream: &mut UnixStream, response: &DocsdResponse) -> anyhow::Result<()> {
    let raw = serde_json::to_vec(response)?;
    stream.write_all(&raw)?;
    stream.flush()?;
    Ok(())
}
