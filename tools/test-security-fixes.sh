#!/bin/bash
# Test security fixes: JSON injection + path traversal
# These tests verify the fixes from Gemini Code Assist's review of PR #2
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0

assert_valid_json() {
  local desc="$1"
  local result="$2"
  if [ -z "$result" ]; then
    # Empty result means allowed (no JSON output) — valid
    PASS=$((PASS + 1))
    echo "  PASS: $desc (allowed, no output)"
    return
  fi
  if echo "$result" | jq . >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (invalid JSON: $result)"
  fi
}

assert_blocked() {
  local desc="$1"
  local result="$2"
  if echo "$result" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected block, got: $result)"
  fi
}

assert_allowed() {
  local desc="$1"
  local result="$2"
  if [ -z "$result" ] || ! echo "$result" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected allow, got blocked)"
  fi
}

# --- Setup temp environment ---
TMPDIR=$(mktemp -d)
CONFIG="$TMPDIR/.file-guard"
export FILE_GUARD_CONFIG="$CONFIG"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

echo "=== Security Fix Tests ==="
echo ""

# ============================================================
# TEST 1: JSON injection in file-guard
# ============================================================
echo "--- JSON injection: file-guard ---"

cat > "$CONFIG" <<'EOF'
.env
secrets/
EOF

# File path with double quote (would break string-concatenated JSON)
result=$(echo '{"tool_name":"Write","tool_input":{"file_path":"test\".env"}}' | bash "$SCRIPT_DIR/file-guard/hook.sh" 2>/dev/null) || true
assert_valid_json "Write with double-quote in path produces valid JSON" "$result"

# File path with backslash
result=$(echo '{"tool_name":"Write","tool_input":{"file_path":".env\\backup"}}' | bash "$SCRIPT_DIR/file-guard/hook.sh" 2>/dev/null) || true
assert_valid_json "Write with backslash in path produces valid JSON" "$result"

# Protected file with special chars in path
result=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"secrets/key\"file.pem"}}' | bash "$SCRIPT_DIR/file-guard/hook.sh" 2>/dev/null) || true
assert_valid_json "Edit with quote in dir path produces valid JSON" "$result"
assert_blocked "Edit to secrets/ subdir with special chars is blocked" "$result"

# Normal .env still blocked (regression check)
result=$(echo '{"tool_name":"Write","tool_input":{"file_path":".env"}}' | bash "$SCRIPT_DIR/file-guard/hook.sh" 2>/dev/null) || true
assert_blocked "Write to .env still blocked after security fix" "$result"
assert_valid_json "Write to .env produces valid JSON" "$result"

# Normal safe file still allowed
result=$(echo '{"tool_name":"Write","tool_input":{"file_path":"src/app.js"}}' | bash "$SCRIPT_DIR/file-guard/hook.sh" 2>/dev/null) || true
assert_allowed "Write to safe file still allowed" "$result"

# ============================================================
# TEST 2: Path traversal in file-guard
# ============================================================
echo ""
echo "--- Path traversal: file-guard ---"

cat > "$CONFIG" <<'EOF'
.env
secrets.json
config/
EOF

# Traversal: subdir/../.env should resolve to .env and be blocked
result=$(echo '{"tool_name":"Write","tool_input":{"file_path":"subdir/../.env"}}' | bash "$SCRIPT_DIR/file-guard/hook.sh" 2>/dev/null) || true
assert_blocked "subdir/../.env traversal is caught" "$result"

# Traversal: deep nesting
result=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"a/b/c/../../../.env"}}' | bash "$SCRIPT_DIR/file-guard/hook.sh" 2>/dev/null) || true
assert_blocked "a/b/c/../../../.env deep traversal is caught" "$result"

# Traversal: into protected directory
result=$(echo '{"tool_name":"Write","tool_input":{"file_path":"src/../config/db.yml"}}' | bash "$SCRIPT_DIR/file-guard/hook.sh" 2>/dev/null) || true
assert_blocked "src/../config/db.yml directory traversal is caught" "$result"

# Non-traversal: safe file with .. in name (not a directory component)
result=$(echo '{"tool_name":"Write","tool_input":{"file_path":"src/app.js"}}' | bash "$SCRIPT_DIR/file-guard/hook.sh" 2>/dev/null) || true
assert_allowed "Normal path without traversal still allowed" "$result"

# Traversal with ./ prefix
result=$(echo '{"tool_name":"Write","tool_input":{"file_path":"./subdir/../secrets.json"}}' | bash "$SCRIPT_DIR/file-guard/hook.sh" 2>/dev/null) || true
assert_blocked "./subdir/../secrets.json traversal with ./ prefix caught" "$result"

# ============================================================
# TEST 3: JSON injection in bash-guard
# ============================================================
echo ""
echo "--- JSON injection: bash-guard ---"

# Config with deny rule containing special chars
BASH_CONFIG="$TMPDIR/.bash-guard"
export BASH_GUARD_CONFIG="$BASH_CONFIG"
cat > "$BASH_CONFIG" <<'EOF'
deny: mycommand
EOF

result=$(echo '{"tool_name":"Bash","tool_input":{"command":"mycommand with \"quotes\""}}' | bash "$SCRIPT_DIR/bash-guard/hook.sh" 2>/dev/null) || true
assert_valid_json "bash-guard block with quotes in command produces valid JSON" "$result"
assert_blocked "bash-guard deny rule still works" "$result"
unset BASH_GUARD_CONFIG

# ============================================================
# TEST 4: JSON injection in git-safe
# ============================================================
echo ""
echo "--- JSON injection: git-safe ---"

result=$(echo '{"tool_name":"Bash","tool_input":{"command":"git push --force origin \"my-branch\""}}' | bash "$SCRIPT_DIR/git-safe/hook.sh" 2>/dev/null) || true
assert_valid_json "git-safe block with quotes produces valid JSON" "$result"
assert_blocked "git-safe force push still blocked" "$result"

# ============================================================
# TEST 5: JSON injection in branch-guard
# ============================================================
echo ""
echo "--- JSON injection: branch-guard ---"

# branch-guard depends on the current git branch, so we test the block() function indirectly
# We need to be on a protected branch for this test
CURRENT=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [ "$CURRENT" = "main" ] || [ "$CURRENT" = "master" ]; then
  result=$(echo '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"test with \\\"quotes\\\"\""}}' | bash "$SCRIPT_DIR/branch-guard/hook.sh" 2>/dev/null) || true
  assert_valid_json "branch-guard block produces valid JSON" "$result"
  assert_blocked "branch-guard blocks commit on main" "$result"
else
  echo "  SKIP: branch-guard JSON test (not on main/master, on: $CURRENT)"
fi

# ============================================================
# SUMMARY
# ============================================================
echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed (of $((PASS + FAIL)) assertions)"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
