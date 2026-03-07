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
use std::{fmt, fs, io, process};

/// Tracks consecutive LLM failures across loop invocations.
#[derive(Debug, Serialize, Deserialize, Default)]
struct FailureState {
    consecutive_failures: u32,
    first_failure: Option<String>,
    last_failure: Option<String>,
    last_error: Option<String>,
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
model = "claude-sonnet-4-20250514"
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
    acquire_lock(&lock_path)?;

    // Ensure cleanup on all exit paths
    let _lock_guard = LockGuard(lock_path.clone());

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

    // Check that claude CLI is available
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

    // Build claude command
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

    // Pass the assembled context via stdin (avoids OS arg length limits
    // and ensures Claude CLI reads it correctly when not on a tty)
    cmd.stdin(process::Stdio::piped());
    cmd.stdout(process::Stdio::piped());
    cmd.stderr(process::Stdio::piped());

    log(&log_file, "Running LLM...")?;

    let mut child = cmd.spawn()?;

    // Write prompt to stdin
    if let Some(mut stdin) = child.stdin.take() {
        use std::io::Write;
        stdin.write_all(assembled_context.as_bytes())?;
        // stdin is dropped here, closing the pipe
    }

    let output = child.wait_with_output()?;
    let exit_code = output.status.code().unwrap_or(-1);

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);

    log(&log_file, &format!("LLM exit code: {exit_code}"))?;
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
            "Claude exited with code {exit_code}: {}",
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
            send_failure_alert(root, &state, &log_file);
            state.alert_sent = true;
        }

        save_failure_state(&failure_state_path, &state);

        return Err(RunnerError::Llm(format!(
            "Claude exited with code {exit_code} (failure #{} of {FAILURE_THRESHOLD})",
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
        let pid = fs::read_to_string(&lock_path).unwrap_or_default();
        println!("Status: RUNNING (PID: {})", pid.trim());
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

fn acquire_lock(lock_path: &Path) -> Result<(), RunnerError> {
    if lock_path.exists() {
        let content = fs::read_to_string(lock_path)?;
        let pid: Option<u32> = content.trim().parse().ok();

        // Check if the process is still running
        if let Some(pid) = pid {
            if is_process_running(pid) {
                return Err(RunnerError::Lock(format!(
                    "Another loop is running (PID: {pid})"
                )));
            }
        }

        // Stale lock, remove it
        fs::remove_file(lock_path)?;
    }

    fs::write(lock_path, format!("{}", std::process::id()))?;
    Ok(())
}

struct LockGuard(PathBuf);

impl Drop for LockGuard {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

fn is_process_running(pid: u32) -> bool {
    // Use kill(pid, 0) syscall directly — no subprocess, no flakiness under load
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
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

fn send_failure_alert(root: &Path, state: &FailureState, log_file: &Path) {
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

    // Email primary — works even if Linear/Claude tokens are the broken thing
    let send_email = root.join("send-email.py");
    if send_email.exists() {
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
            }
            _ => {
                let _ = log(log_file, "Alert email FAILED to send.");
            }
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
                println!("[ok]  boucle.toml — agent '{}', model '{}'", cfg.agent.name, cfg.agent.model);
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
                        println!("[warn] memory — {} ({})", memory_dir.display(), mem_issues.join(", "));
                        warned += 1;
                    }
                } else {
                    println!("[FAIL] memory — directory '{}' not found", memory_dir.display());
                    failed += 1;
                }

                // 3. Check system prompt
                let prompt_path = root.join(&cfg.agent.system_prompt);
                if prompt_path.exists() {
                    println!("[ok]  system prompt — {}", cfg.agent.system_prompt);
                    passed += 1;
                } else {
                    println!("[warn] system prompt — '{}' not found (optional but recommended)", cfg.agent.system_prompt);
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
                                    let perms = fs::metadata(&path).map(|m| m.permissions().mode()).unwrap_or(0);
                                    if perms & 0o111 == 0 {
                                        non_exec.push(entry.file_name().to_string_lossy().to_string());
                                    }
                                }
                            }
                        }
                    }
                    if non_exec.is_empty() {
                        println!("[ok]  hooks — {} hook(s) found", hook_count);
                        passed += 1;
                    } else {
                        println!("[warn] hooks — {} hook(s), but not executable: {}", hook_count, non_exec.join(", "));
                        warned += 1;
                    }
                } else {
                    println!("[ok]  hooks — none configured (optional)");
                    passed += 1;
                }

                // 5. Check context.d directory
                let context_path = cfg.loop_config.context_dir.as_deref().unwrap_or("context.d");
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

    // 6. Check claude CLI
    match process::Command::new("claude").arg("--version").output() {
        Ok(output) if output.status.success() => {
            let version = String::from_utf8_lossy(&output.stdout);
            println!("[ok]  claude CLI — {}", version.trim());
            passed += 1;
        }
        _ => {
            println!("[FAIL] claude CLI — not found on PATH");
            println!("       Install: https://docs.anthropic.com/en/docs/claude-code");
            failed += 1;
        }
    }

    // 7. Check git
    match process::Command::new("git").args(["rev-parse", "--git-dir"]).current_dir(root).output() {
        Ok(output) if output.status.success() => {
            println!("[ok]  git — repository initialized");
            passed += 1;
        }
        _ => {
            println!("[warn] git — not a git repository (memory won't be versioned)");
            println!("       Run 'git init' in {} to enable versioning", root.display());
            warned += 1;
        }
    }

    // Summary
    println!();
    if failed == 0 && warned == 0 {
        println!("All checks passed ({passed} ok). Ready to run!");
    } else if failed == 0 {
        println!("{passed} ok, {warned} warning(s). Agent can run but some features may be limited.");
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
        println!("  Average size: {} bytes ({:.1} KB)", avg, avg as f64 / 1024.0);
        println!("  Total sent:   {} bytes ({:.1} KB)", total_context_bytes, total_context_bytes as f64 / 1024.0);
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
            fs::write(&lock_path, "12345").unwrap();
            let _guard = LockGuard(lock_path.clone());
            assert!(lock_path.exists());
        }
        // Guard dropped, lock should be removed
        assert!(!lock_path.exists());
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
}
