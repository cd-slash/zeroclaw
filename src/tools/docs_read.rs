use super::traits::{Tool, ToolResult};
use crate::memory::docsd_client;
use crate::memory::managed_docs::normalize_doc_id;
use async_trait::async_trait;
use serde_json::json;
use std::path::PathBuf;

pub struct DocsReadTool {
    workspace_dir: PathBuf,
}

impl DocsReadTool {
    pub fn new(workspace_dir: PathBuf) -> Self {
        Self { workspace_dir }
    }
}

#[async_trait]
impl Tool for DocsReadTool {
    fn name(&self) -> &str {
        "docs_read"
    }

    fn description(&self) -> &str {
        "Read managed markdown docs (AGENTS, SOUL, TOOLS, IDENTITY, USER, HEARTBEAT, BOOTSTRAP, MEMORY, and skills/*/SKILL.md)."
    }

    fn parameters_schema(&self) -> serde_json::Value {
        json!({
            "type": "object",
            "properties": {
                "doc": {
                    "type": "string",
                    "description": "Document selector: memory|agents|soul|tools|identity|user|heartbeat|bootstrap|<name>.md|skills/<skill>/SKILL.md"
                }
            },
            "required": ["doc"]
        })
    }

    async fn execute(&self, args: serde_json::Value) -> anyhow::Result<ToolResult> {
        let doc = args
            .get("doc")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow::anyhow!("Missing 'doc' parameter"))?;

        let Some(doc_id) = normalize_doc_id(doc) else {
            return Ok(ToolResult {
                success: false,
                output: String::new(),
                error: Some(format!("Unsupported managed document: {doc}")),
            });
        };

        match docsd_client::read_doc(&self.workspace_dir, &doc_id)? {
            Some(content) => Ok(ToolResult {
                success: true,
                output: content,
                error: None,
            }),
            None => Ok(ToolResult {
                success: false,
                output: String::new(),
                error: Some(format!("Managed document not initialized: {doc_id}")),
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::memory::managed_docs;
    use tempfile::TempDir;

    #[tokio::test]
    async fn docs_read_returns_seeded_memory_doc() {
        let tmp = TempDir::new().unwrap();
        managed_docs::initialize_managed_docs(tmp.path(), None).unwrap();

        let tool = DocsReadTool::new(tmp.path().to_path_buf());
        let result = tool.execute(json!({ "doc": "memory" })).await.unwrap();
        assert!(result.success);
        assert!(result.output.contains("MEMORY.md"));
    }
}
