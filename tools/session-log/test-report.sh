#!/usr/bin/env bash
# Tests for session-report
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPORT="${SCRIPT_DIR}/report.sh"
PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export HOME="$TMPDIR/fakehome"
mkdir -p "$HOME/.claude/session-logs"

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

assert_contains() {
    if echo "$1" | grep -qF "$2"; then pass "$3"; else fail "$3 — expected '$2'"; fi
}

assert_not_contains() {
    if echo "$1" | grep -qF "$2"; then fail "$3 — unexpected '$2'"; else pass "$3"; fi
}

echo "=== session-report tests ==="

# --- Test 1: No logs directory ---
echo "Test: No log directory"
OLDHOME="$HOME"
export HOME="$TMPDIR/nohome"
mkdir -p "$HOME"
OUT=$(bash "$REPORT" 2>&1 || true)
assert_contains "$OUT" "No session logs found" "reports missing log dir"
export HOME="$OLDHOME"

# --- Test 2: No logs for today ---
echo "Test: No logs for today"
OUT=$(bash "$REPORT" 2>&1 || true)
assert_contains "$OUT" "No logs found" "reports no logs for today"

# --- Test 3: Empty log file ---
echo "Test: Empty log file"
touch "$HOME/.claude/session-logs/2026-01-01.jsonl"
OUT=$(bash "$REPORT" 2026-01-01 2>&1 || true)
assert_contains "$OUT" "No entries found" "handles empty file"

# --- Test 4: Basic report ---
echo "Test: Basic report"
cat > "$HOME/.claude/session-logs/2026-03-07.jsonl" <<'JSONL'
{"ts":"2026-03-07T10:00:00Z","session":"s1","tool":"Read","detail":"/src/main.rs","cwd":"/project"}
{"ts":"2026-03-07T10:00:01Z","session":"s1","tool":"Bash","detail":"cargo test","cwd":"/project"}
{"ts":"2026-03-07T10:00:05Z","session":"s1","tool":"Write","detail":"/src/lib.rs","cwd":"/project"}
{"ts":"2026-03-07T10:01:00Z","session":"s1","tool":"Read","detail":"/Cargo.toml","cwd":"/project"}
{"ts":"2026-03-07T10:01:30Z","session":"s1","tool":"Edit","detail":"/src/main.rs","cwd":"/project"}
JSONL
OUT=$(bash "$REPORT" 2026-03-07 2>&1)
assert_contains "$OUT" "Session Report: 2026-03-07" "shows date label"
assert_contains "$OUT" "Total tool calls: 5" "counts total calls"
assert_contains "$OUT" "Sessions: 1" "counts sessions"
assert_contains "$OUT" "Read" "shows Read tool"
assert_contains "$OUT" "Bash" "shows Bash tool"
assert_contains "$OUT" "Write" "shows Write tool"
assert_contains "$OUT" "Files read: 2" "counts files read"
assert_contains "$OUT" "/src/lib.rs" "shows written file"
assert_contains "$OUT" "cargo test" "shows command"

# --- Test 5: Multiple sessions ---
echo "Test: Multiple sessions"
cat >> "$HOME/.claude/session-logs/2026-03-07.jsonl" <<'JSONL'
{"ts":"2026-03-07T14:00:00Z","session":"s2","tool":"Read","detail":"/README.md","cwd":"/other"}
{"ts":"2026-03-07T14:00:05Z","session":"s2","tool":"Grep","detail":"TODO in /other","cwd":"/other"}
JSONL
OUT=$(bash "$REPORT" 2026-03-07 2>&1)
assert_contains "$OUT" "Sessions: 2" "counts multiple sessions"
assert_contains "$OUT" "Total tool calls: 7" "counts all calls"
assert_contains "$OUT" "Grep" "shows Grep tool"

# --- Test 6: --all flag ---
echo "Test: --all flag"
cat > "$HOME/.claude/session-logs/2026-03-06.jsonl" <<'JSONL'
{"ts":"2026-03-06T08:00:00Z","session":"s0","tool":"Bash","detail":"ls","cwd":"/"}
JSONL
OUT=$(bash "$REPORT" --all 2>&1)
assert_contains "$OUT" "Session Report: all time" "shows all time label"
assert_contains "$OUT" "Total tool calls: 8" "counts across days"
assert_contains "$OUT" "Sessions: 3" "counts all sessions"

# --- Test 7: Hourly distribution ---
echo "Test: Hourly distribution"
OUT=$(bash "$REPORT" 2026-03-07 2>&1)
assert_contains "$OUT" "Activity by hour" "shows hourly section"
assert_contains "$OUT" "10:00" "shows hour 10"
assert_contains "$OUT" "14:00" "shows hour 14"

# --- Test 8: Invalid JSON lines ---
echo "Test: Invalid JSON skipped"
cat > "$HOME/.claude/session-logs/2026-02-01.jsonl" <<'JSONL'
not valid json
{"ts":"2026-02-01T12:00:00Z","session":"s1","tool":"Read","detail":"/foo","cwd":"/"}
also bad
{"ts":"2026-02-01T12:00:01Z","session":"s1","tool":"Write","detail":"/bar","cwd":"/"}
JSONL
OUT=$(bash "$REPORT" 2026-02-01 2>&1)
assert_contains "$OUT" "Total tool calls: 2" "skips invalid JSON"

# --- Test 9: Repeated commands ---
echo "Test: Command frequency"
cat > "$HOME/.claude/session-logs/2026-02-02.jsonl" <<'JSONL'
{"ts":"2026-02-02T09:00:00Z","session":"s1","tool":"Bash","detail":"cargo test","cwd":"/p"}
{"ts":"2026-02-02T09:00:01Z","session":"s1","tool":"Bash","detail":"cargo test","cwd":"/p"}
{"ts":"2026-02-02T09:00:02Z","session":"s1","tool":"Bash","detail":"cargo test","cwd":"/p"}
{"ts":"2026-02-02T09:00:03Z","session":"s1","tool":"Bash","detail":"git status","cwd":"/p"}
JSONL
OUT=$(bash "$REPORT" 2026-02-02 2>&1)
assert_contains "$OUT" "Commands run: 4" "counts total commands"
assert_contains "$OUT" "3x" "shows repeated command count"

# --- Test 10: Files written list ---
echo "Test: Written files list"
cat > "$HOME/.claude/session-logs/2026-02-03.jsonl" <<'JSONL'
{"ts":"2026-02-03T09:00:00Z","session":"s1","tool":"Write","detail":"/a.txt","cwd":"/p"}
{"ts":"2026-02-03T09:00:01Z","session":"s1","tool":"Edit","detail":"/b.txt","cwd":"/p"}
{"ts":"2026-02-03T09:00:02Z","session":"s1","tool":"Write","detail":"/c.txt","cwd":"/p"}
JSONL
OUT=$(bash "$REPORT" 2026-02-03 2>&1)
assert_contains "$OUT" "Files written/edited: 3" "counts unique written files"
assert_contains "$OUT" "/a.txt" "lists written file a"
assert_contains "$OUT" "/b.txt" "lists edited file b"
assert_contains "$OUT" "/c.txt" "lists written file c"

# --- Test 11: Specific date argument ---
echo "Test: Date argument"
OUT=$(bash "$REPORT" 2026-03-06 2>&1)
assert_contains "$OUT" "Session Report: 2026-03-06" "uses date argument"
assert_contains "$OUT" "Total tool calls: 1" "shows single entry"

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed out of $((PASS + FAIL)) tests"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
