//! Boucle — A framework for autonomous AI agent loops.
//!
//! Provides structured memory (Broca), lifecycle hooks, context assembly,
//! and scheduling for AI agents that run in recurring loops.

mod broca;
mod config;
mod runner;

use clap::{Parser, Subcommand};
use std::path::PathBuf;
use std::process;

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
                                    if !entry.tags.is_empty() {
                                        println!("   tags: {}", entry.tags.join(", "));
                                    }
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

                MemoryCommands::Show { entry } => {
                    match broca::show(&memory_dir, &entry) {
                        Ok(content) => print!("{content}"),
                        Err(e) => {
                            eprintln!("Error: {e}");
                            process::exit(1);
                        }
                    }
                }

                MemoryCommands::SearchTag { tag } => {
                    match broca::search_tag(&memory_dir, &tag) {
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
                    }
                }

                MemoryCommands::Journal { content } => {
                    match broca::journal(&memory_dir, &content) {
                        Ok(path) => println!("Journal entry: {}", path.display()),
                        Err(e) => {
                            eprintln!("Error: {e}");
                            process::exit(1);
                        }
                    }
                }

                MemoryCommands::Stats => {
                    match broca::stats(&memory_dir) {
                        Ok(s) => print!("{s}"),
                        Err(e) => {
                            eprintln!("Error: {e}");
                            process::exit(1);
                        }
                    }
                }

                MemoryCommands::Index => {
                    match broca::build_index(&memory_dir) {
                        Ok(count) => println!("Indexed {count} entries."),
                        Err(e) => {
                            eprintln!("Error: {e}");
                            process::exit(1);
                        }
                    }
                }
            }
        }
    }
}
