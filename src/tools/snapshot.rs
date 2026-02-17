use super::traits::{Tool, ToolResult};
use async_trait::async_trait;
use serde_json::json;
use std::path::PathBuf;
use std::time::Duration;
use tokio::fs;
use tokio::time::sleep;

/// Database snapshot tool - allows agents to create point-in-time snapshots
/// of their SQLite memory database and rollback to previous states.
///
/// This is useful for:
/// - Creating checkpoints before risky memory operations
/// - Experimenting with different memory states
/// - Recovering from memory corruption or unwanted changes
/// - A/B testing different memory configurations
pub struct SnapshotTool {
    workspace_dir: PathBuf,
}

impl SnapshotTool {
    pub fn new(workspace_dir: PathBuf) -> Self {
        Self { workspace_dir }
    }

    fn get_db_path(&self) -> PathBuf {
        self.workspace_dir.join(".zeroclaw").join("memory.db")
    }

    fn get_snapshot_dir(&self) -> PathBuf {
        self.workspace_dir.join(".zeroclaw").join("snapshots")
    }

    fn get_wal_path(&self) -> PathBuf {
        self.workspace_dir.join(".zeroclaw").join("memory.db-wal")
    }

    fn get_shm_path(&self) -> PathBuf {
        self.workspace_dir.join(".zeroclaw").join("memory.db-shm")
    }

    /// Create a snapshot of the current database state
    async fn create_snapshot(&self, name: Option<&str>) -> anyhow::Result<String> {
        let db_path = self.get_db_path();

        if !db_path.exists() {
            return Err(anyhow::anyhow!(
                "SQLite database not found at {}. Are you using the SQLite memory backend?",
                db_path.display()
            ));
        }

        let snapshot_dir = self.get_snapshot_dir();
        fs::create_dir_all(&snapshot_dir).await?;

        // Generate snapshot filename
        let timestamp = chrono::Local::now().format("%Y%m%d-%H%M%S").to_string();
        let snapshot_name = name
            .map(|n| format!("{}-{}", n, timestamp))
            .unwrap_or_else(|| format!("snapshot-{}", timestamp));
        let snapshot_path = snapshot_dir.join(format!("{}.db", snapshot_name));
        let metadata_path = snapshot_dir.join(format!("{}.json", snapshot_name));

        // First, checkpoint WAL to ensure database is consistent
        self.checkpoint_wal().await?;

        // Copy the database file
        fs::copy(&db_path, &snapshot_path).await?;

        // Create metadata
        let metadata = json!({
            "name": snapshot_name,
            "created_at": chrono::Local::now().to_rfc3339(),
            "original_db": db_path.to_string_lossy().to_string(),
            "snapshot_file": snapshot_path.to_string_lossy().to_string(),
        });
        fs::write(&metadata_path, metadata.to_string()).await?;

        // Get file sizes
        let db_size = fs::metadata(&db_path).await?.len();
        let db_size_mb = db_size as f64 / 1024.0 / 1024.0;

        Ok(format!(
            "Snapshot created: {} ({:.2} MB)",
            snapshot_name, db_size_mb
        ))
    }

    /// Checkpoint WAL to ensure database consistency before snapshot
    async fn checkpoint_wal(&self) -> anyhow::Result<()> {
        // Use sqlite3 command to checkpoint if available
        let db_path = self.get_db_path();

        match std::process::Command::new("sqlite3")
            .arg(&db_path)
            .arg("PRAGMA wal_checkpoint(TRUNCATE);")
            .output()
        {
            Ok(output) if output.status.success() => Ok(()),
            _ => {
                // If sqlite3 command not available or fails,
                // just wait a moment for any pending writes
                sleep(Duration::from_millis(100)).await;
                Ok(())
            }
        }
    }

    /// List all available snapshots
    async fn list_snapshots(&self) -> anyhow::Result<String> {
        let snapshot_dir = self.get_snapshot_dir();

        if !snapshot_dir.exists() {
            return Ok(
                "No snapshots found. Create one with: snapshot action=\"create\"".to_string(),
            );
        }

        let mut entries = fs::read_dir(&snapshot_dir).await?;
        let mut snapshots = Vec::new();

        while let Some(entry) = entries.next_entry().await? {
            let path = entry.path();
            if let Some(ext) = path.extension() {
                if ext == "db" {
                    let name = path
                        .file_stem()
                        .and_then(|s| s.to_str())
                        .unwrap_or("unknown")
                        .to_string();

                    let metadata_path = path.with_extension("json");
                    let created_at = if metadata_path.exists() {
                        match fs::read_to_string(&metadata_path).await {
                            Ok(content) => serde_json::from_str::<serde_json::Value>(&content)
                                .ok()
                                .and_then(|v| {
                                    v.get("created_at")
                                        .and_then(|c| c.as_str())
                                        .map(|s| s.to_string())
                                })
                                .unwrap_or_else(|| "unknown".to_string()),
                            Err(_) => "unknown".to_string(),
                        }
                    } else {
                        "unknown".to_string()
                    };

                    let size = match fs::metadata(&path).await {
                        Ok(m) => format!("{:.2} MB", m.len() as f64 / 1024.0 / 1024.0),
                        Err(_) => "unknown size".to_string(),
                    };

                    snapshots.push((name, created_at, size));
                }
            }
        }

        if snapshots.is_empty() {
            return Ok(
                "No snapshots found. Create one with: snapshot action=\"create\"".to_string(),
            );
        }

        // Sort by creation time (newest first)
        snapshots.sort_by(|a, b| b.1.cmp(&a.1));

        let mut result = String::from("Available snapshots:\n");
        for (name, created, size) in snapshots {
            result.push_str(&format!("  • {} (created: {}, {})\n", name, created, size));
        }

        Ok(result)
    }

    /// Rollback to a snapshot
    async fn rollback(&self, snapshot_name: &str) -> anyhow::Result<String> {
        let snapshot_dir = self.get_snapshot_dir();
        let snapshot_path = snapshot_dir.join(format!("{}.db", snapshot_name));
        let db_path = self.get_db_path();

        if !snapshot_path.exists() {
            return Err(anyhow::anyhow!(
                "Snapshot '{}' not found. Use snapshot action=\"list\" to see available snapshots.",
                snapshot_name
            ));
        }

        if !db_path.exists() {
            return Err(anyhow::anyhow!(
                "Current database not found at {}. Cannot rollback.",
                db_path.display()
            ));
        }

        // Verify snapshot is a valid SQLite database
        if !self.verify_sqlite(&snapshot_path).await? {
            return Err(anyhow::anyhow!(
                "Snapshot '{}' does not appear to be a valid SQLite database.",
                snapshot_name
            ));
        }

        // Create backup of current state before rollback
        let backup_name = format!(
            "pre-rollback-{}-{}",
            snapshot_name,
            chrono::Local::now().format("%Y%m%d-%H%M%S")
        );
        let backup_path = snapshot_dir.join(format!("{}.db", backup_name));
        fs::copy(&db_path, &backup_path).await?;

        // Remove WAL and SHM files if they exist
        let wal_path = self.get_wal_path();
        let shm_path = self.get_shm_path();

        let _ = fs::remove_file(&wal_path).await;
        let _ = fs::remove_file(&shm_path).await;

        // Copy snapshot to current database location
        fs::copy(&snapshot_path, &db_path).await?;

        Ok(format!(
            "Rollback successful. Database restored to snapshot: {}\nPre-rollback backup created: {}",
            snapshot_name,
            backup_name
        ))
    }

    /// Delete a snapshot
    async fn delete_snapshot(&self, snapshot_name: &str) -> anyhow::Result<String> {
        let snapshot_dir = self.get_snapshot_dir();
        let snapshot_path = snapshot_dir.join(format!("{}.db", snapshot_name));
        let metadata_path = snapshot_dir.join(format!("{}.json", snapshot_name));

        if !snapshot_path.exists() {
            return Err(anyhow::anyhow!("Snapshot '{}' not found.", snapshot_name));
        }

        fs::remove_file(&snapshot_path).await?;

        // Also delete metadata if it exists
        if metadata_path.exists() {
            fs::remove_file(&metadata_path).await?;
        }

        Ok(format!("Snapshot '{}' deleted.", snapshot_name))
    }

    /// Verify a file is a valid SQLite database
    async fn verify_sqlite(&self, path: &PathBuf) -> anyhow::Result<bool> {
        match fs::read(path).await {
            Ok(bytes) if bytes.len() >= 16 => {
                // Check SQLite magic number
                let header = &bytes[0..16];
                Ok(header.starts_with(b"SQLite format 3"))
            }
            _ => Ok(false),
        }
    }
}

#[async_trait]
impl Tool for SnapshotTool {
    fn name(&self) -> &str {
        "snapshot_memory"
    }

    fn description(&self) -> &str {
        "Create, manage, and rollback point-in-time snapshots of the SQLite memory database. \
         Use this before risky memory operations, experiments, or when you want the ability to \
         undo changes to your memory database. Each snapshot is a complete copy of the database \
         at a specific moment."
    }

    fn parameters_schema(&self) -> serde_json::Value {
        json!({
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": ["create", "list", "rollback", "delete"],
                    "description": "Action to perform: 'create' a new snapshot, 'list' available snapshots, 'rollback' to a snapshot, or 'delete' a snapshot"
                },
                "name": {
                    "type": "string",
                    "description": "For 'create' action: optional name for the snapshot (will be prefixed with timestamp)"
                },
                "snapshot": {
                    "type": "string",
                    "description": "For 'rollback' or 'delete' action: name of the snapshot to rollback to or delete"
                }
            },
            "required": ["action"]
        })
    }

    async fn execute(&self, args: serde_json::Value) -> anyhow::Result<ToolResult> {
        let action = args
            .get("action")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow::anyhow!("Missing 'action' parameter"))?;

        match action {
            "create" => {
                let name = args.get("name").and_then(|v| v.as_str());

                match self.create_snapshot(name).await {
                    Ok(message) => Ok(ToolResult {
                        success: true,
                        output: message,
                        error: None,
                    }),
                    Err(e) => Ok(ToolResult {
                        success: false,
                        output: String::new(),
                        error: Some(format!("Failed to create snapshot: {}", e)),
                    }),
                }
            }
            "list" => match self.list_snapshots().await {
                Ok(message) => Ok(ToolResult {
                    success: true,
                    output: message,
                    error: None,
                }),
                Err(e) => Ok(ToolResult {
                    success: false,
                    output: String::new(),
                    error: Some(format!("Failed to list snapshots: {}", e)),
                }),
            },
            "rollback" => {
                let snapshot = args
                    .get("snapshot")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| {
                        anyhow::anyhow!("Missing 'snapshot' parameter for rollback action")
                    })?;

                match self.rollback(snapshot).await {
                    Ok(message) => Ok(ToolResult {
                        success: true,
                        output: message,
                        error: None,
                    }),
                    Err(e) => Ok(ToolResult {
                        success: false,
                        output: String::new(),
                        error: Some(format!("Failed to rollback: {}", e)),
                    }),
                }
            }
            "delete" => {
                let snapshot = args
                    .get("snapshot")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| {
                        anyhow::anyhow!("Missing 'snapshot' parameter for delete action")
                    })?;

                match self.delete_snapshot(snapshot).await {
                    Ok(message) => Ok(ToolResult {
                        success: true,
                        output: message,
                        error: None,
                    }),
                    Err(e) => Ok(ToolResult {
                        success: false,
                        output: String::new(),
                        error: Some(format!("Failed to delete snapshot: {}", e)),
                    }),
                }
            }
            _ => Ok(ToolResult {
                success: false,
                output: String::new(),
                error: Some(format!("Unknown action: {}", action)),
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[tokio::test]
    async fn test_snapshot_tool_spec() {
        let temp_dir = TempDir::new().unwrap();
        let tool = SnapshotTool::new(temp_dir.path().to_path_buf());

        assert_eq!(tool.name(), "snapshot_memory");
        assert!(!tool.description().is_empty());

        let schema = tool.parameters_schema();
        assert_eq!(schema["type"], "object");
        assert!(schema["properties"]["action"]["enum"]
            .as_array()
            .unwrap()
            .contains(&json!("create")));
    }

    #[tokio::test]
    async fn test_create_snapshot_no_database() {
        let temp_dir = TempDir::new().unwrap();
        let tool = SnapshotTool::new(temp_dir.path().to_path_buf());

        // Try to create snapshot without database
        let result = tool.create_snapshot(None).await;
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .to_string()
            .contains("SQLite database not found"));
    }

    #[tokio::test]
    async fn test_list_snapshots_empty() {
        let temp_dir = TempDir::new().unwrap();
        let tool = SnapshotTool::new(temp_dir.path().to_path_buf());

        let result = tool.list_snapshots().await;
        assert!(result.is_ok());
        assert!(result.unwrap().contains("No snapshots found"));
    }

    #[tokio::test]
    async fn test_verify_sqlite() {
        let temp_dir = TempDir::new().unwrap();
        let tool = SnapshotTool::new(temp_dir.path().to_path_buf());

        // Create a fake SQLite file header
        let fake_db = temp_dir.path().join("fake.db");
        fs::write(&fake_db, b"SQLite format 3\x00").await.unwrap();

        let is_valid = tool.verify_sqlite(&fake_db).await.unwrap();
        assert!(is_valid);

        // Create invalid file
        let invalid = temp_dir.path().join("invalid.db");
        fs::write(&invalid, b"not a database").await.unwrap();

        let is_invalid = tool.verify_sqlite(&invalid).await.unwrap();
        assert!(!is_invalid);
    }
}
