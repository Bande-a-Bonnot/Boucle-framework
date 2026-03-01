//! Broca MCP Server
//!
//! Exposes Broca memory operations as an MCP (Model Context Protocol) server,
//! allowing other AI agents to use the file-based memory system.

use std::error::Error;
use std::io::{self, BufRead, BufReader, Write};
use std::path::Path;
use crate::config::Config;
use crate::broca;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

const MCP_VERSION: &str = "2025-11-25";

#[derive(Debug, Serialize, Deserialize)]
struct JsonRpcMessage {
    jsonrpc: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    id: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    method: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    params: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<JsonRpcError>,
}

#[derive(Debug, Serialize, Deserialize)]
struct JsonRpcError {
    code: i32,
    message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<Value>,
}

/// Start the MCP server to expose Broca functionality
pub async fn serve(
    root: &Path,
    config: &Config,
    _port: Option<u16>,
    stdio: bool,
) -> Result<(), Box<dyn Error>> {
    let memory_dir = root.join(&config.memory.dir);

    eprintln!("Starting Broca MCP Server...");
    eprintln!("Memory directory: {}", memory_dir.display());

    if !stdio {
        eprintln!("Error: Only stdio transport is currently supported");
        return Err("Only stdio transport is supported".into());
    }

    eprintln!("Transport: stdio");
    eprintln!("Waiting for initialization...");

    let stdin = io::stdin();
    let mut reader = BufReader::new(stdin.lock());
    let mut stdout = io::stdout();

    let mut line = String::new();
    while reader.read_line(&mut line)? > 0 {
        line = line.trim().to_string();
        if line.is_empty() {
            line.clear();
            continue;
        }

        match serde_json::from_str::<JsonRpcMessage>(&line) {
            Ok(message) => {
                let response = handle_message(message, root, config).await?;
                if let Some(response) = response {
                    let response_json = serde_json::to_string(&response)?;
                    writeln!(stdout, "{}", response_json)?;
                    stdout.flush()?;
                }
            }
            Err(e) => {
                eprintln!("Failed to parse JSON-RPC message: {}", e);
                // Send parse error response
                let error_response = JsonRpcMessage {
                    jsonrpc: "2.0".to_string(),
                    id: None,
                    method: None,
                    params: None,
                    result: None,
                    error: Some(JsonRpcError {
                        code: -32700,
                        message: "Parse error".to_string(),
                        data: Some(json!(e.to_string())),
                    }),
                };
                let response_json = serde_json::to_string(&error_response)?;
                writeln!(stdout, "{}", response_json)?;
                stdout.flush()?;
            }
        }

        line.clear();
    }

    Ok(())
}

async fn handle_message(
    message: JsonRpcMessage,
    root: &Path,
    config: &Config,
) -> Result<Option<JsonRpcMessage>, Box<dyn Error>> {
    match message.method.as_deref() {
        Some("initialize") => handle_initialize(message),
        Some("tools/list") => handle_tools_list(message),
        Some("tools/call") => handle_tools_call(message, root, config).await,
        Some(method) => {
            // Unknown method
            Ok(Some(JsonRpcMessage {
                jsonrpc: "2.0".to_string(),
                id: message.id,
                method: None,
                params: None,
                result: None,
                error: Some(JsonRpcError {
                    code: -32601,
                    message: format!("Method not found: {}", method),
                    data: None,
                }),
            }))
        }
        None => {
            // Notification or response - no reply needed
            Ok(None)
        }
    }
}

fn handle_initialize(message: JsonRpcMessage) -> Result<Option<JsonRpcMessage>, Box<dyn Error>> {
    let result = json!({
        "protocolVersion": MCP_VERSION,
        "capabilities": {
            "tools": {
                "listChanged": false
            }
        },
        "serverInfo": {
            "name": "Broca",
            "version": "0.3.0",
            "description": "File-based memory system for AI agents"
        },
        "icons": [
            {
                "src": "data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iNDgiIGhlaWdodD0iNDgiIHZpZXdCb3g9IjAgMCA0OCA0OCIgZmlsbD0ibm9uZSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj4KPHJlY3Qgd2lkdGg9IjQ4IiBoZWlnaHQ9IjQ4IiByeD0iOCIgZmlsbD0iIzI1NjNlYiIvPgo8cGF0aCBkPSJNMjQgMTJjNi42MjcgMCAxMiA1LjM3MyAxMiAxMnMtNS4zNzMgMTItMTIgMTItMTItNS4zNzMtMTItMTIgNS4zNzMtMTIgMTItMTJ6bTAgNGMtNC40MTggMC04IDMuNTgyLTggOHMzLjU4MiA4IDggOCA4LTMuNTgyIDgtOC0zLjU4Mi04LTgtOHoiIGZpbGw9IndoaXRlIi8+CjxjaXJjbGUgY3g9IjI0IiBjeT0iMjQiIHI9IjMiIGZpbGw9IndoaXRlIi8+Cjwvc3ZnPgo=",
                "mimeType": "image/svg+xml",
                "sizes": ["48x48"]
            }
        ]
    });

    Ok(Some(JsonRpcMessage {
        jsonrpc: "2.0".to_string(),
        id: message.id,
        method: None,
        params: None,
        result: Some(result),
        error: None,
    }))
}

fn handle_tools_list(message: JsonRpcMessage) -> Result<Option<JsonRpcMessage>, Box<dyn Error>> {
    let tools = json!([
        {
            "name": "broca_remember",
            "title": "Store Memory",
            "description": "Store a structured memory with content, title, and tags",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "content": {
                        "type": "string",
                        "description": "The main content to remember"
                    },
                    "title": {
                        "type": "string",
                        "description": "Optional title for the memory"
                    },
                    "tags": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Optional tags for categorization"
                    }
                },
                "required": ["content"]
            }
        },
        {
            "name": "broca_recall",
            "title": "Search Memory",
            "description": "Search memories by content, title, or tags with relevance ranking",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Search query to find relevant memories"
                    },
                    "limit": {
                        "type": "integer",
                        "description": "Maximum number of results to return",
                        "default": 10,
                        "minimum": 1,
                        "maximum": 100
                    }
                },
                "required": ["query"]
            }
        },
        {
            "name": "broca_journal",
            "title": "Add Journal Entry",
            "description": "Add a timestamped journal entry",
            "inputSchema": {
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
            "name": "broca_relate",
            "title": "Create Relationship",
            "description": "Create a relationship between two memories",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "from_id": {
                        "type": "string",
                        "description": "ID of the source memory"
                    },
                    "to_id": {
                        "type": "string",
                        "description": "ID of the target memory"
                    },
                    "relation_type": {
                        "type": "string",
                        "enum": ["related_to", "caused_by", "leads_to", "similar_to", "contradicts", "elaborates_on"],
                        "description": "Type of relationship between memories"
                    },
                    "description": {
                        "type": "string",
                        "description": "Optional description of the relationship"
                    }
                },
                "required": ["from_id", "to_id", "relation_type"]
            }
        },
        {
            "name": "broca_supersede",
            "title": "Supersede Memory",
            "description": "Mark a memory as superseded by another",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "old_id": {
                        "type": "string",
                        "description": "ID of the memory to be superseded"
                    },
                    "new_id": {
                        "type": "string",
                        "description": "ID of the new memory that supersedes the old one"
                    }
                },
                "required": ["old_id", "new_id"]
            }
        },
        {
            "name": "broca_stats",
            "title": "Memory Statistics",
            "description": "Get statistics about the memory system",
            "inputSchema": {
                "type": "object",
                "additionalProperties": false
            }
        }
    ]);

    let result = json!({
        "tools": tools
    });

    Ok(Some(JsonRpcMessage {
        jsonrpc: "2.0".to_string(),
        id: message.id,
        method: None,
        params: None,
        result: Some(result),
        error: None,
    }))
}

async fn handle_tools_call(
    message: JsonRpcMessage,
    root: &Path,
    config: &Config,
) -> Result<Option<JsonRpcMessage>, Box<dyn Error>> {
    let params = message.params.as_ref().ok_or("Missing params")?;
    let tool_name = params.get("name").and_then(|v| v.as_str()).ok_or("Missing tool name")?;
    let default_args = json!({});
    let arguments = params.get("arguments").unwrap_or(&default_args);

    let result = match tool_name {
        "broca_remember" => handle_broca_remember(arguments, root, config).await,
        "broca_recall" => handle_broca_recall(arguments, root, config).await,
        "broca_journal" => handle_broca_journal(arguments, root, config).await,
        "broca_relate" => handle_broca_relate(arguments, root, config).await,
        "broca_supersede" => handle_broca_supersede(arguments, root, config).await,
        "broca_stats" => handle_broca_stats(root, config).await,
        _ => {
            return Ok(Some(JsonRpcMessage {
                jsonrpc: "2.0".to_string(),
                id: message.id,
                method: None,
                params: None,
                result: None,
                error: Some(JsonRpcError {
                    code: -32602,
                    message: format!("Unknown tool: {}", tool_name),
                    data: None,
                }),
            }));
        }
    };

    match result {
        Ok(content) => {
            let result = json!({
                "content": [
                    {
                        "type": "text",
                        "text": content
                    }
                ],
                "isError": false
            });

            Ok(Some(JsonRpcMessage {
                jsonrpc: "2.0".to_string(),
                id: message.id,
                method: None,
                params: None,
                result: Some(result),
                error: None,
            }))
        }
        Err(e) => {
            let result = json!({
                "content": [
                    {
                        "type": "text",
                        "text": format!("Error: {}", e)
                    }
                ],
                "isError": true
            });

            Ok(Some(JsonRpcMessage {
                jsonrpc: "2.0".to_string(),
                id: message.id,
                method: None,
                params: None,
                result: Some(result),
                error: None,
            }))
        }
    }
}

async fn handle_broca_remember(
    arguments: &Value,
    root: &Path,
    config: &Config,
) -> Result<String, Box<dyn Error>> {
    let content = arguments.get("content").and_then(|v| v.as_str()).ok_or("Missing content")?;
    let title = arguments.get("title").and_then(|v| v.as_str()).unwrap_or("Untitled");
    let tags = arguments.get("tags")
        .and_then(|v| v.as_array())
        .map(|arr| arr.iter().filter_map(|v| v.as_str()).map(|s| s.to_string()).collect::<Vec<_>>())
        .unwrap_or_default();

    let memory_dir = root.join(&config.memory.dir);
    let entry_path = broca::remember(&memory_dir, "fact", title, content, &tags)?;

    Ok(format!("Stored memory with ID: {}", entry_path.file_stem().and_then(|f| f.to_str()).unwrap_or("unknown")))
}

async fn handle_broca_recall(
    arguments: &Value,
    root: &Path,
    config: &Config,
) -> Result<String, Box<dyn Error>> {
    let query = arguments.get("query").and_then(|v| v.as_str()).ok_or("Missing query")?;
    let limit = arguments.get("limit").and_then(|v| v.as_u64()).unwrap_or(10) as usize;

    let memory_dir = root.join(&config.memory.dir);
    let results = broca::recall(&memory_dir, query, limit)?;

    if results.is_empty() {
        Ok("No memories found matching your query.".to_string())
    } else {
        let mut output = format!("Found {} memory(ies):\n\n", results.len());

        for (i, entry) in results.iter().enumerate() {
            output.push_str(&format!("{}. **{}** ({})\n",
                i + 1,
                entry.title,
                entry.filename
            ));

            if !entry.tags.is_empty() {
                output.push_str(&format!("   Tags: {}\n", entry.tags.join(", ")));
            }

            let preview = if entry.content.len() > 200 {
                format!("{}...", &entry.content[..200])
            } else {
                entry.content.clone()
            };
            output.push_str(&format!("   {}\n\n", preview));
        }

        Ok(output)
    }
}

async fn handle_broca_journal(
    arguments: &Value,
    root: &Path,
    config: &Config,
) -> Result<String, Box<dyn Error>> {
    let content = arguments.get("content").and_then(|v| v.as_str()).ok_or("Missing content")?;

    let memory_dir = root.join(&config.memory.dir);
    let entry_path = broca::journal(&memory_dir, content)?;

    Ok(format!("Added journal entry to: {}", entry_path.file_name().and_then(|f| f.to_str()).unwrap_or("unknown")))
}

async fn handle_broca_relate(
    arguments: &Value,
    root: &Path,
    config: &Config,
) -> Result<String, Box<dyn Error>> {
    let from_id = arguments.get("from_id").and_then(|v| v.as_str()).ok_or("Missing from_id")?;
    let to_id = arguments.get("to_id").and_then(|v| v.as_str()).ok_or("Missing to_id")?;
    let relation_type = arguments.get("relation_type").and_then(|v| v.as_str()).ok_or("Missing relation_type")?;

    let memory_dir = root.join(&config.memory.dir);
    broca::relate(&memory_dir, from_id, to_id, relation_type)?;

    Ok(format!("Created {} relationship from {} to {}", relation_type, from_id, to_id))
}

async fn handle_broca_supersede(
    arguments: &Value,
    root: &Path,
    config: &Config,
) -> Result<String, Box<dyn Error>> {
    let old_id = arguments.get("old_id").and_then(|v| v.as_str()).ok_or("Missing old_id")?;
    let new_id = arguments.get("new_id").and_then(|v| v.as_str()).ok_or("Missing new_id")?;

    let memory_dir = root.join(&config.memory.dir);
    broca::supersede(&memory_dir, old_id, new_id)?;

    Ok(format!("Marked {} as superseded by {}", old_id, new_id))
}

async fn handle_broca_stats(
    root: &Path,
    config: &Config,
) -> Result<String, Box<dyn Error>> {
    let memory_dir = root.join(&config.memory.dir);
    let stats_output = broca::stats(&memory_dir)?;

    Ok(stats_output)
}