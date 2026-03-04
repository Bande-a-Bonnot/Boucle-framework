#!/bin/bash
# read-once test suite
# Tests the PreToolUse hook behavior

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="${SCRIPT_DIR}/hook.sh"
PASS=0
FAIL=0
TOTAL=0

# Use a temp directory for test isolation
TEST_DIR=$(mktemp -d)
TEST_FILE="${TEST_DIR}/test-file.txt"
echo "Hello, world!" > "$TEST_FILE"

# Override cache dir for tests
export HOME="$TEST_DIR"
mkdir -p "${TEST_DIR}/.claude/read-once"

# Test session ID
SESSION="test-session-$$"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

assert_eq() {
  TOTAL=$((TOTAL + 1))
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    echo "  ✓ $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $desc"
    echo "    expected: $expected"
    echo "    actual:   $actual"
  fi
}

assert_contains() {
  TOTAL=$((TOTAL + 1))
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -q "$needle"; then
    PASS=$((PASS + 1))
    echo "  ✓ $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $desc"
    echo "    expected to contain: $needle"
    echo "    actual: $haystack"
  fi
}

assert_empty() {
  TOTAL=$((TOTAL + 1))
  local desc="$1" actual="$2"
  if [ -z "$actual" ]; then
    PASS=$((PASS + 1))
    echo "  ✓ $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $desc"
    echo "    expected empty, got: $actual"
  fi
}

make_input() {
  local tool="$1" path="$2" session="${3:-$SESSION}" offset="${4:-}" limit="${5:-}"
  local json="{\"tool_name\":\"${tool}\",\"tool_input\":{\"file_path\":\"${path}\""
  if [ -n "$offset" ]; then
    json="${json},\"offset\":${offset}"
  fi
  if [ -n "$limit" ]; then
    json="${json},\"limit\":${limit}"
  fi
  json="${json}},\"session_id\":\"${session}\"}"
  echo "$json"
}

run_hook() {
  echo "$1" | bash "$HOOK" 2>/dev/null || true
}

echo "read-once test suite"
echo "===================="
echo ""

# --- Test 1: Non-Read tool passes through ---
echo "1. Non-Read tools"
OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"s1"}' | bash "$HOOK" 2>/dev/null || true)
assert_empty "Bash tool passes through (no output)" "$OUTPUT"

OUTPUT=$(echo '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x"},"session_id":"s1"}' | bash "$HOOK" 2>/dev/null || true)
assert_empty "Write tool passes through" "$OUTPUT"

# --- Test 2: First read of a file (cache miss) ---
echo ""
echo "2. First read (cache miss)"
OUTPUT=$(run_hook "$(make_input Read "$TEST_FILE")")
assert_empty "First read passes through (no output)" "$OUTPUT"

# --- Test 3: Second read of same file (cache hit) ---
echo ""
echo "3. Second read (cache hit — should block)"
OUTPUT=$(run_hook "$(make_input Read "$TEST_FILE")")
assert_contains "Blocked with deny" "deny" "$OUTPUT"
assert_contains "Message mentions already in context" "already in context" "$OUTPUT"

# --- Test 4: File changes between reads ---
echo ""
echo "4. File modified between reads (should allow re-read)"
sleep 1  # ensure mtime changes
echo "Modified content" > "$TEST_FILE"
OUTPUT=$(run_hook "$(make_input Read "$TEST_FILE")")
assert_empty "Modified file allowed through" "$OUTPUT"

# --- Test 5: Different session, same file ---
echo ""
echo "5. Different session (independent cache)"
OUTPUT=$(run_hook "$(make_input Read "$TEST_FILE" "different-session")")
assert_empty "Different session allows read" "$OUTPUT"

# --- Test 6: Nonexistent file ---
echo ""
echo "6. Nonexistent file"
OUTPUT=$(run_hook "$(make_input Read "/nonexistent/file.txt")")
assert_empty "Nonexistent file passes through" "$OUTPUT"

# --- Test 7: Partial reads (offset/limit) should not be cached ---
echo ""
echo "7. Partial reads bypass cache"
# Create a fresh file so no prior cache
PARTIAL_FILE="${TEST_DIR}/partial.txt"
echo "line1\nline2\nline3\nline4\nline5" > "$PARTIAL_FILE"

# First full read
OUTPUT=$(run_hook "$(make_input Read "$PARTIAL_FILE")")
assert_empty "Full read passes through" "$OUTPUT"

# Read with offset — should pass through even though file is cached
OUTPUT=$(run_hook "$(make_input Read "$PARTIAL_FILE" "$SESSION" 10)")
assert_empty "Read with offset passes through" "$OUTPUT"

# Read with limit — should pass through
OUTPUT=$(run_hook "$(make_input Read "$PARTIAL_FILE" "$SESSION" "" 50)")
assert_empty "Read with limit passes through" "$OUTPUT"

# Read with both offset and limit
OUTPUT=$(run_hook "$(make_input Read "$PARTIAL_FILE" "$SESSION" 10 50)")
assert_empty "Read with offset+limit passes through" "$OUTPUT"

# Full re-read should still be blocked (was cached from first read)
OUTPUT=$(run_hook "$(make_input Read "$PARTIAL_FILE")")
assert_contains "Full re-read still blocked" "deny" "$OUTPUT"

# --- Test 8: Missing fields ---
echo ""
echo "8. Missing/empty fields"
OUTPUT=$(echo '{"tool_name":"Read","tool_input":{},"session_id":"s1"}' | bash "$HOOK" 2>/dev/null || true)
assert_empty "Missing file_path passes through" "$OUTPUT"

OUTPUT=$(echo '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}' | bash "$HOOK" 2>/dev/null || true)
assert_empty "Missing session_id passes through" "$OUTPUT"

# --- Test 9: Stats file gets written ---
echo ""
echo "9. Stats tracking"
STATS="${TEST_DIR}/.claude/read-once/stats.jsonl"
if [ -f "$STATS" ]; then
  HIT_COUNT=$(grep -c '"event":"hit"' "$STATS" 2>/dev/null || echo 0)
  MISS_COUNT=$(grep -c '"event":"miss"' "$STATS" 2>/dev/null || echo 0)
  assert_eq "Stats has hit events" "1" "$([ "$HIT_COUNT" -gt 0 ] && echo 1 || echo 0)"
  assert_eq "Stats has miss events" "1" "$([ "$MISS_COUNT" -gt 0 ] && echo 1 || echo 0)"
else
  TOTAL=$((TOTAL + 2))
  FAIL=$((FAIL + 2))
  echo "  ✗ Stats file not found"
fi

# --- Test 10: TTL expiry (compaction safety) ---
echo ""
echo "10. TTL expiry allows re-read after timeout"

# Create a fresh file and session for TTL test
TTL_FILE="${TEST_DIR}/ttl-test.txt"
echo "TTL test content" > "$TTL_FILE"
TTL_SESSION="ttl-session-$$"

# First read — should pass through
OUTPUT=$(run_hook "$(make_input Read "$TTL_FILE" "$TTL_SESSION")")
assert_empty "TTL: first read passes through" "$OUTPUT"

# Second read — should be blocked
OUTPUT=$(run_hook "$(make_input Read "$TTL_FILE" "$TTL_SESSION")")
assert_contains "TTL: second read blocked" "deny" "$OUTPUT"
assert_contains "TTL: deny message mentions re-read window" "Re-read allowed after" "$OUTPUT"

# Now backdate the cache entry to simulate TTL expiry
SESSION_HASH=$(echo -n "$TTL_SESSION" | shasum -a 256 | cut -c1-16)
CACHE_FILE="${TEST_DIR}/.claude/read-once/session-${SESSION_HASH}.jsonl"
# Replace timestamp with one that's older than TTL (default 1200s)
if [ -f "$CACHE_FILE" ]; then
  OLD_TS=$(($(date +%s) - 1500))
  # Rewrite the cache file with old timestamp
  sed -i.bak "s/\"ts\":[0-9]*/\"ts\":${OLD_TS}/g" "$CACHE_FILE"
  rm -f "${CACHE_FILE}.bak"
fi

# Third read — should pass through (TTL expired)
OUTPUT=$(run_hook "$(make_input Read "$TTL_FILE" "$TTL_SESSION")")
assert_empty "TTL: read after expiry passes through" "$OUTPUT"

# Verify expired event in stats
EXPIRED_COUNT=$(grep -c '"event":"expired"' "$STATS" 2>/dev/null || echo 0)
assert_eq "TTL: expired event logged in stats" "1" "$([ "$EXPIRED_COUNT" -gt 0 ] && echo 1 || echo 0)"

# --- Test 11: Custom TTL via environment variable ---
echo ""
echo "11. Custom TTL via READ_ONCE_TTL"

CTL_FILE="${TEST_DIR}/custom-ttl.txt"
echo "Custom TTL content" > "$CTL_FILE"
CTL_SESSION="custom-ttl-$$"

# Set very short TTL (2 seconds)
export READ_ONCE_TTL=2

# First read
OUTPUT=$(run_hook "$(make_input Read "$CTL_FILE" "$CTL_SESSION")")
assert_empty "Custom TTL: first read passes" "$OUTPUT"

# Immediate re-read — should block
OUTPUT=$(run_hook "$(make_input Read "$CTL_FILE" "$CTL_SESSION")")
assert_contains "Custom TTL: re-read blocked within 2s" "deny" "$OUTPUT"

# Wait for TTL to expire
sleep 3

# Re-read after TTL — should pass
OUTPUT=$(run_hook "$(make_input Read "$CTL_FILE" "$CTL_SESSION")")
assert_empty "Custom TTL: re-read passes after 2s TTL" "$OUTPUT"

# Reset TTL
unset READ_ONCE_TTL

# --- Test 12: READ_ONCE_DISABLED ---
echo ""
echo "12. Disable via READ_ONCE_DISABLED"

DISABLED_FILE="${TEST_DIR}/disabled-test.txt"
echo "Disabled test" > "$DISABLED_FILE"

# First read (normal)
OUTPUT=$(run_hook "$(make_input Read "$DISABLED_FILE")")
assert_empty "Disabled: first read normal" "$OUTPUT"

# Enable disabled flag
export READ_ONCE_DISABLED=1

# Second read — should pass through even though cached
OUTPUT=$(run_hook "$(make_input Read "$DISABLED_FILE")")
assert_empty "Disabled: re-read passes when disabled" "$OUTPUT"

unset READ_ONCE_DISABLED

# --- Test 13: Changed file event tracking ---
echo ""
echo "13. Changed file event in stats"

CHANGE_FILE="${TEST_DIR}/change-track.txt"
echo "original" > "$CHANGE_FILE"
CHANGE_SESSION="change-session-$$"

# First read
run_hook "$(make_input Read "$CHANGE_FILE" "$CHANGE_SESSION")" > /dev/null

# Modify file
sleep 1
echo "modified" > "$CHANGE_FILE"

# Second read after change
run_hook "$(make_input Read "$CHANGE_FILE" "$CHANGE_SESSION")" > /dev/null

CHANGED_COUNT=$(grep -c '"event":"changed"' "$STATS" 2>/dev/null || echo 0)
assert_eq "Changed file event logged" "1" "$([ "$CHANGED_COUNT" -gt 0 ] && echo 1 || echo 0)"

# --- Summary ---
echo ""
echo "===================="
echo "Results: ${PASS}/${TOTAL} passed, ${FAIL} failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
