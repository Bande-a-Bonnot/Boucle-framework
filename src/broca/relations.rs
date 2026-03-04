//! Cross-reference graph for Broca entries.
//!
//! Parses RELATIONS.md (format: `a.md --[type]--> b.md`) into a bidirectional
//! lookup table. Used by recall() to boost entries related to high-scoring results.

use std::collections::HashMap;
use std::fs;
use std::path::Path;

/// A single directed relationship between two entries.
#[derive(Debug, Clone, PartialEq)]
pub struct Relation {
    pub from: String,
    pub to: String,
    pub relation_type: String,
}

/// Bidirectional relation graph: filename -> [(related_filename, relation_type, direction)]
pub type RelationGraph = HashMap<String, Vec<(String, String)>>;

/// Parse RELATIONS.md into a bidirectional graph.
/// Each entry maps to all entries it's connected to (in either direction).
pub fn load_relations(memory_dir: &Path) -> RelationGraph {
    let relations_path = memory_dir.join("RELATIONS.md");
    let mut graph: RelationGraph = HashMap::new();

    let content = match fs::read_to_string(&relations_path) {
        Ok(c) => c,
        Err(_) => return graph, // No relations file = empty graph
    };

    for relation in parse_relations(&content) {
        // Forward direction
        graph
            .entry(relation.from.clone())
            .or_default()
            .push((relation.to.clone(), relation.relation_type.clone()));

        // Reverse direction (bidirectional lookup)
        graph
            .entry(relation.to.clone())
            .or_default()
            .push((relation.from.clone(), relation.relation_type.clone()));
    }

    graph
}

/// Parse relation lines from RELATIONS.md content.
/// Format: `filename.md --[relation_type]--> filename.md`
fn parse_relations(content: &str) -> Vec<Relation> {
    content
        .lines()
        .filter_map(|line| {
            let line = line.trim();
            // Match: `from.md --[type]--> to.md`
            let arrow_pos = line.find(" --[")?;
            let close_bracket = line.find("]--> ")?;

            if close_bracket <= arrow_pos {
                return None;
            }

            let from = line[..arrow_pos].trim().to_string();
            let relation_type = line[arrow_pos + 4..close_bracket].trim().to_string();
            let to = line[close_bracket + 5..].trim().to_string();

            if from.is_empty() || to.is_empty() || relation_type.is_empty() {
                return None;
            }

            Some(Relation {
                from,
                to,
                relation_type,
            })
        })
        .collect()
}

/// Weight for a relation type. Higher = stronger boost for related entries.
/// Returns 0.0 for relation types that should NOT boost (e.g., contradicts).
pub fn relation_weight(relation_type: &str) -> f64 {
    match relation_type {
        "elaborates_on" => 0.4,
        "similar_to" => 0.35,
        "related_to" => 0.25,
        "leads_to" => 0.2,
        "caused_by" => 0.2,
        "contradicts" => 0.0, // Contradicting entries should not be boosted
        _ => 0.15,            // Unknown types get a small boost
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn test_parse_empty() {
        let relations = parse_relations("");
        assert!(relations.is_empty());
    }

    #[test]
    fn test_parse_header_only() {
        let relations = parse_relations("# Broca Relations\n\n");
        assert!(relations.is_empty());
    }

    #[test]
    fn test_parse_single_relation() {
        let content = "entry-a.md --[related_to]--> entry-b.md\n";
        let relations = parse_relations(content);
        assert_eq!(relations.len(), 1);
        assert_eq!(relations[0].from, "entry-a.md");
        assert_eq!(relations[0].to, "entry-b.md");
        assert_eq!(relations[0].relation_type, "related_to");
    }

    #[test]
    fn test_parse_multiple_relations() {
        let content = "# Broca Relations\n\n\
                        a.md --[similar_to]--> b.md\n\
                        b.md --[elaborates_on]--> c.md\n\
                        d.md --[contradicts]--> a.md\n";
        let relations = parse_relations(content);
        assert_eq!(relations.len(), 3);
        assert_eq!(relations[0].relation_type, "similar_to");
        assert_eq!(relations[1].relation_type, "elaborates_on");
        assert_eq!(relations[2].relation_type, "contradicts");
    }

    #[test]
    fn test_parse_ignores_malformed() {
        let content = "not a relation line\n\
                        a.md --[related_to]--> b.md\n\
                        broken --> line\n";
        let relations = parse_relations(content);
        assert_eq!(relations.len(), 1);
    }

    #[test]
    fn test_load_bidirectional() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(
            dir.path().join("RELATIONS.md"),
            "# Broca Relations\n\na.md --[similar_to]--> b.md\n",
        )
        .unwrap();

        let graph = load_relations(dir.path());

        // a -> b
        let a_rels = graph.get("a.md").unwrap();
        assert_eq!(a_rels.len(), 1);
        assert_eq!(a_rels[0].0, "b.md");
        assert_eq!(a_rels[0].1, "similar_to");

        // b -> a (reverse)
        let b_rels = graph.get("b.md").unwrap();
        assert_eq!(b_rels.len(), 1);
        assert_eq!(b_rels[0].0, "a.md");
        assert_eq!(b_rels[0].1, "similar_to");
    }

    #[test]
    fn test_load_missing_file() {
        let dir = tempfile::tempdir().unwrap();
        let graph = load_relations(dir.path());
        assert!(graph.is_empty());
    }

    #[test]
    fn test_relation_weights() {
        assert!(relation_weight("elaborates_on") > relation_weight("related_to"));
        assert!(relation_weight("similar_to") > relation_weight("related_to"));
        assert_eq!(relation_weight("contradicts"), 0.0);
        assert!(relation_weight("unknown_type") > 0.0);
    }

    #[test]
    fn test_multi_hop_graph() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(
            dir.path().join("RELATIONS.md"),
            "a.md --[related_to]--> b.md\n\
             b.md --[elaborates_on]--> c.md\n\
             a.md --[leads_to]--> c.md\n",
        )
        .unwrap();

        let graph = load_relations(dir.path());

        // a connects to b and c
        let a_rels = graph.get("a.md").unwrap();
        assert_eq!(a_rels.len(), 2);

        // b connects to a (reverse) and c (forward)
        let b_rels = graph.get("b.md").unwrap();
        assert_eq!(b_rels.len(), 2);

        // c connects to b (reverse) and a (reverse)
        let c_rels = graph.get("c.md").unwrap();
        assert_eq!(c_rels.len(), 2);
    }
}
