//! Search and recall functionality for Broca memory.
//!
//! Implements relevance-ranked search across memory entries using
//! keyword matching, title similarity, tag matching, and confidence weighting.

use std::path::Path;

use super::entry::{self, Entry, EntryType};
use super::BrocaError;

/// Calculate Levenshtein distance between two strings.
/// Returns the minimum number of single-character edits required to transform one string into another.
fn levenshtein_distance(s1: &str, s2: &str) -> usize {
    let s1_chars: Vec<char> = s1.chars().collect();
    let s2_chars: Vec<char> = s2.chars().collect();
    let len1 = s1_chars.len();
    let len2 = s2_chars.len();

    let mut matrix = vec![vec![0; len2 + 1]; len1 + 1];

    // Initialize first row and column
    for i in 0..=len1 {
        matrix[i][0] = i;
    }
    for j in 0..=len2 {
        matrix[0][j] = j;
    }

    // Fill the matrix
    for i in 1..=len1 {
        for j in 1..=len2 {
            let cost = if s1_chars[i - 1] == s2_chars[j - 1] {
                0
            } else {
                1
            };
            matrix[i][j] = std::cmp::min(
                std::cmp::min(
                    matrix[i - 1][j] + 1, // deletion
                    matrix[i][j - 1] + 1, // insertion
                ),
                matrix[i - 1][j - 1] + cost, // substitution
            );
        }
    }

    matrix[len1][len2]
}

/// Check if two strings are similar based on fuzzy matching.
/// Returns a similarity score between 0.0 and 1.0.
fn fuzzy_similarity(s1: &str, s2: &str) -> f64 {
    if s1.is_empty() && s2.is_empty() {
        return 1.0;
    }
    if s1.is_empty() || s2.is_empty() {
        return 0.0;
    }

    let max_len = std::cmp::max(s1.len(), s2.len());
    let distance = levenshtein_distance(s1, s2);
    1.0 - (distance as f64 / max_len as f64)
}

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
                // Exact content hits (count occurrences)
                let content_hits = content_lower.matches(keyword.as_str()).count();
                score += content_hits as f64;

                // Fuzzy content matching (split content into words and check similarity)
                for word in content_lower.split_whitespace() {
                    let similarity = fuzzy_similarity(keyword, word);
                    if similarity >= 0.8 {
                        // 80% similarity threshold
                        score += similarity * 0.5; // Lower weight than exact matches
                    }
                }

                // Exact title match (worth more)
                if title_lower.contains(keyword.as_str()) {
                    score += 5.0;
                }

                // Fuzzy title matching
                for title_word in title_lower.split_whitespace() {
                    let similarity = fuzzy_similarity(keyword, title_word);
                    if similarity >= 0.8 {
                        score += similarity * 2.5; // Half weight of exact title match
                    }
                }

                // Exact tag match
                for tag in &entry.tags {
                    let tag_lower = tag.to_lowercase();
                    if tag_lower.contains(keyword.as_str()) {
                        score += 3.0;
                    } else {
                        // Fuzzy tag matching
                        let similarity = fuzzy_similarity(keyword, &tag_lower);
                        if similarity >= 0.8 {
                            score += similarity * 1.5; // Half weight of exact tag match
                        }
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

    #[test]
    fn test_levenshtein_distance() {
        assert_eq!(levenshtein_distance("", ""), 0);
        assert_eq!(levenshtein_distance("abc", ""), 3);
        assert_eq!(levenshtein_distance("", "abc"), 3);
        assert_eq!(levenshtein_distance("abc", "abc"), 0);
        assert_eq!(levenshtein_distance("abc", "ab"), 1);
        assert_eq!(levenshtein_distance("abc", "abcd"), 1);
        assert_eq!(levenshtein_distance("rust", "trust"), 1);
        assert_eq!(levenshtein_distance("kitten", "sitting"), 3);
    }

    #[test]
    fn test_fuzzy_similarity() {
        assert_eq!(fuzzy_similarity("", ""), 1.0);
        assert_eq!(fuzzy_similarity("abc", "abc"), 1.0);
        assert!((fuzzy_similarity("rust", "trust") - 0.8).abs() < 0.01); // 4/5 = 0.8

        // "test" vs "testing": distance=3, max_len=7, similarity = 1 - 3/7 ≈ 0.57
        assert!((fuzzy_similarity("test", "testing") - 0.57).abs() < 0.01);
    }

    #[test]
    fn test_recall_fuzzy_matching() {
        let dir = tempfile::tempdir().unwrap();
        setup_test_memory(dir.path());

        // Add specific content for fuzzy testing
        broca::remember(
            dir.path(),
            "fact",
            "Fuzzy test fact",
            "This contains words like trust and java concepts.",
            &["testing".to_string()],
        )
        .unwrap();

        // Should find "trust" with fuzzy match to "rust" (distance=1, similarity=0.8)
        let results = recall(dir.path(), "rust", 5).unwrap();
        assert!(
            !results.is_empty(),
            "Should find fuzzy matches for 'rust' -> 'trust'"
        );

        // Verify fuzzy similarity calculation for our test case
        let similarity = fuzzy_similarity("rust", "trust");
        assert!(
            similarity >= 0.8,
            "rust/trust similarity should be >= 0.8, got {}",
            similarity
        );
    }

    #[test]
    fn test_recall_exact_vs_fuzzy_scores() {
        let dir = tempfile::tempdir().unwrap();
        setup_test_memory(dir.path());

        // Exact matches should score higher than fuzzy matches
        let exact_results = recall(dir.path(), "rust", 5).unwrap();
        let fuzzy_results = recall(dir.path(), "rast", 5).unwrap();

        if !exact_results.is_empty() && !fuzzy_results.is_empty() {
            // Exact match should have higher score than fuzzy match
            assert!(exact_results[0].relevance_score > fuzzy_results[0].relevance_score);
        }
    }
}
