//! Search and recall functionality for Broca memory.
//!
//! Implements BM25-ranked search across memory entries, with additional
//! boosts for title matches, tag matches, confidence weighting,
//! temporal decay (recency), and access frequency.
//!
//! BM25 (Best Matching 25) normalizes by document length and term rarity.
//! Temporal decay favors recent entries. Access tracking boosts frequently
//! accessed entries. Inspired by OpenClaw's hybrid search.

use chrono::{NaiveDate, NaiveDateTime, Utc};
use std::collections::HashMap;
use std::path::Path;

use super::access;
use super::entry::{self, Entry, EntryType};
use super::relations;
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

// --- Temporal decay parameters ---

/// Decay rate for recency. Controls half-life of entries.
/// With 0.007, half-life ≈ 100 days. Gentle enough that old facts stay relevant.
const RECENCY_DECAY_RATE: f64 = 0.007;

// --- Access boost parameters ---

/// Weight for access frequency boost: score += ACCESS_WEIGHT * ln(1 + count).
/// Logarithmic scaling prevents heavily-accessed entries from dominating.
const ACCESS_WEIGHT: f64 = 0.15;

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
    /// TTL in days, if set.
    pub ttl_days: Option<u32>,
    /// True if the entry has a TTL that has expired.
    pub is_stale: bool,
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
            ttl_days: entry.ttl_days,
            is_stale: entry.is_stale(),
        }
    }
}

/// Tokenize text into lowercase words, filtering short tokens (len <= 2).
pub(crate) fn tokenize(text: &str) -> Vec<String> {
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

/// Compute recency factor from a created timestamp string.
/// Returns a value in (0, 1] where 1.0 = created now, decaying over time.
/// Uses hyperbolic decay: 1 / (1 + age_days * rate).
/// Entries with unparseable dates get 0.5 (neutral).
fn recency_factor(created: &str) -> f64 {
    let now = Utc::now().naive_utc();
    let created_dt = parse_created(created);
    match created_dt {
        Some(dt) => {
            let age_days = (now - dt).num_days().max(0) as f64;
            1.0 / (1.0 + age_days * RECENCY_DECAY_RATE)
        }
        None => 0.5, // unparseable → neutral
    }
}

/// Parse a created timestamp. Supports:
/// - "YYYYMMDD-HHMMSS" (e.g., "20260304-143022")
/// - "YYYYMMDD" (e.g., "20260304")
fn parse_created(created: &str) -> Option<NaiveDateTime> {
    // Try full format first
    if let Ok(dt) = NaiveDateTime::parse_from_str(created, "%Y%m%d-%H%M%S") {
        return Some(dt);
    }
    // Try date-only
    if let Ok(d) = NaiveDate::parse_from_str(created, "%Y%m%d") {
        return d.and_hms_opt(0, 0, 0);
    }
    None
}

/// Compute access frequency boost: ACCESS_WEIGHT * ln(1 + count).
/// Returns 0 for entries never accessed.
fn access_boost(count: u64) -> f64 {
    ACCESS_WEIGHT * (1.0 + count as f64).ln()
}

/// Search memory with BM25 relevance ranking, temporal decay, and access boost.
///
/// Scoring:
/// 1. BM25 on content tokens (standard information retrieval)
/// 2. BM25 on title tokens, boosted by TITLE_BOOST
/// 3. Tag exact-match bonus (TAG_BONUS per matching tag)
/// 4. Confidence multiplier (entry.confidence)
/// 5. Temporal decay — recent entries score higher
/// 6. Access frequency boost — frequently recalled entries score higher
/// 7. Superseded entries penalized (×0.3)
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

    // Load access log for frequency boost
    let access_log = access::load(memory_dir);

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
            let tags_lower: Vec<String> = entry.tags.iter().map(|t| t.to_lowercase()).collect();
            for term in &query_terms {
                if tags_lower.iter().any(|t| t == term) {
                    score += TAG_BONUS;
                }
            }

            // Confidence multiplier
            score *= entry.confidence;

            // Temporal decay — recent entries get higher scores
            score *= recency_factor(&entry.created);

            // Access frequency boost
            let acc_count = access_log
                .get(&entry.filename)
                .map(|r| r.count)
                .unwrap_or(0);
            score *= 1.0 + access_boost(acc_count);

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

    // Cross-reference boost: entries related to high-scoring results get a boost.
    // Load the relation graph (cheap — RELATIONS.md is typically small).
    let graph = relations::load_relations(memory_dir);
    if !graph.is_empty() {
        // Collect current scores by filename for lookup
        let score_map: HashMap<String, f64> = scored
            .iter()
            .map(|e| (e.filename.clone(), e.relevance_score))
            .collect();

        // For each scored entry, accumulate boost from related entries that also scored
        for entry in &mut scored {
            if let Some(neighbors) = graph.get(&entry.filename) {
                let mut cross_boost: f64 = 0.0;
                for (related_file, rel_type) in neighbors {
                    let weight = relations::relation_weight(rel_type);
                    if weight > 0.0 {
                        if let Some(&related_score) = score_map.get(related_file) {
                            // Boost proportional to the related entry's score and relation weight
                            cross_boost += related_score * weight;
                        }
                    }
                }
                entry.relevance_score += cross_boost;
            }
        }
    }

    // Sort by score descending
    scored.sort_by(|a, b| {
        b.relevance_score
            .partial_cmp(&a.relevance_score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    scored.truncate(limit);

    // Record access for returned results (non-blocking best-effort)
    let accessed_files: Vec<&str> = scored.iter().map(|e| e.filename.as_str()).collect();
    let _ = access::record_access(memory_dir, &accessed_files);

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
            None,
        )
        .unwrap();

        broca::remember(
            dir,
            "fact",
            "Python is easy",
            "Python is a high-level language known for readability.",
            &["python".to_string()],
            None,
        )
        .unwrap();

        broca::remember(
            dir,
            "decision",
            "Use Rust for the rewrite",
            "We decided to rewrite the framework in Rust for reliability.",
            &["rust".to_string(), "architecture".to_string()],
            None,
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

        // Create two entries with the same date but different confidence,
        // so recency is equal and only confidence affects ranking.
        let knowledge_dir = dir.path().join("knowledge");
        fs::create_dir_all(&knowledge_dir).unwrap();
        let low_conf = "---\ntype: fact\ntitle: \"Low confidence\"\nconfidence: 0.2\ncreated: 20260228\n---\n\nrust testing";
        fs::write(
            knowledge_dir.join("20260228-000001-low-confidence.md"),
            low_conf,
        )
        .unwrap();
        let high_conf = "---\ntype: fact\ntitle: \"High confidence\"\nconfidence: 1.0\ncreated: 20260228\n---\n\nrust testing";
        fs::write(
            knowledge_dir.join("20260228-000002-high-confidence.md"),
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

        broca::remember(dir.path(), "fact", "Current fact", "rust memory", &[], None).unwrap();

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
            None,
        )
        .unwrap();

        // Entry with content match but no tag
        broca::remember(
            dir.path(),
            "fact",
            "Other topic",
            "The performance of the system was tested.",
            &[],
            None,
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
            None,
        )
        .unwrap();

        // Entry with term only in content
        broca::remember(
            dir.path(),
            "fact",
            "System design",
            "The memory architecture is important for performance.",
            &[],
            None,
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

    // --- Temporal decay tests ---

    #[test]
    fn test_parse_created_full_format() {
        let dt = parse_created("20260304-143022");
        assert!(dt.is_some());
        let dt = dt.unwrap();
        assert_eq!(dt.date(), NaiveDate::from_ymd_opt(2026, 3, 4).unwrap());
    }

    #[test]
    fn test_parse_created_date_only() {
        let dt = parse_created("20260304");
        assert!(dt.is_some());
        let dt = dt.unwrap();
        assert_eq!(dt.date(), NaiveDate::from_ymd_opt(2026, 3, 4).unwrap());
    }

    #[test]
    fn test_parse_created_invalid() {
        assert!(parse_created("").is_none());
        assert!(parse_created("not-a-date").is_none());
    }

    #[test]
    fn test_recency_factor_today() {
        // Entry created now should have factor close to 1.0
        let now = Utc::now().format("%Y%m%d-%H%M%S").to_string();
        let factor = recency_factor(&now);
        assert!(factor > 0.99, "Today's entry should be ~1.0: {factor}");
    }

    #[test]
    fn test_recency_factor_old() {
        // Entry from 200 days ago should have lower factor
        let factor = recency_factor("20250815-120000");
        assert!(factor < 0.5, "200-day-old entry should be < 0.5: {factor}");
    }

    #[test]
    fn test_recency_factor_invalid() {
        // Unparseable date → 0.5 (neutral)
        let factor = recency_factor("garbage");
        assert!((factor - 0.5).abs() < f64::EPSILON);
    }

    #[test]
    fn test_recency_decay_ordering() {
        // Newer entries should have higher recency factor
        let recent = recency_factor("20260303-120000");
        let older = recency_factor("20260101-120000");
        let ancient = recency_factor("20250601-120000");
        assert!(recent > older, "Recent > older: {recent} vs {older}");
        assert!(older > ancient, "Older > ancient: {older} vs {ancient}");
    }

    // --- Access boost tests ---

    #[test]
    fn test_access_boost_zero() {
        assert!((access_boost(0) - 0.0).abs() < f64::EPSILON);
    }

    #[test]
    fn test_access_boost_increases() {
        let boost_1 = access_boost(1);
        let boost_10 = access_boost(10);
        let boost_100 = access_boost(100);
        assert!(boost_1 > 0.0);
        assert!(boost_10 > boost_1);
        assert!(boost_100 > boost_10);
    }

    #[test]
    fn test_access_boost_sublinear() {
        // 100 accesses should not give 100x the boost of 1 access
        let boost_1 = access_boost(1);
        let boost_100 = access_boost(100);
        assert!(
            boost_100 < boost_1 * 10.0,
            "Boost should be sublinear: {boost_100} vs {boost_1}"
        );
    }

    // --- Integration: temporal decay + access in recall ---

    #[test]
    fn test_recall_records_access() {
        let dir = tempfile::tempdir().unwrap();
        setup_test_memory(dir.path());

        // First recall
        let results = recall(dir.path(), "rust", 5).unwrap();
        assert!(!results.is_empty());

        // Check access log was created
        let log = access::load(dir.path());
        assert!(
            !log.is_empty(),
            "Access log should be populated after recall"
        );

        // Each returned result should have been recorded
        for result in &results {
            assert!(
                log.contains_key(&result.filename),
                "Result {} should be in access log",
                result.filename
            );
            assert_eq!(log[&result.filename].count, 1);
        }
    }

    #[test]
    fn test_recall_access_boost_effect() {
        let dir = tempfile::tempdir().unwrap();

        // Create two entries with identical content
        let knowledge_dir = dir.path().join("knowledge");
        fs::create_dir_all(&knowledge_dir).unwrap();

        let entry_a = "---\ntype: fact\ntitle: \"Entry A\"\nconfidence: 0.8\ncreated: 20260304-120000\n---\n\nrust memory system design";
        let entry_b = "---\ntype: fact\ntitle: \"Entry B\"\nconfidence: 0.8\ncreated: 20260304-120000\n---\n\nrust memory system design";
        fs::write(knowledge_dir.join("20260304-120000-entry-a.md"), entry_a).unwrap();
        fs::write(knowledge_dir.join("20260304-120001-entry-b.md"), entry_b).unwrap();

        // Pre-populate access log: entry A has been accessed 20 times
        access::record_access(dir.path(), &["20260304-120000-entry-a.md"]).unwrap();
        for _ in 0..19 {
            access::record_access(dir.path(), &["20260304-120000-entry-a.md"]).unwrap();
        }

        let results = recall(dir.path(), "rust memory", 5).unwrap();
        assert!(results.len() >= 2);

        // Entry A (20 accesses) should rank higher than Entry B (0 accesses)
        let a_score = results
            .iter()
            .find(|e| e.title == "Entry A")
            .unwrap()
            .relevance_score;
        let b_score = results
            .iter()
            .find(|e| e.title == "Entry B")
            .unwrap()
            .relevance_score;
        assert!(
            a_score > b_score,
            "Accessed entry should rank higher: {a_score} vs {b_score}"
        );
    }

    #[test]
    fn test_recall_recency_effect() {
        let dir = tempfile::tempdir().unwrap();

        // Create two entries: one recent, one old — same content
        let knowledge_dir = dir.path().join("knowledge");
        fs::create_dir_all(&knowledge_dir).unwrap();

        let recent = "---\ntype: fact\ntitle: \"Recent fact\"\nconfidence: 0.8\ncreated: 20260304-120000\n---\n\nrust memory";
        let old = "---\ntype: fact\ntitle: \"Old fact\"\nconfidence: 0.8\ncreated: 20250101-120000\n---\n\nrust memory";
        fs::write(knowledge_dir.join("20260304-120000-recent.md"), recent).unwrap();
        fs::write(knowledge_dir.join("20250101-120000-old.md"), old).unwrap();

        let results = recall(dir.path(), "rust memory", 5).unwrap();
        assert!(results.len() >= 2);

        // Recent entry should rank higher than old one
        assert_eq!(
            results[0].title, "Recent fact",
            "Recent entry should rank first"
        );
    }

    // --- Cross-reference boost tests ---

    #[test]
    fn test_cross_ref_boost_raises_related_entry() {
        let dir = tempfile::tempdir().unwrap();
        let knowledge_dir = dir.path().join("knowledge");
        fs::create_dir_all(&knowledge_dir).unwrap();

        // Entry A: strong match for "rust"
        let entry_a = "---\ntype: fact\ntitle: \"Rust overview\"\nconfidence: 0.9\ncreated: 20260304-120000\n---\n\nrust rust rust programming language";
        // Entry B: weak match for "rust" but related to A
        let entry_b = "---\ntype: fact\ntitle: \"Memory design\"\nconfidence: 0.9\ncreated: 20260304-120001\n---\n\nmemory design patterns for systems with some rust";
        // Entry C: weak match for "rust", NOT related to A
        let entry_c = "---\ntype: fact\ntitle: \"Unrelated topic\"\nconfidence: 0.9\ncreated: 20260304-120002\n---\n\nmemory design patterns for systems with some rust";

        fs::write(
            knowledge_dir.join("20260304-120000-rust-overview.md"),
            entry_a,
        )
        .unwrap();
        fs::write(
            knowledge_dir.join("20260304-120001-memory-design.md"),
            entry_b,
        )
        .unwrap();
        fs::write(
            knowledge_dir.join("20260304-120002-unrelated-topic.md"),
            entry_c,
        )
        .unwrap();

        // Create relation: A <-> B (similar_to)
        fs::write(
            dir.path().join("RELATIONS.md"),
            "20260304-120000-rust-overview.md --[similar_to]--> 20260304-120001-memory-design.md\n",
        )
        .unwrap();

        let results = recall(dir.path(), "rust", 5).unwrap();
        assert!(results.len() >= 3);

        // B (related to high-scoring A) should rank higher than C (identical content, no relation)
        let b_score = results
            .iter()
            .find(|e| e.title == "Memory design")
            .unwrap()
            .relevance_score;
        let c_score = results
            .iter()
            .find(|e| e.title == "Unrelated topic")
            .unwrap()
            .relevance_score;
        assert!(
            b_score > c_score,
            "Related entry should rank higher: {b_score} vs {c_score}"
        );
    }

    #[test]
    fn test_cross_ref_no_boost_for_contradicts() {
        let dir = tempfile::tempdir().unwrap();
        let knowledge_dir = dir.path().join("knowledge");
        fs::create_dir_all(&knowledge_dir).unwrap();

        let entry_a = "---\ntype: fact\ntitle: \"Fact A\"\nconfidence: 0.9\ncreated: 20260304-120000\n---\n\nrust programming language overview";
        let entry_b = "---\ntype: fact\ntitle: \"Fact B\"\nconfidence: 0.9\ncreated: 20260304-120001\n---\n\nmemory systems with some rust";
        let entry_c = "---\ntype: fact\ntitle: \"Fact C\"\nconfidence: 0.9\ncreated: 20260304-120002\n---\n\nmemory systems with some rust";

        fs::write(knowledge_dir.join("20260304-120000-fact-a.md"), entry_a).unwrap();
        fs::write(knowledge_dir.join("20260304-120001-fact-b.md"), entry_b).unwrap();
        fs::write(knowledge_dir.join("20260304-120002-fact-c.md"), entry_c).unwrap();

        // B contradicts A (weight = 0.0), C has no relation
        fs::write(
            dir.path().join("RELATIONS.md"),
            "20260304-120000-fact-a.md --[contradicts]--> 20260304-120001-fact-b.md\n",
        )
        .unwrap();

        let results = recall(dir.path(), "rust", 5).unwrap();
        let b_score = results
            .iter()
            .find(|e| e.title == "Fact B")
            .unwrap()
            .relevance_score;
        let c_score = results
            .iter()
            .find(|e| e.title == "Fact C")
            .unwrap()
            .relevance_score;

        // B and C should have equal scores — contradicts gives no boost
        assert!(
            (b_score - c_score).abs() < f64::EPSILON,
            "Contradicts should give no boost: {b_score} vs {c_score}"
        );
    }

    #[test]
    fn test_cross_ref_no_relations_file() {
        let dir = tempfile::tempdir().unwrap();
        broca::remember(
            dir.path(),
            "fact",
            "Test entry",
            "rust programming",
            &[],
            None,
        )
        .unwrap();

        // No RELATIONS.md — should work fine without boost
        let results = recall(dir.path(), "rust", 5).unwrap();
        assert!(!results.is_empty());
    }

    #[test]
    fn test_cross_ref_elaborates_stronger_than_related() {
        let dir = tempfile::tempdir().unwrap();
        let knowledge_dir = dir.path().join("knowledge");
        fs::create_dir_all(&knowledge_dir).unwrap();

        let entry_a = "---\ntype: fact\ntitle: \"Core topic\"\nconfidence: 0.9\ncreated: 20260304-120000\n---\n\nrust programming language details";
        let entry_b = "---\ntype: fact\ntitle: \"Elaboration\"\nconfidence: 0.9\ncreated: 20260304-120001\n---\n\nsome rust details";
        let entry_c = "---\ntype: fact\ntitle: \"Related\"\nconfidence: 0.9\ncreated: 20260304-120002\n---\n\nsome rust details";

        fs::write(knowledge_dir.join("20260304-120000-core.md"), entry_a).unwrap();
        fs::write(
            knowledge_dir.join("20260304-120001-elaboration.md"),
            entry_b,
        )
        .unwrap();
        fs::write(knowledge_dir.join("20260304-120002-related.md"), entry_c).unwrap();

        // B elaborates_on A (weight=0.4), C is related_to A (weight=0.25)
        fs::write(
            dir.path().join("RELATIONS.md"),
            "20260304-120000-core.md --[elaborates_on]--> 20260304-120001-elaboration.md\n\
             20260304-120000-core.md --[related_to]--> 20260304-120002-related.md\n",
        )
        .unwrap();

        let results = recall(dir.path(), "rust", 5).unwrap();
        let b_score = results
            .iter()
            .find(|e| e.title == "Elaboration")
            .unwrap()
            .relevance_score;
        let c_score = results
            .iter()
            .find(|e| e.title == "Related")
            .unwrap()
            .relevance_score;

        assert!(
            b_score > c_score,
            "elaborates_on should boost more than related_to: {b_score} vs {c_score}"
        );
    }

    #[test]
    fn test_cross_ref_bidirectional() {
        let dir = tempfile::tempdir().unwrap();
        let knowledge_dir = dir.path().join("knowledge");
        fs::create_dir_all(&knowledge_dir).unwrap();

        // Both entries match the query equally well
        let entry_a = "---\ntype: fact\ntitle: \"Entry A\"\nconfidence: 0.9\ncreated: 20260304-120000\n---\n\nrust memory system";
        let entry_b = "---\ntype: fact\ntitle: \"Entry B\"\nconfidence: 0.9\ncreated: 20260304-120001\n---\n\nrust memory system";

        fs::write(knowledge_dir.join("20260304-120000-entry-a.md"), entry_a).unwrap();
        fs::write(knowledge_dir.join("20260304-120001-entry-b.md"), entry_b).unwrap();

        // A -> B relation (but should boost both directions)
        fs::write(
            dir.path().join("RELATIONS.md"),
            "20260304-120000-entry-a.md --[similar_to]--> 20260304-120001-entry-b.md\n",
        )
        .unwrap();

        let results = recall(dir.path(), "rust memory", 5).unwrap();
        let a_score = results
            .iter()
            .find(|e| e.title == "Entry A")
            .unwrap()
            .relevance_score;
        let b_score = results
            .iter()
            .find(|e| e.title == "Entry B")
            .unwrap()
            .relevance_score;

        // Both should be boosted (bidirectional), so scores should be higher than base
        // Since they have identical content and mutual relation, scores should be very close
        let ratio = a_score / b_score;
        assert!(
            ratio > 0.9 && ratio < 1.1,
            "Bidirectional boost should keep similar entries close: {a_score} vs {b_score}"
        );
    }
}
