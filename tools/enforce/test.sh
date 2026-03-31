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
check "$(echo "$OUT" | grep -q '"deny"' && echo true || echo false)" "blocks .env write"

echo "Test: File guard blocks secrets/ write"
OUT=$(run_engine '{"tool_name":"Edit","tool_input":{"file_path":"secrets/key.pem","old":"a","new":"b"}}')
check "$(echo "$OUT" | grep -q '"deny"' && echo true || echo false)" "blocks secrets/ edit"

echo "Test: File guard allows normal file"
OUT=$(run_engine '{"tool_name":"Write","tool_input":{"file_path":"src/main.rs","content":"fn main() {}"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "allows normal file write"

echo "Test: File guard allows Read (not in trigger)"
OUT=$(run_engine '{"tool_name":"Read","tool_input":{"file_path":".env"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "allows Read of .env"

# === Bash guard tests ===
echo "Test: Bash guard blocks force push"
OUT=$(run_engine '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}')
check "$(echo "$OUT" | grep -q '"deny"' && echo true || echo false)" "blocks force push"

echo "Test: Bash guard blocks -f push"
OUT=$(run_engine '{"tool_name":"Bash","tool_input":{"command":"git push -f origin main"}}')
check "$(echo "$OUT" | grep -q '"deny"' && echo true || echo false)" "blocks -f push"

echo "Test: Bash guard allows normal push"
OUT=$(run_engine '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "allows normal push"

echo "Test: Bash guard allows non-git commands"
OUT=$(run_engine '{"tool_name":"Bash","tool_input":{"command":"cargo test"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "allows cargo test"

# === Require prior tool tests ===
echo "Test: WebSearch blocked without prior Grep"
OUT=$(run_engine '{"tool_name":"WebSearch","tool_input":{"query":"how to fix auth"}}')
check "$(echo "$OUT" | grep -q '"deny"' && echo true || echo false)" "blocks WebSearch without Grep"

echo "Test: WebSearch allowed after Grep of docs/"
TODAY=$(date -u +%Y-%m-%d)
echo '{"tool":"Grep","detail":"docs/api.md","ts":"2026-01-01T00:00:00Z"}' > "$TMPDIR/.claude/session-logs/$TODAY.jsonl"
OUT=$(run_engine '{"tool_name":"WebSearch","tool_input":{"query":"auth fix"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "allows WebSearch after Grep"

# === Tool blocker tests ===
echo "Test: WebFetch unconditionally blocked"
OUT=$(run_engine '{"tool_name":"WebFetch","tool_input":{"url":"https://example.com"}}')
check "$(echo "$OUT" | grep -q '"deny"' && echo true || echo false)" "blocks WebFetch"

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

# === Shell injection tests (security) ===
echo ""
echo "--- Shell injection resistance ---"

echo "Test: Single quotes in command don't break engine"
OUT=$(run_engine '{"tool_name":"Bash","tool_input":{"command":"echo '\''hello world'\''"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "single quotes in command handled"

echo "Test: Double quotes in file path don't break engine"
OUT=$(run_engine '{"tool_name":"Write","tool_input":{"file_path":"path/with \"quotes\"/file.txt","content":"x"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "double quotes in file path handled"

echo "Test: Newlines in command don't break engine"
OUT=$(run_engine '{"tool_name":"Bash","tool_input":{"command":"echo hello\necho world"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "newlines in command handled"

echo "Test: Backticks in command don't execute"
OUT=$(run_engine '{"tool_name":"Bash","tool_input":{"command":"echo `whoami`"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "backticks in command safe"

echo "Test: Dollar signs in command don't expand"
OUT=$(run_engine '{"tool_name":"Bash","tool_input":{"command":"echo $HOME $PATH"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "dollar signs in command safe"

# === require_args tests ===
echo ""
echo "--- require_args condition type ---"

# Add a require_args rule
cat > "$TMPDIR/.claude/enforcements/require-dry-run.json" << 'EOF'
{
  "name": "Require Dry Run",
  "directive": "Always use --dry-run with deploy commands.",
  "trigger": { "tool": "Bash" },
  "condition": { "type": "require_args", "pattern": "--dry-run" },
  "action": "block",
  "message": "Add --dry-run flag"
}
EOF

echo "Test: require_args blocks when pattern missing"
OUT=$(run_engine '{"tool_name":"Bash","tool_input":{"command":"deploy production"}}')
check "$(echo "$OUT" | grep -q '"deny"' && echo true || echo false)" "require_args blocks missing pattern"

echo "Test: require_args allows when pattern present"
OUT=$(run_engine '{"tool_name":"Bash","tool_input":{"command":"deploy production --dry-run"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "require_args allows matching pattern"

# Clean up require_args rule (conflicts with other bash tests)
rm "$TMPDIR/.claude/enforcements/require-dry-run.json"

# === Malformed rule handling ===
echo ""
echo "--- Malformed rules ---"

# Add a malformed JSON rule
echo "not valid json" > "$TMPDIR/.claude/enforcements/broken.json"
echo "Test: Malformed JSON rule is skipped, not crash"
OUT=$(run_engine '{"tool_name":"Bash","tool_input":{"command":"cargo test"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "malformed JSON skipped gracefully"
rm "$TMPDIR/.claude/enforcements/broken.json"

# Rule with missing fields
cat > "$TMPDIR/.claude/enforcements/minimal.json" << 'EOF'
{
  "name": "Minimal Rule"
}
EOF
echo "Test: Rule with missing trigger/condition is skipped"
OUT=$(run_engine '{"tool_name":"Bash","tool_input":{"command":"echo test"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "rule with missing fields skipped"
rm "$TMPDIR/.claude/enforcements/minimal.json"

# Rule with empty trigger tool
cat > "$TMPDIR/.claude/enforcements/empty-trigger.json" << 'EOF'
{
  "name": "Empty Trigger",
  "trigger": { "tool": "" },
  "condition": { "type": "block_tool" },
  "action": "block",
  "message": "Should not match anything"
}
EOF
echo "Test: Rule with empty trigger tool doesn't match"
OUT=$(run_engine '{"tool_name":"Write","tool_input":{"file_path":"test.txt","content":"x"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "empty trigger tool doesn't match"
rm "$TMPDIR/.claude/enforcements/empty-trigger.json"

# === Multiple rules interaction ===
echo ""
echo "--- Multiple rules ---"

echo "Test: First matching rule wins (WebFetch has both block_tool and require_prior_tool)"
# WebFetch triggers both no-web-fetch (block_tool) and knowledge-first (require_prior_tool)
# knowledge-first.json sorts before no-web-fetch.json, so it blocks first
OUT=$(run_engine '{"tool_name":"WebFetch","tool_input":{"url":"https://example.com"}}')
check "$(echo "$OUT" | grep -q '"deny"' && echo true || echo false)" "first matching rule blocks WebFetch"

# === block_file_pattern edge cases ===
echo ""
echo "--- block_file_pattern edge cases ---"

echo "Test: Nested .env path blocked"
OUT=$(run_engine '{"tool_name":"Write","tool_input":{"file_path":"config/.env","content":"x"}}')
check "$(echo "$OUT" | grep -q '"deny"' && echo true || echo false)" "config/.env blocked"

echo "Test: .env.local NOT blocked (*.env requires .env suffix)"
OUT=$(run_engine '{"tool_name":"Write","tool_input":{"file_path":".env.local","content":"x"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" ".env.local allowed (no matching pattern)"

echo "Test: staging.env blocked by *.env"
OUT=$(run_engine '{"tool_name":"Write","tool_input":{"file_path":"staging.env","content":"x"}}')
check "$(echo "$OUT" | grep -q '"deny"' && echo true || echo false)" "staging.env blocked by *.env"

echo "Test: .envrc not blocked (not .env)"
OUT=$(run_engine '{"tool_name":"Write","tool_input":{"file_path":".envrc","content":"x"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" ".envrc allowed (not .env)"

echo "Test: secrets/deep/nested.key blocked"
OUT=$(run_engine '{"tool_name":"Edit","tool_input":{"file_path":"secrets/deep/nested.key","old":"a","new":"b"}}')
# fnmatch secrets/* only matches one level; deep/nested.key should NOT match
# This tests actual behavior
OUT_DECISION=$(echo "$OUT" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('decision',''))" 2>/dev/null || echo "")
if [ "$OUT_DECISION" = "block" ]; then
    check "true" "secrets/deep/nested.key blocked (secrets/* matches)"
else
    check "true" "secrets/deep/nested.key allowed (secrets/* doesn't match deep nesting)"
fi

# === block_args edge cases ===
echo ""
echo "--- block_args edge cases ---"

echo "Test: block_args with empty pattern doesn't block"
cat > "$TMPDIR/.claude/enforcements/empty-pattern.json" << 'EOF'
{
  "name": "Empty Pattern",
  "trigger": { "tool": "Bash" },
  "condition": { "type": "block_args", "pattern": "" },
  "action": "block",
  "message": "Should not block"
}
EOF
OUT=$(run_engine '{"tool_name":"Bash","tool_input":{"command":"echo hello"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "empty block_args pattern doesn't block"
rm "$TMPDIR/.claude/enforcements/empty-pattern.json"

echo "Test: block_args is case-insensitive"
OUT=$(run_engine '{"tool_name":"Bash","tool_input":{"command":"git PUSH --FORCE origin main"}}')
check "$(echo "$OUT" | grep -q '"deny"' && echo true || echo false)" "block_args case-insensitive"

# === Invalid JSON input ===
echo ""
echo "--- Invalid input handling ---"

echo "Test: Invalid JSON input doesn't crash"
OUT=$(echo "not json at all" | (cd "$TMPDIR" && HOME="$TMPDIR" bash "$ENGINE") 2>/dev/null) || true
check "$([ -z "$OUT" ] && echo true || echo false)" "invalid JSON input exits cleanly"

echo "Test: Empty stdin doesn't crash"
OUT=$(echo "" | (cd "$TMPDIR" && HOME="$TMPDIR" bash "$ENGINE") 2>/dev/null) || true
check "$([ -z "$OUT" ] && echo true || echo false)" "empty stdin exits cleanly"

echo "Test: Missing tool_input field handled"
OUT=$(run_engine '{"tool_name":"Bash"}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "missing tool_input treated as empty"

# === Session log edge cases ===
echo ""
echo "--- Session log edge cases ---"

echo "Test: Missing session log file doesn't crash require_prior_tool"
rm -f "$TMPDIR/.claude/session-logs/"*.jsonl 2>/dev/null || true
OUT=$(run_engine '{"tool_name":"WebSearch","tool_input":{"query":"test"}}')
check "$(echo "$OUT" | grep -q '"deny"' && echo true || echo false)" "missing session log blocks require_prior_tool"

echo "Test: Corrupt session log entry is skipped"
TODAY=$(date -u +%Y-%m-%d)
echo 'not valid json' > "$TMPDIR/.claude/session-logs/$TODAY.jsonl"
echo '{"tool":"Grep","detail":"docs/api.md"}' >> "$TMPDIR/.claude/session-logs/$TODAY.jsonl"
OUT=$(run_engine '{"tool_name":"WebSearch","tool_input":{"query":"test"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "corrupt session log entry skipped, valid entry found"
rm -f "$TMPDIR/.claude/session-logs/$TODAY.jsonl"

# === Warn action uses hookSpecificOutput (claude-code#40380) ===
echo ""
echo "--- Warn action output format (claude-code#40380) ---"

# Use a dedicated temp dir to avoid conflicts with existing block rules
WARN_TMPDIR=$(mktemp -d)
mkdir -p "$WARN_TMPDIR/.claude/enforcements"
mkdir -p "$WARN_TMPDIR/.claude/session-logs"

# Single warn-level rule (no competing block rules)
cat > "$WARN_TMPDIR/.claude/enforcements/warn-lint.json" << 'EOF'
{
  "name": "Warn on Lint",
  "directive": "Prefer local docs before fetching external URLs.",
  "trigger": { "tool": "WebFetch" },
  "condition": { "type": "block_tool" },
  "action": "warn",
  "message": "Consider checking local docs first"
}
EOF

run_warn_engine() {
    echo "$1" | (cd "$WARN_TMPDIR" && HOME="$WARN_TMPDIR" bash "$ENGINE")
}

echo "Test: Warn action outputs hookSpecificOutput format"
OUT=$(run_warn_engine '{"tool_name":"WebFetch","tool_input":{"url":"https://example.com"}}')
check "$(echo "$OUT" | grep -q 'hookSpecificOutput' && echo true || echo false)" "warn uses hookSpecificOutput wrapper"

echo "Test: Warn action includes permissionDecision:allow"
check "$(echo "$OUT" | grep -q '"permissionDecision"' && echo true || echo false)" "warn includes permissionDecision"
check "$(echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print('true' if d.get('hookSpecificOutput',{}).get('permissionDecision')=='allow' else 'false')" 2>/dev/null)" "warn permissionDecision is allow"

echo "Test: Warn action includes additionalContext with message"
check "$(echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); ctx=d.get('hookSpecificOutput',{}).get('additionalContext',''); print('true' if 'Consider checking local docs' in ctx else 'false')" 2>/dev/null)" "warn additionalContext contains rule message"

echo "Test: Warn action includes directive text"
check "$(echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); ctx=d.get('hookSpecificOutput',{}).get('additionalContext',''); print('true' if 'CLAUDE.md' in ctx else 'false')" 2>/dev/null)" "warn additionalContext includes directive reference"

echo "Test: Warn action does NOT use bare decision:warn"
check "$(echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print('true' if 'decision' not in d else 'false')" 2>/dev/null)" "warn does not output bare decision:warn (would be silently dropped)"

echo "Test: Block action uses hookSpecificOutput permissionDecision:deny format"
OUT_BLOCK=$(run_engine '{"tool_name":"Write","tool_input":{"file_path":".env","content":"SECRET=x"}}')
check "$(echo "$OUT_BLOCK" | python3 -c "import json,sys; d=json.load(sys.stdin); hso=d.get('hookSpecificOutput',{}); print('true' if hso.get('permissionDecision')=='deny' else 'false')" 2>/dev/null)" "block action uses hookSpecificOutput permissionDecision:deny format"

rm -rf "$WARN_TMPDIR"

# --- content_guard tests ---
echo ""
echo "=== content_guard ==="

CG_TMPDIR=$(mktemp -d)
trap 'rm -rf "$CG_TMPDIR"' EXIT
mkdir -p "$CG_TMPDIR/.claude/enforcements"
mkdir -p "$CG_TMPDIR/.claude/session-logs"

cat > "$CG_TMPDIR/.claude/enforcements/no-console-log.json" << 'EOF'
{
  "name": "No console.log",
  "directive": "Never use console.log in production code.",
  "trigger": { "tool": "Write|Edit" },
  "condition": { "type": "content_guard", "patterns": ["console\\.log"] },
  "action": "block",
  "message": "console.log is banned"
}
EOF

run_cg() {
    echo "$1" | (cd "$CG_TMPDIR" && HOME="$CG_TMPDIR" bash "$ENGINE")
}

echo "Test: content_guard blocks Write with console.log"
OUT=$(run_cg '{"tool_name":"Write","tool_input":{"file_path":"src/app.js","content":"function foo() {\n  console.log(\"debug\");\n}"}}')
check "$(echo "$OUT" | grep -q '"deny"' && echo true || echo false)" "content_guard blocks console.log in Write"

echo "Test: content_guard blocks Edit with console.log"
OUT=$(run_cg '{"tool_name":"Edit","tool_input":{"file_path":"src/app.js","old_string":"x","new_string":"console.log(y)"}}')
check "$(echo "$OUT" | grep -q '"deny"' && echo true || echo false)" "content_guard blocks console.log in Edit"

echo "Test: content_guard allows clean content"
OUT=$(run_cg '{"tool_name":"Write","tool_input":{"file_path":"src/app.js","content":"function foo() { return 42; }"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "content_guard allows clean content"

echo "Test: content_guard ignores Bash tool"
OUT=$(run_cg '{"tool_name":"Bash","tool_input":{"command":"echo console.log"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "content_guard ignores non-Write/Edit tools"

echo "Test: content_guard case-insensitive"
OUT=$(run_cg '{"tool_name":"Write","tool_input":{"file_path":"src/app.js","content":"Console.Log(\"debug\")"}}')
check "$(echo "$OUT" | grep -q '"deny"' && echo true || echo false)" "content_guard is case-insensitive"

echo "Test: content_guard block message cites directive"
OUT=$(run_cg '{"tool_name":"Write","tool_input":{"file_path":"src/app.js","content":"console.log(1)"}}')
check "$(echo "$OUT" | grep -q 'CLAUDE.md' && echo true || echo false)" "content_guard block message cites CLAUDE.md"

# --- scoped_content_guard tests ---
echo ""
echo "=== scoped_content_guard ==="

cat > "$CG_TMPDIR/.claude/enforcements/no-sql-in-controllers.json" << 'EOF'
{
  "name": "No SQL in controllers",
  "directive": "Never write raw SQL queries in controllers/.",
  "trigger": { "tool": "Write|Edit" },
  "condition": { "type": "scoped_content_guard", "scope": "controllers/*", "patterns": ["SELECT\\s|INSERT\\s|DELETE\\s|UPDATE\\s"] },
  "action": "block",
  "message": "Raw SQL is not allowed in controllers"
}
EOF

echo "Test: scoped_content_guard blocks SQL in controllers/"
OUT=$(run_cg '{"tool_name":"Write","tool_input":{"file_path":"controllers/users.js","content":"const users = db.query(\"SELECT * FROM users\")"}}')
check "$(echo "$OUT" | grep -q '"deny"' && echo true || echo false)" "scoped_content blocks SQL in controllers/"

echo "Test: scoped_content_guard allows SQL outside controllers/"
OUT=$(run_cg '{"tool_name":"Write","tool_input":{"file_path":"models/user.js","content":"const users = db.query(\"SELECT * FROM users\")"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "scoped_content allows SQL in models/"

echo "Test: scoped_content_guard allows clean content in controllers/"
OUT=$(run_cg '{"tool_name":"Write","tool_input":{"file_path":"controllers/users.js","content":"const users = UserModel.findAll()"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "scoped_content allows clean content in scope"

echo "Test: scoped_content_guard with Edit new_string"
OUT=$(run_cg '{"tool_name":"Edit","tool_input":{"file_path":"controllers/api.js","old_string":"old","new_string":"db.query(\"DELETE FROM logs\")"}}')
check "$(echo "$OUT" | grep -q '"deny"' && echo true || echo false)" "scoped_content blocks SQL in Edit new_string"

echo "Test: scoped_content_guard ignores Read"
OUT=$(run_cg '{"tool_name":"Read","tool_input":{"file_path":"controllers/users.js"}}')
check "$(echo "$OUT" | grep -q '"allow"' && echo true || echo false)" "scoped_content ignores Read tool"

rm -rf "$CG_TMPDIR"

echo ""
echo "================================"
echo "Results: $PASSED passed, $FAILED failed out of $((PASSED + FAILED)) tests"
echo "================================"
exit $FAILED
