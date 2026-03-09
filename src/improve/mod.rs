//! Self-observation engine for autonomous agents.
//!
//! Pipeline: HARVEST → CLASSIFY → SCORE → PROMOTE
//!
//! Signals are friction/failure/waste/surprise events logged by the agent or
//! harvested automatically from logs. Patterns emerge when the same fingerprint
//! recurs. Responses are strategies the agent deploys to address patterns.
//! The scoreboard tracks whether responses actually reduce signal rates.
//!
//! Data lives in `improve/` under the agent root:
//! - `signals.jsonl`  — append-only signal log
//! - `patterns.json`  — fingerprint → count, status, response
//! - `scoreboard.json` — response → effectiveness tracking
//! - `pending.json`    — top unaddressed pattern for the agent to act on
//! - `harvesters/`     — executable scripts that auto-detect signals

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Instant;

// ── Data types ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Signal {
    pub ts: String,
    #[serde(default)]
    pub loop_num: u64,
    #[serde(rename = "type")]
    pub signal_type: String,
    #[serde(default = "default_source")]
    pub source: String,
    pub summary: String,
    pub fingerprint: String,
}

fn default_source() -> String {
    "manual".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Pattern {
    pub count: u64,
    pub first_seen: String,
    pub last_seen: String,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub response_id: Option<String>,
    #[serde(default)]
    pub summary: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScoreEntry {
    pub response_id: String,
    pub pattern: String,
    pub deployed_at: String,
    #[serde(default)]
    pub signals_before: u64,
    #[serde(default)]
    pub signals_after: u64,
    #[serde(default)]
    pub effective: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PendingResponse {
    pub pattern: String,
    pub fingerprint: String,
    pub count: u64,
    pub summary: String,
    pub suggested_action: String,
}

// ── File paths ──────────────────────────────────────────────────────────────

fn improve_dir(root: &Path) -> PathBuf {
    root.join("improve")
}

fn signals_path(root: &Path) -> PathBuf {
    improve_dir(root).join("signals.jsonl")
}

fn patterns_path(root: &Path) -> PathBuf {
    improve_dir(root).join("patterns.json")
}

fn scoreboard_path(root: &Path) -> PathBuf {
    improve_dir(root).join("scoreboard.json")
}

fn pending_path(root: &Path) -> PathBuf {
    improve_dir(root).join("pending.json")
}

fn harvesters_dir(root: &Path) -> PathBuf {
    improve_dir(root).join("harvesters")
}

// ── I/O helpers ─────────────────────────────────────────────────────────────

fn read_signals(root: &Path) -> Vec<Signal> {
    let path = signals_path(root);
    if !path.exists() {
        return Vec::new();
    }
    let file = match fs::File::open(&path) {
        Ok(f) => f,
        Err(_) => return Vec::new(),
    };
    let reader = std::io::BufReader::new(file);
    reader
        .lines()
        .filter_map(|line| {
            let line = line.ok()?;
            let trimmed = line.trim();
            if trimmed.is_empty() {
                return None;
            }
            serde_json::from_str(trimmed).ok()
        })
        .collect()
}

fn append_signal(root: &Path, signal: &Signal) -> Result<(), String> {
    let path = signals_path(root);
    fs::create_dir_all(improve_dir(root)).map_err(|e| format!("create improve/: {e}"))?;
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .map_err(|e| format!("open signals.jsonl: {e}"))?;
    let json = serde_json::to_string(signal).map_err(|e| format!("serialize signal: {e}"))?;
    writeln!(file, "{json}").map_err(|e| format!("write signal: {e}"))?;
    Ok(())
}

fn load_patterns(root: &Path) -> HashMap<String, Pattern> {
    let path = patterns_path(root);
    if !path.exists() {
        return HashMap::new();
    }
    fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn save_patterns(root: &Path, patterns: &HashMap<String, Pattern>) -> Result<(), String> {
    let path = patterns_path(root);
    let json =
        serde_json::to_string_pretty(patterns).map_err(|e| format!("serialize patterns: {e}"))?;
    fs::write(&path, json).map_err(|e| format!("write patterns.json: {e}"))?;
    Ok(())
}

fn load_scoreboard(root: &Path) -> Vec<ScoreEntry> {
    let path = scoreboard_path(root);
    if !path.exists() {
        return Vec::new();
    }
    fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn save_scoreboard(root: &Path, scores: &[ScoreEntry]) -> Result<(), String> {
    let path = scoreboard_path(root);
    let json =
        serde_json::to_string_pretty(scores).map_err(|e| format!("serialize scoreboard: {e}"))?;
    fs::write(&path, json).map_err(|e| format!("write scoreboard.json: {e}"))?;
    Ok(())
}

fn now_iso() -> String {
    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

// ── PHASE 1: HARVEST ───────────────────────────────────────────────────────

/// Run all harvester scripts in `improve/harvesters/` and collect signals.
fn harvest(root: &Path, budget_secs: u64) -> Vec<Signal> {
    let dir = harvesters_dir(root);
    if !dir.exists() {
        return Vec::new();
    }

    let mut signals = Vec::new();
    let start = Instant::now();

    let entries: Vec<_> = match fs::read_dir(&dir) {
        Ok(e) => e.filter_map(|e| e.ok()).collect(),
        Err(_) => return signals,
    };

    for entry in entries {
        if start.elapsed().as_secs() > budget_secs {
            break;
        }

        let path = entry.path();
        if !path.is_file() {
            continue;
        }

        // Skip non-executable or hidden files
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
        if name.starts_with('.') || name.starts_with('_') {
            continue;
        }

        let output = Command::new(&path).arg(root).output();

        if let Ok(output) = output {
            if output.status.success() {
                let stdout = String::from_utf8_lossy(&output.stdout);
                for line in stdout.lines() {
                    let trimmed = line.trim();
                    if trimmed.is_empty() {
                        continue;
                    }
                    if let Ok(sig) = serde_json::from_str::<Signal>(trimmed) {
                        signals.push(sig);
                    }
                }
            }
        }
    }

    signals
}

// ── PHASE 2: CLASSIFY ──────────────────────────────────────────────────────

/// Update pattern counts from new signals.
fn classify(patterns: &mut HashMap<String, Pattern>, signals: &[Signal]) {
    for sig in signals {
        let fp = &sig.fingerprint;
        if fp.is_empty() {
            continue;
        }

        let entry = patterns.entry(fp.clone()).or_insert_with(|| Pattern {
            count: 0,
            first_seen: sig.ts.clone(),
            last_seen: sig.ts.clone(),
            status: "open".to_string(),
            response_id: None,
            summary: sig.summary.clone(),
        });

        entry.count += 1;
        entry.last_seen = sig.ts.clone();
        if entry.summary.is_empty() {
            entry.summary = sig.summary.clone();
        }
    }
}

// ── PHASE 3: SCORE ─────────────────────────────────────────────────────────

/// Evaluate whether deployed responses are reducing their target signal rates.
fn score(patterns: &HashMap<String, Pattern>, scores: &mut [ScoreEntry], all_signals: &[Signal]) {
    for entry in scores.iter_mut() {
        if entry.effective.is_some() {
            continue; // already scored
        }

        // Count signals for this pattern after deployment
        let after_count = all_signals
            .iter()
            .filter(|s| s.fingerprint == entry.pattern && s.ts > entry.deployed_at)
            .count() as u64;

        entry.signals_after = after_count;

        // Need at least some time to evaluate (5+ signals total for the pattern)
        if let Some(pattern) = patterns.get(&entry.pattern) {
            if pattern.count >= 5 {
                entry.effective = Some(after_count < entry.signals_before);
            }
        }
    }
}

// ── PHASE 4: PROMOTE ───────────────────────────────────────────────────────

/// Find the top unaddressed pattern and write it to pending.json.
fn promote(root: &Path, patterns: &HashMap<String, Pattern>) -> Result<Option<String>, String> {
    // Find patterns that are open (no response) and have count >= 3
    let mut candidates: Vec<_> = patterns
        .iter()
        .filter(|(_, p)| p.status == "open" && p.response_id.is_none() && p.count >= 3)
        .collect();

    // Sort by count descending
    candidates.sort_by(|a, b| b.1.count.cmp(&a.1.count));

    let pending = pending_path(root);

    if let Some((fingerprint, pattern)) = candidates.first() {
        let response = PendingResponse {
            pattern: fingerprint.to_string(),
            fingerprint: fingerprint.to_string(),
            count: pattern.count,
            summary: pattern.summary.clone(),
            suggested_action: format!(
                "Pattern '{}' occurred {} times. Consider building a response.",
                fingerprint, pattern.count
            ),
        };
        let json = serde_json::to_string_pretty(&response)
            .map_err(|e| format!("serialize pending: {e}"))?;
        fs::write(&pending, json).map_err(|e| format!("write pending.json: {e}"))?;
        Ok(Some(fingerprint.to_string()))
    } else {
        // No candidates: remove pending if it exists
        if pending.exists() {
            let _ = fs::remove_file(&pending);
        }
        Ok(None)
    }
}

// ── Public API ──────────────────────────────────────────────────────────────

/// Log a signal manually.
pub fn log_signal(
    root: &Path,
    signal_type: &str,
    summary: &str,
    fingerprint: &str,
) -> Result<(), String> {
    let valid_types = ["friction", "failure", "waste", "surprise"];
    if !valid_types.contains(&signal_type) {
        return Err(format!(
            "Invalid signal type '{}'. Use: {}",
            signal_type,
            valid_types.join(", ")
        ));
    }

    let signal = Signal {
        ts: now_iso(),
        loop_num: 0,
        signal_type: signal_type.to_string(),
        source: "manual".to_string(),
        summary: summary.to_string(),
        fingerprint: fingerprint.to_string(),
    };

    append_signal(root, &signal)?;
    println!("Signal logged: [{}] {}", signal_type, fingerprint);
    Ok(())
}

/// Run the full improvement pipeline.
pub fn run_pipeline(root: &Path, budget_secs: u64) -> Result<(), String> {
    let start = Instant::now();
    let improve = improve_dir(root);
    if !improve.exists() {
        fs::create_dir_all(&improve).map_err(|e| format!("create improve/: {e}"))?;
    }

    // Phase 1: Harvest
    let harvested = harvest(root, budget_secs / 3);
    let harvest_count = harvested.len();
    for sig in &harvested {
        append_signal(root, sig)?;
    }

    // Phase 2: Classify
    let mut patterns = load_patterns(root);
    let all_signals = read_signals(root);
    classify(&mut patterns, &all_signals);
    save_patterns(root, &patterns)?;

    // Phase 3: Score
    let mut scores = load_scoreboard(root);
    score(&patterns, &mut scores, &all_signals);
    save_scoreboard(root, &scores)?;

    // Phase 4: Promote
    let promoted = promote(root, &patterns)?;

    let elapsed = start.elapsed();
    println!(
        "[improve] {:.1}s, {} signals harvested, {} patterns, {} responses tracked",
        elapsed.as_secs_f64(),
        harvest_count,
        patterns.len(),
        scores.len(),
    );
    if let Some(fp) = promoted {
        println!("[improve] Pending: {fp}");
    } else {
        println!("[improve] No patterns above threshold");
    }

    Ok(())
}

/// Show current improvement status.
pub fn show_status(root: &Path) -> Result<(), String> {
    let patterns = load_patterns(root);
    let scores = load_scoreboard(root);
    let signals = read_signals(root);

    println!("Improvement Engine Status");
    println!("=========================");
    println!("Total signals:  {}", signals.len());
    println!("Patterns:       {}", patterns.len());
    println!("Responses:      {}", scores.len());
    println!();

    if !patterns.is_empty() {
        println!("Top patterns (by count):");
        let mut sorted: Vec<_> = patterns.iter().collect();
        sorted.sort_by(|a, b| b.1.count.cmp(&a.1.count));
        for (fp, pat) in sorted.iter().take(10) {
            let status = if pat.response_id.is_some() {
                "addressed"
            } else {
                "open"
            };
            println!(
                "  {:4} x  {:<30}  [{}]  last: {}",
                pat.count,
                truncate(fp, 30),
                status,
                &pat.last_seen[..10.min(pat.last_seen.len())]
            );
        }
        println!();
    }

    if !scores.is_empty() {
        println!("Response effectiveness:");
        for entry in &scores {
            let status = match entry.effective {
                Some(true) => "effective",
                Some(false) => "ineffective",
                None => "evaluating",
            };
            println!(
                "  {:<30}  {} (before: {}, after: {})",
                truncate(&entry.response_id, 30),
                status,
                entry.signals_before,
                entry.signals_after
            );
        }
        println!();
    }

    let pending = pending_path(root);
    if pending.exists() {
        if let Ok(content) = fs::read_to_string(&pending) {
            if let Ok(p) = serde_json::from_str::<PendingResponse>(&content) {
                println!("Pending action: {} ({}x)", p.fingerprint, p.count);
                println!("  {}", p.suggested_action);
            }
        }
    }

    Ok(())
}

/// Initialize the improve directory with example harvester.
pub fn init(root: &Path) -> Result<(), String> {
    let dir = improve_dir(root);
    fs::create_dir_all(&dir).map_err(|e| format!("create improve/: {e}"))?;
    fs::create_dir_all(harvesters_dir(root))
        .map_err(|e| format!("create improve/harvesters/: {e}"))?;

    // Create example harvester
    let example = harvesters_dir(root).join("check-stderr");
    if !example.exists() {
        let script = r#"#!/bin/sh
# Example harvester: detect errors in recent logs.
# Receives agent root as $1. Output JSONL signals to stdout.
ROOT="$1"
LOG_DIR="$ROOT/logs"
[ -d "$LOG_DIR" ] || exit 0

# Check for recent stderr output
for f in "$LOG_DIR"/*.md; do
    [ -f "$f" ] || continue
    if grep -qi "error\|failed\|panic" "$f" 2>/dev/null; then
        DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        FNAME=$(basename "$f")
        printf '{"ts":"%s","type":"failure","source":"harvester","summary":"Errors in %s","fingerprint":"stderr-errors"}\n' "$DATE" "$FNAME"
    fi
done
"#;
        fs::write(&example, script).map_err(|e| format!("write example harvester: {e}"))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let perms = std::fs::Permissions::from_mode(0o755);
            fs::set_permissions(&example, perms).map_err(|e| format!("chmod harvester: {e}"))?;
        }
    }

    println!("Initialized improve/ with example harvester.");
    println!("  improve/signals.jsonl   — signal log (append-only)");
    println!("  improve/patterns.json   — recurring pattern tracker");
    println!("  improve/scoreboard.json — response effectiveness");
    println!("  improve/harvesters/     — auto-detection scripts");
    println!();
    println!("Log signals:  boucle signal friction 'auth keeps failing' auth-flaky");
    println!("Run engine:   boucle improve run");
    println!("Check status: boucle improve status");
    Ok(())
}

fn truncate(s: &str, max: usize) -> String {
    if s.len() <= max {
        s.to_string()
    } else {
        format!("{}...", &s[..max - 3])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn setup() -> TempDir {
        let tmp = TempDir::new().unwrap();
        fs::create_dir_all(tmp.path().join("improve")).unwrap();
        tmp
    }

    #[test]
    fn test_log_signal_valid_types() {
        let tmp = setup();
        assert!(log_signal(tmp.path(), "friction", "test", "test-fp").is_ok());
        assert!(log_signal(tmp.path(), "failure", "test", "test-fp").is_ok());
        assert!(log_signal(tmp.path(), "waste", "test", "test-fp").is_ok());
        assert!(log_signal(tmp.path(), "surprise", "test", "test-fp").is_ok());
    }

    #[test]
    fn test_log_signal_invalid_type() {
        let tmp = setup();
        assert!(log_signal(tmp.path(), "invalid", "test", "test-fp").is_err());
    }

    #[test]
    fn test_signal_persists_to_jsonl() {
        let tmp = setup();
        log_signal(tmp.path(), "friction", "slow build", "slow-build").unwrap();
        let signals = read_signals(tmp.path());
        assert_eq!(signals.len(), 1);
        assert_eq!(signals[0].fingerprint, "slow-build");
        assert_eq!(signals[0].signal_type, "friction");
        assert_eq!(signals[0].summary, "slow build");
    }

    #[test]
    fn test_multiple_signals_append() {
        let tmp = setup();
        log_signal(tmp.path(), "friction", "a", "fp-a").unwrap();
        log_signal(tmp.path(), "failure", "b", "fp-b").unwrap();
        log_signal(tmp.path(), "friction", "c", "fp-a").unwrap();
        let signals = read_signals(tmp.path());
        assert_eq!(signals.len(), 3);
    }

    #[test]
    fn test_classify_creates_patterns() {
        let signals = vec![
            Signal {
                ts: "2026-01-01T00:00:00Z".to_string(),
                loop_num: 1,
                signal_type: "friction".to_string(),
                source: "manual".to_string(),
                summary: "slow".to_string(),
                fingerprint: "slow-build".to_string(),
            },
            Signal {
                ts: "2026-01-01T01:00:00Z".to_string(),
                loop_num: 2,
                signal_type: "friction".to_string(),
                source: "manual".to_string(),
                summary: "slow again".to_string(),
                fingerprint: "slow-build".to_string(),
            },
        ];
        let mut patterns = HashMap::new();
        classify(&mut patterns, &signals);
        assert_eq!(patterns.len(), 1);
        assert_eq!(patterns["slow-build"].count, 2);
        assert_eq!(patterns["slow-build"].first_seen, "2026-01-01T00:00:00Z");
        assert_eq!(patterns["slow-build"].last_seen, "2026-01-01T01:00:00Z");
    }

    #[test]
    fn test_classify_multiple_fingerprints() {
        let signals = vec![
            Signal {
                ts: "2026-01-01T00:00:00Z".to_string(),
                loop_num: 1,
                signal_type: "friction".to_string(),
                source: "manual".to_string(),
                summary: "slow".to_string(),
                fingerprint: "slow-build".to_string(),
            },
            Signal {
                ts: "2026-01-01T00:00:00Z".to_string(),
                loop_num: 1,
                signal_type: "failure".to_string(),
                source: "manual".to_string(),
                summary: "crash".to_string(),
                fingerprint: "oom-crash".to_string(),
            },
        ];
        let mut patterns = HashMap::new();
        classify(&mut patterns, &signals);
        assert_eq!(patterns.len(), 2);
        assert_eq!(patterns["slow-build"].count, 1);
        assert_eq!(patterns["oom-crash"].count, 1);
    }

    #[test]
    fn test_classify_skips_empty_fingerprint() {
        let signals = vec![Signal {
            ts: "2026-01-01T00:00:00Z".to_string(),
            loop_num: 1,
            signal_type: "friction".to_string(),
            source: "manual".to_string(),
            summary: "vague".to_string(),
            fingerprint: "".to_string(),
        }];
        let mut patterns = HashMap::new();
        classify(&mut patterns, &signals);
        assert!(patterns.is_empty());
    }

    #[test]
    fn test_patterns_persist() {
        let tmp = setup();
        let mut patterns = HashMap::new();
        patterns.insert(
            "test-fp".to_string(),
            Pattern {
                count: 5,
                first_seen: "2026-01-01T00:00:00Z".to_string(),
                last_seen: "2026-01-02T00:00:00Z".to_string(),
                status: "open".to_string(),
                response_id: None,
                summary: "test pattern".to_string(),
            },
        );
        save_patterns(tmp.path(), &patterns).unwrap();
        let loaded = load_patterns(tmp.path());
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded["test-fp"].count, 5);
    }

    #[test]
    fn test_promote_selects_highest_count() {
        let tmp = setup();
        let mut patterns = HashMap::new();
        patterns.insert(
            "low".to_string(),
            Pattern {
                count: 3,
                first_seen: "2026-01-01T00:00:00Z".to_string(),
                last_seen: "2026-01-01T00:00:00Z".to_string(),
                status: "open".to_string(),
                response_id: None,
                summary: "low".to_string(),
            },
        );
        patterns.insert(
            "high".to_string(),
            Pattern {
                count: 10,
                first_seen: "2026-01-01T00:00:00Z".to_string(),
                last_seen: "2026-01-01T00:00:00Z".to_string(),
                status: "open".to_string(),
                response_id: None,
                summary: "high".to_string(),
            },
        );
        let result = promote(tmp.path(), &patterns).unwrap();
        assert_eq!(result, Some("high".to_string()));

        // Check pending.json was written
        let pending = fs::read_to_string(pending_path(tmp.path())).unwrap();
        let p: PendingResponse = serde_json::from_str(&pending).unwrap();
        assert_eq!(p.fingerprint, "high");
        assert_eq!(p.count, 10);
    }

    #[test]
    fn test_promote_ignores_addressed_patterns() {
        let tmp = setup();
        let mut patterns = HashMap::new();
        patterns.insert(
            "addressed".to_string(),
            Pattern {
                count: 100,
                first_seen: "2026-01-01T00:00:00Z".to_string(),
                last_seen: "2026-01-01T00:00:00Z".to_string(),
                status: "open".to_string(),
                response_id: Some("resp-1".to_string()),
                summary: "has response".to_string(),
            },
        );
        patterns.insert(
            "unaddressed".to_string(),
            Pattern {
                count: 5,
                first_seen: "2026-01-01T00:00:00Z".to_string(),
                last_seen: "2026-01-01T00:00:00Z".to_string(),
                status: "open".to_string(),
                response_id: None,
                summary: "no response".to_string(),
            },
        );
        let result = promote(tmp.path(), &patterns).unwrap();
        assert_eq!(result, Some("unaddressed".to_string()));
    }

    #[test]
    fn test_promote_ignores_low_count() {
        let tmp = setup();
        let mut patterns = HashMap::new();
        patterns.insert(
            "rare".to_string(),
            Pattern {
                count: 2,
                first_seen: "2026-01-01T00:00:00Z".to_string(),
                last_seen: "2026-01-01T00:00:00Z".to_string(),
                status: "open".to_string(),
                response_id: None,
                summary: "too rare".to_string(),
            },
        );
        let result = promote(tmp.path(), &patterns).unwrap();
        assert_eq!(result, None);
    }

    #[test]
    fn test_score_marks_effective() {
        let patterns = {
            let mut m = HashMap::new();
            m.insert(
                "test-fp".to_string(),
                Pattern {
                    count: 10,
                    first_seen: "2026-01-01T00:00:00Z".to_string(),
                    last_seen: "2026-01-10T00:00:00Z".to_string(),
                    status: "open".to_string(),
                    response_id: Some("resp-1".to_string()),
                    summary: "test".to_string(),
                },
            );
            m
        };
        let mut scores = vec![ScoreEntry {
            response_id: "resp-1".to_string(),
            pattern: "test-fp".to_string(),
            deployed_at: "2026-01-05T00:00:00Z".to_string(),
            signals_before: 5,
            signals_after: 0,
            effective: None,
        }];
        let all_signals = vec![
            // 5 signals before deployment
            Signal {
                ts: "2026-01-01T00:00:00Z".to_string(),
                loop_num: 1,
                signal_type: "friction".to_string(),
                source: "manual".to_string(),
                summary: "t".to_string(),
                fingerprint: "test-fp".to_string(),
            },
            // 1 signal after deployment (less than before = effective)
            Signal {
                ts: "2026-01-06T00:00:00Z".to_string(),
                loop_num: 6,
                signal_type: "friction".to_string(),
                source: "manual".to_string(),
                summary: "t".to_string(),
                fingerprint: "test-fp".to_string(),
            },
        ];
        score(&patterns, &mut scores, &all_signals);
        assert_eq!(scores[0].signals_after, 1);
        assert_eq!(scores[0].effective, Some(true));
    }

    #[test]
    fn test_full_pipeline_empty() {
        let tmp = setup();
        assert!(run_pipeline(tmp.path(), 10).is_ok());
    }

    #[test]
    fn test_full_pipeline_with_signals() {
        let tmp = setup();
        // Log some signals first
        for _ in 0..4 {
            log_signal(tmp.path(), "friction", "slow", "slow-build").unwrap();
        }
        assert!(run_pipeline(tmp.path(), 10).is_ok());

        // Check that patterns were created
        let patterns = load_patterns(tmp.path());
        assert!(patterns.contains_key("slow-build"));
        assert_eq!(patterns["slow-build"].count, 4);

        // Check that pending was promoted (count >= 3)
        assert!(pending_path(tmp.path()).exists());
    }

    #[test]
    fn test_init_creates_structure() {
        let tmp = TempDir::new().unwrap();
        assert!(init(tmp.path()).is_ok());
        assert!(improve_dir(tmp.path()).exists());
        assert!(harvesters_dir(tmp.path()).exists());
        assert!(harvesters_dir(tmp.path()).join("check-stderr").exists());
    }

    #[test]
    fn test_read_signals_handles_invalid_json() {
        let tmp = setup();
        let path = signals_path(tmp.path());
        fs::write(
            &path,
            "not valid json\n{\"ts\":\"2026-01-01T00:00:00Z\",\"type\":\"friction\",\"source\":\"manual\",\"summary\":\"ok\",\"fingerprint\":\"fp\"}\nbad\n",
        )
        .unwrap();
        let signals = read_signals(tmp.path());
        assert_eq!(signals.len(), 1);
        assert_eq!(signals[0].fingerprint, "fp");
    }

    #[test]
    fn test_show_status_empty() {
        let tmp = setup();
        assert!(show_status(tmp.path()).is_ok());
    }

    #[test]
    fn test_scoreboard_persists() {
        let tmp = setup();
        let scores = vec![ScoreEntry {
            response_id: "r1".to_string(),
            pattern: "p1".to_string(),
            deployed_at: "2026-01-01T00:00:00Z".to_string(),
            signals_before: 5,
            signals_after: 2,
            effective: Some(true),
        }];
        save_scoreboard(tmp.path(), &scores).unwrap();
        let loaded = load_scoreboard(tmp.path());
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].response_id, "r1");
        assert_eq!(loaded[0].effective, Some(true));
    }
}
