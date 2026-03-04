//! Garbage collection for Broca memory.
//!
//! Identifies stale entries using transparent rules (age, access, confidence,
//! superseded status) and archives them. Entries are moved to an `archive/`
//! directory — never deleted — so recovery is always possible.

use chrono::{NaiveDate, NaiveDateTime, Utc};
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};

use super::access;
use super::entry::{self, Entry};
use super::BrocaError;

/// Why an entry was flagged for garbage collection.
#[derive(Debug, Clone, PartialEq)]
pub enum GcReason {
    /// Entry has been superseded and has low confidence.
    Superseded,
    /// Entry is old, never accessed, and has below-threshold confidence.
    OldUnused { age_days: i64 },
    /// Entry has very low confidence (explicitly marked unreliable).
    LowConfidence,
}

impl fmt::Display for GcReason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            GcReason::Superseded => write!(f, "superseded"),
            GcReason::OldUnused { age_days } => write!(f, "old and unused ({age_days} days)"),
            GcReason::LowConfidence => write!(f, "very low confidence"),
        }
    }
}

/// A memory entry flagged for garbage collection.
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct GcCandidate {
    pub filename: String,
    pub title: String,
    pub confidence: f64,
    pub created: String,
    pub reason: GcReason,
}

/// Configuration for garbage collection thresholds.
#[derive(Debug, Clone)]
pub struct GcConfig {
    /// Entries older than this with 0 accesses are candidates (default: 365 days).
    pub max_age_days: i64,
    /// Confidence threshold for old+unused rule (default: 0.7).
    pub old_unused_confidence: f64,
    /// Entries at or below this confidence are always candidates (default: 0.2).
    pub min_confidence: f64,
    /// Confidence threshold for superseded entries (default: 0.3).
    pub superseded_confidence: f64,
}

impl Default for GcConfig {
    fn default() -> Self {
        GcConfig {
            max_age_days: 365,
            old_unused_confidence: 0.7,
            min_confidence: 0.2,
            superseded_confidence: 0.3,
        }
    }
}

/// Parse a created timestamp to determine age in days.
/// Supports "YYYYMMDD-HHMMSS" and "YYYYMMDD" formats.
fn age_days(created: &str) -> Option<i64> {
    let now = Utc::now().naive_utc();
    let dt = if let Ok(dt) = NaiveDateTime::parse_from_str(created, "%Y%m%d-%H%M%S") {
        Some(dt)
    } else {
        NaiveDate::parse_from_str(created, "%Y%m%d")
            .ok()
            .and_then(|d| d.and_hms_opt(0, 0, 0))
    };
    dt.map(|d| (now - d).num_days().max(0))
}

/// Identify entries that are candidates for garbage collection.
///
/// Rules (transparent, no magic scores):
/// 1. Superseded entries with confidence ≤ `superseded_confidence`
/// 2. Old entries (> `max_age_days`) with 0 accesses AND confidence < `old_unused_confidence`
/// 3. Very low confidence entries (≤ `min_confidence`)
pub fn candidates(memory_dir: &Path, config: &GcConfig) -> Result<Vec<GcCandidate>, BrocaError> {
    let knowledge_dir = memory_dir.join("knowledge");
    let entries = entry::load_all(&knowledge_dir)?;
    let access_log = access::load(memory_dir);

    let mut result = Vec::new();

    for entry in &entries {
        let access_count = access_log
            .get(&entry.filename)
            .map(|r| r.count)
            .unwrap_or(0);

        if let Some(reason) = check_entry(entry, access_count, config) {
            result.push(GcCandidate {
                filename: entry.filename.clone(),
                title: entry.title.clone(),
                confidence: entry.confidence,
                created: entry.created.clone(),
                reason,
            });
        }
    }

    Ok(result)
}

/// Check a single entry against GC rules. Returns the reason if it's a candidate.
fn check_entry(entry: &Entry, access_count: u64, config: &GcConfig) -> Option<GcReason> {
    // Rule 1: Superseded with low confidence
    if entry.superseded_by.is_some() && entry.confidence <= config.superseded_confidence {
        return Some(GcReason::Superseded);
    }

    // Rule 3: Very low confidence (check before Rule 2 — more specific)
    if entry.confidence <= config.min_confidence {
        return Some(GcReason::LowConfidence);
    }

    // Rule 2: Old, never accessed, below-threshold confidence
    if access_count == 0 && entry.confidence < config.old_unused_confidence {
        if let Some(days) = age_days(&entry.created) {
            if days > config.max_age_days {
                return Some(GcReason::OldUnused { age_days: days });
            }
        }
    }

    None
}

/// Archive GC candidates by moving them from `knowledge/` to `archive/`.
/// Returns the list of archived filenames.
pub fn archive(
    memory_dir: &Path,
    gc_candidates: &[GcCandidate],
) -> Result<Vec<String>, BrocaError> {
    if gc_candidates.is_empty() {
        return Ok(Vec::new());
    }

    let knowledge_dir = memory_dir.join("knowledge");
    let archive_dir = memory_dir.join("archive");
    fs::create_dir_all(&archive_dir)?;

    let mut archived = Vec::new();

    for candidate in gc_candidates {
        let src = knowledge_dir.join(&candidate.filename);
        let dst = archive_dir.join(&candidate.filename);

        if src.exists() {
            fs::rename(&src, &dst)?;
            archived.push(candidate.filename.clone());
        }
    }

    Ok(archived)
}

/// Full GC: find candidates and archive them. Returns archived filenames.
#[allow(dead_code)]
pub fn collect(memory_dir: &Path, config: &GcConfig) -> Result<Vec<String>, BrocaError> {
    let gc_candidates = candidates(memory_dir, config)?;
    archive(memory_dir, &gc_candidates)
}

/// Restore an archived entry back to `knowledge/`.
pub fn restore(memory_dir: &Path, filename: &str) -> Result<PathBuf, BrocaError> {
    let archive_dir = memory_dir.join("archive");
    let knowledge_dir = memory_dir.join("knowledge");

    let src = archive_dir.join(filename);
    if !src.exists() {
        return Err(BrocaError::Parse(format!(
            "Archived entry not found: {filename}"
        )));
    }

    fs::create_dir_all(&knowledge_dir)?;
    let dst = knowledge_dir.join(filename);
    fs::rename(&src, &dst)?;
    Ok(dst)
}

/// List all archived entries.
pub fn list_archived(memory_dir: &Path) -> Result<Vec<String>, BrocaError> {
    let archive_dir = memory_dir.join("archive");
    if !archive_dir.exists() {
        return Ok(Vec::new());
    }

    let mut files = Vec::new();
    for dir_entry in fs::read_dir(&archive_dir)? {
        let dir_entry = dir_entry?;
        if dir_entry.path().extension().is_some_and(|ext| ext == "md") {
            if let Some(name) = dir_entry.file_name().to_str() {
                files.push(name.to_string());
            }
        }
    }
    files.sort();
    Ok(files)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::broca;
    use std::fs;

    // --- Helper ---

    fn create_entry(dir: &Path, filename: &str, frontmatter: &str, content: &str) {
        let knowledge_dir = dir.join("knowledge");
        fs::create_dir_all(&knowledge_dir).unwrap();
        let full = format!("---\n{frontmatter}\n---\n\n{content}");
        fs::write(knowledge_dir.join(filename), full).unwrap();
    }

    // --- age_days tests ---

    #[test]
    fn test_age_days_today() {
        let today = Utc::now().format("%Y%m%d-%H%M%S").to_string();
        let age = age_days(&today);
        assert_eq!(age, Some(0));
    }

    #[test]
    fn test_age_days_date_only() {
        let age = age_days("20250101");
        assert!(age.is_some());
        assert!(age.unwrap() > 300); // More than 300 days ago from 2026
    }

    #[test]
    fn test_age_days_invalid() {
        assert!(age_days("garbage").is_none());
        assert!(age_days("").is_none());
    }

    // --- check_entry tests ---

    #[test]
    fn test_superseded_low_confidence_flagged() {
        let entry = Entry {
            filename: "test.md".to_string(),
            entry_type: entry::EntryType::Fact,
            title: "Old fact".to_string(),
            confidence: 0.3,
            tags: vec![],
            content: "content".to_string(),
            created: Utc::now().format("%Y%m%d-%H%M%S").to_string(),
            superseded_by: Some("new-fact.md".to_string()),
        };
        let config = GcConfig::default();
        let reason = check_entry(&entry, 100, &config);
        assert_eq!(reason, Some(GcReason::Superseded));
    }

    #[test]
    fn test_superseded_high_confidence_not_flagged() {
        let entry = Entry {
            filename: "test.md".to_string(),
            entry_type: entry::EntryType::Fact,
            title: "Still relevant".to_string(),
            confidence: 0.8,
            tags: vec![],
            content: "content".to_string(),
            created: Utc::now().format("%Y%m%d-%H%M%S").to_string(),
            superseded_by: Some("new.md".to_string()),
        };
        let config = GcConfig::default();
        assert!(check_entry(&entry, 0, &config).is_none());
    }

    #[test]
    fn test_very_low_confidence_flagged() {
        let entry = Entry {
            filename: "test.md".to_string(),
            entry_type: entry::EntryType::Observation,
            title: "Unreliable".to_string(),
            confidence: 0.1,
            tags: vec![],
            content: "content".to_string(),
            created: Utc::now().format("%Y%m%d-%H%M%S").to_string(),
            superseded_by: None,
        };
        let config = GcConfig::default();
        let reason = check_entry(&entry, 5, &config);
        assert_eq!(reason, Some(GcReason::LowConfidence));
    }

    #[test]
    fn test_old_unused_flagged() {
        let entry = Entry {
            filename: "test.md".to_string(),
            entry_type: entry::EntryType::Fact,
            title: "Old unused".to_string(),
            confidence: 0.5,
            tags: vec![],
            content: "content".to_string(),
            created: "20240101-120000".to_string(), // >1 year ago
            superseded_by: None,
        };
        let config = GcConfig::default();
        let reason = check_entry(&entry, 0, &config);
        assert!(matches!(reason, Some(GcReason::OldUnused { .. })));
    }

    #[test]
    fn test_old_but_accessed_not_flagged() {
        let entry = Entry {
            filename: "test.md".to_string(),
            entry_type: entry::EntryType::Fact,
            title: "Old but used".to_string(),
            confidence: 0.5,
            tags: vec![],
            content: "content".to_string(),
            created: "20240101-120000".to_string(),
            superseded_by: None,
        };
        let config = GcConfig::default();
        // Has accesses → not flagged
        assert!(check_entry(&entry, 3, &config).is_none());
    }

    #[test]
    fn test_old_high_confidence_not_flagged() {
        let entry = Entry {
            filename: "test.md".to_string(),
            entry_type: entry::EntryType::Fact,
            title: "Old but important".to_string(),
            confidence: 0.9,
            tags: vec![],
            content: "content".to_string(),
            created: "20240101-120000".to_string(),
            superseded_by: None,
        };
        let config = GcConfig::default();
        // High confidence → not flagged
        assert!(check_entry(&entry, 0, &config).is_none());
    }

    #[test]
    fn test_recent_low_confidence_not_old_unused() {
        let entry = Entry {
            filename: "test.md".to_string(),
            entry_type: entry::EntryType::Observation,
            title: "Recent low conf".to_string(),
            confidence: 0.5,
            tags: vec![],
            content: "content".to_string(),
            created: Utc::now().format("%Y%m%d-%H%M%S").to_string(),
            superseded_by: None,
        };
        let config = GcConfig::default();
        // Recent + conf > 0.2 → not flagged
        assert!(check_entry(&entry, 0, &config).is_none());
    }

    // --- Integration tests ---

    #[test]
    fn test_candidates_empty() {
        let dir = tempfile::tempdir().unwrap();
        let result = candidates(dir.path(), &GcConfig::default()).unwrap();
        assert!(result.is_empty());
    }

    #[test]
    fn test_candidates_finds_superseded() {
        let dir = tempfile::tempdir().unwrap();

        broca::remember(dir.path(), "fact", "New Fact", "content", &[]).unwrap();
        broca::supersede(dir.path(), "new-fact", "something").unwrap();

        // supersede() sets confidence to 0.3, which matches rule 1
        let result = candidates(dir.path(), &GcConfig::default()).unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].reason, GcReason::Superseded);
    }

    #[test]
    fn test_candidates_finds_low_confidence() {
        let dir = tempfile::tempdir().unwrap();

        create_entry(
            dir.path(),
            "bad.md",
            "type: fact\ntitle: \"Bad\"\nconfidence: 0.1\ncreated: 20260304",
            "unreliable info",
        );

        let result = candidates(dir.path(), &GcConfig::default()).unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].reason, GcReason::LowConfidence);
    }

    #[test]
    fn test_candidates_skips_healthy_entries() {
        let dir = tempfile::tempdir().unwrap();

        broca::remember(dir.path(), "fact", "Good Fact", "accurate content", &[]).unwrap();

        let result = candidates(dir.path(), &GcConfig::default()).unwrap();
        assert!(result.is_empty());
    }

    #[test]
    fn test_archive_and_restore() {
        let dir = tempfile::tempdir().unwrap();

        create_entry(
            dir.path(),
            "stale.md",
            "type: fact\ntitle: \"Stale\"\nconfidence: 0.1\ncreated: 20260304",
            "stale info",
        );

        let gc = candidates(dir.path(), &GcConfig::default()).unwrap();
        assert_eq!(gc.len(), 1);

        // Archive
        let archived = archive(dir.path(), &gc).unwrap();
        assert_eq!(archived, vec!["stale.md"]);

        // Entry should be gone from knowledge/
        assert!(!dir.path().join("knowledge/stale.md").exists());
        // But present in archive/
        assert!(dir.path().join("archive/stale.md").exists());

        // Restore
        let restored = restore(dir.path(), "stale.md").unwrap();
        assert!(restored.exists());
        assert!(dir.path().join("knowledge/stale.md").exists());
        assert!(!dir.path().join("archive/stale.md").exists());
    }

    #[test]
    fn test_list_archived_empty() {
        let dir = tempfile::tempdir().unwrap();
        let result = list_archived(dir.path()).unwrap();
        assert!(result.is_empty());
    }

    #[test]
    fn test_list_archived() {
        let dir = tempfile::tempdir().unwrap();
        let archive_dir = dir.path().join("archive");
        fs::create_dir_all(&archive_dir).unwrap();
        fs::write(archive_dir.join("old.md"), "content").unwrap();
        fs::write(archive_dir.join("stale.md"), "content").unwrap();

        let result = list_archived(dir.path()).unwrap();
        assert_eq!(result, vec!["old.md", "stale.md"]);
    }

    #[test]
    fn test_collect_full_gc() {
        let dir = tempfile::tempdir().unwrap();

        // Create one healthy, one stale
        broca::remember(dir.path(), "fact", "Healthy", "good content", &[]).unwrap();
        create_entry(
            dir.path(),
            "stale.md",
            "type: observation\ntitle: \"Stale\"\nconfidence: 0.15\ncreated: 20260304",
            "unreliable",
        );

        let archived = collect(dir.path(), &GcConfig::default()).unwrap();
        assert_eq!(archived.len(), 1);
        assert_eq!(archived[0], "stale.md");

        // Healthy entry still exists
        let entries = entry::load_all(&dir.path().join("knowledge")).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].title, "Healthy");
    }

    #[test]
    fn test_restore_nonexistent() {
        let dir = tempfile::tempdir().unwrap();
        let result = restore(dir.path(), "nonexistent.md");
        assert!(result.is_err());
    }

    #[test]
    fn test_custom_config() {
        let dir = tempfile::tempdir().unwrap();

        // Entry ~200 days old with confidence 0.6 — not flagged with default (365) but flagged with aggressive (180)
        create_entry(
            dir.path(),
            "old.md",
            "type: fact\ntitle: \"Old\"\nconfidence: 0.6\ncreated: 20250901",
            "content",
        );

        let default_gc = candidates(dir.path(), &GcConfig::default()).unwrap();
        assert_eq!(default_gc.len(), 0); // ~200 days < 365

        // With aggressive config: max_age=180 days
        let aggressive = GcConfig {
            max_age_days: 180,
            ..GcConfig::default()
        };
        let result = candidates(dir.path(), &aggressive).unwrap();
        assert_eq!(result.len(), 1);
    }

    #[test]
    fn test_gc_reason_display() {
        assert_eq!(GcReason::Superseded.to_string(), "superseded");
        assert_eq!(
            GcReason::OldUnused { age_days: 400 }.to_string(),
            "old and unused (400 days)"
        );
        assert_eq!(GcReason::LowConfidence.to_string(), "very low confidence");
    }
}
