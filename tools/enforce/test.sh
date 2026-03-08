#!/usr/bin/env bash
# Tests for enforce-hooks engine.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$SCRIPT_DIR/engine.sh"
PASSED=0
FAILED=0

check() {
    if [ "$1" = "true" ]; then
        PASSED=$((PASSED + 1))
        echo "  PASS: $2"
    else
        FAILED=$((FAILED + 1))
        echo "  FAIL: $2"
    fi
}

# Set up temp project with enforcements
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/.claude/enforcements"
mkdir -p "$TMPDIR/.claude/session-logs"

# Rule 1: block Write to .env
cat > "$TMPDIR/.claude/enforcements/protected-files.json" << 'EOF'
{
  "name": "Protected Files",
  "directive": "Never modify .env files.",
  "trigger": { "tool": "Write|Edit" },
  "condition": { "type": "block_file_pattern", "patterns": [".env", "*.env", "secrets/*"] },
  "action": "block",
  "message": "This file is protected"
}
EOF

# Rule 2: block force push
cat > "$TMPDIR/.claude/enforcements/no-force-push.json" << 'EOF'
{
  "name": "No Force Push",
  "directive": "Never use git push --force.",
  "trigger": { "tool": "Bash" },
  "condition": { "type": "block_args", "pattern": "push\\s+(-f|--force)" },
  "action": "block",
  "message": "Force push is blocked"
}
EOF

# Rule 3: require Grep before WebSearch
cat > "$TMPDIR/.claude/enforcements/knowledge-first.json" << 'EOF'
{
  "name": "Knowledge First",
  "directive": "Grep docs/ before WebSearch.",
  "trigger": { "tool": "WebSearch|WebFetch" },
  "condition": { "type": "require_prior_tool", "tool": "Grep", "args_pattern": "docs/" },
  "action": "block",
  "message": "Search docs/ first"
}
EOF

# Rule 4: block specific tool
cat > "$TMPDIR/.claude/enforcements/no-web-fetch.json" << 'EOF'
{
  "name": "No WebFetch",
  "directive": "Do not fetch external URLs.",
  "trigger": { "tool": "WebFetch" },
  "condition": { "type": "block_tool" },
  "action": "block",
  "message": "WebFetch is disabled"
}
EOF

run_engine() {
    echo "$1" | (cd "$TMPDIR" && HOME="$TMPDIR" bash "$ENGINE")
}

# === File guard tests ===
echo "Test: File guard blocks .env write"
OUT=$(run_engine '{"tool_name":"Write","tool_input":{"file_path":".env","content":"x"}}')
check "$(echo "$OUT" | grep -q '"block"' && echo true || echo false)" "blocks .env write"

echo "Test: File guard blocks secrets/ write"
OUT=$(run_engine '{"tool_name":"Edit","tool_input":{"file_path":"secrets/key.pem","old":"a","new":"b"}}')
check "$(echo "$OUT" | grep -q '"block"' && echo true || echo false)" "blocks secrets/ edit"

echo "Test: File guard allows normal file"
OUT=$(run_engine '{"tool_name":"Write","tool_input":{"file_path":"src/main.rs","content":"fn main() {}"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "allows normal file write"

echo "Test: File guard allows Read (not in trigger)"
OUT=$(run_engine '{"tool_name":"Read","tool_input":{"file_path":".env"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "allows Read of .env"

# === Bash guard tests ===
echo "Test: Bash guard blocks force push"
OUT=$(run_engine '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}')
check "$(echo "$OUT" | grep -q '"block"' && echo true || echo false)" "blocks force push"

echo "Test: Bash guard blocks -f push"
OUT=$(run_engine '{"tool_name":"Bash","tool_input":{"command":"git push -f origin main"}}')
check "$(echo "$OUT" | grep -q '"block"' && echo true || echo false)" "blocks -f push"

echo "Test: Bash guard allows normal push"
OUT=$(run_engine '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "allows normal push"

echo "Test: Bash guard allows non-git commands"
OUT=$(run_engine '{"tool_name":"Bash","tool_input":{"command":"cargo test"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "allows cargo test"

# === Require prior tool tests ===
echo "Test: WebSearch blocked without prior Grep"
OUT=$(run_engine '{"tool_name":"WebSearch","tool_input":{"query":"how to fix auth"}}')
check "$(echo "$OUT" | grep -q '"block"' && echo true || echo false)" "blocks WebSearch without Grep"

echo "Test: WebSearch allowed after Grep of docs/"
TODAY=$(date -u +%Y-%m-%d)
echo '{"tool":"Grep","detail":"docs/api.md","ts":"2026-01-01T00:00:00Z"}' > "$TMPDIR/.claude/session-logs/$TODAY.jsonl"
OUT=$(run_engine '{"tool_name":"WebSearch","tool_input":{"query":"auth fix"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "allows WebSearch after Grep"

# === Tool blocker tests ===
echo "Test: WebFetch unconditionally blocked"
OUT=$(run_engine '{"tool_name":"WebFetch","tool_input":{"url":"https://example.com"}}')
check "$(echo "$OUT" | grep -q '"block"' && echo true || echo false)" "blocks WebFetch"

echo "Test: WebSearch not blocked by WebFetch rule"
# Reset session log (remove the Grep entry to test isolation)
rm -f "$TMPDIR/.claude/session-logs/$TODAY.jsonl"
OUT=$(run_engine '{"tool_name":"WebSearch","tool_input":{"query":"test"}}')
# WebSearch IS blocked, but by knowledge-first rule, not WebFetch rule
check "$(echo "$OUT" | grep -q 'Search docs' && echo true || echo false)" "WebSearch blocked by correct rule (knowledge-first)"

# === Edge cases ===
echo "Test: Unknown tool allowed"
OUT=$(run_engine '{"tool_name":"Glob","tool_input":{"pattern":"*.rs"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "unknown tool allowed"

echo "Test: Empty input handled"
OUT=$(run_engine '{}')
check "$(echo "$OUT" | grep -q '"allow"' || [ -z "$OUT" ] && echo true || echo false)" "empty input handled"

echo "Test: Block message includes CLAUDE.md directive"
OUT=$(run_engine '{"tool_name":"Write","tool_input":{"file_path":".env","content":"x"}}')
check "$(echo "$OUT" | grep -q 'CLAUDE.md' && echo true || echo false)" "block message cites CLAUDE.md"

echo "Test: No enforcements dir = allow all"
TMPDIR2=$(mktemp -d)
OUT=$(echo '{"tool_name":"Write","tool_input":{"file_path":".env"}}' | (cd "$TMPDIR2" && bash "$ENGINE"))
check "$([ -z "$OUT" ] && echo true || echo false)" "no enforcements dir = silent allow"
rm -rf "$TMPDIR2"

echo ""
echo "Results: $PASSED passed, $FAILED failed out of $((PASSED + FAILED)) tests"
exit $FAILED
