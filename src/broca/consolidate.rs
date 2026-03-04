//! Memory consolidation — detect and merge overlapping entries.
//!
//! Finds entries with similar content (using Jaccard similarity on token sets)
//! and groups them into consolidation candidates. Merging creates a new entry
//! with the union of information and supersedes the originals.
//!
//! Dry-run by default. Use `--apply` to execute merges.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use super::entry::{self, Entry};
use super::search::tokenize;
use super::BrocaError;

/// Configuration for consolidation.
pub struct ConsolidateConfig {
    /// Minimum combined similarity to flag as candidates (0.0–1.0).
    pub similarity_threshold: f64,
}

impl Default for ConsolidateConfig {
    fn default() -> Self {
        ConsolidateConfig {
            similarity_threshold: 0.4,
        }
    }
}

/// A pair of entries flagged as similar.
#[derive(Debug)]
pub struct ConsolidationPair {
    pub entry_a: String,
    pub entry_b: String,
    pub title_a: String,
    pub title_b: String,
    pub similarity: f64,
    pub reason: String,
}

/// A group of entries that should be merged together.
#[derive(Debug)]
pub struct ConsolidationGroup {
    pub entries: Vec<String>,
    pub titles: Vec<String>,
    pub avg_similarity: f64,
}

/// Compute Jaccard similarity between two token sets.
fn jaccard(a: &HashSet<&str>, b: &HashSet<&str>) -> f64 {
    if a.is_empty() && b.is_empty() {
        return 0.0;
    }
    let intersection = a.intersection(b).count() as f64;
    let union = a.union(b).count() as f64;
    intersection / union
}

/// Find pairs of entries similar enough to consolidate.
pub fn find_candidates(
    memory_dir: &Path,
    config: &ConsolidateConfig,
) -> Result<Vec<ConsolidationPair>, BrocaError> {
    let knowledge_dir = memory_dir.join("knowledge");
    let entries = entry::load_all(&knowledge_dir)?;

    if entries.len() < 2 {
        return Ok(Vec::new());
    }

    // Pre-tokenize and build token sets.
    let tokenized: Vec<(Vec<String>, Vec<String>, Vec<String>)> = entries
        .iter()
        .map(|e| {
            let title_tokens = tokenize(&e.title);
            let content_tokens = tokenize(&e.content);
            let tag_tokens: Vec<String> = e.tags.iter().map(|t| t.to_lowercase()).collect();
            (title_tokens, content_tokens, tag_tokens)
        })
        .collect();

    let sets: Vec<(HashSet<&str>, HashSet<&str>, HashSet<&str>)> = tokenized
        .iter()
        .map(|(t, c, g)| {
            let ts: HashSet<&str> = t.iter().map(|s| s.as_str()).collect();
            let cs: HashSet<&str> = c.iter().map(|s| s.as_str()).collect();
            let gs: HashSet<&str> = g.iter().map(|s| s.as_str()).collect();
            (ts, cs, gs)
        })
        .collect();

    let mut candidates = Vec::new();

    for i in 0..entries.len() {
        for j in (i + 1)..entries.len() {
            // Only consolidate same-type entries.
            if entries[i].entry_type != entries[j].entry_type {
                continue;
            }
            // Skip already-superseded entries.
            if entries[i].superseded_by.is_some() || entries[j].superseded_by.is_some() {
                continue;
            }

            let title_sim = jaccard(&sets[i].0, &sets[j].0);
            let content_sim = jaccard(&sets[i].1, &sets[j].1);
            let tag_sim = jaccard(&sets[i].2, &sets[j].2);

            // Weighted combination: content 50%, title 35%, tags 15%.
            let combined = content_sim * 0.5 + title_sim * 0.35 + tag_sim * 0.15;

            if combined >= config.similarity_threshold {
                let reason = format!(
                    "content: {:.0}%, title: {:.0}%, tags: {:.0}%",
                    content_sim * 100.0,
                    title_sim * 100.0,
                    tag_sim * 100.0,
                );
                candidates.push(ConsolidationPair {
                    entry_a: entries[i].filename.clone(),
                    entry_b: entries[j].filename.clone(),
                    title_a: entries[i].title.clone(),
                    title_b: entries[j].title.clone(),
                    similarity: combined,
                    reason,
                });
            }
        }
    }

    candidates.sort_by(|a, b| {
        b.similarity
            .partial_cmp(&a.similarity)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    Ok(candidates)
}

/// Group overlapping pairs into merge clusters using union-find.
pub fn group_candidates(pairs: &[ConsolidationPair]) -> Vec<ConsolidationGroup> {
    if pairs.is_empty() {
        return Vec::new();
    }

    let mut parent: HashMap<&str, &str> = HashMap::new();
    let mut titles: HashMap<&str, &str> = HashMap::new();

    // Collect all unique entry names first.
    for pair in pairs {
        parent
            .entry(pair.entry_a.as_str())
            .or_insert(pair.entry_a.as_str());
        parent
            .entry(pair.entry_b.as_str())
            .or_insert(pair.entry_b.as_str());
        titles
            .entry(pair.entry_a.as_str())
            .or_insert(pair.title_a.as_str());
        titles
            .entry(pair.entry_b.as_str())
            .or_insert(pair.title_b.as_str());
    }

    // Find with path compression (iterative to avoid borrow issues).
    fn find_root<'a>(parent: &HashMap<&'a str, &'a str>, x: &'a str) -> &'a str {
        let mut current = x;
        while parent.get(current).copied().unwrap_or(current) != current {
            current = parent.get(current).copied().unwrap_or(current);
        }
        current
    }

    // Union all pairs.
    for pair in pairs {
        let ra = find_root(&parent, pair.entry_a.as_str());
        let rb = find_root(&parent, pair.entry_b.as_str());
        if ra != rb {
            // Point rb's root to ra.
            parent.insert(rb, ra);
        }
    }

    // Group by root.
    let mut groups: HashMap<&str, Vec<&str>> = HashMap::new();
    for &entry_name in parent.keys() {
        let root = find_root(&parent, entry_name);
        groups.entry(root).or_default().push(entry_name);
    }

    let mut result: Vec<ConsolidationGroup> = groups
        .into_values()
        .filter(|g| g.len() > 1)
        .map(|mut members| {
            members.sort();
            let member_titles: Vec<String> = members
                .iter()
                .map(|m| titles.get(m).unwrap_or(&"").to_string())
                .collect();

            // Average similarity among pairs in this group.
            let group_pairs: Vec<&ConsolidationPair> = pairs
                .iter()
                .filter(|p| {
                    members.contains(&p.entry_a.as_str()) && members.contains(&p.entry_b.as_str())
                })
                .collect();
            let avg_sim = if group_pairs.is_empty() {
                0.0
            } else {
                group_pairs.iter().map(|p| p.similarity).sum::<f64>() / group_pairs.len() as f64
            };

            ConsolidationGroup {
                entries: members.into_iter().map(|s| s.to_string()).collect(),
                titles: member_titles,
                avg_similarity: avg_sim,
            }
        })
        .collect();

    result.sort_by(|a, b| {
        b.avg_similarity
            .partial_cmp(&a.avg_similarity)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    result
}

/// Merge a group of entries into one consolidated entry.
///
/// Creates a new entry with:
/// - Type and title from the newest entry
/// - Union of all tags
/// - Highest confidence from the group
/// - Merged content (newest first, then older versions)
///
/// Old entries are superseded, pointing to the new one.
pub fn merge(memory_dir: &Path, filenames: &[String]) -> Result<PathBuf, BrocaError> {
    if filenames.len() < 2 {
        return Err(BrocaError::Parse(
            "Need at least 2 entries to merge".to_string(),
        ));
    }

    let knowledge_dir = memory_dir.join("knowledge");

    // Load all entries.
    let mut entries: Vec<Entry> = Vec::new();
    for fname in filenames {
        let path = knowledge_dir.join(fname);
        if !path.exists() {
            return Err(BrocaError::Parse(format!("Entry not found: {fname}")));
        }
        entries.push(Entry::from_file(&path)?);
    }

    // Sort by filename (timestamp) so newest is last.
    entries.sort_by(|a, b| a.filename.cmp(&b.filename));

    let newest = entries.last().unwrap();

    // Union of tags.
    let mut all_tags: HashSet<String> = HashSet::new();
    for e in &entries {
        for t in &e.tags {
            all_tags.insert(t.clone());
        }
    }
    let tags: Vec<String> = {
        let mut v: Vec<_> = all_tags.into_iter().collect();
        v.sort();
        v
    };

    // Highest confidence.
    let max_confidence = entries.iter().map(|e| e.confidence).fold(0.0f64, f64::max);

    // Merge content: newest on top, older entries below a separator.
    let mut merged_content = newest.content.clone();
    let older: Vec<&Entry> = entries.iter().rev().skip(1).collect();
    if !older.is_empty() {
        merged_content.push_str("\n\n---\n*Consolidated from earlier entries:*\n");
        for e in older {
            merged_content.push_str(&format!(
                "\n**{}** ({}): {}\n",
                e.title, e.created, e.content
            ));
        }
    }

    // Create the new consolidated entry.
    let new_path = super::remember(
        memory_dir,
        &newest.entry_type.to_string(),
        &format!("{} (consolidated)", newest.title),
        &merged_content,
        &tags,
    )?;

    let new_fname = new_path
        .file_name()
        .and_then(|f| f.to_str())
        .unwrap_or("")
        .to_string();

    // Set max confidence on the new entry if different from default.
    if (max_confidence - 0.8).abs() > f64::EPSILON {
        super::update_confidence(memory_dir, &new_fname, max_confidence)?;
    }

    // Supersede old entries.
    for e in &entries {
        super::supersede(memory_dir, &e.filename, &new_fname)?;
    }

    Ok(new_path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::broca;
    use std::fs;

    #[test]
    fn test_jaccard_identical() {
        let a: HashSet<&str> = ["rust", "memory", "agent"].into();
        let b: HashSet<&str> = ["rust", "memory", "agent"].into();
        assert!((jaccard(&a, &b) - 1.0).abs() < f64::EPSILON);
    }

    #[test]
    fn test_jaccard_disjoint() {
        let a: HashSet<&str> = ["rust", "memory"].into();
        let b: HashSet<&str> = ["python", "flask"].into();
        assert!((jaccard(&a, &b) - 0.0).abs() < f64::EPSILON);
    }

    #[test]
    fn test_jaccard_partial() {
        let a: HashSet<&str> = ["rust", "memory", "agent"].into();
        let b: HashSet<&str> = ["rust", "memory", "python"].into();
        // intersection=2, union=4 → 0.5
        assert!((jaccard(&a, &b) - 0.5).abs() < f64::EPSILON);
    }

    #[test]
    fn test_jaccard_empty() {
        let a: HashSet<&str> = HashSet::new();
        let b: HashSet<&str> = HashSet::new();
        assert!((jaccard(&a, &b) - 0.0).abs() < f64::EPSILON);
    }

    #[test]
    fn test_find_candidates_identical_entries() {
        let dir = tempfile::tempdir().unwrap();
        let knowledge_dir = dir.path().join("knowledge");
        fs::create_dir_all(&knowledge_dir).unwrap();

        // Create two identical entries with different timestamps to avoid filename collision.
        let e1 = "---\ntype: fact\ntitle: \"Rust is fast\"\nconfidence: 0.8\ncreated: 20260304-120000\ntags: [rust, performance]\n---\n\nRust is a systems programming language known for speed and safety.";
        let e2 = "---\ntype: fact\ntitle: \"Rust is fast\"\nconfidence: 0.8\ncreated: 20260304-120001\ntags: [rust, performance]\n---\n\nRust is a systems programming language known for speed and safety.";
        fs::write(knowledge_dir.join("20260304-120000-rust-is-fast.md"), e1).unwrap();
        fs::write(knowledge_dir.join("20260304-120001-rust-is-fast-2.md"), e2).unwrap();

        let config = ConsolidateConfig::default();
        let candidates = find_candidates(dir.path(), &config).unwrap();
        assert_eq!(candidates.len(), 1);
        assert!(candidates[0].similarity > 0.9);
    }

    #[test]
    fn test_find_candidates_different_entries() {
        let dir = tempfile::tempdir().unwrap();
        broca::remember(
            dir.path(),
            "fact",
            "Rust is fast",
            "Rust is a systems programming language known for speed.",
            &["rust".to_string()],
        )
        .unwrap();
        broca::remember(
            dir.path(),
            "fact",
            "Python web frameworks",
            "Django and Flask are popular Python web frameworks.",
            &["python".to_string()],
        )
        .unwrap();

        let config = ConsolidateConfig::default();
        let candidates = find_candidates(dir.path(), &config).unwrap();
        assert!(candidates.is_empty());
    }

    #[test]
    fn test_find_candidates_different_types_skipped() {
        let dir = tempfile::tempdir().unwrap();
        broca::remember(
            dir.path(),
            "fact",
            "Rust is fast",
            "Rust is a systems programming language known for speed and safety.",
            &["rust".to_string()],
        )
        .unwrap();
        // Same content but different type — should NOT be flagged.
        broca::remember(
            dir.path(),
            "decision",
            "Rust is fast",
            "Rust is a systems programming language known for speed and safety.",
            &["rust".to_string()],
        )
        .unwrap();

        let config = ConsolidateConfig::default();
        let candidates = find_candidates(dir.path(), &config).unwrap();
        assert!(candidates.is_empty());
    }

    #[test]
    fn test_find_candidates_superseded_skipped() {
        let dir = tempfile::tempdir().unwrap();
        broca::remember(
            dir.path(),
            "fact",
            "Old version",
            "Rust is a systems programming language known for speed.",
            &["rust".to_string()],
        )
        .unwrap();
        broca::remember(
            dir.path(),
            "fact",
            "New version",
            "Rust is a systems programming language known for speed.",
            &["rust".to_string()],
        )
        .unwrap();

        // Supersede old → should be excluded from candidates.
        broca::supersede(dir.path(), "old-version", "new-version").unwrap();

        let config = ConsolidateConfig::default();
        let candidates = find_candidates(dir.path(), &config).unwrap();
        assert!(candidates.is_empty());
    }

    #[test]
    fn test_find_candidates_threshold() {
        let dir = tempfile::tempdir().unwrap();
        broca::remember(
            dir.path(),
            "fact",
            "Rust memory system",
            "The Broca memory system uses files for storage.",
            &["rust".to_string(), "memory".to_string()],
        )
        .unwrap();
        broca::remember(
            dir.path(),
            "fact",
            "Rust memory design",
            "The Broca memory system stores entries as markdown files.",
            &["rust".to_string(), "memory".to_string()],
        )
        .unwrap();

        // High threshold — should find nothing.
        let strict = ConsolidateConfig {
            similarity_threshold: 0.99,
        };
        assert!(find_candidates(dir.path(), &strict).unwrap().is_empty());

        // Lower threshold — should find the pair.
        let loose = ConsolidateConfig {
            similarity_threshold: 0.2,
        };
        assert!(!find_candidates(dir.path(), &loose).unwrap().is_empty());
    }

    #[test]
    fn test_find_candidates_single_entry() {
        let dir = tempfile::tempdir().unwrap();
        broca::remember(dir.path(), "fact", "Only one", "Single entry.", &[]).unwrap();

        let config = ConsolidateConfig::default();
        let candidates = find_candidates(dir.path(), &config).unwrap();
        assert!(candidates.is_empty());
    }

    #[test]
    fn test_group_candidates_single_pair() {
        let pairs = vec![ConsolidationPair {
            entry_a: "a.md".to_string(),
            entry_b: "b.md".to_string(),
            title_a: "Entry A".to_string(),
            title_b: "Entry B".to_string(),
            similarity: 0.8,
            reason: "test".to_string(),
        }];

        let groups = group_candidates(&pairs);
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].entries.len(), 2);
    }

    #[test]
    fn test_group_candidates_transitive() {
        // A~B and B~C should produce one group {A, B, C}.
        let pairs = vec![
            ConsolidationPair {
                entry_a: "a.md".to_string(),
                entry_b: "b.md".to_string(),
                title_a: "A".to_string(),
                title_b: "B".to_string(),
                similarity: 0.7,
                reason: "test".to_string(),
            },
            ConsolidationPair {
                entry_a: "b.md".to_string(),
                entry_b: "c.md".to_string(),
                title_a: "B".to_string(),
                title_b: "C".to_string(),
                similarity: 0.6,
                reason: "test".to_string(),
            },
        ];

        let groups = group_candidates(&pairs);
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].entries.len(), 3);
    }

    #[test]
    fn test_group_candidates_disjoint() {
        // A~B and C~D should produce two groups.
        let pairs = vec![
            ConsolidationPair {
                entry_a: "a.md".to_string(),
                entry_b: "b.md".to_string(),
                title_a: "A".to_string(),
                title_b: "B".to_string(),
                similarity: 0.8,
                reason: "test".to_string(),
            },
            ConsolidationPair {
                entry_a: "c.md".to_string(),
                entry_b: "d.md".to_string(),
                title_a: "C".to_string(),
                title_b: "D".to_string(),
                similarity: 0.7,
                reason: "test".to_string(),
            },
        ];

        let groups = group_candidates(&pairs);
        assert_eq!(groups.len(), 2);
    }

    #[test]
    fn test_group_candidates_empty() {
        let groups = group_candidates(&[]);
        assert!(groups.is_empty());
    }

    #[test]
    fn test_merge_creates_consolidated_entry() {
        let dir = tempfile::tempdir().unwrap();
        let p1 = broca::remember(
            dir.path(),
            "fact",
            "Rust speed",
            "Rust is known for speed.",
            &["rust".to_string()],
        )
        .unwrap();
        // Small delay to ensure different timestamps.
        std::thread::sleep(std::time::Duration::from_millis(10));
        let p2 = broca::remember(
            dir.path(),
            "fact",
            "Rust performance",
            "Rust compiles to native code for high performance.",
            &["performance".to_string()],
        )
        .unwrap();

        let f1 = p1.file_name().unwrap().to_str().unwrap().to_string();
        let f2 = p2.file_name().unwrap().to_str().unwrap().to_string();

        let new_path = merge(dir.path(), &[f1.clone(), f2.clone()]).unwrap();
        assert!(new_path.exists());

        // New entry should exist and contain "(consolidated)".
        let new_entry = Entry::from_file(&new_path).unwrap();
        assert!(new_entry.title.contains("consolidated"));

        // Should have union of tags.
        assert!(new_entry.tags.contains(&"rust".to_string()));
        assert!(new_entry.tags.contains(&"performance".to_string()));

        // Content should contain both originals' text.
        let content = fs::read_to_string(&new_path).unwrap();
        assert!(content.contains("native code"));
        assert!(content.contains("known for speed"));

        // Old entries should be superseded.
        let knowledge_dir = dir.path().join("knowledge");
        let old1 = Entry::from_file(&knowledge_dir.join(&f1)).unwrap();
        assert!(old1.superseded_by.is_some());
        assert_eq!(old1.confidence, 0.3);

        let old2 = Entry::from_file(&knowledge_dir.join(&f2)).unwrap();
        assert!(old2.superseded_by.is_some());
        assert_eq!(old2.confidence, 0.3);
    }

    #[test]
    fn test_merge_preserves_highest_confidence() {
        let dir = tempfile::tempdir().unwrap();
        let knowledge_dir = dir.path().join("knowledge");
        fs::create_dir_all(&knowledge_dir).unwrap();

        let e1 = "---\ntype: fact\ntitle: \"Entry A\"\nconfidence: 0.95\ncreated: 20260304-120000\ntags: [rust]\n---\n\nHigh confidence content.";
        let e2 = "---\ntype: fact\ntitle: \"Entry B\"\nconfidence: 0.6\ncreated: 20260304-120001\ntags: [memory]\n---\n\nLow confidence content.";
        fs::write(knowledge_dir.join("20260304-120000-entry-a.md"), e1).unwrap();
        fs::write(knowledge_dir.join("20260304-120001-entry-b.md"), e2).unwrap();

        let new_path = merge(
            dir.path(),
            &[
                "20260304-120000-entry-a.md".to_string(),
                "20260304-120001-entry-b.md".to_string(),
            ],
        )
        .unwrap();

        let new_entry = Entry::from_file(&new_path).unwrap();
        assert!(
            (new_entry.confidence - 0.95).abs() < 0.05,
            "Should preserve highest confidence: {}",
            new_entry.confidence
        );
    }

    #[test]
    fn test_merge_needs_at_least_two() {
        let dir = tempfile::tempdir().unwrap();
        let p = broca::remember(dir.path(), "fact", "Only one", "Content.", &[]).unwrap();
        let f = p.file_name().unwrap().to_str().unwrap().to_string();

        let result = merge(dir.path(), &[f]);
        assert!(result.is_err());
    }

    #[test]
    fn test_merge_missing_entry() {
        let dir = tempfile::tempdir().unwrap();
        fs::create_dir_all(dir.path().join("knowledge")).unwrap();

        let result = merge(
            dir.path(),
            &[
                "nonexistent-a.md".to_string(),
                "nonexistent-b.md".to_string(),
            ],
        );
        assert!(result.is_err());
    }

    #[test]
    fn test_end_to_end_find_and_merge() {
        let dir = tempfile::tempdir().unwrap();

        // Create three similar entries.
        broca::remember(
            dir.path(),
            "fact",
            "Rust memory system",
            "The Broca memory system uses markdown files for persistent storage.",
            &[
                "rust".to_string(),
                "memory".to_string(),
                "broca".to_string(),
            ],
        )
        .unwrap();
        std::thread::sleep(std::time::Duration::from_millis(10));
        broca::remember(
            dir.path(),
            "fact",
            "Rust memory design",
            "The Broca memory system stores entries as markdown files persistently.",
            &["rust".to_string(), "memory".to_string()],
        )
        .unwrap();
        std::thread::sleep(std::time::Duration::from_millis(10));
        broca::remember(
            dir.path(),
            "fact",
            "Memory storage approach",
            "Broca uses the filesystem with markdown files for memory storage.",
            &["memory".to_string(), "broca".to_string()],
        )
        .unwrap();

        // Should find at least one pair.
        let config = ConsolidateConfig {
            similarity_threshold: 0.25,
        };
        let candidates = find_candidates(dir.path(), &config).unwrap();
        assert!(
            !candidates.is_empty(),
            "Should find similar entries among three near-duplicates"
        );

        // Group them.
        let groups = group_candidates(&candidates);
        assert!(!groups.is_empty());

        // Merge the first group.
        let group = &groups[0];
        let new_path = merge(dir.path(), &group.entries).unwrap();
        assert!(new_path.exists());

        // After merge, running find_candidates again should find fewer candidates
        // (merged entries are superseded).
        let after = find_candidates(dir.path(), &config).unwrap();
        assert!(
            after.len() < candidates.len(),
            "After merge, fewer candidates: {} vs {}",
            after.len(),
            candidates.len()
        );
    }
}
