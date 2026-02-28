//! Loop runner — the engine that drives each agent iteration.
//!
//! Extension points:
//!   context.d/  — Executable scripts that output extra context sections
//!   hooks/      — Scripts at lifecycle points: pre-run, post-context, post-llm, post-commit

mod context;
mod hooks;

use crate::config;
use chrono::Utc;
use std::path::{Path, PathBuf};
use std::{fmt, fs, io, process};

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

const LOCK_FILE: &str = ".boucle.lock";
const LOG_DIR_DEFAULT: &str = "logs";

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

    fs::write(root.join("boucle.toml"), config_content)?;

    // Create directories
    for dir in &[
        "memory/knowledge",
        "memory/journal",
        "context.d",
        "hooks",
        "logs",
    ] {
        fs::create_dir_all(root.join(dir))?;
    }

    // Create system prompt template
    let prompt = format!(
        "You are {name}, an autonomous agent running in a loop.\n\
         Read your state, decide what to do, then update your state.\n"
    );
    fs::write(root.join("system-prompt.md"), prompt)?;

    // Create initial state
    let state = format!(
        "# {name} — State\n\n\
         ## What I know\n\n\
         - Initialized: {}\n\n\
         ## What I'm working on\n\n\
         (nothing yet)\n",
        Utc::now().format("%Y-%m-%d %H:%M:%S UTC")
    );
    fs::write(root.join("memory/STATE.md"), state)?;

    Ok(())
}

/// Run one iteration of the agent loop.
pub fn run(root: &Path) -> Result<(), RunnerError> {
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

    // Load system prompt
    let system_prompt_path = root.join(&cfg.agent.system_prompt);
    let system_prompt = if system_prompt_path.exists() {
        fs::read_to_string(&system_prompt_path)?
    } else {
        String::new()
    };

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

    // The assembled context is the prompt
    cmd.arg(&assembled_context);

    log(&log_file, "Running LLM...")?;

    let output = cmd.output()?;
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

    if exit_code != 0 {
        return Err(RunnerError::Llm(format!(
            "Claude exited with code {exit_code}"
        )));
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
    // Use kill -0 to check if process exists (works on Unix)
    process::Command::new("kill")
        .args(["-0", &pid.to_string()])
        .stdout(process::Stdio::null())
        .stderr(process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
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
}
