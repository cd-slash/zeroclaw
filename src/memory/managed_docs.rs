use anyhow::Context;
use chrono::Local;
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde_json::json;
use std::fs;
use std::path::{Path, PathBuf};
use uuid::Uuid;

const SNAPSHOT_INTERVAL: i64 = 200;

pub const MANAGED_TOP_LEVEL_DOCS: &[&str] = &[
    "AGENTS.md",
    "SOUL.md",
    "TOOLS.md",
    "IDENTITY.md",
    "USER.md",
    "HEARTBEAT.md",
    "BOOTSTRAP.md",
    "MEMORY.md",
];

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
enum DocEventOp {
    InitFromSeed,
    AppendBlock,
    ReplaceSection,
    ReplaceDoc,
}

impl DocEventOp {
    fn as_str(self) -> &'static str {
        match self {
            Self::InitFromSeed => "init_from_seed",
            Self::AppendBlock => "append_block",
            Self::ReplaceSection => "replace_section",
            Self::ReplaceDoc => "replace_doc",
        }
    }

    fn parse(raw: &str) -> Option<Self> {
        match raw {
            "init_from_seed" => Some(Self::InitFromSeed),
            "append_block" => Some(Self::AppendBlock),
            "replace_section" => Some(Self::ReplaceSection),
            "replace_doc" => Some(Self::ReplaceDoc),
            _ => None,
        }
    }
}

pub struct ManagedDocStore {
    workspace_dir: PathBuf,
    conn: Connection,
}

impl ManagedDocStore {
    pub fn open(workspace_dir: &Path) -> anyhow::Result<Self> {
        let db_path = workspace_dir.join("memory").join("brain.db");
        if let Some(parent) = db_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let conn = Connection::open(db_path)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA synchronous = NORMAL;
             PRAGMA temp_store = MEMORY;",
        )?;
        init_schema(&conn)?;

        Ok(Self {
            workspace_dir: workspace_dir.to_path_buf(),
            conn,
        })
    }

    pub fn seed_and_materialize(
        &mut self,
        scaffold_dir: Option<&Path>,
    ) -> anyhow::Result<ManagedDocsBootstrapReport> {
        let mut seeded = 0_usize;

        for doc in MANAGED_TOP_LEVEL_DOCS {
            if self.has_stream(doc)? {
                continue;
            }

            let seed_content = read_scaffold_doc(scaffold_dir, &self.workspace_dir, doc)
                .unwrap_or_else(|| default_doc_content(doc).to_string());
            self.append_event(doc, DocEventOp::InitFromSeed, &seed_content, "system:seed")?;
            seeded += 1;
        }

        for skill_doc in discover_skill_docs(scaffold_dir, &self.workspace_dir)? {
            if self.has_stream(&skill_doc)? {
                continue;
            }
            if let Some(seed_content) =
                read_scaffold_doc(scaffold_dir, &self.workspace_dir, &skill_doc)
            {
                self.append_event(
                    &skill_doc,
                    DocEventOp::InitFromSeed,
                    &seed_content,
                    "system:seed",
                )?;
                seeded += 1;
            }
        }

        let materialized = self.materialize_all()?;

        Ok(ManagedDocsBootstrapReport {
            seeded_docs: seeded,
            materialized_docs: materialized,
        })
    }

    pub fn read_doc(&self, doc: &str) -> anyhow::Result<Option<String>> {
        let doc_id = normalize_doc_id(doc)
            .ok_or_else(|| anyhow::anyhow!("Unsupported managed document: {doc}"))?;
        if !self.has_stream(&doc_id)? {
            return Ok(None);
        }
        self.render_doc(&doc_id).map(Some)
    }

    pub fn list_doc_ids(&self) -> anyhow::Result<Vec<String>> {
        let mut stmt = self
            .conn
            .prepare("SELECT doc_id FROM doc_streams ORDER BY doc_id ASC")?;
        let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
        let mut docs = Vec::new();
        for row in rows {
            docs.push(row?);
        }
        Ok(docs)
    }

    pub fn append_block(
        &mut self,
        doc: &str,
        section: Option<&str>,
        content: &str,
        actor: &str,
    ) -> anyhow::Result<()> {
        let doc_id = normalize_doc_id(doc)
            .ok_or_else(|| anyhow::anyhow!("Unsupported managed document: {doc}"))?;
        ensure_stream_exists(&self.conn, &doc_id)?;
        let payload = json!({
            "section": section.map(str::trim).filter(|s| !s.is_empty()),
            "content": content,
        })
        .to_string();
        self.append_event(&doc_id, DocEventOp::AppendBlock, &payload, actor)?;
        self.materialize_doc(&doc_id)?;
        Ok(())
    }

    pub fn replace_section(
        &mut self,
        doc: &str,
        section: &str,
        content: &str,
        actor: &str,
    ) -> anyhow::Result<()> {
        let doc_id = normalize_doc_id(doc)
            .ok_or_else(|| anyhow::anyhow!("Unsupported managed document: {doc}"))?;
        ensure_stream_exists(&self.conn, &doc_id)?;
        let payload = json!({
            "section": section,
            "content": content,
        })
        .to_string();
        self.append_event(&doc_id, DocEventOp::ReplaceSection, &payload, actor)?;
        self.materialize_doc(&doc_id)?;
        Ok(())
    }

    fn has_stream(&self, doc_id: &str) -> anyhow::Result<bool> {
        let count: i64 = self.conn.query_row(
            "SELECT COUNT(*) FROM doc_streams WHERE doc_id = ?1",
            params![doc_id],
            |row| row.get(0),
        )?;
        Ok(count > 0)
    }

    fn append_event(
        &mut self,
        doc_id: &str,
        op: DocEventOp,
        payload: &str,
        actor: &str,
    ) -> anyhow::Result<()> {
        let tx = self.conn.transaction()?;
        ensure_stream_exists_tx(&tx, doc_id)?;

        let current_version: i64 = tx.query_row(
            "SELECT version FROM doc_streams WHERE doc_id = ?1",
            params![doc_id],
            |row| row.get(0),
        )?;
        let next_version = current_version + 1;
        let now = Local::now().to_rfc3339();

        tx.execute(
            "INSERT INTO doc_events (event_id, doc_id, version, op, payload, actor, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                Uuid::new_v4().to_string(),
                doc_id,
                next_version,
                op.as_str(),
                payload,
                actor,
                now,
            ],
        )?;

        tx.execute(
            "UPDATE doc_streams SET version = ?1, updated_at = ?2 WHERE doc_id = ?3",
            params![next_version, now, doc_id],
        )?;

        tx.commit()?;

        if next_version % SNAPSHOT_INTERVAL == 0 {
            self.update_snapshot(doc_id, next_version)?;
        }

        Ok(())
    }

    fn update_snapshot(&self, doc_id: &str, version: i64) -> anyhow::Result<()> {
        let rendered = self.render_doc_at_version(doc_id, version)?;
        let now = Local::now().to_rfc3339();
        self.conn.execute(
            "INSERT INTO doc_snapshots (doc_id, version, content, updated_at)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(doc_id) DO UPDATE SET
               version = excluded.version,
               content = excluded.content,
               updated_at = excluded.updated_at",
            params![doc_id, version, rendered, now],
        )?;
        Ok(())
    }

    fn render_doc(&self, doc_id: &str) -> anyhow::Result<String> {
        let stream_version: i64 = self.conn.query_row(
            "SELECT version FROM doc_streams WHERE doc_id = ?1",
            params![doc_id],
            |row| row.get(0),
        )?;
        self.render_doc_at_version(doc_id, stream_version)
    }

    fn render_doc_at_version(&self, doc_id: &str, target_version: i64) -> anyhow::Result<String> {
        let snapshot: Option<(i64, String)> = self
            .conn
            .query_row(
                "SELECT version, content FROM doc_snapshots WHERE doc_id = ?1",
                params![doc_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;

        let (start_version, mut content) = match snapshot {
            Some((v, c)) if v <= target_version => (v, c),
            _ => (0, String::new()),
        };

        let mut stmt = self.conn.prepare(
            "SELECT version, op, payload
             FROM doc_events
             WHERE doc_id = ?1 AND version > ?2 AND version <= ?3
             ORDER BY version ASC",
        )?;

        let rows = stmt.query_map(params![doc_id, start_version, target_version], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        })?;

        for row in rows {
            let (_version, op_raw, payload) = row?;
            let Some(op) = DocEventOp::parse(&op_raw) else {
                tracing::warn!(
                    doc = doc_id,
                    op = op_raw,
                    "Unknown managed-doc op; skipping"
                );
                continue;
            };
            content = apply_event(&content, op, &payload)?;
        }

        Ok(normalize_trailing_newline(&content))
    }

    fn materialize_all(&self) -> anyhow::Result<usize> {
        let mut stmt = self
            .conn
            .prepare("SELECT doc_id FROM doc_streams ORDER BY doc_id ASC")?;

        let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
        let mut count = 0_usize;
        for row in rows {
            self.materialize_doc(&row?)?;
            count += 1;
        }
        Ok(count)
    }

    pub fn materialize_all_docs(&self) -> anyhow::Result<usize> {
        self.materialize_all()
    }

    fn materialize_doc(&self, doc_id: &str) -> anyhow::Result<()> {
        let content = self.render_doc(doc_id)?;
        let target = self.workspace_dir.join(doc_id);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }

        if target.exists() {
            make_writable_if_exists(&target)?;
        }
        fs::write(&target, content)?;
        set_read_only(&target)?;
        Ok(())
    }
}

pub struct ManagedDocsBootstrapReport {
    pub seeded_docs: usize,
    pub materialized_docs: usize,
}

pub fn initialize_managed_docs(
    workspace_dir: &Path,
    scaffold_dir: Option<&Path>,
) -> anyhow::Result<ManagedDocsBootstrapReport> {
    let mut store = ManagedDocStore::open(workspace_dir)?;
    store.seed_and_materialize(scaffold_dir)
}

pub fn is_managed_doc_relative_path(path: &str) -> bool {
    normalize_doc_id(path).is_some()
}

pub fn normalize_doc_id(input: &str) -> Option<String> {
    let raw = input.trim();
    if raw.is_empty() {
        return None;
    }

    let lowered = raw.to_ascii_lowercase();
    let mapped = match lowered.as_str() {
        "agents" | "agents.md" => Some("AGENTS.md".to_string()),
        "soul" | "soul.md" => Some("SOUL.md".to_string()),
        "tools" | "tools.md" => Some("TOOLS.md".to_string()),
        "identity" | "identity.md" => Some("IDENTITY.md".to_string()),
        "user" | "user.md" => Some("USER.md".to_string()),
        "heartbeat" | "heartbeat.md" => Some("HEARTBEAT.md".to_string()),
        "bootstrap" | "bootstrap.md" => Some("BOOTSTRAP.md".to_string()),
        "memory" | "memory.md" => Some("MEMORY.md".to_string()),
        _ => None,
    };
    if mapped.is_some() {
        return mapped;
    }

    let normalized = raw.replace('\\', "/");
    if normalized.contains("..") || normalized.starts_with('/') {
        return None;
    }
    if MANAGED_TOP_LEVEL_DOCS
        .iter()
        .any(|doc| normalized.eq_ignore_ascii_case(doc))
    {
        return Some(
            MANAGED_TOP_LEVEL_DOCS
                .iter()
                .find(|doc| normalized.eq_ignore_ascii_case(doc))
                .unwrap_or(&"MEMORY.md")
                .to_string(),
        );
    }

    if is_skill_doc_path(&normalized) {
        return Some(normalized);
    }

    None
}

fn init_schema(conn: &Connection) -> anyhow::Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS doc_streams (
            doc_id           TEXT PRIMARY KEY,
            version          INTEGER NOT NULL DEFAULT 0,
            snapshot_version INTEGER NOT NULL DEFAULT 0,
            created_at       TEXT NOT NULL,
            updated_at       TEXT NOT NULL
         );

         CREATE TABLE IF NOT EXISTS doc_events (
            event_id    TEXT PRIMARY KEY,
            doc_id      TEXT NOT NULL,
            version     INTEGER NOT NULL,
            op          TEXT NOT NULL,
            payload     TEXT NOT NULL,
            actor       TEXT NOT NULL,
            created_at  TEXT NOT NULL,
            UNIQUE(doc_id, version)
         );
         CREATE INDEX IF NOT EXISTS idx_doc_events_doc_version ON doc_events(doc_id, version);

         CREATE TABLE IF NOT EXISTS doc_snapshots (
            doc_id      TEXT PRIMARY KEY,
            version     INTEGER NOT NULL,
            content     TEXT NOT NULL,
            updated_at  TEXT NOT NULL
         );",
    )?;
    Ok(())
}

fn ensure_stream_exists(conn: &Connection, doc_id: &str) -> anyhow::Result<()> {
    let now = Local::now().to_rfc3339();
    conn.execute(
        "INSERT OR IGNORE INTO doc_streams (doc_id, version, snapshot_version, created_at, updated_at)
         VALUES (?1, 0, 0, ?2, ?2)",
        params![doc_id, now],
    )?;
    Ok(())
}

fn ensure_stream_exists_tx(tx: &Transaction<'_>, doc_id: &str) -> anyhow::Result<()> {
    let now = Local::now().to_rfc3339();
    tx.execute(
        "INSERT OR IGNORE INTO doc_streams (doc_id, version, snapshot_version, created_at, updated_at)
         VALUES (?1, 0, 0, ?2, ?2)",
        params![doc_id, now],
    )?;
    Ok(())
}

fn apply_event(current: &str, op: DocEventOp, payload: &str) -> anyhow::Result<String> {
    match op {
        DocEventOp::InitFromSeed | DocEventOp::ReplaceDoc => Ok(payload.to_string()),
        DocEventOp::AppendBlock => {
            let parsed: serde_json::Value =
                serde_json::from_str(payload).with_context(|| "Invalid append_block payload")?;
            let section = parsed
                .get("section")
                .and_then(serde_json::Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty());
            let block_content = parsed
                .get("content")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("")
                .trim();
            if block_content.is_empty() {
                return Ok(current.to_string());
            }

            let block = match section {
                Some(s) => format!("## {s}\n{block_content}"),
                None => block_content.to_string(),
            };
            Ok(append_block_markdown(current, &block))
        }
        DocEventOp::ReplaceSection => {
            let parsed: serde_json::Value =
                serde_json::from_str(payload).with_context(|| "Invalid replace_section payload")?;
            let section = parsed
                .get("section")
                .and_then(serde_json::Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| anyhow::anyhow!("replace_section requires non-empty section"))?;

            let replacement = parsed
                .get("content")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("")
                .trim();
            Ok(replace_markdown_section(current, section, replacement))
        }
    }
}

fn append_block_markdown(current: &str, block: &str) -> String {
    if current.trim().is_empty() {
        return format!("{}\n", block.trim());
    }

    let mut out = current.trim_end().to_string();
    out.push_str("\n\n");
    out.push_str(block.trim());
    out.push('\n');
    out
}

fn replace_markdown_section(doc: &str, section: &str, replacement: &str) -> String {
    let heading = format!("## {section}");
    let lines: Vec<&str> = doc.lines().collect();
    let start = lines.iter().position(|line| line.trim() == heading);

    if let Some(start_idx) = start {
        let end_idx = lines
            .iter()
            .enumerate()
            .skip(start_idx + 1)
            .find(|(_, line)| line.trim_start().starts_with("## "))
            .map(|(idx, _)| idx)
            .unwrap_or(lines.len());

        let before = lines[..start_idx].join("\n");
        let after = lines[end_idx..].join("\n");
        let section_block = format!("{heading}\n{replacement}");

        return join_markdown_chunks(&[before.as_str(), section_block.as_str(), after.as_str()]);
    }

    append_block_markdown(doc, &format!("{heading}\n{replacement}"))
}

fn join_markdown_chunks(chunks: &[&str]) -> String {
    let kept: Vec<String> = chunks
        .iter()
        .map(|chunk| chunk.trim())
        .filter(|chunk| !chunk.is_empty())
        .map(std::string::ToString::to_string)
        .collect();

    if kept.is_empty() {
        String::new()
    } else {
        format!("{}\n", kept.join("\n\n"))
    }
}

fn normalize_trailing_newline(content: &str) -> String {
    if content.trim().is_empty() {
        String::new()
    } else {
        format!("{}\n", content.trim_end())
    }
}

fn is_skill_doc_path(path: &str) -> bool {
    if !path.starts_with("skills/") || !path.ends_with("/SKILL.md") {
        return false;
    }
    let parts: Vec<&str> = path.split('/').collect();
    if parts.len() != 3 {
        return false;
    }
    let skill_name = parts[1];
    !skill_name.is_empty()
        && !skill_name.contains("..")
        && skill_name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

fn discover_skill_docs(
    scaffold_dir: Option<&Path>,
    workspace_dir: &Path,
) -> anyhow::Result<Vec<String>> {
    let mut docs = Vec::new();
    for base in [scaffold_dir, Some(workspace_dir)] {
        let Some(base) = base else {
            continue;
        };
        let skills_dir = base.join("skills");
        if !skills_dir.exists() {
            continue;
        }
        for entry in fs::read_dir(&skills_dir)? {
            let entry = entry?;
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let Some(name) = path.file_name().and_then(|s| s.to_str()) else {
                continue;
            };
            let doc_id = format!("skills/{name}/SKILL.md");
            if is_skill_doc_path(&doc_id) && path.join("SKILL.md").exists() {
                docs.push(doc_id);
            }
        }
    }
    docs.sort();
    docs.dedup();
    Ok(docs)
}

fn read_scaffold_doc(
    scaffold_dir: Option<&Path>,
    workspace_dir: &Path,
    doc_id: &str,
) -> Option<String> {
    for base in [scaffold_dir, Some(workspace_dir)] {
        let Some(base) = base else {
            continue;
        };
        let path = base.join(doc_id);
        if path.exists() {
            if let Ok(content) = fs::read_to_string(path) {
                if !content.trim().is_empty() {
                    return Some(content);
                }
            }
        }
    }
    None
}

fn default_doc_content(doc_id: &str) -> &'static str {
    match doc_id {
        "AGENTS.md" => {
            "# AGENTS.md\n\nManaged by ZeroClaw event-sourced docs. Use docs_* tools to update this file.\n"
        }
        "SOUL.md" => {
            "# SOUL.md\n\nManaged by ZeroClaw event-sourced docs. Use docs_* tools to update this file.\n"
        }
        "TOOLS.md" => {
            "# TOOLS.md\n\nManaged by ZeroClaw event-sourced docs. Use docs_* tools to update this file.\n"
        }
        "IDENTITY.md" => {
            "# IDENTITY.md\n\nManaged by ZeroClaw event-sourced docs. Use docs_* tools to update this file.\n"
        }
        "USER.md" => {
            "# USER.md\n\nManaged by ZeroClaw event-sourced docs. Use docs_* tools to update this file.\n"
        }
        "HEARTBEAT.md" => {
            "# HEARTBEAT.md\n\nManaged by ZeroClaw event-sourced docs. Use docs_* tools to update this file.\n"
        }
        "BOOTSTRAP.md" => {
            "# BOOTSTRAP.md\n\nManaged by ZeroClaw event-sourced docs. Use docs_* tools to update this file.\n"
        }
        "MEMORY.md" => {
            "# MEMORY.md — Long-Term Memory\n\nThis file is managed by ZeroClaw event-sourced docs. Use docs_append/docs_replace_section for updates.\n"
        }
        _ => "# Managed Document\n",
    }
}

fn make_writable_if_exists(path: &Path) -> anyhow::Result<()> {
    if !path.exists() {
        return Ok(());
    }
    let mut perms = fs::metadata(path)?.permissions();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        perms.set_mode(0o644);
        fs::set_permissions(path, perms)?;
    }
    #[cfg(not(unix))]
    {
        perms.set_readonly(false);
        fs::set_permissions(path, perms)?;
    }
    Ok(())
}

fn set_read_only(path: &Path) -> anyhow::Result<()> {
    let mut perms = fs::metadata(path)?.permissions();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        perms.set_mode(0o444);
        fs::set_permissions(path, perms)?;
    }
    #[cfg(not(unix))]
    {
        perms.set_readonly(true);
        fs::set_permissions(path, perms)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn normalize_doc_id_handles_shorthand_and_skill_docs() {
        assert_eq!(normalize_doc_id("memory"), Some("MEMORY.md".to_string()));
        assert_eq!(
            normalize_doc_id("skills/git/SKILL.md"),
            Some("skills/git/SKILL.md".to_string())
        );
        assert_eq!(normalize_doc_id("../../etc/passwd"), None);
    }

    #[test]
    fn replace_section_updates_existing_heading() {
        let doc = "# Memory\n\n## Open Loops\nA\n\n## Other\nB\n";
        let updated = replace_markdown_section(doc, "Open Loops", "C");
        assert!(updated.contains("## Open Loops\nC"));
        assert!(updated.contains("## Other\nB"));
        assert!(!updated.contains("## Open Loops\nA"));
    }

    #[test]
    fn append_block_keeps_existing_content() {
        let base = "# MEMORY.md\n";
        let appended = append_block_markdown(base, "## Lessons\nNew");
        assert!(appended.contains("# MEMORY.md"));
        assert!(appended.contains("## Lessons\nNew"));
    }

    #[test]
    fn bootstrap_seeds_and_materializes_docs() {
        let tmp = TempDir::new().unwrap();
        let workspace = tmp.path();

        let report = initialize_managed_docs(workspace, None).unwrap();
        assert!(report.seeded_docs >= MANAGED_TOP_LEVEL_DOCS.len());
        assert!(workspace.join("MEMORY.md").exists());
        assert!(workspace.join("AGENTS.md").exists());
    }

    #[test]
    fn append_and_read_roundtrip() {
        let tmp = TempDir::new().unwrap();
        let workspace = tmp.path();
        let mut store = ManagedDocStore::open(workspace).unwrap();
        store.seed_and_materialize(None).unwrap();

        store
            .append_block(
                "memory",
                Some("Lessons Learned"),
                "Prefer deterministic tests",
                "tool:docs_append",
            )
            .unwrap();

        let rendered = store.read_doc("MEMORY.md").unwrap().unwrap();
        assert!(rendered.contains("## Lessons Learned"));
        assert!(rendered.contains("Prefer deterministic tests"));
    }
}
