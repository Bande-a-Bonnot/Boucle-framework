//! Search and recall functionality for Broca memory.
//!
//! Implements relevance-ranked search across memory entries using
//! keyword matching, title similarity, tag matching, and confidence weighting.

use std::path::Path;

use super::entry::{self, Entry, EntryType};
use super::BrocaError;

/// A memory entry with a relevance score.
#[derive(Debug, Clone)]
pub struct ScoredEntry {
    pub filename: String,
    pub entry_type: EntryType,
    pub title: String,
    pub confidence: f64,
    pub tags: Vec<String>,
    pub content: String,
    pub relevance_score: f64,
    pub superseded_by: Option<String>,
}

impl From<&Entry> for ScoredEntry {
    fn from(entry: &Entry) -> Self {
        ScoredEntry {
            filename: entry.filename.clone(),
            entry_type: entry.entry_type.clone(),
            title: entry.title.clone(),
            confidence: entry.confidence,
            tags: entry.tags.clone(),
            content: entry.content.clone(),
            relevance_score: 0.0,
            superseded_by: entry.superseded_by.clone(),
        }
    }
}

/// Search memory with relevance ranking.
///
/// Scoring factors:
/// - Keyword hits in content (1.0 per hit)
/// - Title match (5.0 per keyword)
/// - Tag match (3.0 per matching tag)
/// - Confidence weighting (multiplier)
/// - Superseded entries are penalized
pub fn recall(
    memory_dir: &Path,
    query: &str,
    limit: usize,
) -> Result<Vec<ScoredEntry>, BrocaError> {
    let knowledge_dir = memory_dir.join("knowledge");
    let entries = entry::load_all(&knowledge_dir)?;

    let keywords: Vec<String> = query
        .to_lowercase()
        .split_whitespace()
        .filter(|w| w.len() > 2) // Skip short words
        .map(|w| w.to_string())
        .collect();

    if keywords.is_empty() {
        return Ok(Vec::new());
    }

    let mut scored: Vec<ScoredEntry> = entries
        .iter()
        .map(|entry| {
            let mut score = 0.0f64;
            let content_lower = entry.content.to_lowercase();
            let title_lower = entry.title.to_lowercase();

            for keyword in &keywords {
                // Content hits (count occurrences)
                let content_hits = content_lower.matches(keyword.as_str()).count();
                score += content_hits as f64;

                // Title match (worth more)
                if title_lower.contains(keyword.as_str()) {
                    score += 5.0;
                }

                // Tag match
                for tag in &entry.tags {
                    if tag.to_lowercase().contains(keyword.as_str()) {
                        score += 3.0;
                    }
                }
            }

            // Confidence multiplier
            score *= entry.confidence;

            // Penalize superseded entries
            if entry.superseded_by.is_some() {
                score *= 0.3;
            }

            let mut scored_entry = ScoredEntry::from(entry);
            scored_entry.relevance_score = score;
            scored_entry
        })
        .filter(|e| e.relevance_score > 0.0)
        .collect();

    // Sort by score descending
    scored.sort_by(|a, b| {
        b.relevance_score
            .partial_cmp(&a.relevance_score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    scored.truncate(limit);
    Ok(scored)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::broca;
    use std::fs;

    fn setup_test_memory(dir: &Path) {
        broca::remember(
            dir,
            "fact",
            "Rust is fast",
            "Rust is a systems programming language known for speed and safety.",
            &["rust".to_string(), "performance".to_string()],
        )
        .unwrap();

        broca::remember(
            dir,
            "fact",
            "Python is easy",
            "Python is a high-level language known for readability.",
            &["python".to_string()],
        )
        .unwrap();

        broca::remember(
            dir,
            "decision",
            "Use Rust for the rewrite",
            "We decided to rewrite the framework in Rust for reliability.",
            &["rust".to_string(), "architecture".to_string()],
        )
        .unwrap();
    }

    #[test]
    fn test_recall_basic() {
        let dir = tempfile::tempdir().unwrap();
        setup_test_memory(dir.path());

        let results = recall(dir.path(), "rust", 5).unwrap();
        assert!(!results.is_empty());
        // "Use Rust for the rewrite" or "Rust is fast" should be top
        assert!(results[0].title.contains("Rust") || results[0].title.contains("rust"));
    }

    #[test]
    fn test_recall_multiple_keywords() {
        let dir = tempfile::tempdir().unwrap();
        setup_test_memory(dir.path());

        let results = recall(dir.path(), "rust speed", 5).unwrap();
        assert!(!results.is_empty());
        // "Rust is fast" should rank highest (matches both title and content)
        assert!(results[0].title.contains("fast") || results[0].content.contains("speed"));
    }

    #[test]
    fn test_recall_no_match() {
        let dir = tempfile::tempdir().unwrap();
        setup_test_memory(dir.path());

        let results = recall(dir.path(), "javascript", 5).unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_recall_empty_query() {
        let dir = tempfile::tempdir().unwrap();
        setup_test_memory(dir.path());

        let results = recall(dir.path(), "", 5).unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_recall_short_words_filtered() {
        let dir = tempfile::tempdir().unwrap();
        setup_test_memory(dir.path());

        // "is" and "a" are too short, should be filtered
        let results = recall(dir.path(), "is a", 5).unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_recall_limit() {
        let dir = tempfile::tempdir().unwrap();
        setup_test_memory(dir.path());

        let results = recall(dir.path(), "language", 1).unwrap();
        assert!(results.len() <= 1);
    }

    #[test]
    fn test_recall_confidence_weighting() {
        let dir = tempfile::tempdir().unwrap();

        // Create two entries with different confidence
        broca::remember(dir.path(), "fact", "Low confidence", "rust testing", &[]).unwrap();

        // Manually create a high-confidence entry
        let knowledge_dir = dir.path().join("knowledge");
        let high_conf = "---\ntype: fact\ntitle: \"High confidence\"\nconfidence: 1.0\ncreated: 20260228\n---\n\nrust testing";
        fs::write(
            knowledge_dir.join("20260228-999999-high-confidence.md"),
            high_conf,
        )
        .unwrap();

        let results = recall(dir.path(), "rust testing", 5).unwrap();
        assert!(results.len() >= 2);
        // Higher confidence should rank first when content matches equally
        assert!(results[0].confidence >= results[1].confidence);
    }

    #[test]
    fn test_recall_superseded_penalty() {
        let dir = tempfile::tempdir().unwrap();

        broca::remember(dir.path(), "fact", "Current fact", "rust memory", &[]).unwrap();

        // Create a superseded entry
        let knowledge_dir = dir.path().join("knowledge");
        let superseded = "---\ntype: fact\ntitle: \"Old fact\"\nconfidence: 0.9\nsuperseded_by: current\ncreated: 20260228\n---\n\nrust memory old version";
        fs::write(
            knowledge_dir.join("20260228-000001-old-fact.md"),
            superseded,
        )
        .unwrap();

        let results = recall(dir.path(), "rust memory", 5).unwrap();
        assert!(results.len() >= 2);
        // Non-superseded should rank higher
        assert!(results[0].superseded_by.is_none());
    }
}
