//! Lifecycle hooks for the agent loop.
//!
//! Hooks are scripts in the hooks/ directory that run at specific points:
//! - pre-run: before anything else
//! - post-context: after context assembly
//! - post-llm: after the LLM runs
//! - post-commit: after git commit

use std::path::Path;
use std::{fs, process};

use super::RunnerError;

/// Valid hook names.
const VALID_HOOKS: &[&str] = &["pre-run", "post-context", "post-llm", "post-commit"];

/// Run a named hook if it exists.
pub fn run_hook(hooks_dir: &Path, hook_name: &str, working_dir: &Path) -> Result<(), RunnerError> {
    if !VALID_HOOKS.contains(&hook_name) {
        return Err(RunnerError::Hook(format!("Unknown hook: {hook_name}")));
    }

    if !hooks_dir.exists() {
        return Ok(());
    }

    // Look for hook script (with or without extension)
    let hook_path = find_hook_script(hooks_dir, hook_name);

    let hook_path = match hook_path {
        Some(p) => p,
        None => return Ok(()), // No hook, that's fine
    };

    // Detect interpreter from shebang
    let content = fs::read_to_string(&hook_path)?;
    let interpreter = detect_shebang(&content);

    let output = match interpreter {
        Some(interp) => process::Command::new(interp)
            .arg(&hook_path)
            .current_dir(working_dir)
            .output()?,
        None => process::Command::new(&hook_path)
            .current_dir(working_dir)
            .output()?,
    };

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(RunnerError::Hook(format!(
            "Hook '{hook_name}' failed (exit {}): {stderr}",
            output.status.code().unwrap_or(-1)
        )));
    }

    Ok(())
}

/// Find a hook script by name, trying common extensions.
fn find_hook_script(hooks_dir: &Path, name: &str) -> Option<std::path::PathBuf> {
    // Try exact name first, then common extensions
    let candidates = [
        name.to_string(),
        format!("{name}.sh"),
        format!("{name}.py"),
        format!("{name}.rb"),
    ];

    for candidate in &candidates {
        let path = hooks_dir.join(candidate);
        if path.exists() && path.is_file() {
            return Some(path);
        }
    }

    None
}

/// Detect interpreter from a shebang line.
fn detect_shebang(content: &str) -> Option<String> {
    let first_line = content.lines().next()?;
    let shebang = first_line.strip_prefix("#!")?;
    let parts: Vec<&str> = shebang.trim().split_whitespace().collect();
    let interpreter = parts.first()?;

    if interpreter.ends_with("/env") {
        parts.get(1).map(|s| s.to_string())
    } else {
        Some(interpreter.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_valid_hooks() {
        assert!(VALID_HOOKS.contains(&"pre-run"));
        assert!(VALID_HOOKS.contains(&"post-context"));
        assert!(VALID_HOOKS.contains(&"post-llm"));
        assert!(VALID_HOOKS.contains(&"post-commit"));
    }

    #[test]
    fn test_unknown_hook_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let result = run_hook(dir.path(), "invalid-hook", dir.path());
        assert!(result.is_err());
    }

    #[test]
    fn test_missing_hook_is_ok() {
        let dir = tempfile::tempdir().unwrap();
        fs::create_dir_all(dir.path().join("hooks")).unwrap();
        let result = run_hook(&dir.path().join("hooks"), "pre-run", dir.path());
        assert!(result.is_ok());
    }

    #[test]
    fn test_missing_hooks_dir_is_ok() {
        let dir = tempfile::tempdir().unwrap();
        let result = run_hook(&dir.path().join("nonexistent"), "pre-run", dir.path());
        assert!(result.is_ok());
    }

    #[test]
    fn test_find_hook_script_exact() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("pre-run"), "#!/bin/bash\necho ok").unwrap();
        assert!(find_hook_script(dir.path(), "pre-run").is_some());
    }

    #[test]
    fn test_find_hook_script_with_extension() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("pre-run.sh"), "#!/bin/bash\necho ok").unwrap();
        assert!(find_hook_script(dir.path(), "pre-run").is_some());
    }

    #[test]
    fn test_find_hook_script_not_found() {
        let dir = tempfile::tempdir().unwrap();
        assert!(find_hook_script(dir.path(), "pre-run").is_none());
    }

    #[test]
    fn test_detect_shebang_bash() {
        assert_eq!(
            detect_shebang("#!/bin/bash\necho hello"),
            Some("/bin/bash".to_string())
        );
    }

    #[test]
    fn test_detect_shebang_env() {
        assert_eq!(
            detect_shebang("#!/usr/bin/env python3\nprint('hi')"),
            Some("python3".to_string())
        );
    }

    #[test]
    fn test_detect_shebang_none() {
        assert_eq!(detect_shebang("no shebang"), None);
    }
}
