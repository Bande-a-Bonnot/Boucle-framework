//! Broca MCP Server
//!
//! Exposes Broca memory operations as an MCP (Model Context Protocol) server,
//! allowing other AI agents to use the file-based memory system.

use std::error::Error;
use std::path::Path;
use crate::config::Config;
use crate::broca;
use serde_json::{json, Value};
use tokio;

/// Start the MCP server to expose Broca functionality
pub async fn serve(
    root: &Path,
    config: &Config,
    port: Option<u16>,
    stdio: bool,
) -> Result<(), Box<dyn Error>> {
    let memory_dir = root.join(&config.memory.dir);

    println!("Starting Broca MCP Server...");
    println!("Memory directory: {}", memory_dir.display());

    if stdio {
        println!("Transport: stdio");
        start_stdio_server(&memory_dir).await?;
    } else {
        let port = port.unwrap_or(8080);
        println!("Transport: HTTP on port {}", port);
        start_http_server(&memory_dir, port).await?;
    }

    Ok(())
}

/// Start stdio-based MCP server (most common for desktop AI apps)
async fn start_stdio_server(memory_dir: &Path) -> Result<(), Box<dyn Error>> {
    // For now, create a minimal implementation that demonstrates the structure
    // This would use mcpr or the official Rust MCP SDK

    let server_config = create_server_config();

    println!("Broca MCP Server ready");
    println!("Available tools:");
    println!("  - broca_remember: Store structured memories");
    println!("  - broca_recall: Search memories with relevance ranking");
    println!("  - broca_relate: Create relationships between memories");
    println!("  - broca_supersede: Mark memories as superseded");
    println!("  - broca_journal: Add timestamped journal entries");
    println!("  - broca_stats: Get memory statistics");

    // This is a placeholder - would implement actual MCP protocol here
    println!("Note: MCP server implementation in progress");
    println!("Press Ctrl+C to stop...");

    // Wait indefinitely (in real implementation, this would handle MCP requests)
    tokio::signal::ctrl_c().await?;
    println!("\nShutting down Broca MCP Server");

    Ok(())
}

/// Start HTTP-based MCP server (alternative transport)
async fn start_http_server(memory_dir: &Path, port: u16) -> Result<(), Box<dyn Error>> {
    println!("HTTP server not yet implemented");
    Ok(())
}

/// Create the server configuration with tool definitions
fn create_server_config() -> Value {
    json!({
        "name": "broca-mcp-server",
        "version": "0.1.0",
        "description": "File-based memory system for AI agents",
        "tools": [
            {
                "name": "broca_remember",
                "description": "Store a structured memory entry",
                "parameters_schema": {
                    "type": "object",
                    "properties": {
                        "entry_type": {
                            "type": "string",
                            "enum": ["fact", "decision", "observation", "error", "procedure"],
                            "default": "fact",
                            "description": "Type of memory entry"
                        },
                        "title": {
                            "type": "string",
                            "description": "Title of the memory entry"
                        },
                        "content": {
                            "type": "string",
                            "description": "Content of the memory entry"
                        },
                        "tags": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": "Optional tags for the entry"
                        }
                    },
                    "required": ["title", "content"]
                }
            },
            {
                "name": "broca_recall",
                "description": "Search memories with relevance ranking",
                "parameters_schema": {
                    "type": "object",
                    "properties": {
                        "query": {
                            "type": "string",
                            "description": "Search query"
                        },
                        "limit": {
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 50,
                            "default": 5,
                            "description": "Maximum number of results"
                        }
                    },
                    "required": ["query"]
                }
            },
            {
                "name": "broca_relate",
                "description": "Create relationships between memory entries",
                "parameters_schema": {
                    "type": "object",
                    "properties": {
                        "entry_a": {
                            "type": "string",
                            "description": "First entry filename or partial name"
                        },
                        "entry_b": {
                            "type": "string",
                            "description": "Second entry filename or partial name"
                        },
                        "relation_type": {
                            "type": "string",
                            "default": "related",
                            "description": "Type of relationship (e.g., supports, contradicts, extends)"
                        }
                    },
                    "required": ["entry_a", "entry_b"]
                }
            },
            {
                "name": "broca_supersede",
                "description": "Mark an entry as superseded by a newer one",
                "parameters_schema": {
                    "type": "object",
                    "properties": {
                        "old_entry": {
                            "type": "string",
                            "description": "Old entry filename or partial name"
                        },
                        "new_entry": {
                            "type": "string",
                            "description": "New entry filename or partial name"
                        }
                    },
                    "required": ["old_entry", "new_entry"]
                }
            },
            {
                "name": "broca_journal",
                "description": "Add a timestamped journal entry",
                "parameters_schema": {
                    "type": "object",
                    "properties": {
                        "content": {
                            "type": "string",
                            "description": "Journal entry content"
                        }
                    },
                    "required": ["content"]
                }
            },
            {
                "name": "broca_stats",
                "description": "Get memory statistics",
                "parameters_schema": {
                    "type": "object",
                    "properties": {},
                    "additionalProperties": false
                }
            }
        ]
    })
}

/// Handle broca_remember tool call
async fn handle_remember(
    memory_dir: &Path,
    params: &Value,
) -> Result<Value, Box<dyn Error>> {
    let entry_type = params["entry_type"].as_str().unwrap_or("fact");
    let title = params["title"].as_str().ok_or("Missing title")?;
    let content = params["content"].as_str().ok_or("Missing content")?;
    let tags: Vec<String> = params["tags"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();

    let path = broca::remember(memory_dir, entry_type, title, content, &tags)?;

    Ok(json!({
        "success": true,
        "path": path.to_string_lossy(),
        "message": format!("Stored memory entry: {}", title)
    }))
}

/// Handle broca_recall tool call
async fn handle_recall(
    memory_dir: &Path,
    params: &Value,
) -> Result<Value, Box<dyn Error>> {
    let query = params["query"].as_str().ok_or("Missing query")?;
    let limit = params["limit"].as_u64().unwrap_or(5) as usize;

    let results = broca::recall(memory_dir, query, limit)?;

    Ok(json!({
        "success": true,
        "results": results.iter().map(|entry| {
            json!({
                "title": entry.title,
                "entry_type": entry.entry_type,
                "confidence": entry.confidence,
                "relevance_score": entry.relevance_score,
                "filename": entry.filename,
                "tags": entry.tags,
                "superseded_by": entry.superseded_by,
                "content_preview": entry.content.chars().take(200).collect::<String>()
            })
        }).collect::<Vec<_>>()
    }))
}

/// Handle broca_stats tool call
async fn handle_stats(memory_dir: &Path) -> Result<Value, Box<dyn Error>> {
    let stats_output = broca::stats(memory_dir)?;

    Ok(json!({
        "success": true,
        "stats": stats_output
    }))
}

// Tool handlers for other operations would follow similar patterns