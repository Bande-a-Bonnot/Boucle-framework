#!/bin/bash
# Tests for unified hook installer
set -euo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# Create temp home for testing
TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

export HOME="$TEST_HOME"

echo "=== Unified Installer Tests ==="

# Test 1: Valid bash syntax
echo "--- Syntax ---"
if bash -n "$SCRIPT_DIR/install.sh" 2>/dev/null; then
  pass "install.sh has valid syntax"
else
  fail "install.sh syntax error"
fi

# Test 2: Install single hook
echo "--- Single hook (read-once) ---"
bash "$SCRIPT_DIR/install.sh" read-once >/dev/null 2>&1

if [ -f "$TEST_HOME/.claude/read-once/hook.sh" ]; then
  pass "hook.sh downloaded"
else
  fail "hook.sh not found"
fi

if [ -f "$TEST_HOME/.claude/read-once/read-once" ]; then
  pass "CLI downloaded"
else
  fail "CLI not found"
fi

if [ -x "$TEST_HOME/.claude/read-once/hook.sh" ]; then
  pass "hook.sh is executable"
else
  fail "hook.sh not executable"
fi

# Test 3: Settings created
echo "--- Settings ---"
if [ -f "$TEST_HOME/.claude/settings.json" ]; then
  pass "settings.json created"
else
  fail "settings.json not created"
fi

if python3 -c "
import json, sys
def get_cmds(entry):
    '''Extract commands from flat or nested hook format'''
    c = entry.get('command', '')
    if c: return [c]
    return [h.get('command','') for h in entry.get('hooks',[])]
with open(sys.argv[1]) as f:
    s = json.load(f)
hooks = s.get('hooks', {}).get('PreToolUse', [])
found = any('read-once' in c for h in hooks for c in get_cmds(h))
sys.exit(0 if found else 1)
" "$TEST_HOME/.claude/settings.json" 2>/dev/null; then
  pass "read-once in settings.json"
else
  fail "read-once not in settings.json"
fi

# Test 4: Multiple hooks
echo "--- Multiple hooks ---"
rm -rf "$TEST_HOME/.claude"
bash "$SCRIPT_DIR/install.sh" file-guard git-safe >/dev/null 2>&1

if [ -f "$TEST_HOME/.claude/file-guard/hook.sh" ] && [ -f "$TEST_HOME/.claude/git-safe/hook.sh" ]; then
  pass "both hooks downloaded"
else
  fail "missing hooks"
fi

if [ -f "$TEST_HOME/.claude/file-guard/init.sh" ]; then
  pass "file-guard init.sh downloaded"
else
  fail "file-guard init.sh missing"
fi

count=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    s = json.load(f)
hooks = s.get('hooks', {}).get('PreToolUse', [])
print(len(hooks))
" "$TEST_HOME/.claude/settings.json" 2>/dev/null)

if [ "$count" = "2" ]; then
  pass "2 hooks in settings.json"
else
  fail "expected 2 hooks, got $count"
fi

# Test 5: Idempotency
echo "--- Idempotency ---"
bash "$SCRIPT_DIR/install.sh" file-guard >/dev/null 2>&1

count=$(python3 -c "
import json, sys
def get_cmds(entry):
    c = entry.get('command', '')
    if c: return [c]
    return [h.get('command','') for h in entry.get('hooks',[])]
with open(sys.argv[1]) as f:
    s = json.load(f)
hooks = s.get('hooks', {}).get('PreToolUse', [])
n = sum(1 for h in hooks for c in get_cmds(h) if 'file-guard' in c)
print(n)
" "$TEST_HOME/.claude/settings.json" 2>/dev/null)

if [ "$count" = "1" ]; then
  pass "no duplicates after re-install"
else
  fail "duplicates found ($count)"
fi

# Test 6: Unknown hook
echo "--- Unknown hook ---"
output=$(bash "$SCRIPT_DIR/install.sh" nonexistent 2>&1 || true)
if echo "$output" | grep -q "Unknown hook"; then
  pass "unknown hook warned"
else
  fail "unknown hook not handled"
fi

# Test 7: All four hooks
echo "--- All hooks ---"
rm -rf "$TEST_HOME/.claude"
bash "$SCRIPT_DIR/install.sh" read-once file-guard git-safe bash-guard >/dev/null 2>&1

count=$(python3 -c "
import json, sys
def get_cmds(entry):
    c = entry.get('command', '')
    if c: return [c]
    return [h.get('command','') for h in entry.get('hooks',[])]
with open(sys.argv[1]) as f:
    s = json.load(f)
hooks = s.get('hooks', {}).get('PreToolUse', [])
names = set()
for h in hooks:
    for c in get_cmds(h):
        for name in ['read-once','file-guard','git-safe','bash-guard']:
            if name in c: names.add(name)
print(len(names))
" "$TEST_HOME/.claude/settings.json" 2>/dev/null)

if [ "$count" = "4" ]; then
  pass "all 4 hooks installed"
else
  fail "expected 4, got $count"
fi

# Test 7b: bash-guard hook file exists
if [ -f "$TEST_HOME/.claude/bash-guard/hook.sh" ]; then
  pass "bash-guard hook.sh downloaded"
else
  fail "bash-guard hook.sh missing"
fi

# Test 8: Existing settings preserved
echo "--- Preserves existing settings ---"
rm -rf "$TEST_HOME/.claude"
mkdir -p "$TEST_HOME/.claude"
echo '{"allowedTools": ["Bash"], "hooks": {"PostToolUse": [{"type": "command", "command": "echo hi"}]}}' > "$TEST_HOME/.claude/settings.json"
bash "$SCRIPT_DIR/install.sh" read-once >/dev/null 2>&1

has_both=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    s = json.load(f)
has_allowed = 'allowedTools' in s
has_post = len(s.get('hooks', {}).get('PostToolUse', [])) > 0
has_pre = len(s.get('hooks', {}).get('PreToolUse', [])) > 0
print('yes' if (has_allowed and has_post and has_pre) else 'no')
" "$TEST_HOME/.claude/settings.json" 2>/dev/null)

if [ "$has_both" = "yes" ]; then
  pass "existing settings preserved"
else
  fail "existing settings lost"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed (total $((PASS + FAIL)))"
[ "$FAIL" -eq 0 ] || exit 1
