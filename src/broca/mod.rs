//! Broca — File-based, git-native memory for AI agents.
//!
//! Named after Broca's area (the brain region for language production).
//! Memory entries are Markdown files with YAML-style frontmatter.
//! No database required. Just files.

mod entry;
mod search;

pub use entry::{Entry, EntryType};
pub use search::ScoredEntry;

use chrono::Utc;
use std::path::{Path, PathBuf};
use std::{fmt, fs, io};

/// Errors that can occur in Broca operations.
#[derive(Debug)]
pub enum BrocaError {
    Io(io::Error),
    Parse(String),
}

impl fmt::Display for BrocaError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            BrocaError::Io(e) => write!(f, "IO error: {e}"),
            BrocaError::Parse(msg) => write!(f, "Parse error: {msg}"),
        }
    }
}

impl std::error::Error for BrocaError {}

impl From<io::Error> for BrocaError {
    fn from(e: io::Error) -> Self {
        BrocaError::Io(e)
    }
}

/// Store a new memory entry.
pub fn remember(
    memory_dir: &Path,
    entry_type: &str,
    title: &str,
    content: &str,
    tags: &[String],
) -> Result<PathBuf, BrocaError> {
    let entry_type: EntryType = entry_type.parse().map_err(BrocaError::Parse)?;

    let knowledge_dir = memory_dir.join("knowledge");
    fs::create_dir_all(&knowledge_dir)?;

    let timestamp = Utc::now().format("%Y%m%d-%H%M%S").to_string();
    let slug = slugify(title);
    let filename = format!("{timestamp}-{slug}.md");
    let path = knowledge_dir.join(&filename);

    let tags_str = if tags.is_empty() {
        String::new()
    } else {
        format!("tags: [{}]\n", tags.join(", "))
    };

    let frontmatter = format!(
        "---\n\
         type: {entry_type}\n\
         title: \"{title}\"\n\
         created: {timestamp}\n\
         confidence: 0.8\n\
         {tags_str}\
         ---\n\n\
         {content}\n"
    );

    fs::write(&path, frontmatter)?;
    Ok(path)
}

/// Search memory with relevance ranking.
pub fn recall(
    memory_dir: &Path,
    query: &str,
    limit: usize,
) -> Result<Vec<ScoredEntry>, BrocaError> {
    search::recall(memory_dir, query, limit)
}

/// Show a specific memory entry's content (without frontmatter).
pub fn show(memory_dir: &Path, entry_name: &str) -> Result<String, BrocaError> {
    let knowledge_dir = memory_dir.join("knowledge");

    // Try exact match first, then glob
    let path = if knowledge_dir.join(entry_name).exists() {
        knowledge_dir.join(entry_name)
    } else {
        // Search for partial match
        find_entry_by_name(&knowledge_dir, entry_name)?
            .ok_or_else(|| BrocaError::Parse(format!("Entry not found: {entry_name}")))?
    };

    let content = fs::read_to_string(&path)?;
    // Strip frontmatter
    Ok(strip_frontmatter(&content))
}

/// Search entries by tag.
pub fn search_tag(memory_dir: &Path, tag: &str) -> Result<Vec<Entry>, BrocaError> {
    let entries = entry::load_all(&memory_dir.join("knowledge"))?;
    Ok(entries
        .into_iter()
        .filter(|e| e.tags.iter().any(|t| t.eq_ignore_ascii_case(tag)))
        .collect())
}

/// Add a journal entry (timestamped, informal).
pub fn journal(memory_dir: &Path, content: &str) -> Result<PathBuf, BrocaError> {
    let journal_dir = memory_dir.join("journal");
    fs::create_dir_all(&journal_dir)?;

    let now = Utc::now();
    let date = now.format("%Y-%m-%d").to_string();
    let time = now.format("%H:%M").to_string();
    let path = journal_dir.join(format!("{date}.md"));

    let entry = if path.exists() {
        let existing = fs::read_to_string(&path)?;
        format!("{existing}\n## {time}\n\n{content}\n")
    } else {
        format!("# Journal — {date}\n\n## {time}\n\n{content}\n")
    };

    fs::write(&path, entry)?;
    Ok(path)
}

/// Show memory statistics.
pub fn stats(memory_dir: &Path) -> Result<String, BrocaError> {
    let knowledge_dir = memory_dir.join("knowledge");
    let journal_dir = memory_dir.join("journal");

    let entries = if knowledge_dir.exists() {
        entry::load_all(&knowledge_dir)?
    } else {
        Vec::new()
    };

    let journal_count = if journal_dir.exists() {
        fs::read_dir(&journal_dir)?
            .filter_map(|e| e.ok())
            .filter(|e| e.path().extension().is_some_and(|ext| ext == "md"))
            .count()
    } else {
        0
    };

    // Count by type
    let mut type_counts = std::collections::HashMap::new();
    let mut total_confidence = 0.0f64;
    for entry in &entries {
        *type_counts
            .entry(entry.entry_type.to_string())
            .or_insert(0usize) += 1;
        total_confidence += entry.confidence;
    }

    let avg_confidence = if entries.is_empty() {
        0.0
    } else {
        total_confidence / entries.len() as f64
    };

    let mut output = format!(
        "# Broca Memory Stats\n\n\
         Total entries: {}\n\
         Journal days: {}\n\
         Average confidence: {:.2}\n\n\
         ## By Type\n",
        entries.len(),
        journal_count,
        avg_confidence
    );

    let mut types: Vec<_> = type_counts.iter().collect();
    types.sort_by_key(|(_, count)| std::cmp::Reverse(**count));
    for (entry_type, count) in types {
        output.push_str(&format!("- {entry_type}: {count}\n"));
    }

    Ok(output)
}

/// Build an index of all memory entries.
pub fn build_index(memory_dir: &Path) -> Result<usize, BrocaError> {
    let knowledge_dir = memory_dir.join("knowledge");
    let entries = if knowledge_dir.exists() {
        entry::load_all(&knowledge_dir)?
    } else {
        Vec::new()
    };

    let mut index = String::from("# Broca Memory Index\n\n");
    index.push_str(&format!(
        "Generated: {}\n\n",
        Utc::now().format("%Y-%m-%d %H:%M:%S UTC")
    ));

    for entry in &entries {
        index.push_str(&format!(
            "- **{}** [{}] (confidence: {:.1}, created: {}) — {}\n",
            entry.title, entry.entry_type, entry.confidence, entry.created, entry.filename
        ));
        if !entry.tags.is_empty() {
            index.push_str(&format!("  tags: {}\n", entry.tags.join(", ")));
        }
    }

    fs::write(memory_dir.join("INDEX.md"), &index)?;
    Ok(entries.len())
}

/// Update the confidence score of a memory entry.
pub fn update_confidence(
    memory_dir: &Path,
    entry_name: &str,
    new_confidence: f64,
) -> Result<PathBuf, BrocaError> {
    let knowledge_dir = memory_dir.join("knowledge");
    let path = find_entry_by_name(&knowledge_dir, entry_name)?
        .ok_or_else(|| BrocaError::Parse(format!("Entry not found: {entry_name}")))?;

    let content = fs::read_to_string(&path)?;
    let updated =
        replace_frontmatter_field(&content, "confidence", &format!("{new_confidence:.1}"));
    fs::write(&path, updated)?;
    Ok(path)
}

/// Mark an entry as superseded by another.
pub fn supersede(
    memory_dir: &Path,
    old_entry: &str,
    new_entry: &str,
) -> Result<PathBuf, BrocaError> {
    let knowledge_dir = memory_dir.join("knowledge");
    let path = find_entry_by_name(&knowledge_dir, old_entry)?
        .ok_or_else(|| BrocaError::Parse(format!("Entry not found: {old_entry}")))?;

    let content = fs::read_to_string(&path)?;

    // Add superseded_by field to frontmatter
    let updated = if content.contains("superseded_by:") {
        replace_frontmatter_field(&content, "superseded_by", new_entry)
    } else {
        add_frontmatter_field(&content, "superseded_by", new_entry)
    };

    // Also lower the confidence
    let updated = replace_frontmatter_field(&updated, "confidence", "0.3");
    fs::write(&path, updated)?;
    Ok(path)
}

/// Add a relationship between two entries.
pub fn relate(
    memory_dir: &Path,
    entry_a: &str,
    entry_b: &str,
    relation_type: &str,
) -> Result<(), BrocaError> {
    let knowledge_dir = memory_dir.join("knowledge");

    // Verify both entries exist
    let path_a = find_entry_by_name(&knowledge_dir, entry_a)?
        .ok_or_else(|| BrocaError::Parse(format!("Entry not found: {entry_a}")))?;
    let path_b = find_entry_by_name(&knowledge_dir, entry_b)?
        .ok_or_else(|| BrocaError::Parse(format!("Entry not found: {entry_b}")))?;

    let name_a = path_a
        .file_name()
        .and_then(|f| f.to_str())
        .unwrap_or(entry_a);
    let name_b = path_b
        .file_name()
        .and_then(|f| f.to_str())
        .unwrap_or(entry_b);

    // Store relationships in a RELATIONS.md file
    let relations_path = memory_dir.join("RELATIONS.md");
    let relation_line = format!("{name_a} --[{relation_type}]--> {name_b}\n");

    if relations_path.exists() {
        let existing = fs::read_to_string(&relations_path)?;
        if !existing.contains(relation_line.trim()) {
            fs::write(&relations_path, format!("{existing}{relation_line}"))?;
        }
    } else {
        fs::write(
            &relations_path,
            format!("# Broca Relations\n\n{relation_line}"),
        )?;
    }

    Ok(())
}

// --- Helpers ---

/// Replace a field value in frontmatter.
fn replace_frontmatter_field(content: &str, key: &str, value: &str) -> String {
    let mut lines: Vec<String> = content.lines().map(|l| l.to_string()).collect();
    let mut found = false;

    for line in &mut lines {
        if line.trim().starts_with(&format!("{key}:")) {
            *line = format!("{key}: {value}");
            found = true;
            break;
        }
    }

    if !found {
        // Key not found — no change
        return content.to_string();
    }

    lines.join("\n") + "\n"
}

/// Add a new field to the frontmatter (before the closing ---).
fn add_frontmatter_field(content: &str, key: &str, value: &str) -> String {
    if let Some(pos) = content[3..].find("---") {
        let insert_pos = pos + 3;
        format!(
            "{}{key}: {value}\n{}",
            &content[..insert_pos],
            &content[insert_pos..]
        )
    } else {
        content.to_string()
    }
}

/// Convert a title to a filename-safe slug.
fn slugify(title: &str) -> String {
    title
        .to_lowercase()
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { '-' })
        .collect::<String>()
        .split('-')
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("-")
}

/// Strip YAML frontmatter from markdown content.
fn strip_frontmatter(content: &str) -> String {
    if !content.starts_with("---") {
        return content.to_string();
    }
    // Find the closing ---
    if let Some(end) = content[3..].find("---") {
        content[end + 6..].trim_start().to_string()
    } else {
        content.to_string()
    }
}

/// Find an entry by partial name match.
fn find_entry_by_name(dir: &Path, name: &str) -> Result<Option<PathBuf>, BrocaError> {
    if !dir.exists() {
        return Ok(None);
    }
    let name_lower = name.to_lowercase();
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if let Some(fname) = path.file_name().and_then(|f| f.to_str()) {
            if fname.to_lowercase().contains(&name_lower) {
                return Ok(Some(path));
            }
        }
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_slugify() {
        assert_eq!(slugify("Hello World"), "hello-world");
        assert_eq!(slugify("API Keys & Secrets"), "api-keys-secrets");
        assert_eq!(slugify("test"), "test");
        assert_eq!(slugify("Multiple   Spaces"), "multiple-spaces");
    }

    #[test]
    fn test_strip_frontmatter() {
        let input = "---\ntype: fact\ntitle: test\n---\n\nContent here.";
        assert_eq!(strip_frontmatter(input), "Content here.");
    }

    #[test]
    fn test_strip_frontmatter_no_frontmatter() {
        let input = "Just content.";
        assert_eq!(strip_frontmatter(input), "Just content.");
    }

    #[test]
    fn test_remember_and_show() {
        let dir = tempfile::tempdir().unwrap();
        let memory_dir = dir.path();

        let path = remember(
            memory_dir,
            "fact",
            "Test Entry",
            "This is test content.",
            &["test".to_string(), "unit".to_string()],
        )
        .unwrap();

        assert!(path.exists());

        // Read the file and verify frontmatter
        let content = fs::read_to_string(&path).unwrap();
        assert!(content.contains("type: fact"));
        assert!(content.contains("title: \"Test Entry\""));
        assert!(content.contains("confidence: 0.8"));
        assert!(content.contains("tags: [test, unit]"));
        assert!(content.contains("This is test content."));
    }

    #[test]
    fn test_remember_invalid_type() {
        let dir = tempfile::tempdir().unwrap();
        let result = remember(dir.path(), "invalid", "Test", "Content", &[]);
        assert!(result.is_err());
    }

    #[test]
    fn test_journal() {
        let dir = tempfile::tempdir().unwrap();
        let memory_dir = dir.path();

        let path = journal(memory_dir, "First entry").unwrap();
        assert!(path.exists());

        let content = fs::read_to_string(&path).unwrap();
        assert!(content.contains("First entry"));
        assert!(content.contains("# Journal"));

        // Second entry same day appends
        let _ = journal(memory_dir, "Second entry").unwrap();
        let content = fs::read_to_string(&path).unwrap();
        assert!(content.contains("First entry"));
        assert!(content.contains("Second entry"));
    }

    #[test]
    fn test_stats_empty() {
        let dir = tempfile::tempdir().unwrap();
        let result = stats(dir.path()).unwrap();
        assert!(result.contains("Total entries: 0"));
    }

    #[test]
    fn test_stats_with_entries() {
        let dir = tempfile::tempdir().unwrap();
        let memory_dir = dir.path();

        remember(memory_dir, "fact", "Fact One", "Content", &[]).unwrap();
        remember(memory_dir, "fact", "Fact Two", "Content", &[]).unwrap();
        remember(memory_dir, "decision", "A Decision", "Content", &[]).unwrap();

        let result = stats(memory_dir).unwrap();
        assert!(result.contains("Total entries: 3"));
        assert!(result.contains("fact: 2"));
        assert!(result.contains("decision: 1"));
    }

    #[test]
    fn test_build_index() {
        let dir = tempfile::tempdir().unwrap();
        let memory_dir = dir.path();

        remember(
            memory_dir,
            "fact",
            "Alpha",
            "Content A",
            &["tag1".to_string()],
        )
        .unwrap();
        remember(memory_dir, "observation", "Beta", "Content B", &[]).unwrap();

        let count = build_index(memory_dir).unwrap();
        assert_eq!(count, 2);
        assert!(memory_dir.join("INDEX.md").exists());

        let index = fs::read_to_string(memory_dir.join("INDEX.md")).unwrap();
        assert!(index.contains("Alpha"));
        assert!(index.contains("Beta"));
    }

    #[test]
    fn test_search_tag() {
        let dir = tempfile::tempdir().unwrap();
        let memory_dir = dir.path();

        remember(
            memory_dir,
            "fact",
            "Tagged",
            "Content",
            &["important".to_string()],
        )
        .unwrap();
        remember(memory_dir, "fact", "Not Tagged", "Content", &[]).unwrap();

        let results = search_tag(memory_dir, "important").unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].title, "Tagged");
    }

    #[test]
    fn test_update_confidence() {
        let dir = tempfile::tempdir().unwrap();
        let memory_dir = dir.path();

        let path = remember(memory_dir, "fact", "Confidence Test", "Content", &[]).unwrap();

        // Original confidence is 0.8
        let content = fs::read_to_string(&path).unwrap();
        assert!(content.contains("confidence: 0.8"));

        // Update to 0.95
        update_confidence(memory_dir, "confidence-test", 0.95).unwrap();

        let content = fs::read_to_string(&path).unwrap();
        assert!(content.contains("confidence: 0.9")); // 0.95 formatted as 0.9 with .1 precision
    }

    #[test]
    fn test_supersede() {
        let dir = tempfile::tempdir().unwrap();
        let memory_dir = dir.path();

        remember(memory_dir, "fact", "Old Fact", "Old content", &[]).unwrap();
        remember(memory_dir, "fact", "New Fact", "New content", &[]).unwrap();

        supersede(memory_dir, "old-fact", "new-fact").unwrap();

        // Old entry should have superseded_by and lower confidence
        let entries = entry::load_all(&memory_dir.join("knowledge")).unwrap();
        let old = entries.iter().find(|e| e.title == "Old Fact").unwrap();
        assert_eq!(old.confidence, 0.3);
        assert!(old.superseded_by.is_some());
    }

    #[test]
    fn test_relate() {
        let dir = tempfile::tempdir().unwrap();
        let memory_dir = dir.path();

        remember(memory_dir, "fact", "Entry A", "Content A", &[]).unwrap();
        remember(memory_dir, "fact", "Entry B", "Content B", &[]).unwrap();

        relate(memory_dir, "entry-a", "entry-b", "supports").unwrap();

        let relations = fs::read_to_string(memory_dir.join("RELATIONS.md")).unwrap();
        assert!(relations.contains("--[supports]-->"));
    }

    #[test]
    fn test_replace_frontmatter_field() {
        let content = "---\ntype: fact\nconfidence: 0.8\n---\n\nContent.";
        let updated = replace_frontmatter_field(content, "confidence", "0.95");
        assert!(updated.contains("confidence: 0.95"));
        assert!(!updated.contains("confidence: 0.8"));
    }

    #[test]
    fn test_add_frontmatter_field() {
        let content = "---\ntype: fact\n---\n\nContent.";
        let updated = add_frontmatter_field(content, "superseded_by", "new-entry.md");
        assert!(updated.contains("superseded_by: new-entry.md"));
        assert!(updated.contains("type: fact"));
    }
}
