//! Memory entry types and parsing.

use chrono::{NaiveDateTime, Utc};
use serde::Serialize;
use std::path::Path;
use std::str::FromStr;
use std::{fmt, fs};

use super::BrocaError;

/// The type of a memory entry.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub enum EntryType {
    Fact,
    Decision,
    Observation,
    Error,
    Procedure,
}

impl FromStr for EntryType {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_lowercase().as_str() {
            "fact" => Ok(EntryType::Fact),
            "decision" => Ok(EntryType::Decision),
            "observation" => Ok(EntryType::Observation),
            "error" => Ok(EntryType::Error),
            "procedure" => Ok(EntryType::Procedure),
            _ => Err(format!("Unknown entry type: {s}")),
        }
    }
}

impl fmt::Display for EntryType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            EntryType::Fact => write!(f, "fact"),
            EntryType::Decision => write!(f, "decision"),
            EntryType::Observation => write!(f, "observation"),
            EntryType::Error => write!(f, "error"),
            EntryType::Procedure => write!(f, "procedure"),
        }
    }
}

/// A parsed memory entry.
#[derive(Debug, Clone)]
pub struct Entry {
    pub filename: String,
    pub entry_type: EntryType,
    pub title: String,
    pub confidence: f64,
    pub tags: Vec<String>,
    pub content: String,
    pub created: String,
    pub superseded_by: Option<String>,
    /// Optional time-to-live in days. If set, the entry is considered stale
    /// after `created + ttl_days` has passed.
    pub ttl_days: Option<u32>,
}

impl Entry {
    /// Returns true if this entry has a TTL and it has expired.
    pub fn is_stale(&self) -> bool {
        let Some(ttl) = self.ttl_days else {
            return false;
        };
        // Parse created timestamp: "%Y%m%d-%H%M%S"
        if let Ok(created_dt) =
            NaiveDateTime::parse_from_str(&self.created, "%Y%m%d-%H%M%S")
        {
            let age_days = (Utc::now().naive_utc() - created_dt).num_days();
            return age_days > ttl as i64;
        }
        false
    }
}

impl Entry {
    /// Parse a memory entry from a file.
    pub fn from_file(path: &Path) -> Result<Self, BrocaError> {
        let content = fs::read_to_string(path)?;
        let filename = path
            .file_name()
            .and_then(|f| f.to_str())
            .unwrap_or("unknown")
            .to_string();

        Self::parse(&filename, &content)
    }

    /// Parse a memory entry from its content string.
    pub fn parse(filename: &str, raw: &str) -> Result<Self, BrocaError> {
        if !raw.starts_with("---") {
            return Err(BrocaError::Parse(format!("No frontmatter in {filename}")));
        }

        let end = raw[3..]
            .find("---")
            .ok_or_else(|| BrocaError::Parse(format!("Unclosed frontmatter in {filename}")))?;

        let frontmatter = &raw[3..end + 3];
        let content = raw[end + 6..].trim().to_string();

        let entry_type = extract_field(frontmatter, "type")
            .ok_or_else(|| BrocaError::Parse(format!("Missing type in {filename}")))?
            .parse::<EntryType>()
            .map_err(|e| BrocaError::Parse(format!("{e} in {filename}")))?;

        let title = extract_field(frontmatter, "title")
            .map(|t| t.trim_matches('"').to_string())
            .unwrap_or_else(|| filename.to_string());

        let confidence = extract_field(frontmatter, "confidence")
            .and_then(|c| c.parse::<f64>().ok())
            .unwrap_or(0.8);

        let tags = extract_tags(frontmatter);
        let created = extract_field(frontmatter, "created").unwrap_or_default();
        let superseded_by = extract_field(frontmatter, "superseded_by");
        let ttl_days = extract_field(frontmatter, "ttl")
            .and_then(|v| v.parse::<u32>().ok());

        Ok(Entry {
            filename: filename.to_string(),
            entry_type,
            title,
            confidence,
            tags,
            content,
            created,
            superseded_by,
            ttl_days,
        })
    }
}

/// Load all entries from a knowledge directory.
pub fn load_all(knowledge_dir: &Path) -> Result<Vec<Entry>, BrocaError> {
    if !knowledge_dir.exists() {
        return Ok(Vec::new());
    }

    let mut entries = Vec::new();
    for dir_entry in fs::read_dir(knowledge_dir)? {
        let dir_entry = dir_entry?;
        let path = dir_entry.path();
        if path.extension().is_some_and(|ext| ext == "md") {
            match Entry::from_file(&path) {
                Ok(entry) => entries.push(entry),
                Err(e) => {
                    eprintln!("Warning: skipping {}: {e}", path.display());
                }
            }
        }
    }

    // Sort by filename (which starts with timestamp)
    entries.sort_by(|a, b| a.filename.cmp(&b.filename));
    Ok(entries)
}

// --- Frontmatter parsing helpers ---

/// Extract a simple key: value field from frontmatter.
fn extract_field(frontmatter: &str, key: &str) -> Option<String> {
    for line in frontmatter.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix(key) {
            if let Some(value) = rest.strip_prefix(':') {
                return Some(value.trim().to_string());
            }
        }
    }
    None
}

/// Extract tags from frontmatter (supports `tags: [a, b, c]` format).
fn extract_tags(frontmatter: &str) -> Vec<String> {
    let tags_str = match extract_field(frontmatter, "tags") {
        Some(s) => s,
        None => return Vec::new(),
    };

    // Parse [tag1, tag2, tag3] format
    let inner = tags_str
        .trim_start_matches('[')
        .trim_end_matches(']')
        .trim();

    if inner.is_empty() {
        return Vec::new();
    }

    inner
        .split(',')
        .map(|t| t.trim().trim_matches('"').trim_matches('\'').to_string())
        .filter(|t| !t.is_empty())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_entry_type_from_str() {
        assert_eq!("fact".parse::<EntryType>(), Ok(EntryType::Fact));
        assert_eq!("DECISION".parse::<EntryType>(), Ok(EntryType::Decision));
        assert!("invalid".parse::<EntryType>().is_err());
    }

    #[test]
    fn test_entry_type_display() {
        assert_eq!(EntryType::Fact.to_string(), "fact");
        assert_eq!(EntryType::Decision.to_string(), "decision");
    }

    #[test]
    fn test_extract_field() {
        let fm = "type: fact\ntitle: \"Hello World\"\nconfidence: 0.9";
        assert_eq!(extract_field(fm, "type"), Some("fact".to_string()));
        assert_eq!(
            extract_field(fm, "title"),
            Some("\"Hello World\"".to_string())
        );
        assert_eq!(extract_field(fm, "confidence"), Some("0.9".to_string()));
        assert_eq!(extract_field(fm, "missing"), None);
    }

    #[test]
    fn test_extract_tags() {
        let fm = "tags: [rust, memory, agent]";
        let tags = extract_tags(fm);
        assert_eq!(tags, vec!["rust", "memory", "agent"]);
    }

    #[test]
    fn test_extract_tags_empty() {
        assert!(extract_tags("no tags here").is_empty());
        assert!(extract_tags("tags: []").is_empty());
    }

    #[test]
    fn test_parse_entry() {
        let raw = "---\ntype: fact\ntitle: \"Test\"\nconfidence: 0.9\ntags: [a, b]\ncreated: 20260228\n---\n\nSome content here.";
        let entry = Entry::parse("test.md", raw).unwrap();
        assert_eq!(entry.entry_type, EntryType::Fact);
        assert_eq!(entry.title, "Test");
        assert_eq!(entry.confidence, 0.9);
        assert_eq!(entry.tags, vec!["a", "b"]);
        assert_eq!(entry.content, "Some content here.");
    }

    #[test]
    fn test_parse_entry_no_frontmatter() {
        let result = Entry::parse("test.md", "Just content");
        assert!(result.is_err());
    }

    #[test]
    fn test_parse_entry_defaults() {
        let raw = "---\ntype: observation\n---\n\nContent.";
        let entry = Entry::parse("test.md", raw).unwrap();
        assert_eq!(entry.entry_type, EntryType::Observation);
        assert_eq!(entry.title, "test.md"); // Falls back to filename
        assert_eq!(entry.confidence, 0.8); // Default
        assert!(entry.tags.is_empty());
        assert_eq!(entry.ttl_days, None);
    }

    #[test]
    fn test_parse_entry_with_ttl() {
        let raw = "---\ntype: fact\ntitle: \"Versioned Fact\"\nttl: 30\ncreated: 20260101-120000\nconfidence: 0.9\n---\n\nContent.";
        let entry = Entry::parse("test.md", raw).unwrap();
        assert_eq!(entry.ttl_days, Some(30));
        // Created 2026-01-01, TTL 30 days → expired by April 2026
        assert!(entry.is_stale());
    }

    #[test]
    fn test_parse_entry_no_ttl_never_stale() {
        let raw = "---\ntype: fact\ntitle: \"Permanent\"\ncreated: 20200101-000000\nconfidence: 0.9\n---\n\nContent.";
        let entry = Entry::parse("test.md", raw).unwrap();
        assert_eq!(entry.ttl_days, None);
        // No TTL → never stale regardless of age
        assert!(!entry.is_stale());
    }

    #[test]
    fn test_parse_entry_ttl_not_yet_expired() {
        // Use a very far future created date to simulate "fresh" entry
        let raw = "---\ntype: fact\ntitle: \"Fresh\"\nttl: 3650\ncreated: 20260401-120000\nconfidence: 0.9\n---\n\nContent.";
        let entry = Entry::parse("test.md", raw).unwrap();
        assert_eq!(entry.ttl_days, Some(3650));
        // 10 year TTL from April 2026 → not stale yet
        assert!(!entry.is_stale());
    }
}
