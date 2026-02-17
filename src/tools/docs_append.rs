use super::traits::{Tool, ToolResult};
use crate::memory::docsd_client;
use crate::memory::managed_docs::normalize_doc_id;
use async_trait::async_trait;
use serde_json::json;
use std::path::PathBuf;

pub struct DocsAppendTool {
    workspace_dir: PathBuf,
}

impl DocsAppendTool {
    pub fn new(workspace_dir: PathBuf) -> Self {
        Self { workspace_dir }
    }
}

#[async_trait]
impl Tool for DocsAppendTool {
    fn name(&self) -> &str {
        "docs_append"
    }

    fn description(&self) -> &str {
        "Append a markdown block to a managed document. Preferred for MEMORY.md long-term notes and incremental updates."
    }

    fn parameters_schema(&self) -> serde_json::Value {
        json!({
            "type": "object",
            "properties": {
                "doc": {
                    "type": "string",
                    "description": "Document selector: memory|agents|soul|tools|identity|user|heartbeat|bootstrap|<name>.md|skills/<skill>/SKILL.md"
                },
                "section": {
                    "type": "string",
                    "description": "Optional markdown section title. When provided, appended block uses heading level 2."
                },
                "content": {
                    "type": "string",
                    "description": "Markdown content to append"
                }
            },
            "required": ["doc", "content"]
        })
    }

    async fn execute(&self, args: serde_json::Value) -> anyhow::Result<ToolResult> {
        let doc = args
            .get("doc")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow::anyhow!("Missing 'doc' parameter"))?;
        let content = args
            .get("content")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow::anyhow!("Missing 'content' parameter"))?;
        let section = args.get("section").and_then(|v| v.as_str());

        let Some(doc_id) = normalize_doc_id(doc) else {
            return Ok(ToolResult {
                success: false,
                output: String::new(),
                error: Some(format!("Unsupported managed document: {doc}")),
            });
        };

        docsd_client::append_doc(
            &self.workspace_dir,
            &doc_id,
            section,
            content,
            "tool:docs_append",
        )?;
        Ok(ToolResult {
            success: true,
            output: format!("Appended content to {doc_id}"),
            error: None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::memory::managed_docs;
    use tempfile::TempDir;

    #[tokio::test]
    async fn docs_append_updates_memory_doc() {
        let tmp = TempDir::new().unwrap();
        managed_docs::initialize_managed_docs(tmp.path(), None).unwrap();

        let tool = DocsAppendTool::new(tmp.path().to_path_buf());
        let result = tool
            .execute(json!({
                "doc": "memory",
                "section": "Lessons Learned",
                "content": "Prefer append events for long-term memory updates"
            }))
            .await
            .unwrap();

        assert!(result.success);

        let doc = docsd_client::read_doc(tmp.path(), "memory")
            .unwrap()
            .unwrap();
        assert!(doc.contains("## Lessons Learned"));
        assert!(doc.contains("Prefer append events"));
    }
}
