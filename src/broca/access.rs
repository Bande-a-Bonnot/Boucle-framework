//! Access tracking for Broca memory entries.
//!
//! Maintains a sidecar JSON file (`access_log.json`) that records how often
//! and how recently each entry has been accessed. This data feeds into search
//! scoring: frequently/recently accessed entries get a relevance boost.

use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::{fs, io};

/// A single entry's access history.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccessRecord {
    /// Number of times this entry was accessed (via recall or show).
    pub count: u64,
    /// ISO 8601 timestamp of last access.
    pub last_accessed: String,
}

/// Mapping from filename → access record.
pub type AccessLog = HashMap<String, AccessRecord>;

fn access_log_path(memory_dir: &Path) -> PathBuf {
    memory_dir.join("access_log.json")
}

/// Load the access log from disk. Returns empty map if missing or corrupt.
pub fn load(memory_dir: &Path) -> AccessLog {
    let path = access_log_path(memory_dir);
    match fs::read_to_string(path) {
        Ok(content) => serde_json::from_str(&content).unwrap_or_default(),
        Err(_) => HashMap::new(),
    }
}

/// Save the access log to disk.
pub fn save(memory_dir: &Path, log: &AccessLog) -> Result<(), io::Error> {
    let path = access_log_path(memory_dir);
    let content = serde_json::to_string_pretty(log).map_err(io::Error::other)?;
    fs::write(path, content)
}

/// Record an access event for the given filenames.
/// Creates or updates the access record for each file.
pub fn record_access(memory_dir: &Path, filenames: &[&str]) -> Result<(), io::Error> {
    if filenames.is_empty() {
        return Ok(());
    }

    let mut log = load(memory_dir);
    let now = Utc::now().to_rfc3339();

    for filename in filenames {
        let record = log.entry((*filename).to_string()).or_insert(AccessRecord {
            count: 0,
            last_accessed: now.clone(),
        });
        record.count += 1;
        record.last_accessed = now.clone();
    }

    save(memory_dir, &log)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_load_empty() {
        let dir = tempfile::tempdir().unwrap();
        let log = load(dir.path());
        assert!(log.is_empty());
    }

    #[test]
    fn test_record_and_load() {
        let dir = tempfile::tempdir().unwrap();

        record_access(dir.path(), &["entry-a.md", "entry-b.md"]).unwrap();
        let log = load(dir.path());
        assert_eq!(log.len(), 2);
        assert_eq!(log["entry-a.md"].count, 1);
        assert_eq!(log["entry-b.md"].count, 1);

        // Access again
        record_access(dir.path(), &["entry-a.md"]).unwrap();
        let log = load(dir.path());
        assert_eq!(log["entry-a.md"].count, 2);
        assert_eq!(log["entry-b.md"].count, 1);
    }

    #[test]
    fn test_record_empty() {
        let dir = tempfile::tempdir().unwrap();
        record_access(dir.path(), &[]).unwrap();
        // Should not create the file
        assert!(!access_log_path(dir.path()).exists());
    }

    #[test]
    fn test_corrupt_file() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(access_log_path(dir.path()), "not json").unwrap();
        let log = load(dir.path());
        assert!(log.is_empty()); // graceful fallback
    }
}
