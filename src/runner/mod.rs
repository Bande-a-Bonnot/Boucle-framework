//! Loop runner — the engine that drives each agent iteration.
//!
//! Extension points:
//!   context.d/  — Executable scripts that output extra context sections
//!   hooks/      — Scripts at lifecycle points: pre-run, post-context, post-llm, post-commit

pub(crate) mod builtin_plugins;
pub(crate) mod context;
mod hooks;
pub(crate) mod plugins;

use crate::config;
use chrono::{FixedOffset, NaiveDateTime, Timelike, Utc};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use std::{fmt, fs, io, process};

/// Tracks consecutive LLM failures across loop invocations.
///
/// `serde(default)` per field: other writers (e.g. a shell loop's failure
/// classifier) share this file with a different schema. A partially matching
/// file must degrade to field defaults, not silently reset the whole state.
#[derive(Debug, Serialize, Deserialize, Default)]
struct FailureState {
    #[serde(default)]
    consecutive_failures: u32,
    #[serde(default)]
    first_failure: Option<String>,
    #[serde(default)]
    last_failure: Option<String>,
    #[serde(default)]
    last_error: Option<String>,
    #[serde(default)]
    alert_sent: bool,
}

/// Errors from the runner.
#[derive(Debug)]
pub enum RunnerError {
    Io(io::Error),
    Config(config::ConfigError),
    Lock(String),
    Hook(String),
    Llm(String),
}

impl fmt::Display for RunnerError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RunnerError::Io(e) => write!(f, "IO error: {e}"),
            RunnerError::Config(e) => write!(f, "Config error: {e}"),
            RunnerError::Lock(msg) => write!(f, "Lock error: {msg}"),
            RunnerError::Hook(msg) => write!(f, "Hook error: {msg}"),
            RunnerError::Llm(msg) => write!(f, "LLM error: {msg}"),
        }
    }
}

impl std::error::Error for RunnerError {}

impl From<io::Error> for RunnerError {
    fn from(e: io::Error) -> Self {
        RunnerError::Io(e)
    }
}

impl From<config::ConfigError> for RunnerError {
    fn from(e: config::ConfigError) -> Self {
        RunnerError::Config(e)
    }
}

impl From<serde_json::Error> for RunnerError {
    fn from(e: serde_json::Error) -> Self {
        RunnerError::Io(std::io::Error::other(e))
    }
}

const LOCK_FILE: &str = ".boucle.lock";
const LOG_DIR_DEFAULT: &str = "logs";
const FAILURE_STATE_FILE: &str = ".boucle-failures.json";
const FAILURE_THRESHOLD: u32 = 3;
const PROCESS_SHUTDOWN_GRACE: Duration = Duration::from_secs(5);

/// Office hours: sleep from 9pm to 6am CET/CEST (UTC+1 in winter, UTC+2 in summer)
const SLEEP_START_HOUR: u32 = 21; // 9pm
const SLEEP_END_HOUR: u32 = 6; // 6am

/// Check if we're currently in office hours (6am-9pm CET/CEST).
/// Returns true if agent should be awake, false if in sleep period.
fn is_office_hours() -> bool {
    // Get current UTC time
    let utc_now = Utc::now();

    // Convert to CET/CEST (approximation: UTC+1 in winter, UTC+2 in summer)
    // For simplicity, we'll use UTC+1 (CET) as the primary timezone
    let cet_offset = FixedOffset::east_opt(3600).unwrap(); // UTC+1
    let local_time = utc_now.with_timezone(&cet_offset);
    let hour = local_time.hour();

    // Sleep hours: 21:00 (9pm) to 06:00 (6am)
    // Awake hours: 06:00 to 21:00
    // Sleep crosses midnight (21:00-06:00), so awake = [6, 21)
    #[allow(clippy::manual_range_contains)]
    if SLEEP_START_HOUR < SLEEP_END_HOUR {
        // Normal case (e.g., 8am to 5pm) - doesn't apply here
        hour >= SLEEP_END_HOUR && hour < SLEEP_START_HOUR
    } else {
        // Sleep period crosses midnight (9pm to 6am)
        // Awake when NOT in sleep hours: hour >= 6 AND hour < 21
        hour >= SLEEP_END_HOUR && hour < SLEEP_START_HOUR
    }
}

/// Initialize a new Boucle agent.
pub fn init(root: &Path, name: &str) -> Result<(), RunnerError> {
    // Create boucle.toml
    let config_content = format!(
        r#"[agent]
name = "{name}"
model = "gpt-5.4"
system_prompt = "system-prompt.md"

[memory]
dir = "memory"
state_file = "STATE.md"

[loop]
context_dir = "context.d"
hooks_dir = "hooks"
log_dir = "logs"

[schedule]
interval = "1h"
"#
    );

    let config_path = root.join("boucle.toml");
    if config_path.exists() {
        eprintln!(
            "Warning: {} already exists, skipping (use --force to overwrite)",
            config_path.display()
        );
    } else {
        fs::write(&config_path, config_content)?;
    }

    // Create directories (idempotent)
    for dir in &[
        "memory/knowledge",
        "memory/journal",
        "context.d",
        "hooks",
        "logs",
    ] {
        fs::create_dir_all(root.join(dir))?;
    }

    // Create system prompt template (skip if exists)
    let prompt_path = root.join("system-prompt.md");
    if !prompt_path.exists() {
        let prompt = format!(
            r#"# {name}

You are {name}, an autonomous agent running in a loop.

## Each iteration

1. Read `memory/STATE.md` to understand where you left off.
2. Decide what to do based on your goals and current state.
3. Do the work (write code, run commands, research, etc.).
4. Update `memory/STATE.md` with what you learned and what comes next.

## Rules

- Be honest about what worked and what didn't.
- Don't confuse activity with progress — measure external results.
- If something needs human approval, note it in state and move on.
- Always leave enough context for your next iteration to pick up where you left off.

## Memory

Use `boucle memory remember` to store durable knowledge.
Use `boucle memory recall` to search what you've learned.
State is for "what's happening now." Memory is for "what I know."
"#
        );
        fs::write(&prompt_path, prompt)?;
    }

    // Create initial state (skip if exists)
    let state_path = root.join("memory/STATE.md");
    if !state_path.exists() {
        let state = format!(
            "# {name} — State\n\n\
             ## Initialized\n\n\
             {}\n\n\
             ## Goals\n\n\
             1. (Define your first goal here)\n\n\
             ## Last iteration\n\n\
             First run — no history yet.\n\n\
             ## Next actions\n\n\
             1. Explore the environment and figure out what's possible.\n\
             2. Define concrete goals with measurable success criteria.\n\
             3. Start working.\n",
            Utc::now().format("%Y-%m-%d %H:%M:%S UTC")
        );
        fs::write(&state_path, state)?;
    }

    // Create memory directory README for new users
    let memory_readme = r#"# Broca Memory System 🧠

Welcome to Broca! This is your agent's persistent memory system.

Broca stores knowledge as human-readable Markdown files with YAML frontmatter for structured search and retrieval. No databases required — just files, git, and intelligent indexing.

## What You're Looking At

- **Structured memories** — Each `.md` file has metadata (tags, confidence, timestamps)
- **Git-native** — Every memory change is versioned and auditable
- **Zero dependencies** — Just files you can read, edit, and backup anywhere
- **MCP compatible** — Can be shared between multiple AI agents

## Key Directories (when created)

- `knowledge/` — Facts, concepts, and structured information
- `journal/` — Timestamped entries and interaction summaries
- `experiments/` — Test results and exploration findings
- `state.md` — Current agent state (read at startup, updated at completion)

## Memory Format

```markdown
---
type: fact
tags: [python, deployment]
confidence: 0.9
learned: 2026-03-03
source: documentation
---

# FastAPI supports async/await natively

FastAPI is built on ASGI and handles async route handlers without
additional configuration. Just use `async def` for route functions.
```

## Agent Commands

```bash
# Store new memory
./target/release/boucle memory remember "API keys rotate monthly" --tags "security,ops"

# Search memories
./target/release/boucle memory recall "API keys"
./target/release/boucle memory recall "security" --limit 5

# Memory statistics
./target/release/boucle memory stats

# Add journal entry
./target/release/boucle memory journal "Discovered performance bottleneck in auth module"
```

## Manual Management

```bash
# View all memories
find . -name "*.md" | head -10

# Search content
grep -r "performance" knowledge/

# Edit directly (memories are just Markdown files)
$EDITOR knowledge/api-patterns.md

# Validate memory structure
./target/release/boucle memory validate
```

## Privacy & Security

- **Local only** — Memories stay on your machine unless explicitly shared
- **Human readable** — No proprietary formats or locked-in databases
- **Git tracked** — Full history of what your agent learned and when
- **Agent boundaries** — Memory respects the agent's approval gates and security rules

## Architecture

Broca can operate as:
- **Embedded** — Direct library usage within the agent
- **MCP Server** — Shared memory accessible by multiple agents
- **Standalone CLI** — Manual memory management and exploration

## Getting Help

- **Framework docs**: [Boucle README](../README.md)
- **Memory corruption**: Run `./target/release/boucle memory validate`
- **Performance issues**: Check `./target/release/boucle memory stats`
- **Manual backup**: `tar -czf backup-$(date +%Y%m%d).tar.gz memory/`

Your agent's memory compounds over time — every iteration makes it smarter! 🎯
"#;
    let readme_path = root.join("memory/README.md");
    if !readme_path.exists() {
        fs::write(&readme_path, memory_readme)?;
    }

    Ok(())
}

/// Run one iteration of the agent loop.
/// If `dry_run` is true, assemble and print the context without calling the LLM.
pub fn run(root: &Path, dry_run: bool) -> Result<(), RunnerError> {
    // Note office hours status (Thomas unavailable 9pm-6am CET)
    if !is_office_hours() {
        eprintln!("Note: Outside Thomas's office hours. Running autonomously — no human support available.");
    }

    let cfg = config::load(root)?;

    // Acquire lock
    let lock_path = root.join(LOCK_FILE);
    let lock_info = acquire_lock(&lock_path)?;

    // Ensure cleanup on all exit paths
    let _lock_guard = LockGuard {
        path: lock_path.clone(),
        token: lock_info.token,
    };

    let timestamp = Utc::now().format("%Y-%m-%d_%H-%M-%S").to_string();
    let log_dir = root.join(
        cfg.loop_config
            .log_dir
            .as_deref()
            .unwrap_or(LOG_DIR_DEFAULT),
    );
    fs::create_dir_all(&log_dir)?;
    let log_file = log_dir.join(format!("{timestamp}.log"));

    log(&log_file, &format!("=== Boucle loop: {timestamp} ==="))?;
    log(&log_file, &format!("Agent: {}", cfg.agent.name))?;
    log(
        &log_file,
        &format!("Max tokens: {}", cfg.loop_config.max_tokens),
    )?;

    // Run pre-run hook
    let hooks_dir = cfg.loop_config.hooks_dir.as_deref().map(|d| root.join(d));
    if let Some(ref hooks) = hooks_dir {
        hooks::run_hook(hooks, "pre-run", root)?;
    }

    // Assemble context
    let context_dir = cfg.loop_config.context_dir.as_deref().map(|d| root.join(d));
    let assembled_context = context::assemble(root, &cfg, context_dir.as_deref())?;

    log(
        &log_file,
        &format!("Context assembled: {} bytes", assembled_context.len()),
    )?;

    // Run post-context hook
    if let Some(ref hooks) = hooks_dir {
        hooks::run_hook(hooks, "post-context", root)?;
    }

    // Dry-run: print assembled context and exit
    if dry_run {
        let system_prompt_path = root.join(&cfg.agent.system_prompt);
        let system_prompt = if system_prompt_path.exists() {
            fs::read_to_string(&system_prompt_path)?
        } else {
            String::new()
        };

        println!("=== Boucle dry run ===");
        println!("Agent: {}", cfg.agent.name);
        println!("Model: {}", cfg.agent.model);
        println!();
        if !system_prompt.is_empty() {
            println!("--- System prompt ---");
            println!("{system_prompt}");
            println!();
        }
        println!("--- Context ({} bytes) ---", assembled_context.len());
        println!("{assembled_context}");
        println!("--- End dry run ---");
        log(&log_file, "Dry run complete — LLM not called.")?;
        return Ok(());
    }

    // Load system prompt
    let system_prompt_path = root.join(&cfg.agent.system_prompt);
    let system_prompt = if system_prompt_path.exists() {
        fs::read_to_string(&system_prompt_path)?
    } else {
        String::new()
    };

    let use_codex = cfg.agent.model.starts_with("gpt-");
    let llm_label = if use_codex { "codex" } else { "claude" };

    let mut llm_input = assembled_context.clone();
    if use_codex && !system_prompt.is_empty() {
        // Codex CLI has no --system-prompt flag; prepend the prompt to stdin.
        llm_input = format!("{system_prompt}\n\n---\n\n{assembled_context}");
    }

    let mut cmd = if use_codex {
        // Check that codex CLI is available.
        if process::Command::new("codex")
            .arg("--version")
            .stdout(process::Stdio::null())
            .stderr(process::Stdio::null())
            .status()
            .is_err()
        {
            return Err(RunnerError::Llm(
                "codex CLI not found. Install Codex CLI or use 'boucle run --dry-run' to preview the context without an LLM."
                    .to_string(),
            ));
        }

        let mut cmd = process::Command::new("codex");
        cmd.current_dir(root);
        cmd.arg("exec");
        cmd.arg("-m");
        cmd.arg(&cfg.agent.model);
        cmd.arg("-c");
        cmd.arg("model_reasoning_effort=\"high\"");
        cmd.arg("--dangerously-bypass-approvals-and-sandbox");
        cmd.arg("--skip-git-repo-check");
        cmd.arg("--ephemeral");
        cmd.arg("-C");
        cmd.arg(root);
        cmd.arg("-");

        let codex_home = root.join(".codex-home");
        if codex_home.exists() {
            cmd.env("CODEX_HOME", codex_home);
        }

        let tools_file = root.join("allowed-tools.txt");
        if tools_file.exists()
            || cfg
                .agent
                .allowed_tools
                .as_deref()
                .is_some_and(|tools| !tools.is_empty())
        {
            log(&log_file, "codex backend ignores allowed-tools; enforce tool policy in AGENTS.md / harness config")?;
        }
        if cfg.mcp.enable {
            log(
                &log_file,
                "codex backend ignores mcp.enable / mcp-config.json in the runner",
            )?;
        }

        cmd
    } else {
        // Check that claude CLI is available.
        if process::Command::new("claude")
            .arg("--version")
            .stdout(process::Stdio::null())
            .stderr(process::Stdio::null())
            .status()
            .is_err()
        {
            return Err(RunnerError::Llm(
                "claude CLI not found. Install it from https://docs.anthropic.com/en/docs/claude-code \
                 or use 'boucle run --dry-run' to preview the context without an LLM."
                    .to_string(),
            ));
        }

        let mut cmd = process::Command::new("claude");
        cmd.current_dir(root);
        cmd.arg("-p"); // Non-interactive
        cmd.arg("--model");
        cmd.arg(&cfg.agent.model);

        if !system_prompt.is_empty() {
            cmd.arg("--system-prompt");
            cmd.arg(&system_prompt);
        }

        // Load allowed tools (file takes precedence, then config)
        let tools_file = root.join("allowed-tools.txt");
        if tools_file.exists() {
            let tools = fs::read_to_string(&tools_file)?;
            let tool_list: Vec<&str> = tools
                .lines()
                .filter(|l| !l.trim().is_empty() && !l.starts_with('#'))
                .collect();
            if !tool_list.is_empty() {
                cmd.arg("--allowed-tools");
                cmd.arg(tool_list.join(","));
            }
        } else if let Some(ref tools) = cfg.agent.allowed_tools {
            if !tools.is_empty() {
                cmd.arg("--allowed-tools");
                cmd.arg(tools);
            }
        }

        // Add MCP configuration if enabled
        if cfg.mcp.enable {
            let mcp_config_path = root.join("mcp-config.json");
            if mcp_config_path.exists() {
                cmd.arg("--mcp-config");
                cmd.arg(&mcp_config_path);
                log(
                    &log_file,
                    &format!("MCP enabled: {}", mcp_config_path.display()),
                )?;
            } else {
                log(
                    &log_file,
                    "MCP enabled but mcp-config.json not found, creating default...",
                )?;
                // Create default MCP config
                let mcp_config = serde_json::json!({
                    "mcpServers": {
                        "boucle": {
                            "command": "./Boucle-framework/target/release/boucle",
                            "args": ["mcp", "--stdio"],
                            "env": {}
                        }
                    }
                });
                fs::write(&mcp_config_path, serde_json::to_string_pretty(&mcp_config)?)?;
                cmd.arg("--mcp-config");
                cmd.arg(&mcp_config_path);
            }
        }

        cmd
    };

    // Pass the assembled context via stdin (avoids OS arg length limits
    // and ensures the CLI reads it correctly when not on a tty).
    cmd.stdin(process::Stdio::piped());
    cmd.stdout(process::Stdio::piped());
    cmd.stderr(process::Stdio::piped());
    configure_child_process_group(&mut cmd);

    log(&log_file, &format!("Running LLM via {llm_label}..."))?;

    let mut child = cmd.spawn()?;

    // Write prompt to stdin
    if let Some(mut stdin) = child.stdin.take() {
        use std::io::Write;
        stdin.write_all(llm_input.as_bytes())?;
        // stdin is dropped here, closing the pipe
    }

    let output = wait_with_output_timeout(
        child,
        Duration::from_secs(cfg.loop_config.llm_timeout_seconds),
    )?;
    let exit_code = output.status.code().unwrap_or(-1);

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);

    log(&log_file, &format!("LLM exit code: {exit_code}"))?;
    if output.timed_out {
        log(
            &log_file,
            &format!(
                "LLM timed out after {} seconds; process group was terminated",
                cfg.loop_config.llm_timeout_seconds
            ),
        )?;
    }
    if !stdout.is_empty() {
        log(&log_file, &format!("--- stdout ---\n{stdout}"))?;
    }
    if !stderr.is_empty() {
        log(&log_file, &format!("--- stderr ---\n{stderr}"))?;
    }

    // Run post-llm hook
    if let Some(ref hooks) = hooks_dir {
        hooks::run_hook(hooks, "post-llm", root)?;
    }

    // Check if there are git changes to commit
    let git_status = process::Command::new("git")
        .current_dir(root)
        .args(["status", "--porcelain"])
        .output()?;

    if !git_status.stdout.is_empty() {
        log(&log_file, "Changes detected, committing...")?;

        process::Command::new("git")
            .current_dir(root)
            .args(["add", "-A"])
            .output()?;

        let commit_msg = format!("Loop iteration: {timestamp}");
        process::Command::new("git")
            .current_dir(root)
            .args([
                "-c",
                &format!("user.name={}", cfg.git.commit_name),
                "-c",
                &format!("user.email={}", cfg.git.commit_email),
                "commit",
                "-m",
                &commit_msg,
            ])
            .output()?;

        log(&log_file, "Committed.")?;

        // Run post-commit hook
        if let Some(ref hooks) = hooks_dir {
            hooks::run_hook(hooks, "post-commit", root)?;
        }
    }

    log(&log_file, "=== Loop complete ===")?;

    // Track consecutive failures and alert if threshold reached
    let failure_state_path = root.join(FAILURE_STATE_FILE);

    if exit_code != 0 {
        let mut state = load_failure_state(&failure_state_path);
        let now = Utc::now().to_rfc3339();

        state.consecutive_failures += 1;
        if state.first_failure.is_none() {
            state.first_failure = Some(now.clone());
        }
        state.last_failure = Some(now);
        state.last_error = Some(format!(
            "{llm_label} exited with code {exit_code}: {}",
            stdout.chars().take(200).collect::<String>()
        ));

        log(
            &log_file,
            &format!(
                "LLM failure #{} (threshold: {FAILURE_THRESHOLD})",
                state.consecutive_failures
            ),
        )?;

        if state.consecutive_failures >= FAILURE_THRESHOLD && !state.alert_sent {
            log(&log_file, "Failure threshold reached, sending alert...")?;
            // Latch only on confirmed delivery: a failed send must retry on the
            // next failure, not go silent forever. (Production once recorded 681
            // consecutive failures with zero pages because the latch was set
            // even though the email transport was broken.)
            if send_failure_alert(root, &state, &log_file) {
                state.alert_sent = true;
            }
        }

        save_failure_state(&failure_state_path, &state);

        return Err(RunnerError::Llm(format!(
            "{llm_label} exited with code {exit_code} (failure #{} of {FAILURE_THRESHOLD})",
            state.consecutive_failures
        )));
    }

    // Success — clear any failure state
    if failure_state_path.exists() {
        let old_state = load_failure_state(&failure_state_path);
        if old_state.consecutive_failures > 0 {
            log(
                &log_file,
                &format!(
                    "Recovery: cleared {} consecutive failures",
                    old_state.consecutive_failures
                ),
            )?;
        }
        let _ = fs::remove_file(&failure_state_path);
    }

    Ok(())
}

/// Show agent status.
pub fn status(root: &Path) -> Result<(), RunnerError> {
    let cfg = config::load(root)?;

    println!("Agent: {}", cfg.agent.name);
    println!("Root: {}", root.display());
    println!("Model: {}", cfg.agent.model);

    // Check lock
    let lock_path = root.join(LOCK_FILE);
    if lock_path.exists() {
        let status = fs::read_to_string(&lock_path)
            .map(|content| lock_status_label(&content))
            .unwrap_or_else(|_| "RUNNING (lock present, owner unreadable)".to_string());
        println!("Status: {status}");
    } else {
        println!("Status: idle");
    }

    // Show memory stats
    let memory_dir = root.join(&cfg.memory.dir);
    let knowledge_dir = memory_dir.join("knowledge");
    if knowledge_dir.exists() {
        let count = fs::read_dir(&knowledge_dir)?
            .filter_map(|e| e.ok())
            .filter(|e| e.path().extension().is_some_and(|ext| ext == "md"))
            .count();
        println!("Memory entries: {count}");
    }

    // Show last log
    let log_dir = root.join(
        cfg.loop_config
            .log_dir
            .as_deref()
            .unwrap_or(LOG_DIR_DEFAULT),
    );
    if log_dir.exists() {
        let mut logs: Vec<_> = fs::read_dir(&log_dir)?
            .filter_map(|e| e.ok())
            .filter(|e| e.path().extension().is_some_and(|ext| ext == "log"))
            .collect();
        logs.sort_by_key(|e| e.file_name());
        if let Some(last) = logs.last() {
            println!(
                "Last run: {}",
                last.file_name().to_string_lossy().trim_end_matches(".log")
            );
        }
    }

    Ok(())
}

/// Show loop log history.
pub fn show_log(root: &Path, count: usize) -> Result<(), RunnerError> {
    let cfg = config::load(root)?;
    let log_dir = root.join(
        cfg.loop_config
            .log_dir
            .as_deref()
            .unwrap_or(LOG_DIR_DEFAULT),
    );

    if !log_dir.exists() {
        println!("No logs yet.");
        return Ok(());
    }

    let mut logs: Vec<_> = fs::read_dir(&log_dir)?
        .filter_map(|e| e.ok())
        .filter(|e| e.path().extension().is_some_and(|ext| ext == "log"))
        .collect();
    logs.sort_by_key(|e| e.file_name());

    let start = if logs.len() > count {
        logs.len() - count
    } else {
        0
    };

    for entry in &logs[start..] {
        let name = entry.file_name();
        let timestamp = name.to_string_lossy().trim_end_matches(".log").to_string();
        println!("--- {timestamp} ---");

        let content = fs::read_to_string(entry.path())?;
        // Show first few lines
        for line in content.lines().take(5) {
            println!("  {line}");
        }
        println!();
    }

    Ok(())
}

/// Set up scheduling.
pub fn schedule(root: &Path, interval: &str) -> Result<(), RunnerError> {
    let cfg = config::load(root)?;

    // Use provided interval, or fall back to config
    let effective_interval = if interval.is_empty() {
        &cfg.schedule.interval
    } else {
        interval
    };

    let seconds = config::parse_interval(effective_interval)
        .map_err(|e| RunnerError::Io(io::Error::new(io::ErrorKind::InvalidInput, e)))?;
    let boucle_path = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("boucle"));

    if cfg!(target_os = "macos") {
        let plist = generate_launchd_plist(&cfg.agent.name, &boucle_path, root, seconds);
        println!(
            "# Save this as ~/Library/LaunchAgents/com.boucle.{}.plist",
            cfg.agent.name
        );
        println!("{plist}");
        println!("\n# Then run:");
        println!(
            "# launchctl load ~/Library/LaunchAgents/com.boucle.{}.plist",
            cfg.agent.name
        );
    } else {
        let cron = generate_cron_entry(&boucle_path, root, seconds);
        println!("# Add this to your crontab (crontab -e):");
        println!("{cron}");
    }

    Ok(())
}

// --- Lock management ---

#[derive(Clone, Debug, PartialEq, Eq)]
struct LockInfo {
    pid: u32,
    token: String,
    started_at_unix_ms: u128,
    process_start: Option<String>,
}

fn acquire_lock(lock_path: &Path) -> Result<LockInfo, RunnerError> {
    if lock_path.exists() {
        let content = fs::read_to_string(lock_path)?;
        if let Some(info) = parse_lock_info(&content) {
            if lock_matches_running_process(&info) {
                return Err(RunnerError::Lock(format!(
                    "Another loop is running (PID: {})",
                    info.pid
                )));
            }
        }

        // Stale lock, remove it
        fs::remove_file(lock_path)?;
    }

    let info = current_lock_info();
    fs::write(lock_path, render_lock_info(&info))?;
    Ok(info)
}

struct LockGuard {
    path: PathBuf,
    token: String,
}

impl Drop for LockGuard {
    fn drop(&mut self) {
        if let Ok(content) = fs::read_to_string(&self.path) {
            if parse_lock_info(&content).is_some_and(|info| info.token == self.token) {
                let _ = fs::remove_file(&self.path);
            }
        }
    }
}

fn is_process_running(pid: u32) -> bool {
    // Use kill(pid, 0) syscall directly — no subprocess, no flakiness under load
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

fn current_lock_info() -> LockInfo {
    let pid = std::process::id();
    let started_at_unix_ms = current_unix_millis();
    LockInfo {
        pid,
        token: format!("{pid}-{started_at_unix_ms}"),
        started_at_unix_ms,
        process_start: process_start_fingerprint(pid),
    }
}

fn render_lock_info(info: &LockInfo) -> String {
    let process_start = info.process_start.clone().unwrap_or_default();
    format!(
        "version=2\npid={}\ntoken={}\nstarted_at_unix_ms={}\nprocess_start={}\n",
        info.pid, info.token, info.started_at_unix_ms, process_start
    )
}

fn lock_status_label(content: &str) -> String {
    if let Some(info) = parse_lock_info(content) {
        if lock_matches_running_process(&info) {
            return format!("RUNNING (PID: {})", info.pid);
        }
        return format!("STALE LOCK (PID: {})", info.pid);
    }

    "RUNNING (lock present, owner unreadable)".to_string()
}

fn parse_lock_info(content: &str) -> Option<LockInfo> {
    let trimmed = content.trim();
    if let Ok(pid) = trimmed.parse::<u32>() {
        return Some(LockInfo {
            pid,
            token: String::new(),
            started_at_unix_ms: 0,
            process_start: None,
        });
    }

    let mut pid = None;
    let mut token = None;
    let mut started_at_unix_ms = None;
    let mut process_start = None;
    for line in content.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        match key.trim() {
            "pid" => pid = value.trim().parse::<u32>().ok(),
            "token" => token = Some(value.trim().to_string()),
            "started_at_unix_ms" => started_at_unix_ms = value.trim().parse::<u128>().ok(),
            "process_start" => {
                let value = value.trim();
                if !value.is_empty() {
                    process_start = Some(value.to_string());
                }
            }
            _ => {}
        }
    }

    Some(LockInfo {
        pid: pid?,
        token: token?,
        started_at_unix_ms: started_at_unix_ms.unwrap_or_default(),
        process_start,
    })
}

fn lock_matches_running_process(info: &LockInfo) -> bool {
    if !is_process_running(info.pid) {
        return false;
    }

    if let Some(stored) = info.process_start.as_deref() {
        if let Some(current) = process_start_fingerprint(info.pid) {
            return current == stored;
        }
    }

    // Be conservative for legacy locks or platforms where start time is unavailable.
    true
}

fn current_unix_millis() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or_default()
}

fn process_start_fingerprint(pid: u32) -> Option<String> {
    let output = process::Command::new("ps")
        .args(["-p", &pid.to_string(), "-o", "lstart="])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let fingerprint = stdout.trim();
    if fingerprint.is_empty() {
        None
    } else {
        Some(fingerprint.to_string())
    }
}

#[derive(Debug)]
struct TimedProcessOutput {
    status: process::ExitStatus,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    timed_out: bool,
}

#[cfg(unix)]
fn configure_child_process_group(cmd: &mut process::Command) {
    use std::os::unix::process::CommandExt;
    unsafe {
        cmd.pre_exec(|| {
            if libc::setpgid(0, 0) == 0 {
                Ok(())
            } else {
                Err(io::Error::last_os_error())
            }
        });
    }
}

#[cfg(not(unix))]
fn configure_child_process_group(_cmd: &mut process::Command) {}

fn wait_with_output_timeout(
    mut child: process::Child,
    timeout: Duration,
) -> Result<TimedProcessOutput, RunnerError> {
    let stdout_handle = child.stdout.take().map(spawn_reader);
    let stderr_handle = child.stderr.take().map(spawn_reader);
    let deadline = Instant::now() + timeout;
    let mut timed_out = false;

    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }

        if Instant::now() >= deadline {
            timed_out = true;
            terminate_child_group(child.id(), false);

            let grace_deadline = Instant::now() + PROCESS_SHUTDOWN_GRACE;
            let shutdown_status = loop {
                if let Some(status) = child.try_wait()? {
                    break status;
                }
                if Instant::now() >= grace_deadline {
                    terminate_child_group(child.id(), true);
                    break child.wait()?;
                }
                thread::sleep(Duration::from_millis(100));
            };
            break shutdown_status;
        }

        thread::sleep(Duration::from_millis(200));
    };

    let stdout = join_reader(stdout_handle)?;
    let stderr = join_reader(stderr_handle)?;
    Ok(TimedProcessOutput {
        status,
        stdout,
        stderr,
        timed_out,
    })
}

fn spawn_reader<R: io::Read + Send + 'static>(
    mut reader: R,
) -> thread::JoinHandle<io::Result<Vec<u8>>> {
    thread::spawn(move || {
        let mut buf = Vec::new();
        reader.read_to_end(&mut buf)?;
        Ok(buf)
    })
}

fn join_reader(
    handle: Option<thread::JoinHandle<io::Result<Vec<u8>>>>,
) -> Result<Vec<u8>, RunnerError> {
    match handle {
        Some(handle) => handle
            .join()
            .map_err(|_| RunnerError::Llm("process output reader panicked".to_string()))?
            .map_err(RunnerError::Io),
        None => Ok(Vec::new()),
    }
}

#[cfg(unix)]
fn terminate_child_group(pid: u32, force: bool) {
    let signal = if force { libc::SIGKILL } else { libc::SIGTERM };
    unsafe {
        let pgid = -(pid as libc::pid_t);
        if libc::kill(pgid, signal) != 0 {
            let _ = libc::kill(pid as libc::pid_t, signal);
        }
    }
}

#[cfg(not(unix))]
fn terminate_child_group(pid: u32, force: bool) {
    let mut cmd = process::Command::new("taskkill");
    cmd.arg("/T");
    if force {
        cmd.arg("/F");
    }
    let _ = cmd.args(["/PID", &pid.to_string()]).output();
}

// --- Helpers ---

fn log(log_file: &Path, message: &str) -> Result<(), io::Error> {
    use std::io::Write;
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_file)?;
    writeln!(file, "{}", message)?;
    Ok(())
}

fn load_failure_state(path: &Path) -> FailureState {
    fs::read_to_string(path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn save_failure_state(path: &Path, state: &FailureState) {
    if let Ok(json) = serde_json::to_string_pretty(state) {
        let _ = fs::write(path, json);
    }
}

fn send_failure_alert(root: &Path, state: &FailureState, log_file: &Path) -> bool {
    let subject = format!(
        "Boucle: {} consecutive LLM failures",
        state.consecutive_failures
    );
    let body = format!(
        "Boucle has failed {} consecutive times.\n\n\
         First failure: {}\n\
         Last failure:  {}\n\
         Last error:    {}\n\n\
         The loop will keep retrying but likely needs manual attention \
         (expired token? API outage?).\n",
        state.consecutive_failures,
        state.first_failure.as_deref().unwrap_or("unknown"),
        state.last_failure.as_deref().unwrap_or("unknown"),
        state.last_error.as_deref().unwrap_or("unknown"),
    );

    // Email primary — works even if Linear/Claude tokens are the broken thing.
    // Returns true only on CONFIRMED delivery; the caller must not latch
    // alert_sent on a failed or skipped send.
    let send_email = root.join("send-email.py");
    if !send_email.exists() {
        let _ = log(
            log_file,
            "Alert NOT sent: send-email.py not found in agent root — no alert transport configured.",
        );
        return false;
    }
    let result = process::Command::new("python3")
        .arg(&send_email)
        .arg("thomas.leger@tlgr.io")
        .arg(&subject)
        .arg(&body)
        .current_dir(root)
        .output();
    match result {
        Ok(o) if o.status.success() => {
            let _ = log(log_file, "Alert email sent.");
            true
        }
        Ok(o) => {
            let stderr: String = String::from_utf8_lossy(&o.stderr)
                .chars()
                .take(300)
                .collect();
            let stdout: String = String::from_utf8_lossy(&o.stdout)
                .chars()
                .take(300)
                .collect();
            let _ = log(
                log_file,
                &format!(
                    "Alert email FAILED to send (exit {:?}). stdout: {} stderr: {}",
                    o.status.code(),
                    stdout.trim(),
                    stderr.trim()
                ),
            );
            false
        }
        Err(e) => {
            let _ = log(
                log_file,
                &format!("Alert email FAILED to spawn python3: {e}"),
            );
            false
        }
    }
}

fn generate_launchd_plist(name: &str, binary: &Path, root: &Path, interval_secs: u64) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.boucle.{name}</string>
    <key>ProgramArguments</key>
    <array>
        <string>{binary}</string>
        <string>--root</string>
        <string>{root}</string>
        <string>run</string>
    </array>
    <key>StartInterval</key>
    <integer>{interval_secs}</integer>
    <key>WorkingDirectory</key>
    <string>{root}</string>
    <key>StandardOutPath</key>
    <string>{root}/logs/launchd-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>{root}/logs/launchd-stderr.log</string>
</dict>
</plist>"#,
        binary = binary.display(),
        root = root.display(),
    )
}

fn generate_cron_entry(binary: &Path, root: &Path, interval_secs: u64) -> String {
    let minutes = interval_secs / 60;
    let cron_expr = if minutes == 0 {
        "* * * * *".to_string() // Every minute
    } else if minutes < 60 {
        format!("*/{minutes} * * * *")
    } else {
        let hours = minutes / 60;
        format!("0 */{hours} * * *")
    };

    format!(
        "{cron_expr} cd {} && {} run",
        root.display(),
        binary.display()
    )
}

/// Check prerequisites and agent health.
pub fn doctor(root: &Path) -> Result<(), RunnerError> {
    let mut passed = 0u32;
    let mut warned = 0u32;
    let mut failed = 0u32;

    println!("Boucle Doctor");
    println!("=============\n");

    // 1. Check boucle.toml
    let config_path = root.join("boucle.toml");
    if config_path.exists() {
        match config::load(root) {
            Ok(cfg) => {
                println!(
                    "[ok]  boucle.toml — agent '{}', model '{}'",
                    cfg.agent.name, cfg.agent.model
                );
                passed += 1;

                // 2. Check memory directory
                let memory_dir = root.join(&cfg.memory.dir);
                if memory_dir.exists() {
                    let knowledge_dir = memory_dir.join("knowledge");
                    let journal_dir = memory_dir.join("journal");
                    let state_file = memory_dir.join(&cfg.memory.state_file);
                    let mut mem_issues = Vec::new();
                    if !knowledge_dir.exists() {
                        mem_issues.push("knowledge/ missing");
                    }
                    if !journal_dir.exists() {
                        mem_issues.push("journal/ missing");
                    }
                    if !state_file.exists() {
                        mem_issues.push("state file missing");
                    }
                    if mem_issues.is_empty() {
                        println!("[ok]  memory — {}", memory_dir.display());
                        passed += 1;
                    } else {
                        println!(
                            "[warn] memory — {} ({})",
                            memory_dir.display(),
                            mem_issues.join(", ")
                        );
                        warned += 1;
                    }
                } else {
                    println!(
                        "[FAIL] memory — directory '{}' not found",
                        memory_dir.display()
                    );
                    failed += 1;
                }

                // 3. Check system prompt
                let prompt_path = root.join(&cfg.agent.system_prompt);
                if prompt_path.exists() {
                    println!("[ok]  system prompt — {}", cfg.agent.system_prompt);
                    passed += 1;
                } else {
                    println!(
                        "[warn] system prompt — '{}' not found (optional but recommended)",
                        cfg.agent.system_prompt
                    );
                    warned += 1;
                }

                // 4. Check hooks directory
                let hooks_path = cfg.loop_config.hooks_dir.as_deref().unwrap_or("hooks");
                let hooks_dir = root.join(hooks_path);
                if hooks_dir.exists() {
                    let mut hook_count = 0;
                    let mut non_exec = Vec::new();
                    if let Ok(entries) = fs::read_dir(&hooks_dir) {
                        for entry in entries.flatten() {
                            let path = entry.path();
                            if path.is_file() {
                                hook_count += 1;
                                #[cfg(unix)]
                                {
                                    use std::os::unix::fs::PermissionsExt;
                                    let perms = fs::metadata(&path)
                                        .map(|m| m.permissions().mode())
                                        .unwrap_or(0);
                                    if perms & 0o111 == 0 {
                                        non_exec
                                            .push(entry.file_name().to_string_lossy().to_string());
                                    }
                                }
                            }
                        }
                    }
                    if non_exec.is_empty() {
                        println!("[ok]  hooks — {} hook(s) found", hook_count);
                        passed += 1;
                    } else {
                        println!(
                            "[warn] hooks — {} hook(s), but not executable: {}",
                            hook_count,
                            non_exec.join(", ")
                        );
                        warned += 1;
                    }
                } else {
                    println!("[ok]  hooks — none configured (optional)");
                    passed += 1;
                }

                // 5. Check context.d directory
                let context_path = cfg
                    .loop_config
                    .context_dir
                    .as_deref()
                    .unwrap_or("context.d");
                let context_dir = root.join(context_path);
                if context_dir.exists() {
                    let count = fs::read_dir(&context_dir).map(|r| r.count()).unwrap_or(0);
                    println!("[ok]  context plugins — {} script(s)", count);
                    passed += 1;
                } else {
                    println!("[ok]  context plugins — none configured (optional)");
                    passed += 1;
                }
            }
            Err(e) => {
                println!("[FAIL] boucle.toml — parse error: {e}");
                failed += 1;
            }
        }
    } else {
        println!("[FAIL] boucle.toml — not found in {}", root.display());
        println!("       Run 'boucle init' to create one.");
        failed += 1;
    }

    // 6. Check the configured LLM CLI
    let model = config::load(root)
        .map(|cfg| cfg.agent.model)
        .unwrap_or_default();
    let (cli_name, version_arg, install_hint) = if model.starts_with("gpt-") {
        (
            "codex",
            "--version",
            "Install Codex CLI or choose a Claude model.",
        )
    } else {
        (
            "claude",
            "--version",
            "Install: https://docs.anthropic.com/en/docs/claude-code",
        )
    };
    match process::Command::new(cli_name).arg(version_arg).output() {
        Ok(output) if output.status.success() => {
            let version_stdout = String::from_utf8_lossy(&output.stdout);
            let version_stderr = String::from_utf8_lossy(&output.stderr);
            let version = if version_stdout.trim().is_empty() {
                version_stderr.trim()
            } else {
                version_stdout.trim()
            };
            println!("[ok]  {cli_name} CLI — {version}");
            passed += 1;
        }
        _ => {
            println!("[FAIL] {cli_name} CLI — not found on PATH");
            println!("       {install_hint}");
            failed += 1;
        }
    }

    // 7. Check git
    match process::Command::new("git")
        .args(["rev-parse", "--git-dir"])
        .current_dir(root)
        .output()
    {
        Ok(output) if output.status.success() => {
            println!("[ok]  git — repository initialized");
            passed += 1;
        }
        _ => {
            println!("[warn] git — not a git repository (memory won't be versioned)");
            println!(
                "       Run 'git init' in {} to enable versioning",
                root.display()
            );
            warned += 1;
        }
    }

    // Summary
    println!();
    if failed == 0 && warned == 0 {
        println!("All checks passed ({passed} ok). Ready to run!");
    } else if failed == 0 {
        println!(
            "{passed} ok, {warned} warning(s). Agent can run but some features may be limited."
        );
    } else {
        println!("{passed} ok, {warned} warning(s), {failed} FAILED. Fix failures before running.");
    }

    Ok(())
}

/// Show aggregate loop statistics parsed from log files.
pub fn show_stats(root: &Path) -> Result<(), RunnerError> {
    let cfg = config::load(root)?;
    let log_dir = root.join(
        cfg.loop_config
            .log_dir
            .as_deref()
            .unwrap_or(LOG_DIR_DEFAULT),
    );

    if !log_dir.exists() {
        println!("No logs directory found. Run `boucle run` first.");
        return Ok(());
    }

    let mut logs: Vec<_> = fs::read_dir(&log_dir)?
        .filter_map(|e| e.ok())
        .filter(|e| e.path().extension().is_some_and(|ext| ext == "log"))
        .collect();
    logs.sort_by_key(|e| e.file_name());

    if logs.is_empty() {
        println!("No loop logs found yet. Run `boucle run` to create one.");
        return Ok(());
    }

    let mut total = 0u32;
    let mut successes = 0u32;
    let mut failures = 0u32;
    let mut dry_runs = 0u32;
    let mut total_context_bytes: u64 = 0;
    let mut context_count = 0u32;
    let mut first_timestamp: Option<String> = None;
    let mut last_timestamp: Option<String> = None;

    for entry in &logs {
        let name = entry.file_name();
        let timestamp = name.to_string_lossy().trim_end_matches(".log").to_string();

        if first_timestamp.is_none() {
            first_timestamp = Some(timestamp.clone());
        }
        last_timestamp = Some(timestamp);

        total += 1;

        let content = fs::read_to_string(entry.path()).unwrap_or_default();

        // Parse exit code
        let mut found_exit = false;
        for line in content.lines() {
            if let Some(rest) = line.strip_prefix("LLM exit code: ") {
                found_exit = true;
                match rest.trim().parse::<i32>() {
                    Ok(0) => successes += 1,
                    _ => failures += 1,
                }
            }
            if line.contains("Dry run complete") {
                dry_runs += 1;
            }
            if let Some(rest) = line.strip_prefix("Context assembled: ") {
                if let Some(bytes_str) = rest.strip_suffix(" bytes") {
                    if let Ok(bytes) = bytes_str.trim().parse::<u64>() {
                        total_context_bytes += bytes;
                        context_count += 1;
                    }
                }
            }
        }

        // Log with no exit code and not a dry run = interrupted/crashed
        if !found_exit && !content.contains("Dry run complete") {
            failures += 1;
        }
    }

    // Display
    println!("Boucle Stats");
    println!("============\n");

    println!("Agent: {}", cfg.agent.name);
    println!("Total loops: {total}");

    if let (Some(first), Some(last)) = (&first_timestamp, &last_timestamp) {
        println!("First loop:  {first}");
        println!("Last loop:   {last}");
    }

    println!();
    println!("Outcomes:");
    println!("  Succeeded:    {successes}");
    println!("  Failed:       {failures}");
    println!("  Dry runs:     {dry_runs}");

    if successes + failures > 0 {
        let rate = (successes as f64 / (successes + failures) as f64) * 100.0;
        println!("  Success rate: {rate:.1}%");
    }

    if context_count > 0 {
        let avg = total_context_bytes / context_count as u64;
        println!();
        println!("Context:");
        println!(
            "  Average size: {} bytes ({:.1} KB)",
            avg,
            avg as f64 / 1024.0
        );
        println!(
            "  Total sent:   {} bytes ({:.1} KB)",
            total_context_bytes,
            total_context_bytes as f64 / 1024.0
        );
    }

    // Calculate loops per day if we have timestamps
    if let (Some(first), Some(last)) = (&first_timestamp, &last_timestamp) {
        if first != last {
            if let (Some(first_dt), Some(last_dt)) = (
                NaiveDateTime::parse_from_str(first, "%Y-%m-%d_%H-%M-%S").ok(),
                NaiveDateTime::parse_from_str(last, "%Y-%m-%d_%H-%M-%S").ok(),
            ) {
                let duration = last_dt - first_dt;
                let days = duration.num_hours() as f64 / 24.0;
                if days > 0.0 {
                    println!();
                    println!("Throughput:");
                    println!("  Duration:      {:.1} days", days);
                    println!("  Loops per day: {:.1}", total as f64 / days);
                }
            }
        }
    }

    Ok(())
}

/// Validate boucle.toml configuration for common mistakes and misconfigurations.
///
/// Unlike `doctor` (which checks prerequisites exist), `validate` checks the
/// config *content* for semantic correctness: typos, bad values, unreachable
/// paths, and known anti-patterns.
pub fn validate(root: &Path) -> Result<(), RunnerError> {
    let config_path = root.join("boucle.toml");
    if !config_path.exists() {
        println!("No boucle.toml found in {}", root.display());
        println!("Run 'boucle init' to create one.");
        return Ok(());
    }

    let raw = fs::read_to_string(&config_path)?;
    let mut errors: Vec<String> = Vec::new();
    let mut warnings: Vec<String> = Vec::new();

    // 1. Check for unknown top-level keys (common typos)
    let known_sections = ["agent", "memory", "loop", "schedule", "git", "mcp"];
    match raw.parse::<toml::Table>() {
        Ok(table) => {
            for key in table.keys() {
                if !known_sections.contains(&key.as_str()) {
                    warnings.push(format!(
                        "Unknown section '[{key}]' — expected one of: {}",
                        known_sections.join(", ")
                    ));
                }
            }

            // Check unknown keys within known sections
            let known_agent_keys = [
                "name",
                "model",
                "system_prompt",
                "allowed_tools",
                "description",
                "version",
            ];
            let known_memory_keys = ["dir", "state_file"];
            let known_loop_keys = [
                "context_dir",
                "hooks_dir",
                "log_dir",
                "max_tokens",
                "llm_timeout_seconds",
            ];
            let known_schedule_keys = ["interval", "method"];
            let known_git_keys = ["commit_name", "commit_email"];
            let known_mcp_keys = ["enable"];

            check_section_keys(&table, "agent", &known_agent_keys, &mut warnings);
            check_section_keys(&table, "memory", &known_memory_keys, &mut warnings);
            check_section_keys(&table, "loop", &known_loop_keys, &mut warnings);
            check_section_keys(&table, "schedule", &known_schedule_keys, &mut warnings);
            check_section_keys(&table, "git", &known_git_keys, &mut warnings);
            check_section_keys(&table, "mcp", &known_mcp_keys, &mut warnings);
        }
        Err(e) => {
            errors.push(format!("TOML parse error: {e}"));
            // Can't do further validation if we can't parse
            print_validation_results(&errors, &warnings);
            return Ok(());
        }
    }

    // 2. Try loading as typed config
    let cfg = match config::load(root) {
        Ok(c) => c,
        Err(e) => {
            errors.push(format!("Config load error: {e}"));
            print_validation_results(&errors, &warnings);
            return Ok(());
        }
    };

    // 3. Validate agent section
    if cfg.agent.name.is_empty() {
        errors.push("agent.name is empty".to_string());
    }
    if cfg.agent.name.contains(' ') {
        warnings
            .push("agent.name contains spaces — consider using hyphens or underscores".to_string());
    }

    // 4. Validate model name
    let model = &cfg.agent.model;
    let known_prefixes = ["claude-", "gpt-", "o1-", "o3-", "gemini-"];
    if !known_prefixes.iter().any(|p| model.starts_with(p)) {
        warnings.push(format!(
            "agent.model '{model}' doesn't match known model prefixes (claude-, gpt-, gemini-, o1-, o3-)"
        ));
    }

    // 5. Validate interval format
    if let Err(e) = config::parse_interval(&cfg.schedule.interval) {
        errors.push(format!(
            "schedule.interval '{}': {e}",
            cfg.schedule.interval
        ));
    } else {
        let seconds = config::parse_interval(&cfg.schedule.interval).unwrap();
        if seconds < 60 {
            warnings.push(format!(
                "schedule.interval '{}' is under 1 minute — this will consume tokens very quickly",
                cfg.schedule.interval
            ));
        }
        if seconds > 86400 {
            warnings.push(format!(
                "schedule.interval '{}' is over 24 hours — agent will be slow to respond",
                cfg.schedule.interval
            ));
        }
    }

    // 6. Validate max_tokens
    if cfg.loop_config.max_tokens == 0 {
        errors.push("loop.max_tokens is 0 — LLM calls will fail".to_string());
    } else if cfg.loop_config.max_tokens < 1000 {
        warnings.push(format!(
            "loop.max_tokens is {} — very low, agent may not have enough context",
            cfg.loop_config.max_tokens
        ));
    } else if cfg.loop_config.max_tokens > 1_000_000 {
        warnings.push(format!(
            "loop.max_tokens is {} — unusually high, check if this is intentional",
            cfg.loop_config.max_tokens
        ));
    }

    if cfg.loop_config.llm_timeout_seconds == 0 {
        errors.push(
            "loop.llm_timeout_seconds is 0 — LLM calls would be killed immediately".to_string(),
        );
    } else if cfg.loop_config.llm_timeout_seconds < 60 {
        warnings.push(format!(
            "loop.llm_timeout_seconds is {} — very short, normal LLM calls may be killed",
            cfg.loop_config.llm_timeout_seconds
        ));
    }

    // 7. Validate memory paths
    let memory_dir = root.join(&cfg.memory.dir);
    let state_path = memory_dir.join(&cfg.memory.state_file);
    if memory_dir.exists() && !state_path.exists() {
        warnings.push(format!(
            "memory.state_file '{}' not found in {} — will be created on first run",
            cfg.memory.state_file, cfg.memory.dir
        ));
    }

    // Check state_file isn't an absolute path
    if cfg.memory.state_file.starts_with('/') {
        errors.push("memory.state_file should be relative to memory.dir, not absolute".to_string());
    }

    // 8. Validate system prompt
    let prompt_path = root.join(&cfg.agent.system_prompt);
    if !prompt_path.exists() && cfg.agent.system_prompt != "system-prompt.md" {
        // Non-default prompt path that doesn't exist is likely a mistake
        warnings.push(format!(
            "agent.system_prompt '{}' not found — agent will run without system prompt",
            cfg.agent.system_prompt
        ));
    }

    // 9. Check for path traversal in config values
    let path_values = [
        ("memory.dir", &cfg.memory.dir),
        ("memory.state_file", &cfg.memory.state_file),
        ("agent.system_prompt", &cfg.agent.system_prompt),
    ];
    for (key, value) in &path_values {
        if value.contains("..") {
            warnings.push(format!(
                "{key} contains '..' — avoid path traversal in config"
            ));
        }
    }

    // 10. Check git config
    if cfg.git.commit_email == "boucle@agent" {
        warnings.push(
            "git.commit_email is default 'boucle@agent' — set a real email for better git history"
                .to_string(),
        );
    }

    print_validation_results(&errors, &warnings);
    Ok(())
}

fn check_section_keys(
    table: &toml::Table,
    section: &str,
    known_keys: &[&str],
    warnings: &mut Vec<String>,
) {
    if let Some(toml::Value::Table(sec)) = table.get(section) {
        for key in sec.keys() {
            if !known_keys.contains(&key.as_str()) {
                warnings.push(format!(
                    "Unknown key '{key}' in [{section}] — expected one of: {}",
                    known_keys.join(", ")
                ));
            }
        }
    }
}

fn print_validation_results(errors: &[String], warnings: &[String]) {
    println!("Boucle Validate");
    println!("===============\n");

    if errors.is_empty() && warnings.is_empty() {
        println!("Config is valid. No issues found.");
        return;
    }

    for e in errors {
        println!("[ERROR]   {e}");
    }
    for w in warnings {
        println!("[warning] {w}");
    }

    println!();
    if errors.is_empty() {
        println!(
            "{} warning(s), 0 errors. Config will work but review the warnings.",
            warnings.len()
        );
    } else {
        println!(
            "{} error(s), {} warning(s). Fix errors before running.",
            errors.len(),
            warnings.len()
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_init_creates_files() {
        let dir = tempfile::tempdir().unwrap();
        init(dir.path(), "test-agent").unwrap();

        assert!(dir.path().join("boucle.toml").exists());
        assert!(dir.path().join("system-prompt.md").exists());
        assert!(dir.path().join("memory/STATE.md").exists());
        assert!(dir.path().join("memory/knowledge").is_dir());
        assert!(dir.path().join("context.d").is_dir());
        assert!(dir.path().join("hooks").is_dir());
        assert!(dir.path().join("logs").is_dir());
    }

    #[test]
    fn test_init_config_is_valid() {
        let dir = tempfile::tempdir().unwrap();
        init(dir.path(), "test-agent").unwrap();

        let cfg = config::load(dir.path()).unwrap();
        assert_eq!(cfg.agent.name, "test-agent");
    }

    #[test]
    fn test_alert_not_sent_without_transport() {
        // A missing send-email.py must return false so the caller never
        // latches alert_sent on a send that did not happen.
        let dir = tempfile::tempdir().unwrap();
        let log_file = dir.path().join("test.log");
        let state = FailureState {
            consecutive_failures: 3,
            ..Default::default()
        };
        assert!(!send_failure_alert(dir.path(), &state, &log_file));
        let logged = fs::read_to_string(&log_file).unwrap_or_default();
        assert!(logged.contains("Alert NOT sent"));
    }

    #[test]
    fn test_alert_failed_send_returns_false_and_logs_stderr() {
        // A transport that exits non-zero must return false and surface stderr.
        let dir = tempfile::tempdir().unwrap();
        let log_file = dir.path().join("test.log");
        fs::write(
            dir.path().join("send-email.py"),
            "import sys\nprint('smtp handshake', file=sys.stderr)\nsys.exit(1)\n",
        )
        .unwrap();
        let state = FailureState {
            consecutive_failures: 3,
            ..Default::default()
        };
        assert!(!send_failure_alert(dir.path(), &state, &log_file));
        let logged = fs::read_to_string(&log_file).unwrap_or_default();
        assert!(logged.contains("FAILED to send"));
        assert!(logged.contains("smtp handshake"));
    }

    #[test]
    fn test_alert_successful_send_returns_true() {
        let dir = tempfile::tempdir().unwrap();
        let log_file = dir.path().join("test.log");
        fs::write(dir.path().join("send-email.py"), "print('sent')\n").unwrap();
        let state = FailureState {
            consecutive_failures: 3,
            ..Default::default()
        };
        assert!(send_failure_alert(dir.path(), &state, &log_file));
    }

    #[test]
    fn test_failure_state_tolerates_foreign_schema() {
        // A file written by another tool (extra/missing fields) must parse
        // with defaults instead of silently resetting via a hard error path.
        let parsed: FailureState = serde_json::from_str(
            r#"{"consecutive_failures": 5, "type": "runtime", "unknown_field": 1}"#,
        )
        .unwrap();
        assert_eq!(parsed.consecutive_failures, 5);
        assert!(!parsed.alert_sent);
    }

    #[test]
    fn test_lock_acquire_release() {
        let dir = tempfile::tempdir().unwrap();
        let lock_path = dir.path().join(LOCK_FILE);

        // Acquire
        acquire_lock(&lock_path).unwrap();
        assert!(lock_path.exists());

        // Can't acquire again (our own PID is running)
        assert!(acquire_lock(&lock_path).is_err());

        // Release
        fs::remove_file(&lock_path).unwrap();

        // Can acquire again
        acquire_lock(&lock_path).unwrap();
    }

    #[test]
    fn test_lock_stale_cleanup() {
        let dir = tempfile::tempdir().unwrap();
        let lock_path = dir.path().join(LOCK_FILE);

        // Write a PID that definitely doesn't exist
        fs::write(&lock_path, "99999999").unwrap();

        // Should clean up stale lock and acquire
        acquire_lock(&lock_path).unwrap();
        assert!(lock_path.exists());
    }

    #[test]
    fn test_doctor_after_init() {
        let dir = tempfile::tempdir().unwrap();
        init(dir.path(), "doc-test").unwrap();
        // Doctor should succeed on a freshly initialized agent
        assert!(doctor(dir.path()).is_ok());
    }

    #[test]
    fn test_doctor_no_config() {
        let dir = tempfile::tempdir().unwrap();
        // Doctor should succeed (returns Ok) even with no config — it just reports failures
        assert!(doctor(dir.path()).is_ok());
    }

    #[test]
    fn test_lock_guard_cleanup() {
        let dir = tempfile::tempdir().unwrap();
        let lock_path = dir.path().join(LOCK_FILE);

        {
            let info = LockInfo {
                pid: std::process::id(),
                token: "owner-token".to_string(),
                started_at_unix_ms: 1,
                process_start: None,
            };
            fs::write(&lock_path, render_lock_info(&info)).unwrap();
            let _guard = LockGuard {
                path: lock_path.clone(),
                token: info.token,
            };
            assert!(lock_path.exists());
        }
        // Guard dropped, lock should be removed
        assert!(!lock_path.exists());
    }

    #[test]
    fn test_lock_guard_does_not_remove_new_owner() {
        let dir = tempfile::tempdir().unwrap();
        let lock_path = dir.path().join(LOCK_FILE);
        let old_info = LockInfo {
            pid: std::process::id(),
            token: "old-token".to_string(),
            started_at_unix_ms: 1,
            process_start: None,
        };
        let new_info = LockInfo {
            pid: std::process::id(),
            token: "new-token".to_string(),
            started_at_unix_ms: 2,
            process_start: None,
        };

        {
            fs::write(&lock_path, render_lock_info(&new_info)).unwrap();
            let _guard = LockGuard {
                path: lock_path.clone(),
                token: old_info.token,
            };
        }

        assert_eq!(
            parse_lock_info(&fs::read_to_string(lock_path).unwrap()),
            Some(new_info)
        );
    }

    #[test]
    fn test_lock_info_round_trip_and_legacy_pid() {
        let info = LockInfo {
            pid: 42,
            token: "token-42".to_string(),
            started_at_unix_ms: 123,
            process_start: Some("Mon May 25 12:00:00 2026".to_string()),
        };
        assert_eq!(parse_lock_info(&render_lock_info(&info)), Some(info));

        let legacy = parse_lock_info("12345\n").unwrap();
        assert_eq!(legacy.pid, 12345);
        assert!(legacy.token.is_empty());
    }

    #[test]
    fn test_lock_status_label_formats_running_structured_and_legacy_locks() {
        let info = current_lock_info();

        assert_eq!(
            lock_status_label(&render_lock_info(&info)),
            format!("RUNNING (PID: {})", std::process::id())
        );
        assert_eq!(
            lock_status_label(&format!("{}\n", std::process::id())),
            format!("RUNNING (PID: {})", std::process::id())
        );
        assert_eq!(
            lock_status_label("not a lock owner record"),
            "RUNNING (lock present, owner unreadable)"
        );
    }

    #[test]
    fn test_lock_status_label_formats_stale_locks() {
        let info = LockInfo {
            pid: 99999999,
            token: "token-99999999".to_string(),
            started_at_unix_ms: 123,
            process_start: None,
        };

        assert_eq!(
            lock_status_label(&render_lock_info(&info)),
            "STALE LOCK (PID: 99999999)"
        );
        assert_eq!(
            lock_status_label("99999999\n"),
            "STALE LOCK (PID: 99999999)"
        );
    }

    #[cfg(unix)]
    #[test]
    fn test_wait_with_output_timeout_kills_process_group() {
        let mut cmd = process::Command::new("sh");
        cmd.arg("-c")
            .arg("trap '' TERM; sleep 10 & wait")
            .stdout(process::Stdio::piped())
            .stderr(process::Stdio::piped());
        configure_child_process_group(&mut cmd);
        let started = Instant::now();
        let child = cmd.spawn().unwrap();

        let output = wait_with_output_timeout(child, Duration::from_millis(100)).unwrap();

        assert!(output.timed_out);
        assert!(started.elapsed() < Duration::from_secs(7));
    }

    #[test]
    fn test_generate_cron_hourly() {
        let entry = generate_cron_entry(
            Path::new("/usr/local/bin/boucle"),
            Path::new("/home/agent"),
            3600,
        );
        assert!(entry.contains("0 */1 * * *"));
        assert!(entry.contains("/usr/local/bin/boucle"));
    }

    #[test]
    fn test_generate_cron_every_5_min() {
        let entry = generate_cron_entry(
            Path::new("/usr/local/bin/boucle"),
            Path::new("/home/agent"),
            300,
        );
        assert!(entry.contains("*/5 * * * *"));
    }

    #[test]
    fn test_generate_launchd_plist() {
        let plist = generate_launchd_plist(
            "test",
            Path::new("/usr/local/bin/boucle"),
            Path::new("/home/agent"),
            3600,
        );
        assert!(plist.contains("com.boucle.test"));
        assert!(plist.contains("<integer>3600</integer>"));
        assert!(plist.contains("/usr/local/bin/boucle"));
    }

    #[test]
    fn test_status_after_init() {
        let dir = tempfile::tempdir().unwrap();
        init(dir.path(), "status-test").unwrap();
        // Just verify it doesn't error
        status(dir.path()).unwrap();
    }

    #[test]
    fn test_show_log_empty() {
        let dir = tempfile::tempdir().unwrap();
        init(dir.path(), "log-test").unwrap();
        show_log(dir.path(), 10).unwrap();
    }

    #[test]
    fn test_failure_state_default() {
        let state = FailureState::default();
        assert_eq!(state.consecutive_failures, 0);
        assert!(state.first_failure.is_none());
        assert!(!state.alert_sent);
    }

    #[test]
    fn test_failure_state_persistence() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(FAILURE_STATE_FILE);

        let state = FailureState {
            consecutive_failures: 3,
            first_failure: Some("2026-03-02T10:00:00Z".to_string()),
            last_failure: Some("2026-03-02T10:30:00Z".to_string()),
            last_error: Some("exit code 1".to_string()),
            alert_sent: true,
        };

        save_failure_state(&path, &state);
        let loaded = load_failure_state(&path);

        assert_eq!(loaded.consecutive_failures, 3);
        assert!(loaded.alert_sent);
        assert_eq!(
            loaded.first_failure.as_deref(),
            Some("2026-03-02T10:00:00Z")
        );
    }

    #[test]
    fn test_failure_state_missing_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nonexistent.json");
        let state = load_failure_state(&path);
        assert_eq!(state.consecutive_failures, 0);
    }

    #[test]
    fn test_failure_state_corrupt_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(FAILURE_STATE_FILE);
        fs::write(&path, "not valid json").unwrap();
        let state = load_failure_state(&path);
        assert_eq!(state.consecutive_failures, 0);
    }

    #[test]
    fn test_office_hours_logic() {
        // These tests check the logic but cannot fully test time-dependent behavior
        // The office hours function uses actual current time, so we test the logic indirectly

        // Test that the sleep period (9pm-6am) spans midnight correctly
        // If it's 22:00 (10pm), should be in sleep period
        // If it's 05:00 (5am), should be in sleep period
        // If it's 12:00 (noon), should be awake

        // Note: These constants verify the logic is correct
        assert_eq!(SLEEP_START_HOUR, 21); // 9pm
        assert_eq!(SLEEP_END_HOUR, 6); // 6am
        assert!(SLEEP_START_HOUR > SLEEP_END_HOUR); // Sleep period spans midnight
    }

    #[test]
    fn test_dry_run_succeeds_without_claude() {
        let dir = tempfile::tempdir().unwrap();
        init(dir.path(), "dry-test").unwrap();

        // dry_run=true should succeed even without claude CLI
        let result = run(dir.path(), true);
        assert!(result.is_ok(), "dry run should succeed: {result:?}");

        // Verify a log file was created
        let logs: Vec<_> = fs::read_dir(dir.path().join("logs"))
            .unwrap()
            .filter_map(|e| e.ok())
            .collect();
        assert!(!logs.is_empty(), "dry run should create a log file");
    }

    #[test]
    fn test_dry_run_does_not_modify_state() {
        let dir = tempfile::tempdir().unwrap();
        init(dir.path(), "dry-test").unwrap();

        let state_before = fs::read_to_string(dir.path().join("memory/STATE.md")).unwrap();
        run(dir.path(), true).unwrap();
        let state_after = fs::read_to_string(dir.path().join("memory/STATE.md")).unwrap();

        assert_eq!(state_before, state_after, "dry run should not modify state");
    }

    #[test]
    fn test_stats_no_logs() {
        let dir = tempfile::tempdir().unwrap();
        init(dir.path(), "stats-test").unwrap();
        // Should succeed with no logs
        show_stats(dir.path()).unwrap();
    }

    #[test]
    fn test_stats_with_logs() {
        let dir = tempfile::tempdir().unwrap();
        init(dir.path(), "stats-test").unwrap();

        let log_dir = dir.path().join("logs");

        // Create some fake log files
        fs::write(
            log_dir.join("2026-03-01_10-00-00.log"),
            "=== Boucle loop: 2026-03-01_10-00-00 ===\n\
             Agent: stats-test\n\
             Max tokens: 50000\n\
             Context assembled: 8192 bytes\n\
             Running LLM...\n\
             LLM exit code: 0\n",
        )
        .unwrap();

        fs::write(
            log_dir.join("2026-03-02_10-00-00.log"),
            "=== Boucle loop: 2026-03-02_10-00-00 ===\n\
             Agent: stats-test\n\
             Max tokens: 50000\n\
             Context assembled: 12288 bytes\n\
             Running LLM...\n\
             LLM exit code: 1\n",
        )
        .unwrap();

        fs::write(
            log_dir.join("2026-03-03_10-00-00.log"),
            "=== Boucle loop: 2026-03-03_10-00-00 ===\n\
             Agent: stats-test\n\
             Max tokens: 50000\n\
             Context assembled: 10240 bytes\n\
             Dry run complete — LLM not called.\n",
        )
        .unwrap();

        // Should parse and display without error
        show_stats(dir.path()).unwrap();
    }

    #[test]
    fn test_stats_after_dry_run() {
        let dir = tempfile::tempdir().unwrap();
        init(dir.path(), "stats-test").unwrap();

        // Do a dry run to create a real log
        run(dir.path(), true).unwrap();

        // Stats should work on the real log
        show_stats(dir.path()).unwrap();
    }

    // ---- validate tests ----

    #[test]
    fn test_validate_valid_config() {
        let dir = tempfile::tempdir().unwrap();
        init(dir.path(), "valid-agent").unwrap();
        // Should succeed without error
        validate(dir.path()).unwrap();
    }

    #[test]
    fn test_validate_no_config() {
        let dir = tempfile::tempdir().unwrap();
        // No boucle.toml — should still succeed (prints message)
        validate(dir.path()).unwrap();
    }

    #[test]
    fn test_validate_unknown_section() {
        let dir = tempfile::tempdir().unwrap();
        let config = r#"
[agent]
name = "test"

[unknown_section]
foo = "bar"
"#;
        fs::write(dir.path().join("boucle.toml"), config).unwrap();
        // Should succeed (warnings, not errors)
        validate(dir.path()).unwrap();
    }

    #[test]
    fn test_validate_unknown_key_in_section() {
        let dir = tempfile::tempdir().unwrap();
        let config = r#"
[agent]
name = "test"
naem = "typo"
"#;
        fs::write(dir.path().join("boucle.toml"), config).unwrap();
        // serde will ignore unknown keys, but our TOML check catches them
        validate(dir.path()).unwrap();
    }

    #[test]
    fn test_validate_bad_interval() {
        let dir = tempfile::tempdir().unwrap();
        let config = r#"
[agent]
name = "test"

[schedule]
interval = "5x"
"#;
        fs::write(dir.path().join("boucle.toml"), config).unwrap();
        validate(dir.path()).unwrap();
    }

    #[test]
    fn test_validate_zero_max_tokens() {
        let dir = tempfile::tempdir().unwrap();
        let config = r#"
[agent]
name = "test"

[loop]
max_tokens = 0
"#;
        fs::write(dir.path().join("boucle.toml"), config).unwrap();
        validate(dir.path()).unwrap();
    }

    #[test]
    fn test_validate_path_traversal() {
        let dir = tempfile::tempdir().unwrap();
        let config = r#"
[agent]
name = "test"
system_prompt = "../../etc/passwd"

[memory]
dir = "../sneaky"
"#;
        fs::write(dir.path().join("boucle.toml"), config).unwrap();
        validate(dir.path()).unwrap();
    }

    #[test]
    fn test_validate_absolute_state_file() {
        let dir = tempfile::tempdir().unwrap();
        let config = r#"
[agent]
name = "test"

[memory]
state_file = "/tmp/state.md"
"#;
        fs::write(dir.path().join("boucle.toml"), config).unwrap();
        validate(dir.path()).unwrap();
    }

    #[test]
    fn test_validate_very_short_interval() {
        let dir = tempfile::tempdir().unwrap();
        let config = r#"
[agent]
name = "test"

[schedule]
interval = "5s"
"#;
        fs::write(dir.path().join("boucle.toml"), config).unwrap();
        validate(dir.path()).unwrap();
    }

    #[test]
    fn test_validate_name_with_spaces() {
        let dir = tempfile::tempdir().unwrap();
        let config = r#"
[agent]
name = "my cool agent"
"#;
        fs::write(dir.path().join("boucle.toml"), config).unwrap();
        validate(dir.path()).unwrap();
    }

    #[test]
    fn test_validate_invalid_toml() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("boucle.toml"), "this is not [valid toml").unwrap();
        validate(dir.path()).unwrap();
    }
}
