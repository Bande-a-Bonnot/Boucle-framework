//! Search and recall functionality for Broca memory.
//!
//! Implements BM25-ranked search across memory entries, with additional
//! boosts for title matches, tag matches, and confidence weighting.
//! BM25 (Best Matching 25) normalizes by document length and term rarity,
//! replacing naive keyword counting. Inspired by OpenClaw's hybrid search.

use std::collections::HashMap;
use std::path::Path;

use super::entry::{self, Entry, EntryType};
use super::BrocaError;

// --- BM25 parameters ---

/// Term frequency saturation. Higher = slower saturation (1.2 is standard).
const K1: f64 = 1.2;
/// Document length normalization. 0 = no normalization, 1 = full (0.75 is standard).
const B: f64 = 0.75;
/// Score multiplier for title matches (BM25 on title text).
const TITLE_BOOST: f64 = 3.0;
/// Score bonus for each matching tag.
const TAG_BONUS: f64 = 2.0;

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

/// Tokenize text into lowercase words, filtering short tokens (len <= 2).
fn tokenize(text: &str) -> Vec<String> {
    text.to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| w.len() > 2)
        .map(|w| w.to_string())
        .collect()
}

/// Count term frequency in a token list.
fn term_freq(tokens: &[String], term: &str) -> usize {
    tokens.iter().filter(|t| t.as_str() == term).count()
}

/// Compute IDF(term) = ln((N - df + 0.5) / (df + 0.5) + 1)
/// Uses the "plus 1" variant to avoid negative IDF for common terms.
fn idf(num_docs: usize, doc_freq: usize) -> f64 {
    let n = num_docs as f64;
    let df = doc_freq as f64;
    ((n - df + 0.5) / (df + 0.5) + 1.0).ln()
}

/// Compute BM25 term score: IDF * (f * (k1 + 1)) / (f + k1 * (1 - b + b * dl / avgdl))
fn bm25_term_score(tf: usize, doc_len: usize, avg_doc_len: f64, idf_val: f64) -> f64 {
    let f = tf as f64;
    let dl = doc_len as f64;
    let numerator = f * (K1 + 1.0);
    let denominator = f + K1 * (1.0 - B + B * dl / avg_doc_len);
    idf_val * numerator / denominator
}

/// Search memory with BM25 relevance ranking.
///
/// Scoring:
/// 1. BM25 on content tokens (standard information retrieval)
/// 2. BM25 on title tokens, boosted by TITLE_BOOST
/// 3. Tag exact-match bonus (TAG_BONUS per matching tag)
/// 4. Confidence multiplier (entry.confidence)
/// 5. Superseded entries penalized (×0.3)
pub fn recall(
    memory_dir: &Path,
    query: &str,
    limit: usize,
) -> Result<Vec<ScoredEntry>, BrocaError> {
    let knowledge_dir = memory_dir.join("knowledge");
    let entries = entry::load_all(&knowledge_dir)?;

    let query_terms = tokenize(query);
    if query_terms.is_empty() {
        return Ok(Vec::new());
    }

    let num_docs = entries.len();
    if num_docs == 0 {
        return Ok(Vec::new());
    }

    // Pre-tokenize all documents
    let doc_tokens: Vec<Vec<String>> = entries.iter().map(|e| tokenize(&e.content)).collect();
    let title_tokens: Vec<Vec<String>> = entries.iter().map(|e| tokenize(&e.title)).collect();

    // Compute average document length
    let total_tokens: usize = doc_tokens.iter().map(|t| t.len()).sum();
    let avg_doc_len = if num_docs > 0 {
        total_tokens as f64 / num_docs as f64
    } else {
        1.0
    };
    let avg_title_len = {
        let total: usize = title_tokens.iter().map(|t| t.len()).sum();
        if num_docs > 0 {
            (total as f64 / num_docs as f64).max(1.0)
        } else {
            1.0
        }
    };

    // Compute document frequency for each query term (across content + title)
    let mut content_df: HashMap<&str, usize> = HashMap::new();
    let mut title_df: HashMap<&str, usize> = HashMap::new();
    for term in &query_terms {
        let cdf = doc_tokens
            .iter()
            .filter(|tokens| tokens.iter().any(|t| t == term))
            .count();
        content_df.insert(term.as_str(), cdf);

        let tdf = title_tokens
            .iter()
            .filter(|tokens| tokens.iter().any(|t| t == term))
            .count();
        title_df.insert(term.as_str(), tdf);
    }

    // Score each document
    let mut scored: Vec<ScoredEntry> = entries
        .iter()
        .enumerate()
        .map(|(i, entry)| {
            let mut score = 0.0f64;

            // BM25 on content
            for term in &query_terms {
                let tf = term_freq(&doc_tokens[i], term);
                if tf > 0 {
                    let idf_val = idf(num_docs, *content_df.get(term.as_str()).unwrap_or(&0));
                    score += bm25_term_score(tf, doc_tokens[i].len(), avg_doc_len, idf_val);
                }
            }

            // BM25 on title (boosted)
            for term in &query_terms {
                let tf = term_freq(&title_tokens[i], term);
                if tf > 0 {
                    let idf_val = idf(num_docs, *title_df.get(term.as_str()).unwrap_or(&0));
                    score += TITLE_BOOST
                        * bm25_term_score(tf, title_tokens[i].len(), avg_title_len, idf_val);
                }
            }

            // Tag exact-match bonus
            let tags_lower: Vec<String> =
                entry.tags.iter().map(|t| t.to_lowercase()).collect();
            for term in &query_terms {
                if tags_lower.iter().any(|t| t == term) {
                    score += TAG_BONUS;
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
    fn test_tokenize() {
        let tokens = tokenize("Hello, World! This is a test.");
        assert!(tokens.contains(&"hello".to_string()));
        assert!(tokens.contains(&"world".to_string()));
        assert!(tokens.contains(&"this".to_string()));
        assert!(tokens.contains(&"test".to_string()));
        // Short words filtered
        assert!(!tokens.contains(&"is".to_string()));
        assert!(!tokens.contains(&"a".to_string()));
    }

    #[test]
    fn test_idf_basic() {
        // Term in no documents → high IDF
        let idf_rare = idf(10, 0);
        // Term in all documents → low IDF
        let idf_common = idf(10, 10);
        assert!(idf_rare > idf_common);
        // IDF should always be positive with the +1 variant
        assert!(idf_common > 0.0);
    }

    #[test]
    fn test_bm25_term_score_basic() {
        // Higher TF → higher score (with diminishing returns)
        let score_tf1 = bm25_term_score(1, 10, 10.0, 1.0);
        let score_tf5 = bm25_term_score(5, 10, 10.0, 1.0);
        assert!(score_tf5 > score_tf1);
        // But sublinear — tf5 should not be 5x tf1
        assert!(score_tf5 < score_tf1 * 5.0);
    }

    #[test]
    fn test_bm25_length_normalization() {
        // Shorter doc with same TF should score higher
        let score_short = bm25_term_score(2, 5, 10.0, 1.0);
        let score_long = bm25_term_score(2, 50, 10.0, 1.0);
        assert!(score_short > score_long);
    }

    #[test]
    fn test_recall_basic() {
        let dir = tempfile::tempdir().unwrap();
        setup_test_memory(dir.path());

        let results = recall(dir.path(), "rust", 5).unwrap();
        assert!(!results.is_empty());
        // Entries mentioning "rust" in title, content, or tags should appear
        assert!(results[0].title.contains("Rust") || results[0].title.contains("rust"));
    }

    #[test]
    fn test_recall_multiple_keywords() {
        let dir = tempfile::tempdir().unwrap();
        setup_test_memory(dir.path());

        let results = recall(dir.path(), "rust speed", 5).unwrap();
        assert!(!results.is_empty());
        // "Rust is fast" should rank highest — matches "rust" in title+content+tag AND "speed" in content
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
    fn test_recall_tag_boost() {
        let dir = tempfile::tempdir().unwrap();

        // Entry with tag "performance" but no content match
        broca::remember(
            dir.path(),
            "fact",
            "Speed matters",
            "Latency impacts user experience significantly.",
            &["performance".to_string()],
        )
        .unwrap();

        // Entry with content match but no tag
        broca::remember(
            dir.path(),
            "fact",
            "Other topic",
            "The performance of the system was tested.",
            &[],
        )
        .unwrap();

        let results = recall(dir.path(), "performance", 5).unwrap();
        assert!(results.len() >= 2);
        // Both should match — tag match gives bonus on top of any content match
    }

    #[test]
    fn test_recall_title_boost() {
        let dir = tempfile::tempdir().unwrap();

        // Entry with term in title
        broca::remember(
            dir.path(),
            "fact",
            "Memory architecture",
            "Description of system design.",
            &[],
        )
        .unwrap();

        // Entry with term only in content
        broca::remember(
            dir.path(),
            "fact",
            "System design",
            "The memory architecture is important for performance.",
            &[],
        )
        .unwrap();

        let results = recall(dir.path(), "memory", 5).unwrap();
        assert!(!results.is_empty());
        // Title match should boost the first entry higher
        assert_eq!(results[0].title, "Memory architecture");
    }

    #[test]
    fn test_bm25_rare_terms_score_higher() {
        // Rare term (appears in 1/10 docs) should have higher IDF than common term (9/10)
        let idf_rare = idf(10, 1);
        let idf_common = idf(10, 9);
        assert!(
            idf_rare > idf_common,
            "Rare terms should have higher IDF: {} vs {}",
            idf_rare,
            idf_common
        );
    }
}
