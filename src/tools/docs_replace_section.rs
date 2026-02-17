use super::traits::{Tool, ToolResult};
use crate::memory::docsd_client;
use crate::memory::managed_docs::normalize_doc_id;
use async_trait::async_trait;
use serde_json::json;
use std::path::PathBuf;

pub struct DocsReplaceSectionTool {
    workspace_dir: PathBuf,
}

impl DocsReplaceSectionTool {
    pub fn new(workspace_dir: PathBuf) -> Self {
        Self { workspace_dir }
    }
}

#[async_trait]
impl Tool for DocsReplaceSectionTool {
    fn name(&self) -> &str {
        "docs_replace_section"
    }

    fn description(&self) -> &str {
        "Replace or create a level-2 markdown section in a managed document without rewriting the full file."
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
                    "description": "Section title (matches markdown heading '## <section>')"
                },
                "content": {
                    "type": "string",
                    "description": "Replacement markdown body for the section"
                }
            },
            "required": ["doc", "section", "content"]
        })
    }

    async fn execute(&self, args: serde_json::Value) -> anyhow::Result<ToolResult> {
        let doc = args
            .get("doc")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow::anyhow!("Missing 'doc' parameter"))?;
        let section = args
            .get("section")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow::anyhow!("Missing 'section' parameter"))?;
        let content = args
            .get("content")
            .and_then(|v| v.as_str())
            .ok_or_else(|| anyhow::anyhow!("Missing 'content' parameter"))?;

        let Some(doc_id) = normalize_doc_id(doc) else {
            return Ok(ToolResult {
                success: false,
                output: String::new(),
                error: Some(format!("Unsupported managed document: {doc}")),
            });
        };

        docsd_client::replace_doc_section(
            &self.workspace_dir,
            &doc_id,
            section,
            content,
            "tool:docs_replace_section",
        )?;

        Ok(ToolResult {
            success: true,
            output: format!("Updated section '{section}' in {doc_id}"),
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
    async fn docs_replace_section_creates_or_updates_section() {
        let tmp = TempDir::new().unwrap();
        managed_docs::initialize_managed_docs(tmp.path(), None).unwrap();

        let tool = DocsReplaceSectionTool::new(tmp.path().to_path_buf());
        let result = tool
            .execute(json!({
                "doc": "memory",
                "section": "Open Loops",
                "content": "- Validate hello world path"
            }))
            .await
            .unwrap();

        assert!(result.success);

        let doc = docsd_client::read_doc(tmp.path(), "memory")
            .unwrap()
            .unwrap();
        assert!(doc.contains("## Open Loops"));
        assert!(doc.contains("- Validate hello world path"));
    }
}
