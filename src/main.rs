//! Boucle — A framework for autonomous AI agent loops.
//!
//! Provides structured memory (Broca), lifecycle hooks, context assembly,
//! and scheduling for AI agents that run in recurring loops.

mod broca;
mod config;
mod mcp;
mod runner;

use clap::{Parser, Subcommand};
use std::path::PathBuf;
use std::process;
use std::process::Command;

#[derive(Parser)]
#[command(name = "boucle")]
#[command(about = "Framework for autonomous AI agent loops")]
#[command(version)]
struct Cli {
    /// Path to the agent root directory (default: search upward for boucle.toml)
    #[arg(short, long)]
    root: Option<PathBuf>,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Initialize a new Boucle agent in the current directory
    Init {
        /// Agent name
        #[arg(short, long, default_value = "my-agent")]
        name: String,
    },

    /// Run one iteration of the agent loop
    Run,

    /// Show agent status
    Status,

    /// Show loop history
    Log {
        /// Number of entries to show
        #[arg(short, long, default_value = "10")]
        count: usize,
    },

    /// Set up scheduling (launchd on macOS, cron on Linux)
    Schedule {
        /// Interval between iterations (e.g., "1h", "30m", "5m")
        #[arg(short, long, default_value = "1h")]
        interval: String,
    },

    /// Broca memory operations
    #[command(subcommand)]
    Memory(MemoryCommands),

    /// Start MCP server to expose Broca to other AI agents
    Mcp {
        /// Server port (for HTTP transport, optional)
        #[arg(short, long)]
        port: Option<u16>,

        /// Use stdio transport instead of HTTP
        #[arg(long, default_value = "true")]
        stdio: bool,
    },

    /// List available plugins
    Plugins,

    /// Run a plugin from the plugins/ directory
    #[command(external_subcommand)]
    Plugin(Vec<String>),
}

#[derive(Subcommand)]
enum MemoryCommands {
    /// Store a new memory entry
    Remember {
        /// Entry type: fact, decision, observation, error, procedure
        #[arg(short = 't', long, default_value = "fact")]
        entry_type: String,

        /// Title of the memory entry
        title: String,

        /// Content of the memory entry
        content: String,

        /// Tags (comma-separated)
        #[arg(long)]
        tags: Option<String>,
    },

    /// Search memory with relevance ranking
    Recall {
        /// Search query
        query: String,

        /// Maximum results
        #[arg(short, long, default_value = "5")]
        limit: usize,
    },

    /// Show a specific memory entry
    Show {
        /// Entry filename (without path)
        entry: String,
    },

    /// Search by tag
    SearchTag {
        /// Tag to search for
        tag: String,
    },

    /// Add a journal entry
    Journal {
        /// Journal content
        content: String,
    },

    /// Update confidence score for an entry
    UpdateConfidence {
        /// Entry filename or partial name
        entry: String,

        /// New confidence score (0.0 to 1.0)
        confidence: f64,
    },

    /// Mark an entry as superseded by a newer one
    Supersede {
        /// Old entry filename or partial name
        old_entry: String,

        /// New entry filename or partial name
        new_entry: String,
    },

    /// Add a relationship between two entries
    Relate {
        /// First entry filename or partial name
        entry_a: String,

        /// Second entry filename or partial name
        entry_b: String,

        /// Relationship type (e.g., "supports", "contradicts", "extends")
        #[arg(short = 't', long, default_value = "related")]
        relation_type: String,
    },

    /// Show memory statistics
    Stats,

    /// Build or rebuild the memory index
    Index,
}

fn main() {
    let cli = Cli::parse();

    // Find or use the agent root
    let root = match cli.root {
        Some(r) => r,
        None => match config::find_agent_root(&std::env::current_dir().unwrap()) {
            Some(r) => r,
            None => {
                if !matches!(cli.command, Commands::Init { .. }) {
                    eprintln!("Error: No boucle.toml found. Run 'boucle init' first.");
                    process::exit(1);
                }
                std::env::current_dir().unwrap()
            }
        },
    };

    match cli.command {
        Commands::Init { name } => {
            if let Err(e) = runner::init(&root, &name) {
                eprintln!("Error initializing: {e}");
                process::exit(1);
            }
            println!("Initialized Boucle agent '{name}' in {}", root.display());
        }

        Commands::Run => {
            if let Err(e) = runner::run(&root) {
                eprintln!("Error: {e}");
                process::exit(1);
            }
        }

        Commands::Status => {
            if let Err(e) = runner::status(&root) {
                eprintln!("Error: {e}");
                process::exit(1);
            }
        }

        Commands::Log { count } => {
            if let Err(e) = runner::show_log(&root, count) {
                eprintln!("Error: {e}");
                process::exit(1);
            }
        }

        Commands::Schedule { interval } => {
            if let Err(e) = runner::schedule(&root, &interval) {
                eprintln!("Error: {e}");
                process::exit(1);
            }
        }

        Commands::Memory(mem_cmd) => {
            let cfg = match config::load(&root) {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("Error loading config: {e}");
                    process::exit(1);
                }
            };
            let memory_dir = root.join(&cfg.memory.dir);

            match mem_cmd {
                MemoryCommands::Remember {
                    entry_type,
                    title,
                    content,
                    tags,
                } => {
                    let tag_list: Vec<String> = tags
                        .map(|t| t.split(',').map(|s| s.trim().to_string()).collect())
                        .unwrap_or_default();
                    match broca::remember(&memory_dir, &entry_type, &title, &content, &tag_list) {
                        Ok(path) => println!("Stored: {}", path.display()),
                        Err(e) => {
                            eprintln!("Error: {e}");
                            process::exit(1);
                        }
                    }
                }

                MemoryCommands::Recall { query, limit } => {
                    match broca::recall(&memory_dir, &query, limit) {
                        Ok(results) => {
                            if results.is_empty() {
                                println!("No matching memories found.");
                            } else {
                                for (i, entry) in results.iter().enumerate() {
                                    println!(
                                        "{}. [{}] {} (confidence: {:.1}, score: {:.1})",
                                        i + 1,
                                        entry.entry_type,
                                        entry.title,
                                        entry.confidence,
                                        entry.relevance_score
                                    );
                                    println!("   file: {}", entry.filename);
                                    if let Some(ref sup) = entry.superseded_by {
                                        println!("   ⚠ superseded by: {sup}");
                                    }
                                    if !entry.tags.is_empty() {
                                        println!("   tags: {}", entry.tags.join(", "));
                                    }
                                    // Show content preview (first 100 chars)
                                    let preview: String = entry.content.chars().take(100).collect();
                                    let ellipsis =
                                        if entry.content.len() > 100 { "..." } else { "" };
                                    println!("   {preview}{ellipsis}");
                                    println!();
                                }
                            }
                        }
                        Err(e) => {
                            eprintln!("Error: {e}");
                            process::exit(1);
                        }
                    }
                }

                MemoryCommands::Show { entry } => match broca::show(&memory_dir, &entry) {
                    Ok(content) => print!("{content}"),
                    Err(e) => {
                        eprintln!("Error: {e}");
                        process::exit(1);
                    }
                },

                MemoryCommands::SearchTag { tag } => match broca::search_tag(&memory_dir, &tag) {
                    Ok(entries) => {
                        if entries.is_empty() {
                            println!("No entries with tag '{tag}'.");
                        } else {
                            for entry in &entries {
                                println!("[{}] {}", entry.entry_type, entry.title);
                            }
                        }
                    }
                    Err(e) => {
                        eprintln!("Error: {e}");
                        process::exit(1);
                    }
                },

                MemoryCommands::Journal { content } => {
                    match broca::journal(&memory_dir, &content) {
                        Ok(path) => println!("Journal entry: {}", path.display()),
                        Err(e) => {
                            eprintln!("Error: {e}");
                            process::exit(1);
                        }
                    }
                }

                MemoryCommands::UpdateConfidence { entry, confidence } => {
                    match broca::update_confidence(&memory_dir, &entry, confidence) {
                        Ok(path) => {
                            println!("Updated confidence to {confidence:.1}: {}", path.display())
                        }
                        Err(e) => {
                            eprintln!("Error: {e}");
                            process::exit(1);
                        }
                    }
                }

                MemoryCommands::Supersede {
                    old_entry,
                    new_entry,
                } => match broca::supersede(&memory_dir, &old_entry, &new_entry) {
                    Ok(path) => {
                        println!("Marked as superseded: {}", path.display())
                    }
                    Err(e) => {
                        eprintln!("Error: {e}");
                        process::exit(1);
                    }
                },

                MemoryCommands::Relate {
                    entry_a,
                    entry_b,
                    relation_type,
                } => match broca::relate(&memory_dir, &entry_a, &entry_b, &relation_type) {
                    Ok(()) => {
                        println!("Relation added: {entry_a} --[{relation_type}]--> {entry_b}")
                    }
                    Err(e) => {
                        eprintln!("Error: {e}");
                        process::exit(1);
                    }
                },

                MemoryCommands::Stats => match broca::stats(&memory_dir) {
                    Ok(s) => print!("{s}"),
                    Err(e) => {
                        eprintln!("Error: {e}");
                        process::exit(1);
                    }
                },

                MemoryCommands::Index => match broca::build_index(&memory_dir) {
                    Ok(count) => println!("Indexed {count} entries."),
                    Err(e) => {
                        eprintln!("Error: {e}");
                        process::exit(1);
                    }
                },
            }
        }

        Commands::Mcp { port, stdio } => {
            let cfg = match config::load(&root) {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("Error loading config: {e}");
                    process::exit(1);
                }
            };

            // Create a tokio runtime for the async MCP server
            let rt = tokio::runtime::Runtime::new().unwrap();
            if let Err(e) = rt.block_on(mcp::serve(&root, &cfg, port, stdio)) {
                eprintln!("MCP server error: {e}");
                process::exit(1);
            }
        }

        Commands::Plugins => {
            let plugins_dir = root.join("plugins");
            if !plugins_dir.exists() {
                println!("No plugins directory found at {}", plugins_dir.display());
                println!("Create plugins/ and add scripts to extend boucle.");
                return;
            }
            match std::fs::read_dir(&plugins_dir) {
                Ok(entries) => {
                    let mut found = false;
                    for entry in entries.flatten() {
                        let path = entry.path();
                        if path.is_file() {
                            let name = path.file_stem().and_then(|s| s.to_str()).unwrap_or("?");
                            // Read first line after shebang for description
                            let desc = std::fs::read_to_string(&path)
                                .ok()
                                .and_then(|content| {
                                    content
                                        .lines()
                                        .find(|l| l.starts_with("# description:"))
                                        .map(|l| {
                                            l.trim_start_matches("# description:")
                                                .trim()
                                                .to_string()
                                        })
                                })
                                .unwrap_or_default();
                            println!("  {name:20} {desc}");
                            found = true;
                        }
                    }
                    if !found {
                        println!("No plugins found in {}", plugins_dir.display());
                    }
                }
                Err(e) => {
                    eprintln!("Error reading plugins directory: {e}");
                    process::exit(1);
                }
            }
        }

        Commands::Plugin(args) => {
            if args.is_empty() {
                eprintln!("No plugin specified.");
                process::exit(1);
            }
            let plugin_name = &args[0];
            let plugin_args = &args[1..];
            let plugins_dir = root.join("plugins");

            // Find the plugin script (with or without extension)
            let plugin_path = find_plugin(&plugins_dir, plugin_name);
            match plugin_path {
                Some(path) => {
                    // Detect interpreter from shebang
                    let interpreter = detect_interpreter(&path);
                    let mut cmd = match interpreter {
                        Some((interp, arg)) => {
                            let mut c = Command::new(interp);
                            if let Some(a) = arg {
                                c.arg(a);
                            }
                            c.arg(&path);
                            c
                        }
                        None => Command::new(&path),
                    };

                    cmd.args(plugin_args)
                        .env("BOUCLE_ROOT", &root)
                        .env("BOUCLE_PLUGINS", &plugins_dir);

                    // Add config-derived env vars if config exists
                    if let Ok(cfg) = config::load(&root) {
                        cmd.env("BOUCLE_MEMORY", root.join(&cfg.memory.dir));
                    }

                    match cmd.status() {
                        Ok(status) => {
                            process::exit(status.code().unwrap_or(1));
                        }
                        Err(e) => {
                            eprintln!("Error running plugin '{plugin_name}': {e}");
                            process::exit(1);
                        }
                    }
                }
                None => {
                    eprintln!("Unknown command '{plugin_name}'. Not a built-in or plugin.");
                    eprintln!("Run 'boucle plugins' to see available plugins.");
                    process::exit(1);
                }
            }
        }
    }
}

/// Find a plugin script by name, checking with and without common extensions.
fn find_plugin(plugins_dir: &std::path::Path, name: &str) -> Option<PathBuf> {
    if !plugins_dir.exists() {
        return None;
    }
    // Try exact name first, then with common extensions
    let candidates = [
        name.to_string(),
        format!("{name}.py"),
        format!("{name}.sh"),
        format!("{name}.rb"),
    ];
    for candidate in &candidates {
        let path = plugins_dir.join(candidate);
        if path.is_file() {
            return Some(path);
        }
    }
    None
}

/// Detect interpreter from shebang line.
fn detect_interpreter(path: &std::path::Path) -> Option<(String, Option<String>)> {
    let content = std::fs::read_to_string(path).ok()?;
    let first_line = content.lines().next()?;
    if !first_line.starts_with("#!") {
        return None;
    }
    let shebang = first_line.trim_start_matches("#!").trim();
    if shebang.starts_with("/usr/bin/env ") {
        let interp = shebang.trim_start_matches("/usr/bin/env ").trim();
        Some((interp.to_string(), None))
    } else {
        Some((shebang.to_string(), None))
    }
}
