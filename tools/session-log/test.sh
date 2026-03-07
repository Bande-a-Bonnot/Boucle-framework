#!/usr/bin/env bash
# Tests for session-log hook
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="${SCRIPT_DIR}/hook.sh"
PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Override HOME so tests don't pollute real logs
export HOME="$TMPDIR/fakehome"
mkdir -p "$HOME"

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

assert_contains() {
    if echo "$1" | grep -qF "$2"; then pass "$3"; else fail "$3 — expected '$2' in output"; fi
}

assert_file_exists() {
    if [ -f "$1" ]; then pass "$2"; else fail "$2 — file $1 not found"; fi
}

assert_json_field() {
    # $1=json_line $2=field $3=expected_value $4=test_name
    actual=$(echo "$1" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('$2',''))")
    if [ "$actual" = "$3" ]; then pass "$4"; else fail "$4 — expected $2='$3', got '$actual'"; fi
}

assert_json_has_field() {
    actual=$(echo "$1" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print('yes' if '$2' in d else 'no')")
    if [ "$actual" = "yes" ]; then pass "$3"; else fail "$3 — field '$2' missing"; fi
}

assert_json_missing_field() {
    actual=$(echo "$1" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print('yes' if '$2' in d else 'no')")
    if [ "$actual" = "no" ]; then pass "$3"; else fail "$3 — field '$2' should be absent"; fi
}

# ============================================================
echo "=== Basic functionality ==="

# Test 1: Read tool logging
echo '{"tool_name":"Read","tool_input":{"file_path":"/src/main.rs"}}' | bash "$HOOK"
LOG_FILE=$(ls "$HOME/.claude/session-logs/"*.jsonl 2>/dev/null | head -1)
assert_file_exists "$LOG_FILE" "Log file created"

LINE=$(tail -1 "$LOG_FILE")
assert_json_field "$LINE" "tool" "Read" "Read tool name logged"
assert_json_field "$LINE" "detail" "/src/main.rs" "Read file_path logged"
assert_json_has_field "$LINE" "ts" "Timestamp present"
assert_json_has_field "$LINE" "session" "Session ID present"
assert_json_has_field "$LINE" "cwd" "Working directory present"

# Test 2: Write tool logging
echo '{"tool_name":"Write","tool_input":{"file_path":"/src/lib.rs","content":"fn main() {}"}}' | bash "$HOOK"
LINE=$(tail -1 "$LOG_FILE")
assert_json_field "$LINE" "tool" "Write" "Write tool name logged"
assert_json_field "$LINE" "detail" "/src/lib.rs" "Write file_path logged"

# Test 3: Bash tool logging
echo '{"tool_name":"Bash","tool_input":{"command":"cargo test --release"}}' | bash "$HOOK"
LINE=$(tail -1 "$LOG_FILE")
assert_json_field "$LINE" "tool" "Bash" "Bash tool name logged"
assert_json_field "$LINE" "detail" "cargo test --release" "Bash command logged"

# Test 4: Grep tool logging
echo '{"tool_name":"Grep","tool_input":{"pattern":"fn main","path":"/src"}}' | bash "$HOOK"
LINE=$(tail -1 "$LOG_FILE")
assert_json_field "$LINE" "tool" "Grep" "Grep tool name logged"
assert_json_field "$LINE" "detail" "fn main in /src" "Grep pattern+path logged"

# Test 5: Edit tool logging
echo '{"tool_name":"Edit","tool_input":{"file":"/src/utils.rs","changes":"..."}}' | bash "$HOOK"
LINE=$(tail -1 "$LOG_FILE")
assert_json_field "$LINE" "tool" "Edit" "Edit tool name logged"
assert_json_field "$LINE" "detail" "/src/utils.rs" "Edit file path logged"

# Test 6: WebSearch tool logging
echo '{"tool_name":"WebSearch","tool_input":{"query":"rust async patterns 2026"}}' | bash "$HOOK"
LINE=$(tail -1 "$LOG_FILE")
assert_json_field "$LINE" "tool" "WebSearch" "WebSearch tool name logged"
assert_json_field "$LINE" "detail" "rust async patterns 2026" "WebSearch query logged"

# ============================================================
echo ""
echo "=== Edge cases ==="

# Test 7: Unknown tool
echo '{"tool_name":"CustomTool","tool_input":{"foo":"bar"}}' | bash "$HOOK"
LINE=$(tail -1 "$LOG_FILE")
assert_json_field "$LINE" "tool" "CustomTool" "Unknown tool name preserved"
assert_json_field "$LINE" "detail" "foo=bar" "Unknown tool first key-value logged"

# Test 8: Empty tool_input
echo '{"tool_name":"Stop","tool_input":{}}' | bash "$HOOK"
LINE=$(tail -1 "$LOG_FILE")
assert_json_field "$LINE" "tool" "Stop" "Empty input tool name logged"
assert_json_missing_field "$LINE" "detail" "Empty input has no detail"

# Test 9: Missing tool_name
echo '{"tool_input":{"file_path":"/test"}}' | bash "$HOOK"
LINE=$(tail -1 "$LOG_FILE")
assert_json_field "$LINE" "tool" "unknown" "Missing tool_name defaults to unknown"

# Test 10: Invalid JSON — should exit 0 (never block)
RESULT=$(echo 'not json at all' | bash "$HOOK" 2>&1; echo "EXIT:$?")
assert_contains "$RESULT" "EXIT:0" "Invalid JSON exits 0 (non-blocking)"

# Test 11: Empty stdin — should exit 0
RESULT=$(echo '' | bash "$HOOK" 2>&1; echo "EXIT:$?")
assert_contains "$RESULT" "EXIT:0" "Empty stdin exits 0 (non-blocking)"

# Test 12: Tool input with special characters
echo '{"tool_name":"Bash","tool_input":{"command":"echo \"hello world\" && grep '\''pattern'\\'' file"}}' | bash "$HOOK"
LINE=$(tail -1 "$LOG_FILE")
assert_json_field "$LINE" "tool" "Bash" "Special chars don't break logging"

# Test 13: Very long command (truncation)
LONG_CMD=$(python3 -c "print('x' * 500)")
echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$LONG_CMD\"}}" | bash "$HOOK"
LINE=$(tail -1 "$LOG_FILE")
DETAIL_LEN=$(echo "$LINE" | python3 -c "import sys,json; print(len(json.loads(sys.stdin.read()).get('detail','')))")
if [ "$DETAIL_LEN" -le 200 ]; then pass "Long command truncated to 200 chars"; else fail "Long command not truncated (got $DETAIL_LEN chars)"; fi

# Test 14: Non-dict tool_input
echo '{"tool_name":"Custom","tool_input":"just a string"}' | bash "$HOOK"
LINE=$(tail -1 "$LOG_FILE")
assert_json_field "$LINE" "tool" "Custom" "String tool_input handled"

# ============================================================
echo ""
echo "=== JSONL format ==="

# Test 15: All lines are valid JSON
TOTAL=$(wc -l < "$LOG_FILE" | tr -d ' ')
VALID=$(python3 -c "
import json
valid = 0
with open('$LOG_FILE') as f:
    for line in f:
        try:
            json.loads(line)
            valid += 1
        except:
            pass
print(valid)
")
if [ "$TOTAL" = "$VALID" ]; then pass "All $TOTAL lines are valid JSON"; else fail "Only $VALID of $TOTAL lines are valid JSON"; fi

# Test 16: Multiple entries accumulate (not overwrite)
BEFORE=$(wc -l < "$LOG_FILE" | tr -d ' ')
echo '{"tool_name":"Read","tool_input":{"file_path":"/extra"}}' | bash "$HOOK"
AFTER=$(wc -l < "$LOG_FILE" | tr -d ' ')
EXPECTED=$((BEFORE + 1))
if [ "$AFTER" = "$EXPECTED" ]; then pass "Entries append (not overwrite)"; else fail "Expected $EXPECTED lines, got $AFTER"; fi

# ============================================================
echo ""
echo "=== Timestamp format ==="

# Test 17: ISO 8601 UTC timestamp
LINE=$(tail -1 "$LOG_FILE")
TS=$(echo "$LINE" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['ts'])")
if echo "$TS" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
    pass "Timestamp is ISO 8601 UTC"
else
    fail "Timestamp format wrong: $TS"
fi

# ============================================================
echo ""
echo "=== Session ID ==="

# Test 18: Custom session ID from environment
export CLAUDE_SESSION_ID="test-session-42"
echo '{"tool_name":"Read","tool_input":{"file_path":"/test"}}' | bash "$HOOK"
LINE=$(tail -1 "$LOG_FILE")
assert_json_field "$LINE" "session" "test-session-42" "Custom session ID from env"
unset CLAUDE_SESSION_ID

# Test 19: Fallback session ID
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION 2>/dev/null || true
echo '{"tool_name":"Read","tool_input":{"file_path":"/test"}}' | bash "$HOOK"
LINE=$(tail -1 "$LOG_FILE")
SESSION=$(echo "$LINE" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['session'])")
if echo "$SESSION" | grep -qE '^[0-9]+$'; then
    pass "Fallback session ID is numeric timestamp"
else
    fail "Fallback session ID unexpected: $SESSION"
fi

# ============================================================
echo ""
echo "=== Log directory ==="

# Test 20: Log dir created automatically
rm -rf "$HOME/.claude/session-logs"
echo '{"tool_name":"Read","tool_input":{"file_path":"/test"}}' | bash "$HOOK"
if [ -d "$HOME/.claude/session-logs" ]; then pass "Log dir auto-created"; else fail "Log dir not created"; fi

# Test 21: Daily log file naming
DATE=$(date -u +"%Y-%m-%d")
assert_file_exists "$HOME/.claude/session-logs/${DATE}.jsonl" "Log file named with today's date"

# ============================================================
echo ""
echo "=== Grep default path ==="

# Test 22: Grep with no explicit path
echo '{"tool_name":"Grep","tool_input":{"pattern":"TODO"}}' | bash "$HOOK"
LINE=$(tail -1 "$LOG_FILE")
assert_json_field "$LINE" "detail" "TODO in ." "Grep default path is ."

# ============================================================
echo ""
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo "$TOTAL tests: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
