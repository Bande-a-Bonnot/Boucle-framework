//! Broca MCP Server
//!
//! Exposes Broca memory operations as an MCP (Model Context Protocol) server,
//! allowing other AI agents to use the file-based memory system.
//!
//! This is currently a work-in-progress placeholder. The full MCP implementation
//! will be completed in a future iteration once the exact rmcp API is clarified.

use std::error::Error;
use std::path::Path;
use crate::config::Config;

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
        println!("MCP server implementation in progress");
        println!("Available tools (planned):");
        println!("  - broca_remember: Store structured memories");
        println!("  - broca_recall: Search memories with relevance ranking");
        println!("  - broca_relate: Create relationships between memories");
        println!("  - broca_supersede: Mark memories as superseded");
        println!("  - broca_journal: Add timestamped journal entries");
        println!("  - broca_stats: Get memory statistics");

        // Wait for interrupt
        println!("Press Ctrl+C to stop...");
        tokio::signal::ctrl_c().await?;
        println!("\nShutting down Broca MCP Server");
    } else {
        let port = port.unwrap_or(8080);
        println!("Transport: HTTP on port {}", port);
        println!("HTTP transport not yet implemented");
    }

    Ok(())
}