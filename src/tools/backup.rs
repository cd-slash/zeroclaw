use super::traits::{Tool, ToolResult};
use async_trait::async_trait;
use serde_json::json;
use std::path::PathBuf;
use std::process::Command;

/// Backup tool - allows agents to backup their own workspace
///
/// This tool creates a gzipped tar archive of the agent's workspace
/// and optionally syncs it to MinIO for remote storage.
///
/// Config files can be included by setting the `AGENT_CONFIG_DIR` environment variable.
pub struct BackupTool {
    workspace_dir: PathBuf,
}

impl BackupTool {
    pub fn new(workspace_dir: PathBuf) -> Self {
        Self { workspace_dir }
    }

    /// Get the agent config directory from environment, if set
    fn get_config_dir(&self) -> Option<PathBuf> {
        std::env::var("AGENT_CONFIG_DIR")
            .ok()
            .map(PathBuf::from)
            .filter(|p| p.exists())
    }

    /// Create a backup archive of the workspace and config (if available)
    async fn create_backup(&self, destination: &str) -> anyhow::Result<String> {
        let timestamp = chrono::Local::now().format("%Y%m%d-%H%M%S").to_string();
        let backup_name = format!("self-backup-{}.tar.gz", timestamp);
        let backup_path = PathBuf::from(destination).join(&backup_name);

        // Ensure destination directory exists
        tokio::fs::create_dir_all(destination).await?;

        // Check if we have a config directory to include
        let config_dir = self.get_config_dir();

        let output = if let Some(ref config) = config_dir {
            // Create backup including both workspace and config
            let workspace = self.workspace_dir.to_str().unwrap_or("/zeroclaw-data");
            let _config_path = config.to_str().unwrap_or("/agent-config");
            let config_parent = config
                .parent()
                .and_then(|p| p.to_str())
                .unwrap_or("/agent-config");
            let config_name = config
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("config");

            // Use tar with multiple directories
            Command::new("tar")
                .args(&[
                    "czf",
                    backup_path.to_str().unwrap_or("/tmp/backup.tar.gz"),
                    "-C",
                    workspace,
                    ".",
                    "-C",
                    config_parent,
                    config_name,
                ])
                .output()?
        } else {
            // Simple workspace-only backup
            Command::new("tar")
                .args(&[
                    "czf",
                    backup_path.to_str().unwrap_or("/tmp/backup.tar.gz"),
                    "-C",
                    self.workspace_dir.to_str().unwrap_or("/zeroclaw-data"),
                    ".",
                ])
                .output()?
        };

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(anyhow::anyhow!("Failed to create backup: {}", stderr));
        }

        // Get file size
        let metadata = tokio::fs::metadata(&backup_path).await?;
        let size_bytes = metadata.len();
        let size_mb = size_bytes as f64 / 1024.0 / 1024.0;

        let mut message = format!(
            "Backup created successfully: {} ({:.2} MB)",
            backup_path.display(),
            size_mb
        );

        if let Some(config) = config_dir {
            message.push_str(&format!(" (including config from {})", config.display()));
        }

        Ok(message)
    }

    /// Sync backup to MinIO if credentials are available
    async fn sync_to_minio(&self, backup_path: &str) -> anyhow::Result<String> {
        // Check for MinIO credentials in environment
        let endpoint = std::env::var("MINIO_ENDPOINT").ok();
        let access_key = std::env::var("MINIO_ACCESS_KEY").ok();
        let secret_key = std::env::var("MINIO_SECRET_KEY").ok();
        let bucket =
            std::env::var("MINIO_BUCKET").unwrap_or_else(|_| "zeroclaw-backups".to_string());

        // Check if MinIO is configured
        if endpoint.is_none() || access_key.is_none() || secret_key.is_none() {
            return Err(anyhow::anyhow!(
                "MinIO not configured. Set MINIO_ENDPOINT, MINIO_ACCESS_KEY, and MINIO_SECRET_KEY environment variables."
            ));
        }

        let endpoint = endpoint.unwrap();
        let backup_file = std::path::Path::new(backup_path)
            .file_name()
            .and_then(|f| f.to_str())
            .ok_or_else(|| anyhow::anyhow!("Invalid backup path"))?;

        // Try using mc (MinIO client) first
        let mc_result = Command::new("mc")
            .args(&[
                "alias",
                "set",
                "myminio",
                &endpoint,
                &access_key.unwrap(),
                &secret_key.unwrap(),
            ])
            .output();

        if let Ok(output) = mc_result {
            if output.status.success() {
                // Ensure bucket exists
                let _ = Command::new("mc")
                    .args(&["mb", &format!("myminio/{}", bucket)])
                    .output();

                // Upload backup
                let upload = Command::new("mc")
                    .args(&[
                        "cp",
                        backup_path,
                        &format!("myminio/{}/self-backups/", bucket),
                    ])
                    .output()?;

                if upload.status.success() {
                    return Ok(format!(
                        "Backup synced to MinIO: {}/self-backups/{}",
                        bucket, backup_file
                    ));
                }
            }
        }

        // Fallback to AWS CLI with MinIO endpoint
        let upload = Command::new("aws")
            .args(&[
                "--endpoint-url",
                &endpoint,
                "s3",
                "cp",
                backup_path,
                &format!("s3://{}/self-backups/{}", bucket, backup_file),
            ])
            .env(
                "AWS_ACCESS_KEY_ID",
                std::env::var("MINIO_ACCESS_KEY").unwrap_or_default(),
            )
            .env(
                "AWS_SECRET_ACCESS_KEY",
                std::env::var("MINIO_SECRET_KEY").unwrap_or_default(),
            )
            .output()?;

        if upload.status.success() {
            Ok(format!(
                "Backup synced to MinIO: {}/self-backups/{}",
                bucket, backup_file
            ))
        } else {
            let stderr = String::from_utf8_lossy(&upload.stderr);
            Err(anyhow::anyhow!("Failed to sync to MinIO: {}", stderr))
        }
    }

    /// List available self-backups
    async fn list_backups(&self, location: &str) -> anyhow::Result<String> {
        let mut result = String::new();

        // List local backups
        if location == "local" || location == "all" {
            result.push_str("Local backups:\n");
            let backup_dir = PathBuf::from("/zeroclaw-data/.zeroclaw/backups");

            if let Ok(entries) = tokio::fs::read_dir(&backup_dir).await {
                let mut entries = entries;
                while let Ok(Some(entry)) = entries.next_entry().await {
                    let name = entry.file_name();
                    let name_str = name.to_string_lossy();
                    if name_str.starts_with("self-backup-") && name_str.ends_with(".tar.gz") {
                        if let Ok(metadata) = entry.metadata().await {
                            let size_mb = metadata.len() as f64 / 1024.0 / 1024.0;
                            result.push_str(&format!("  - {} ({:.2} MB)\n", name_str, size_mb));
                        }
                    }
                }
            }

            if result == "Local backups:\n" {
                result.push_str("  No local backups found\n");
            }
        }

        // List MinIO backups
        if location == "minio" || location == "all" {
            if let (Ok(endpoint), Ok(_), Ok(_)) = (
                std::env::var("MINIO_ENDPOINT"),
                std::env::var("MINIO_ACCESS_KEY"),
                std::env::var("MINIO_SECRET_KEY"),
            ) {
                let bucket = std::env::var("MINIO_BUCKET")
                    .unwrap_or_else(|_| "zeroclaw-backups".to_string());

                result.push_str("\nMinIO backups:\n");

                // Try using mc
                let mc_result = Command::new("mc")
                    .args(&["ls", &format!("myminio/{}/self-backups/", bucket), "--json"])
                    .env("MC_HOST_myminio", format!("{}", endpoint))
                    .output();

                if let Ok(output) = mc_result {
                    if output.status.success() {
                        let stdout = String::from_utf8_lossy(&output.stdout);
                        for line in stdout.lines() {
                            if let Ok(json) = serde_json::from_str::<serde_json::Value>(line) {
                                if let Some(key) = json.get("key").and_then(|k| k.as_str()) {
                                    result.push_str(&format!("  - {}\n", key));
                                }
                            }
                        }
                    }
                }

                // Fallback to AWS CLI
                if !result.contains("  - ") {
                    let aws_result = Command::new("aws")
                        .args(&[
                            "--endpoint-url",
                            &endpoint,
                            "s3",
                            "ls",
                            &format!("s3://{}/self-backups/", bucket),
                        ])
                        .env(
                            "AWS_ACCESS_KEY_ID",
                            std::env::var("MINIO_ACCESS_KEY").unwrap_or_default(),
                        )
                        .env(
                            "AWS_SECRET_ACCESS_KEY",
                            std::env::var("MINIO_SECRET_KEY").unwrap_or_default(),
                        )
                        .output();

                    if let Ok(output) = aws_result {
                        let stdout = String::from_utf8_lossy(&output.stdout);
                        for line in stdout.lines() {
                            if line.contains(".tar.gz") {
                                result.push_str(&format!("  - {}\n", line.trim()));
                            }
                        }
                    }
                }

                if result.ends_with("MinIO backups:\n") {
                    result.push_str("  No MinIO backups found or unable to connect\n");
                }
            } else {
                result.push_str("\nMinIO: Not configured (set MINIO_ENDPOINT, MINIO_ACCESS_KEY, MINIO_SECRET_KEY)\n");
            }
        }

        Ok(result)
    }
}

#[async_trait]
impl Tool for BackupTool {
    fn name(&self) -> &str {
        "backup_workspace"
    }

    fn description(&self) -> &str {
        "Create a backup of the agent's workspace and optionally sync to MinIO remote storage. \
         This captures the SQLite memory database, configuration, workspace files, and all learned context. \
         Use this before major changes or periodically for disaster recovery."
    }

    fn parameters_schema(&self) -> serde_json::Value {
        json!({
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": ["create", "list", "sync"],
                    "description": "Action to perform: 'create' a new backup, 'list' existing backups, or 'sync' a backup to MinIO"
                },
                "destination": {
                    "type": "string",
                    "description": "For 'create' action: directory path where backup will be saved (default: /zeroclaw-data/.zeroclaw/backups)",
                    "default": "/zeroclaw-data/.zeroclaw/backups"
                },
                "backup_file": {
                    "type": "string",
                    "description": "For 'sync' action: path to the backup file to sync to MinIO"
                },
                "location": {
                    "type": "string",
                    "enum": ["local", "minio", "all"],
                    "description": "For 'list' action: which location to list backups from",
                    "default": "all"
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
                let destination = args
                    .get("destination")
                    .and_then(|v| v.as_str())
                    .unwrap_or("/zeroclaw-data/.zeroclaw/backups");

                // Validate destination path (prevent directory traversal)
                let dest_path = PathBuf::from(destination);
                if !dest_path.is_absolute() {
                    return Ok(ToolResult {
                        success: false,
                        output: String::new(),
                        error: Some("Destination must be an absolute path".to_string()),
                    });
                }

                match self.create_backup(destination).await {
                    Ok(message) => Ok(ToolResult {
                        success: true,
                        output: message,
                        error: None,
                    }),
                    Err(e) => Ok(ToolResult {
                        success: false,
                        output: String::new(),
                        error: Some(format!("Failed to create backup: {}", e)),
                    }),
                }
            }
            "sync" => {
                let backup_file = args
                    .get("backup_file")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| {
                        anyhow::anyhow!("Missing 'backup_file' parameter for sync action")
                    })?;

                // Validate backup file path
                let backup_path = PathBuf::from(backup_file);
                if !backup_path.is_absolute() {
                    return Ok(ToolResult {
                        success: false,
                        output: String::new(),
                        error: Some("Backup file path must be absolute".to_string()),
                    });
                }

                if !backup_path.exists() {
                    return Ok(ToolResult {
                        success: false,
                        output: String::new(),
                        error: Some(format!("Backup file not found: {}", backup_file)),
                    });
                }

                match self.sync_to_minio(backup_file).await {
                    Ok(message) => Ok(ToolResult {
                        success: true,
                        output: message,
                        error: None,
                    }),
                    Err(e) => Ok(ToolResult {
                        success: false,
                        output: String::new(),
                        error: Some(format!("Failed to sync to MinIO: {}", e)),
                    }),
                }
            }
            "list" => {
                let location = args
                    .get("location")
                    .and_then(|v| v.as_str())
                    .unwrap_or("all");

                match self.list_backups(location).await {
                    Ok(message) => Ok(ToolResult {
                        success: true,
                        output: message,
                        error: None,
                    }),
                    Err(e) => Ok(ToolResult {
                        success: false,
                        output: String::new(),
                        error: Some(format!("Failed to list backups: {}", e)),
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
    async fn test_backup_tool_spec() {
        let temp_dir = TempDir::new().unwrap();
        let tool = BackupTool::new(temp_dir.path().to_path_buf());

        assert_eq!(tool.name(), "backup_workspace");
        assert!(!tool.description().is_empty());

        let schema = tool.parameters_schema();
        assert_eq!(schema["type"], "object");
        assert!(schema["properties"]["action"]["enum"]
            .as_array()
            .unwrap()
            .contains(&json!("create")));
    }

    #[tokio::test]
    async fn test_create_backup_success() {
        let temp_dir = TempDir::new().unwrap();
        let tool = BackupTool::new(temp_dir.path().to_path_buf());

        // Create a test file in the workspace
        let test_file = temp_dir.path().join("test.txt");
        tokio::fs::write(&test_file, "test content").await.unwrap();

        // Create backup
        let backup_dir = temp_dir.path().join("backups");
        let result = tool.create_backup(backup_dir.to_str().unwrap()).await;

        assert!(result.is_ok());
        assert!(result.unwrap().contains("Backup created successfully"));

        // Verify backup file exists
        let entries: Vec<_> = std::fs::read_dir(&backup_dir).unwrap().collect();
        assert!(!entries.is_empty());
    }

    #[tokio::test]
    async fn test_list_backups_local() {
        let temp_dir = TempDir::new().unwrap();
        let tool = BackupTool::new(temp_dir.path().to_path_buf());

        let result = tool.list_backups("local").await;
        assert!(result.is_ok());
        // Should show no backups initially
        assert!(result.unwrap().contains("No local backups found"));
    }
}
