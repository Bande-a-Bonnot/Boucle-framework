//! Configuration loading and management.
//!
//! Reads boucle.toml and provides typed access to all settings.

use serde::Deserialize;
use std::path::{Path, PathBuf};
use std::{fmt, fs, io};

/// Top-level configuration from boucle.toml.
#[derive(Debug, Deserialize)]
pub struct Config {
    pub agent: AgentConfig,

    #[serde(default)]
    pub memory: MemoryConfig,

    #[serde(default)]
    pub loop_config: LoopConfig,

    #[serde(default)]
    pub schedule: ScheduleConfig,
}

#[derive(Debug, Deserialize)]
pub struct AgentConfig {
    pub name: String,

    #[serde(default = "default_model")]
    pub model: String,

    #[serde(default = "default_system_prompt")]
    pub system_prompt: String,

    #[serde(default)]
    pub allowed_tools: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct MemoryConfig {
    #[serde(default = "default_memory_dir")]
    pub dir: String,

    #[serde(default = "default_state_file")]
    pub state_file: String,
}

#[derive(Debug, Deserialize)]
pub struct LoopConfig {
    #[serde(default)]
    pub context_dir: Option<String>,

    #[serde(default)]
    pub hooks_dir: Option<String>,

    #[serde(default)]
    pub log_dir: Option<String>,

    #[serde(default = "default_max_tokens")]
    pub max_tokens: usize,
}

#[derive(Debug, Deserialize)]
pub struct ScheduleConfig {
    #[serde(default = "default_interval")]
    pub interval: String,
}

// Default value functions
fn default_model() -> String {
    "claude-sonnet-4-20250514".to_string()
}
fn default_system_prompt() -> String {
    "system-prompt.md".to_string()
}
fn default_memory_dir() -> String {
    "memory".to_string()
}
fn default_state_file() -> String {
    "STATE.md".to_string()
}
fn default_max_tokens() -> usize {
    200_000
}
fn default_interval() -> String {
    "1h".to_string()
}

impl Default for MemoryConfig {
    fn default() -> Self {
        Self {
            dir: default_memory_dir(),
            state_file: default_state_file(),
        }
    }
}

impl Default for LoopConfig {
    fn default() -> Self {
        Self {
            context_dir: None,
            hooks_dir: None,
            log_dir: None,
            max_tokens: default_max_tokens(),
        }
    }
}

impl Default for ScheduleConfig {
    fn default() -> Self {
        Self {
            interval: default_interval(),
        }
    }
}

/// Errors that can occur during configuration.
#[derive(Debug)]
pub enum ConfigError {
    Io(io::Error),
    Parse(toml::de::Error),
    NotFound,
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ConfigError::Io(e) => write!(f, "IO error: {e}"),
            ConfigError::Parse(e) => write!(f, "Parse error: {e}"),
            ConfigError::NotFound => write!(f, "boucle.toml not found"),
        }
    }
}

impl std::error::Error for ConfigError {}

impl From<io::Error> for ConfigError {
    fn from(e: io::Error) -> Self {
        ConfigError::Io(e)
    }
}

impl From<toml::de::Error> for ConfigError {
    fn from(e: toml::de::Error) -> Self {
        ConfigError::Parse(e)
    }
}

/// Load configuration from boucle.toml in the given directory.
pub fn load(root: &Path) -> Result<Config, ConfigError> {
    let config_path = root.join("boucle.toml");
    if !config_path.exists() {
        return Err(ConfigError::NotFound);
    }
    let content = fs::read_to_string(&config_path)?;
    let config: Config = toml::from_str(&content)?;
    Ok(config)
}

/// Find the agent root by searching upward for boucle.toml.
pub fn find_agent_root(start: &Path) -> Option<PathBuf> {
    let mut dir = start.to_path_buf();
    loop {
        if dir.join("boucle.toml").exists() {
            return Some(dir);
        }
        if !dir.pop() {
            return None;
        }
    }
}

/// Parse an interval string like "1h", "30m", "5s" into seconds.
pub fn parse_interval(interval: &str) -> Result<u64, String> {
    let interval = interval.trim();
    if interval.is_empty() {
        return Err("Empty interval".to_string());
    }

    let (num_str, suffix) = interval.split_at(interval.len() - 1);
    let num: u64 = num_str
        .parse()
        .map_err(|_| format!("Invalid number in interval: {num_str}"))?;

    match suffix {
        "s" => Ok(num),
        "m" => Ok(num * 60),
        "h" => Ok(num * 3600),
        "d" => Ok(num * 86400),
        _ => Err(format!("Unknown interval suffix: {suffix}. Use s, m, h, or d.")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_interval_seconds() {
        assert_eq!(parse_interval("30s").unwrap(), 30);
    }

    #[test]
    fn test_parse_interval_minutes() {
        assert_eq!(parse_interval("5m").unwrap(), 300);
    }

    #[test]
    fn test_parse_interval_hours() {
        assert_eq!(parse_interval("1h").unwrap(), 3600);
    }

    #[test]
    fn test_parse_interval_days() {
        assert_eq!(parse_interval("2d").unwrap(), 172800);
    }

    #[test]
    fn test_parse_interval_invalid_suffix() {
        assert!(parse_interval("5x").is_err());
    }

    #[test]
    fn test_parse_interval_invalid_number() {
        assert!(parse_interval("abch").is_err());
    }

    #[test]
    fn test_parse_interval_empty() {
        assert!(parse_interval("").is_err());
    }

    #[test]
    fn test_find_agent_root_not_found() {
        // Searching from root should find nothing (no boucle.toml in /)
        assert!(find_agent_root(Path::new("/tmp/nonexistent")).is_none());
    }

    #[test]
    fn test_load_missing_config() {
        let result = load(Path::new("/tmp/nonexistent"));
        assert!(result.is_err());
    }

    #[test]
    fn test_load_valid_config() {
        let dir = tempfile::tempdir().unwrap();
        let config_content = r#"
[agent]
name = "test-agent"
model = "claude-sonnet-4-20250514"

[memory]
dir = "memory"
"#;
        fs::write(dir.path().join("boucle.toml"), config_content).unwrap();
        let config = load(dir.path()).unwrap();
        assert_eq!(config.agent.name, "test-agent");
        assert_eq!(config.memory.dir, "memory");
    }

    #[test]
    fn test_load_minimal_config() {
        let dir = tempfile::tempdir().unwrap();
        let config_content = r#"
[agent]
name = "minimal"
"#;
        fs::write(dir.path().join("boucle.toml"), config_content).unwrap();
        let config = load(dir.path()).unwrap();
        assert_eq!(config.agent.name, "minimal");
        // Check defaults
        assert_eq!(config.memory.dir, "memory");
        assert_eq!(config.memory.state_file, "STATE.md");
        assert_eq!(config.loop_config.max_tokens, 200_000);
    }

    #[test]
    fn test_find_agent_root_with_config() {
        let dir = tempfile::tempdir().unwrap();
        let sub = dir.path().join("a").join("b").join("c");
        fs::create_dir_all(&sub).unwrap();
        fs::write(dir.path().join("boucle.toml"), "[agent]\nname = \"x\"").unwrap();
        assert_eq!(find_agent_root(&sub).unwrap(), dir.path());
    }
}
