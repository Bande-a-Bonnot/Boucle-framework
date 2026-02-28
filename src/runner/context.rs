//! Context assembly — builds the prompt for each loop iteration.
//!
//! Assembles context from:
//! 1. Current goals (from config or goals file)
//! 2. Memory state (STATE.md)
//! 3. Context plugins (executable scripts in context.d/)
//! 4. System status (disk, git, etc.)

use crate::config::Config;
use chrono::Utc;
use std::path::Path;
use std::{fs, io, process};

/// Assemble the full context for a loop iteration.
pub fn assemble(
    root: &Path,
    config: &Config,
    context_dir: Option<&Path>,
) -> Result<String, io::Error> {
    let mut sections: Vec<String> = Vec::new();

    // 1. Goals (if goals file exists)
    let goals_path = root.join("GOALS.md");
    if goals_path.exists() {
        let goals = fs::read_to_string(&goals_path)?;
        sections.push(format!("## Current Goals\n\n{goals}"));
    }

    // 2. Memory state
    let state_path = root.join(&config.memory.dir).join(&config.memory.state_file);
    if state_path.exists() {
        let state = fs::read_to_string(&state_path)?;
        sections.push(format!("## Memory\n\n{state}"));
    }

    // 3. Context plugins
    if let Some(ctx_dir) = context_dir {
        if ctx_dir.exists() {
            let mut plugin_outputs = run_context_plugins(ctx_dir, root)?;
            sections.append(&mut plugin_outputs);
        }
    }

    // 4. System status
    let status = gather_system_status(root)?;
    sections.push(format!("## System Status\n\n{status}"));

    // 5. Last log entry
    let log_dir = root.join(config.loop_config.log_dir.as_deref().unwrap_or("logs"));
    if let Some(last_log) = get_last_log(&log_dir)? {
        sections.push(format!("## Last Log Entry\n\n{last_log}"));
    }

    Ok(sections.join("\n\n---\n\n"))
}

/// Run all executable scripts in context.d/ and collect their output.
fn run_context_plugins(context_dir: &Path, root: &Path) -> Result<Vec<String>, io::Error> {
    let mut outputs = Vec::new();

    let mut entries: Vec<_> = fs::read_dir(context_dir)?
        .filter_map(|e| e.ok())
        .collect();
    entries.sort_by_key(|e| e.file_name());

    for entry in entries {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }

        // Detect interpreter from shebang
        let interpreter = detect_interpreter(&path)?;

        let output = match interpreter {
            Some(interp) => {
                process::Command::new(interp)
                    .arg(&path)
                    .current_dir(root)
                    .output()?
            }
            None => {
                // Try running directly (requires +x)
                process::Command::new(&path)
                    .current_dir(root)
                    .output()?
            }
        };

        if output.status.success() && !output.stdout.is_empty() {
            let text = String::from_utf8_lossy(&output.stdout).to_string();
            outputs.push(text);
        }
    }

    Ok(outputs)
}

/// Detect interpreter from a script's shebang line.
fn detect_interpreter(path: &Path) -> Result<Option<String>, io::Error> {
    let content = fs::read_to_string(path)?;
    let first_line = content.lines().next().unwrap_or("");

    if let Some(shebang) = first_line.strip_prefix("#!") {
        let parts: Vec<&str> = shebang.trim().split_whitespace().collect();
        if let Some(interpreter) = parts.first() {
            // Handle /usr/bin/env python3 style
            if interpreter.ends_with("/env") {
                return Ok(parts.get(1).map(|s| s.to_string()));
            }
            return Ok(Some(interpreter.to_string()));
        }
    }

    Ok(None)
}

/// Gather basic system status.
fn gather_system_status(root: &Path) -> Result<String, io::Error> {
    let mut status = Vec::new();

    // Timestamp
    status.push(format!(
        "- Timestamp: {}",
        Utc::now().format("%Y-%m-%d %H:%M:%S UTC")
    ));

    // Disk free
    let df = process::Command::new("df")
        .args(["-h", "."])
        .current_dir(root)
        .output();
    if let Ok(output) = df {
        let text = String::from_utf8_lossy(&output.stdout);
        if let Some(line) = text.lines().nth(1) {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() >= 4 {
                status.push(format!("- Disk free: {}", parts[3]));
            }
        }
    }

    // Git status
    let git_status = process::Command::new("git")
        .args(["status", "--porcelain"])
        .current_dir(root)
        .output();
    if let Ok(output) = git_status {
        let changes = String::from_utf8_lossy(&output.stdout);
        let count = changes.lines().filter(|l| !l.is_empty()).count();
        status.push(format!("- Git status: {count} uncommitted changes"));
    }

    // Last commit
    let git_log = process::Command::new("git")
        .args(["log", "--oneline", "-1"])
        .current_dir(root)
        .output();
    if let Ok(output) = git_log {
        let log_line = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !log_line.is_empty() {
            status.push(format!("- Last commit: {log_line}"));
        }
    }

    Ok(status.join("\n"))
}

/// Get the content of the most recent log file.
fn get_last_log(log_dir: &Path) -> Result<Option<String>, io::Error> {
    if !log_dir.exists() {
        return Ok(None);
    }

    let mut logs: Vec<_> = fs::read_dir(log_dir)?
        .filter_map(|e| e.ok())
        .filter(|e| e.path().extension().is_some_and(|ext| ext == "log"))
        .collect();

    if logs.is_empty() {
        return Ok(None);
    }

    logs.sort_by_key(|e| e.file_name());

    let last = logs.last().unwrap();
    let content = fs::read_to_string(last.path())?;

    // Truncate to reasonable size
    let truncated: String = content.lines().take(50).collect::<Vec<_>>().join("\n");
    Ok(Some(truncated))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runner;
    use crate::config;

    #[test]
    fn test_detect_interpreter_bash() {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("test.sh");
        fs::write(&script, "#!/bin/bash\necho hello").unwrap();

        let interp = detect_interpreter(&script).unwrap();
        assert_eq!(interp, Some("/bin/bash".to_string()));
    }

    #[test]
    fn test_detect_interpreter_env() {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("test.py");
        fs::write(&script, "#!/usr/bin/env python3\nprint('hello')").unwrap();

        let interp = detect_interpreter(&script).unwrap();
        assert_eq!(interp, Some("python3".to_string()));
    }

    #[test]
    fn test_detect_interpreter_none() {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("data.txt");
        fs::write(&script, "no shebang here").unwrap();

        let interp = detect_interpreter(&script).unwrap();
        assert_eq!(interp, None);
    }

    #[test]
    fn test_assemble_basic() {
        let dir = tempfile::tempdir().unwrap();
        runner::init(dir.path(), "test-agent").unwrap();

        let cfg = config::load(dir.path()).unwrap();
        let result = assemble(dir.path(), &cfg, Some(&dir.path().join("context.d"))).unwrap();

        // Should contain state section
        assert!(result.contains("Memory"));
        assert!(result.contains("test-agent"));
        // Should contain system status
        assert!(result.contains("System Status"));
    }

    #[test]
    fn test_assemble_with_goals() {
        let dir = tempfile::tempdir().unwrap();
        runner::init(dir.path(), "test-agent").unwrap();
        fs::write(dir.path().join("GOALS.md"), "# Goal 1\nBuild something.").unwrap();

        let cfg = config::load(dir.path()).unwrap();
        let result = assemble(dir.path(), &cfg, None).unwrap();

        assert!(result.contains("Current Goals"));
        assert!(result.contains("Build something"));
    }
}
