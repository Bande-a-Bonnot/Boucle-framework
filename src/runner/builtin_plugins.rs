//! Built-in context plugins using the middleware architecture.
//!
//! This module contains standard plugins that ship with Boucle,
//! demonstrating the middleware pattern and providing core functionality.

use crate::runner::plugins::*;
use std::collections::HashMap;
use std::process::Command;

/// Linear issues plugin - fetches issues delegated to the agent.
pub struct LinearIssuesPlugin {
    meta: PluginMeta,
}

impl LinearIssuesPlugin {
    pub fn new() -> Self {
        Self {
            meta: PluginMetaBuilder::new("linear-issues")
                .description("Fetch Linear issues delegated to Boucle")
                .version("1.0.0")
                .external(true) // Linear API content is external
                .priority(10)   // Run early to inform other plugins
                .build(),
        }
    }

    fn get_auth_token(&self, root: &std::path::Path) -> Result<String, PluginError> {
        let auth_script = root.join("auth-linear.sh");
        let output = Command::new("bash")
            .arg(&auth_script)
            .current_dir(root)
            .output()
            .map_err(|e| PluginError::ExecutionFailed(format!("Failed to run auth script: {}", e)))?;

        if !output.status.success() {
            return Err(PluginError::ExecutionFailed(
                "Auth script failed".to_string(),
            ));
        }

        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    }

    fn execute_graphql(&self, token: &str, query: &str) -> Result<serde_json::Value, PluginError> {
        let query_json = serde_json::json!({"query": query});
        let query_str = serde_json::to_string(&query_json)
            .map_err(|e| PluginError::ExecutionFailed(format!("JSON serialization failed: {}", e)))?;

        let output = Command::new("curl")
            .args([
                "-s",
                "-X", "POST",
                "-H", "Content-Type: application/json",
                "-H", &format!("Authorization: Bearer {}", token),
                "-d", &query_str,
                "https://api.linear.app/graphql",
            ])
            .output()
            .map_err(|e| PluginError::ExecutionFailed(format!("GraphQL request failed: {}", e)))?;

        if !output.status.success() {
            return Err(PluginError::ExecutionFailed(
                "GraphQL request returned error".to_string(),
            ));
        }

        let response_str = String::from_utf8_lossy(&output.stdout);
        serde_json::from_str(&response_str)
            .map_err(|e| PluginError::ExecutionFailed(format!("JSON parsing failed: {}", e)))
    }
}

impl ContextPlugin for LinearIssuesPlugin {
    fn meta(&self) -> &PluginMeta {
        &self.meta
    }

    fn execute(&self, context: &PluginContext) -> Result<PluginResult, PluginError> {
        let mut warnings = Vec::new();

        // Get authentication token
        let token = match self.get_auth_token(context.root) {
            Ok(t) => t,
            Err(e) => {
                return Ok(PluginResult {
                    content: format!(
                        "## Linear Issues (delegated to me)\n\n(Could not fetch Linear issues: {})",
                        e
                    ),
                    warnings,
                    metadata: HashMap::new(),
                });
            }
        };

        // Get current user ID
        let viewer_query = "{ viewer { id } }";
        let viewer_result = match self.execute_graphql(&token, viewer_query) {
            Ok(r) => r,
            Err(e) => {
                return Ok(PluginResult {
                    content: format!(
                        "## Linear Issues (delegated to me)\n\n(Could not fetch viewer info: {})",
                        e
                    ),
                    warnings,
                    metadata: HashMap::new(),
                });
            }
        };

        let my_id = viewer_result["data"]["viewer"]["id"]
            .as_str()
            .ok_or_else(|| PluginError::ExecutionFailed("Invalid viewer response".to_string()))?;

        // Fetch delegated issues
        let issues_query = format!(
            r#"{{
                issues(filter: {{
                    delegate: {{ id: {{ eq: "{}" }} }},
                    state: {{ type: {{ nin: ["completed", "canceled"] }} }}
                }}) {{
                    nodes {{
                        identifier
                        title
                        state {{ name }}
                        priority
                        priorityLabel
                        description
                        comments(first: 5, orderBy: createdAt) {{
                            nodes {{
                                body
                                createdAt
                                user {{ name }}
                                botActor {{ name }}
                            }}
                        }}
                    }}
                }}
            }}"#,
            my_id
        );

        let issues_result = match self.execute_graphql(&token, &issues_query) {
            Ok(r) => r,
            Err(e) => {
                return Ok(PluginResult {
                    content: format!(
                        "## Linear Issues (delegated to me)\n\n(Could not fetch issues: {})",
                        e
                    ),
                    warnings,
                    metadata: HashMap::new(),
                });
            }
        };

        let nodes = issues_result["data"]["issues"]["nodes"]
            .as_array()
            .ok_or_else(|| PluginError::ExecutionFailed("Invalid issues response".to_string()))?;

        // Format output
        let mut content = String::from("## Linear Issues (delegated to me)\n\n");

        if nodes.is_empty() {
            content.push_str("(No issues delegated to me)");
        } else {
            for node in nodes {
                let identifier = node["identifier"].as_str().unwrap_or("?");
                let title = node["title"].as_str().unwrap_or("No title");
                let state = node["state"]["name"].as_str().unwrap_or("Unknown");
                let priority = node["priorityLabel"].as_str().unwrap_or("No priority");

                content.push_str(&format!("- [{}] {} ({}, {})\n", identifier, title, state, priority));

                if let Some(description) = node["description"].as_str() {
                    let desc_lines: Vec<&str> = description[..description.len().min(300)]
                        .split('\n')
                        .collect();
                    for line in desc_lines {
                        content.push_str(&format!("  {}\n", line));
                    }
                }

                if let Some(comments) = node["comments"]["nodes"].as_array() {
                    if !comments.is_empty() {
                        content.push_str("  --- Comments ---\n");
                        for comment in comments {
                            let author = comment["user"]["name"]
                                .as_str()
                                .or_else(|| comment["botActor"]["name"].as_str())
                                .unwrap_or("unknown");
                            let body = comment["body"].as_str().unwrap_or("");
                            let truncated_body = &body[..body.len().min(300)];
                            content.push_str(&format!("  [{}]: {}\n", author, truncated_body));
                        }
                    }
                }

                content.push('\n');
            }
        }

        let mut metadata = HashMap::new();
        metadata.insert("issue_count".to_string(), nodes.len().to_string());

        Ok(PluginResult {
            content,
            warnings,
            metadata,
        })
    }

    fn should_run(&self, context: &PluginContext) -> bool {
        // Only run if auth script exists
        context.root.join("auth-linear.sh").exists()
    }
}

/// System status plugin - provides basic system information.
pub struct SystemStatusPlugin {
    meta: PluginMeta,
}

impl SystemStatusPlugin {
    pub fn new() -> Self {
        Self {
            meta: PluginMetaBuilder::new("system-status")
                .description("Provide system status information")
                .version("1.0.0")
                .external(false) // System info is trusted
                .priority(90)    // Run late
                .build(),
        }
    }
}

impl ContextPlugin for SystemStatusPlugin {
    fn meta(&self) -> &PluginMeta {
        &self.meta
    }

    fn execute(&self, context: &PluginContext) -> Result<PluginResult, PluginError> {
        let mut content = String::from("## System Status\n\n");

        // Current time
        let now = chrono::Utc::now();
        content.push_str(&format!("- Timestamp: {}\n", now.format("%Y-%m-%d %H:%M:%S UTC")));

        // Iteration number
        content.push_str(&format!("- Loop iteration: {}\n", context.iteration));

        // Disk space
        if let Ok(output) = Command::new("df")
            .args(["-h", "."])
            .current_dir(context.root)
            .output()
        {
            let text = String::from_utf8_lossy(&output.stdout);
            if let Some(line) = text.lines().nth(1) {
                let parts: Vec<&str> = line.split_whitespace().collect();
                if parts.len() >= 4 {
                    content.push_str(&format!("- Disk free: {}\n", parts[3]));
                }
            }
        }

        // Git status
        if let Ok(output) = Command::new("git")
            .args(["status", "--porcelain"])
            .current_dir(context.root)
            .output()
        {
            let changes = String::from_utf8_lossy(&output.stdout);
            let count = changes.lines().filter(|l| !l.is_empty()).count();
            content.push_str(&format!("- Git uncommitted changes: {}\n", count));
        }

        let mut metadata = HashMap::new();
        metadata.insert("iteration".to_string(), context.iteration.to_string());

        Ok(PluginResult {
            content,
            warnings: Vec::new(),
            metadata,
        })
    }
}

/// Create and return all built-in plugins.
pub fn create_builtin_plugins() -> Vec<Box<dyn ContextPlugin>> {
    vec![
        Box::new(LinearIssuesPlugin::new()),
        Box::new(SystemStatusPlugin::new()),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;
    use std::path::Path;

    #[test]
    fn test_system_status_plugin() {
        let plugin = SystemStatusPlugin::new();
        assert_eq!(plugin.meta().name, "system-status");
        assert!(!plugin.meta().is_external);
        assert_eq!(plugin.meta().priority, 90);

        let root = Path::new("/tmp");
        let config = Config::default();
        let context = PluginContext {
            root,
            config: &config,
            iteration: 5,
            data: HashMap::new(),
        };

        let result = plugin.execute(&context).unwrap();
        assert!(result.content.contains("System Status"));
        assert!(result.content.contains("Loop iteration: 5"));
        assert_eq!(result.metadata["iteration"], "5");
    }

    #[test]
    fn test_linear_plugin_should_run() {
        let plugin = LinearIssuesPlugin::new();

        let root = Path::new("/nonexistent");
        let config = Config::default();
        let context = PluginContext {
            root,
            config: &config,
            iteration: 1,
            data: HashMap::new(),
        };

        // Should not run if auth script doesn't exist
        assert!(!plugin.should_run(&context));
    }

    #[test]
    fn test_create_builtin_plugins() {
        let plugins = create_builtin_plugins();
        assert_eq!(plugins.len(), 2);

        let names: Vec<&str> = plugins.iter().map(|p| p.meta().name.as_str()).collect();
        assert!(names.contains(&"linear-issues"));
        assert!(names.contains(&"system-status"));
    }
}