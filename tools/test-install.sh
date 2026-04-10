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

# Test 7c: bash-guard installs with explicit Bash matcher and nested hook entry
if python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    s = json.load(f)
pre = s.get('hooks', {}).get('PreToolUse', [])
matches = [
    h for h in pre
    if h.get('matcher') == 'Bash'
    and any('bash-guard' in hk.get('command', '') for hk in h.get('hooks', []))
]
assert len(matches) == 1, matches
assert 'command' not in matches[0], matches[0]
print('OK')
" "$TEST_HOME/.claude/settings.json" 2>/dev/null | grep -q OK; then
  pass "bash-guard uses explicit Bash matcher entry"
else
  fail "bash-guard matcher entry missing or legacy flat format returned"
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

# Test 9: JSONC settings preserved (not silently wiped)
echo "--- JSONC handling ---"
rm -rf "$TEST_HOME/.claude"
mkdir -p "$TEST_HOME/.claude"
cat > "$TEST_HOME/.claude/settings.json" << 'JSONC_EOF'
{
  // This is a JSONC comment
  "allowedTools": ["Bash"],
  "denyRead": [".env"],
  "hooks": {
    "PostToolUse": [
      {
        "type": "command",
        "command": "echo existing-hook"
      }
    ]
  }
}
JSONC_EOF

bash "$SCRIPT_DIR/install.sh" git-safe 2>&1 | tee "$TEST_HOME/jsonc-output.txt" >/dev/null

# Check that settings were NOT silently wiped
has_preserved=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    s = json.load(f)
has_allowed = 'allowedTools' in s
has_deny = 'denyRead' in s
has_post = len(s.get('hooks', {}).get('PostToolUse', [])) > 0
has_pre = len(s.get('hooks', {}).get('PreToolUse', [])) > 0
print('yes' if (has_allowed and has_deny and has_post and has_pre) else 'no')
" "$TEST_HOME/.claude/settings.json" 2>/dev/null)

if [ "$has_preserved" = "yes" ]; then
  pass "JSONC settings preserved after install"
else
  fail "JSONC settings lost (data loss bug)"
fi

# Check that backup was created
if [ -f "$TEST_HOME/.claude/settings.json.bak" ]; then
  pass "JSONC backup created"
else
  fail "no JSONC backup created"
fi

# Check that warning was shown
if grep -qi "jsonc\|comment" "$TEST_HOME/jsonc-output.txt" 2>/dev/null; then
  pass "JSONC warning displayed"
else
  fail "no JSONC warning shown"
fi

# Test 10: Invalid JSON (not JSONC) should error, not silently wipe
echo "--- Invalid JSON handling ---"
rm -rf "$TEST_HOME/.claude"
mkdir -p "$TEST_HOME/.claude"
echo '{invalid json content here' > "$TEST_HOME/.claude/settings.json"

if bash "$SCRIPT_DIR/install.sh" git-safe >/dev/null 2>&1; then
  # Check if settings were silently wiped
  if python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    s = json.load(f)
# If we get here, the file was replaced with valid JSON (data loss)
if 'invalid' not in str(s):
    sys.exit(1)  # settings were silently replaced
" "$TEST_HOME/.claude/settings.json" 2>/dev/null; then
    fail "invalid JSON was silently replaced (data loss)"
  else
    pass "invalid JSON handled (either errored or preserved)"
  fi
else
  pass "invalid JSON caused installer to exit (correct behavior)"
fi

# Test 11: Pure JSON (no comments) still works fine
echo "--- Pure JSON still works ---"
rm -rf "$TEST_HOME/.claude"
mkdir -p "$TEST_HOME/.claude"
echo '{"allowedTools": ["Bash"]}' > "$TEST_HOME/.claude/settings.json"

bash "$SCRIPT_DIR/install.sh" git-safe >/dev/null 2>&1

has_both=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    s = json.load(f)
has_allowed = 'allowedTools' in s
has_pre = len(s.get('hooks', {}).get('PreToolUse', [])) > 0
print('yes' if (has_allowed and has_pre) else 'no')
" "$TEST_HOME/.claude/settings.json" 2>/dev/null)

if [ "$has_both" = "yes" ]; then
  pass "pure JSON still works correctly"
else
  fail "pure JSON handling broken"
fi

# Verify no .bak file created for pure JSON
if [ ! -f "$TEST_HOME/.claude/settings.json.bak" ]; then
  pass "no unnecessary backup for pure JSON"
else
  fail "unnecessary backup created for pure JSON"
fi

# === Uninstall Tests ===
echo ""
echo "=== Uninstall Tests ==="

# Test 12: Uninstall single hook removes directory
echo "--- Uninstall single hook ---"
rm -rf "$TEST_HOME/.claude"
bash "$SCRIPT_DIR/install.sh" read-once git-safe >/dev/null 2>&1

bash "$SCRIPT_DIR/install.sh" uninstall read-once >/dev/null 2>&1

if [ ! -d "$TEST_HOME/.claude/read-once" ]; then
  pass "uninstall removed hook directory"
else
  fail "uninstall did not remove hook directory"
fi

# Test 13: Uninstall removes hook from settings.json
has_read_once=$(python3 -c "
import json, sys
def get_cmds(entry):
    c = entry.get('command', '')
    if c: return [c]
    return [h.get('command','') for h in entry.get('hooks',[])]
with open(sys.argv[1]) as f:
    s = json.load(f)
hooks = s.get('hooks', {}).get('PreToolUse', [])
found = any('read-once' in c for h in hooks for c in get_cmds(h))
print('yes' if found else 'no')
" "$TEST_HOME/.claude/settings.json" 2>/dev/null)

if [ "$has_read_once" = "no" ]; then
  pass "uninstall removed hook from settings.json"
else
  fail "uninstall left hook in settings.json"
fi

# Test 14: Uninstall preserves other hooks
has_git_safe=$(python3 -c "
import json, sys
def get_cmds(entry):
    c = entry.get('command', '')
    if c: return [c]
    return [h.get('command','') for h in entry.get('hooks',[])]
with open(sys.argv[1]) as f:
    s = json.load(f)
hooks = s.get('hooks', {}).get('PreToolUse', [])
found = any('git-safe' in c for h in hooks for c in get_cmds(h))
print('yes' if found else 'no')
" "$TEST_HOME/.claude/settings.json" 2>/dev/null)

if [ "$has_git_safe" = "yes" ]; then
  pass "uninstall preserved other hooks"
else
  fail "uninstall removed other hooks"
fi

if [ -d "$TEST_HOME/.claude/git-safe" ]; then
  pass "uninstall preserved other hook directory"
else
  fail "uninstall removed other hook directory"
fi

# Test 15: Uninstall unknown hook warns
echo "--- Uninstall unknown hook ---"
output=$(bash "$SCRIPT_DIR/install.sh" uninstall nonexistent 2>&1 || true)
if echo "$output" | grep -q "Unknown hook"; then
  pass "uninstall unknown hook warned"
else
  fail "uninstall unknown hook not handled"
fi

# Test 16: Uninstall hook not installed skips
echo "--- Uninstall not-installed hook ---"
output=$(bash "$SCRIPT_DIR/install.sh" uninstall branch-guard 2>&1 || true)
if echo "$output" | grep -qi "skip\|not installed"; then
  pass "uninstall skipped non-installed hook"
else
  fail "uninstall did not skip non-installed hook"
fi

# Test 17: Uninstall all
echo "--- Uninstall all ---"
rm -rf "$TEST_HOME/.claude"
bash "$SCRIPT_DIR/install.sh" bash-guard git-safe file-guard >/dev/null 2>&1
bash "$SCRIPT_DIR/install.sh" uninstall all >/dev/null 2>&1

remaining=0
for hook in bash-guard git-safe file-guard; do
  if [ -d "$TEST_HOME/.claude/${hook}" ]; then
    remaining=$((remaining + 1))
  fi
done

if [ "$remaining" -eq 0 ]; then
  pass "uninstall all removed all hook directories"
else
  fail "uninstall all left $remaining hook directories"
fi

# Check settings.json is clean
hook_count=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    s = json.load(f)
hooks = s.get('hooks', {})
total = sum(len(v) for v in hooks.values())
print(total)
" "$TEST_HOME/.claude/settings.json" 2>/dev/null)

if [ "$hook_count" = "0" ] || [ -z "$hook_count" ]; then
  pass "uninstall all cleaned settings.json"
else
  fail "uninstall all left $hook_count hooks in settings.json"
fi

# Test 18: Uninstall preserves non-hook settings
echo "--- Uninstall preserves other settings ---"
rm -rf "$TEST_HOME/.claude"
mkdir -p "$TEST_HOME/.claude"
echo '{"allowedTools": ["Bash"], "denyRead": [".env"]}' > "$TEST_HOME/.claude/settings.json"
bash "$SCRIPT_DIR/install.sh" read-once >/dev/null 2>&1
bash "$SCRIPT_DIR/install.sh" uninstall read-once >/dev/null 2>&1

preserved=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    s = json.load(f)
has_tools = 'allowedTools' in s
has_deny = 'denyRead' in s
print('yes' if (has_tools and has_deny) else 'no')
" "$TEST_HOME/.claude/settings.json" 2>/dev/null)

if [ "$preserved" = "yes" ]; then
  pass "uninstall preserved non-hook settings"
else
  fail "uninstall lost non-hook settings"
fi

# Test 19: Uninstall no args shows usage
echo "--- Uninstall usage ---"
output=$(bash "$SCRIPT_DIR/install.sh" uninstall 2>&1 || true)
if echo "$output" | grep -qi "usage\|Usage"; then
  pass "uninstall no args shows usage"
else
  fail "uninstall no args missing usage"
fi

# Test 20: Install after uninstall works (round-trip)
echo "--- Install after uninstall ---"
rm -rf "$TEST_HOME/.claude"
bash "$SCRIPT_DIR/install.sh" read-once >/dev/null 2>&1
bash "$SCRIPT_DIR/install.sh" uninstall read-once >/dev/null 2>&1
bash "$SCRIPT_DIR/install.sh" read-once >/dev/null 2>&1

if [ -f "$TEST_HOME/.claude/read-once/hook.sh" ]; then
  pass "reinstall after uninstall works"
else
  fail "reinstall after uninstall failed"
fi

reinstall_count=$(python3 -c "
import json, sys
def get_cmds(entry):
    c = entry.get('command', '')
    if c: return [c]
    return [h.get('command','') for h in entry.get('hooks',[])]
with open(sys.argv[1]) as f:
    s = json.load(f)
hooks = s.get('hooks', {}).get('PreToolUse', [])
n = sum(1 for h in hooks for c in get_cmds(h) if 'read-once' in c)
print(n)
" "$TEST_HOME/.claude/settings.json" 2>/dev/null)

if [ "$reinstall_count" = "1" ]; then
  pass "no duplicates after reinstall"
else
  fail "duplicates after reinstall ($reinstall_count)"
fi

# === List Tests ===
echo ""
echo "=== List Tests ==="

# Test 21: List shows installed hooks
echo "--- List installed hooks ---"
rm -rf "$TEST_HOME/.claude"
bash "$SCRIPT_DIR/install.sh" read-once git-safe >/dev/null 2>&1

output=$(bash "$SCRIPT_DIR/install.sh" list 2>&1)
if echo "$output" | grep -q "read-once" && echo "$output" | grep -q "git-safe"; then
  pass "list shows installed hooks"
else
  fail "list missing installed hooks"
fi

# Test 22: List does not show uninstalled hooks
if echo "$output" | grep -q "bash-guard"; then
  fail "list shows non-installed hook"
else
  pass "list hides non-installed hooks"
fi

# Test 23: List shows count
if echo "$output" | grep -q "2 hook"; then
  pass "list shows correct count"
else
  fail "list count wrong"
fi

# Test 24: List with nothing installed
echo "--- List empty ---"
rm -rf "$TEST_HOME/.claude"
mkdir -p "$TEST_HOME/.claude"
output=$(bash "$SCRIPT_DIR/install.sh" list 2>&1)
if echo "$output" | grep -qi "no hooks"; then
  pass "list reports no hooks"
else
  fail "list does not report empty state"
fi

# === Upgrade Tests ===
echo ""
echo "=== Upgrade Tests ==="

# Test 25: Upgrade with no hooks installed
echo "--- Upgrade empty ---"
rm -rf "$TEST_HOME/.claude"
mkdir -p "$TEST_HOME/.claude"
output=$(bash "$SCRIPT_DIR/install.sh" upgrade 2>&1)
if echo "$output" | grep -qi "up to date"; then
  pass "upgrade with no hooks says up to date"
else
  fail "upgrade with no hooks unclear output"
fi

# Test 26: Upgrade fresh install (already up to date)
echo "--- Upgrade fresh install ---"
rm -rf "$TEST_HOME/.claude"
bash "$SCRIPT_DIR/install.sh" git-safe >/dev/null 2>&1

output=$(bash "$SCRIPT_DIR/install.sh" upgrade 2>&1)
if echo "$output" | grep -qi "up to date"; then
  pass "upgrade of fresh install says up to date"
else
  fail "upgrade of fresh install not detected as current"
fi

# Test 27: Upgrade detects modified hook
echo "--- Upgrade modified hook ---"
rm -rf "$TEST_HOME/.claude"
bash "$SCRIPT_DIR/install.sh" git-safe >/dev/null 2>&1

# Modify the hook to simulate outdated version
echo "# outdated version" > "$TEST_HOME/.claude/git-safe/hook.sh"

output=$(bash "$SCRIPT_DIR/install.sh" upgrade 2>&1)
if echo "$output" | grep -qi "updated"; then
  pass "upgrade detected and updated modified hook"
else
  fail "upgrade did not detect modified hook"
fi

# Verify the hook was actually restored
if grep -q "outdated" "$TEST_HOME/.claude/git-safe/hook.sh" 2>/dev/null; then
  fail "upgrade did not replace outdated hook"
else
  pass "upgrade replaced outdated hook content"
fi

# Test 28: Upgrade preserves non-installed hooks
echo "--- Upgrade only touches installed ---"
rm -rf "$TEST_HOME/.claude"
bash "$SCRIPT_DIR/install.sh" git-safe >/dev/null 2>&1

output=$(bash "$SCRIPT_DIR/install.sh" upgrade 2>&1)
# Should not mention read-once or other non-installed hooks
if echo "$output" | grep -q "read-once"; then
  fail "upgrade mentioned non-installed hook"
else
  pass "upgrade only processes installed hooks"
fi

# Test 29: Upgrade preserves settings.json
echo "--- Upgrade preserves settings ---"
rm -rf "$TEST_HOME/.claude"
mkdir -p "$TEST_HOME/.claude"
echo '{"allowedTools": ["Bash"]}' > "$TEST_HOME/.claude/settings.json"
bash "$SCRIPT_DIR/install.sh" git-safe >/dev/null 2>&1
echo "# outdated" > "$TEST_HOME/.claude/git-safe/hook.sh"

bash "$SCRIPT_DIR/install.sh" upgrade >/dev/null 2>&1

preserved=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    s = json.load(f)
print('yes' if 'allowedTools' in s else 'no')
" "$TEST_HOME/.claude/settings.json" 2>/dev/null)

if [ "$preserved" = "yes" ]; then
  pass "upgrade preserved settings.json"
else
  fail "upgrade corrupted settings.json"
fi

# Test 30: Upgrade read-once also updates CLI
echo "--- Upgrade read-once extras ---"
rm -rf "$TEST_HOME/.claude"
bash "$SCRIPT_DIR/install.sh" read-once >/dev/null 2>&1

# Modify both files
echo "# outdated hook" > "$TEST_HOME/.claude/read-once/hook.sh"
echo "# outdated cli" > "$TEST_HOME/.claude/read-once/read-once"

bash "$SCRIPT_DIR/install.sh" upgrade >/dev/null 2>&1

if grep -q "outdated" "$TEST_HOME/.claude/read-once/hook.sh" 2>/dev/null; then
  fail "upgrade did not update read-once hook"
else
  pass "upgrade updated read-once hook"
fi

if grep -q "outdated" "$TEST_HOME/.claude/read-once/read-once" 2>/dev/null; then
  fail "upgrade did not update read-once CLI"
else
  pass "upgrade updated read-once CLI"
fi

# Test 31: Help subcommand
echo "--- Help output ---"
output=$(bash "$SCRIPT_DIR/install.sh" help 2>&1)
if echo "$output" | grep -q "Commands:"; then
  pass "help shows commands section"
else
  fail "help missing commands section"
fi

if echo "$output" | grep -q "recommended"; then
  pass "help mentions recommended"
else
  fail "help missing recommended command"
fi

if echo "$output" | grep -q "Available hooks:"; then
  pass "help shows available hooks"
else
  fail "help missing available hooks"
fi

if echo "$output" | grep -q "Examples:"; then
  pass "help shows examples"
else
  fail "help missing examples"
fi

# Test 32: --help flag
echo "--- --help flag ---"
output2=$(bash "$SCRIPT_DIR/install.sh" --help 2>&1)
if echo "$output2" | grep -q "Commands:"; then
  pass "--help works same as help"
else
  fail "--help does not show help"
fi

# Test 33: -h flag
echo "--- -h flag ---"
output3=$(bash "$SCRIPT_DIR/install.sh" -h 2>&1)
if echo "$output3" | grep -q "Commands:"; then
  pass "-h works same as help"
else
  fail "-h does not show help"
fi

# Test 34: Help exits 0
echo "--- Help exit code ---"
if bash "$SCRIPT_DIR/install.sh" help >/dev/null 2>&1; then
  pass "help exits 0"
else
  fail "help exits non-zero"
fi

# ---- Backup/Restore Tests ----

echo "--- Backup creates snapshot ---"
# Fresh HOME for backup tests
rm -rf "$TEST_HOME/.claude"
mkdir -p "$TEST_HOME/.claude"
cat > "$TEST_HOME/.claude/settings.json" << 'EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "command": "/home/test/.claude/bash-guard/hook.sh"
      }
    ]
  }
}
EOF
output=$(bash "$SCRIPT_DIR/install.sh" backup 2>&1)
if echo "$output" | grep -q "Backup created"; then
  pass "backup reports success"
else
  fail "backup did not report success: $output"
fi

if ls "$TEST_HOME/.claude/backups"/settings.*.json >/dev/null 2>&1; then
  pass "backup file created"
else
  fail "no backup file found"
fi

# Verify backup content matches original
backup_file=$(ls -t "$TEST_HOME/.claude/backups"/settings.*.json | head -1)
if diff -q "$TEST_HOME/.claude/settings.json" "$backup_file" >/dev/null 2>&1; then
  pass "backup content matches original"
else
  fail "backup content differs from original"
fi

if echo "$output" | grep -q "1 unique hook"; then
  pass "backup counts hooks"
else
  fail "backup hook count missing"
fi

echo "--- Backup list ---"
output=$(bash "$SCRIPT_DIR/install.sh" backup list 2>&1)
if echo "$output" | grep -q "settings\..*\.json"; then
  pass "backup list shows files"
else
  fail "backup list shows no files"
fi
if echo "$output" | grep -q "1 backup"; then
  pass "backup list shows count"
else
  fail "backup list count wrong"
fi

echo "--- Backup list empty ---"
rm -rf "$TEST_HOME/.claude/backups"
output=$(bash "$SCRIPT_DIR/install.sh" backup list 2>&1)
if echo "$output" | grep -q "No backups found"; then
  pass "backup list empty message"
else
  fail "backup list should show no backups"
fi

echo "--- Backup no settings ---"
rm -f "$TEST_HOME/.claude/settings.json"
output=$(bash "$SCRIPT_DIR/install.sh" backup 2>&1)
if echo "$output" | grep -q "Nothing to back up"; then
  pass "backup with no settings.json"
else
  fail "backup should warn about missing settings.json"
fi

echo "--- Restore latest ---"
# Re-create settings and a backup
cat > "$TEST_HOME/.claude/settings.json" << 'EOF'
{"hooks": {"PreToolUse": [{"matcher": "Bash", "command": "/test/bash-guard/hook.sh"}]}}
EOF
bash "$SCRIPT_DIR/install.sh" backup >/dev/null 2>&1

# Wipe settings (simulating auto-update)
echo '{}' > "$TEST_HOME/.claude/settings.json"

output=$(bash "$SCRIPT_DIR/install.sh" restore 2>&1)
if echo "$output" | grep -q "Restored"; then
  pass "restore reports success"
else
  fail "restore did not report success: $output"
fi

if python3 -c "
import json
with open('$TEST_HOME/.claude/settings.json') as f:
    s = json.load(f)
assert 'hooks' in s
assert 'PreToolUse' in s['hooks']
print('OK')
" 2>/dev/null | grep -q OK; then
  pass "restore recovered hooks"
else
  fail "restore did not recover hooks"
fi

echo "--- Restore saves pre-restore copy ---"
if ls "$TEST_HOME/.claude/backups"/settings.pre-restore-*.json >/dev/null 2>&1; then
  pass "pre-restore backup created"
else
  fail "pre-restore backup not found"
fi

echo "--- Restore specific file ---"
# Create a second distinct backup (sleep to ensure different timestamp)
sleep 1
cat > "$TEST_HOME/.claude/settings.json" << 'EOF'
{"hooks": {"PreToolUse": [{"matcher": "Write", "command": "/test/file-guard/hook.sh"}]}}
EOF
bash "$SCRIPT_DIR/install.sh" backup >/dev/null 2>&1

# Find the first backup (older one, has bash-guard)
first_backup=$(ls "$TEST_HOME/.claude/backups"/settings.2*.json | head -1)
first_name=$(basename "$first_backup")

# Wipe and restore the specific older backup
echo '{}' > "$TEST_HOME/.claude/settings.json"
output=$(bash "$SCRIPT_DIR/install.sh" restore "$first_name" 2>&1)
if echo "$output" | grep -q "Restored"; then
  pass "restore specific file works"
else
  fail "restore specific file failed: $output"
fi

if python3 -c "
import json
with open('$TEST_HOME/.claude/settings.json') as f:
    s = json.load(f)
cmds = [h.get('command','') for h in s.get('hooks',{}).get('PreToolUse',[])]
assert any('bash-guard' in c for c in cmds), f'Expected bash-guard, got {cmds}'
print('OK')
" 2>/dev/null | grep -q OK; then
  pass "restore specific file has correct content"
else
  fail "restore specific file has wrong content"
fi

echo "--- Restore nonexistent file ---"
if output=$(bash "$SCRIPT_DIR/install.sh" restore "settings.fake.json" 2>&1); then
  fail "restore nonexistent file should fail"
else
  if echo "$output" | grep -q "not found"; then
    pass "restore nonexistent file fails"
  else
    fail "restore nonexistent file wrong message: $output"
  fi
fi

echo "--- Restore no backups ---"
rm -rf "$TEST_HOME/.claude/backups"
if output=$(bash "$SCRIPT_DIR/install.sh" restore 2>&1); then
  fail "restore should fail with no backups"
else
  if echo "$output" | grep -q "No backups found"; then
    pass "restore with no backups fails"
  else
    fail "restore no backups wrong message: $output"
  fi
fi

echo "--- Multiple backups ---"
rm -rf "$TEST_HOME/.claude/backups"
mkdir -p "$TEST_HOME/.claude"
cat > "$TEST_HOME/.claude/settings.json" << 'EOF'
{"version": 1}
EOF
bash "$SCRIPT_DIR/install.sh" backup >/dev/null 2>&1
sleep 1
cat > "$TEST_HOME/.claude/settings.json" << 'EOF'
{"version": 2}
EOF
bash "$SCRIPT_DIR/install.sh" backup >/dev/null 2>&1

# Restore should pick the latest (version 2)
echo '{}' > "$TEST_HOME/.claude/settings.json"
bash "$SCRIPT_DIR/install.sh" restore >/dev/null 2>&1
if python3 -c "
import json
with open('$TEST_HOME/.claude/settings.json') as f:
    s = json.load(f)
assert s.get('version') == 2, f'Expected version 2, got {s}'
print('OK')
" 2>/dev/null | grep -q OK; then
  pass "restore picks most recent backup"
else
  fail "restore did not pick most recent backup"
fi

output=$(bash "$SCRIPT_DIR/install.sh" backup list 2>&1)
# 2 manual backups + 1 pre-restore = 3 total
if echo "$output" | grep -q "backup.* found"; then
  pass "backup list counts correctly"
else
  fail "backup list should show backup count"
fi

echo "--- Doctor subcommand ---"

# Re-install a hook so doctor has something to check
bash "$SCRIPT_DIR/install.sh" bash-guard >/dev/null 2>&1
output=$(bash "$SCRIPT_DIR/install.sh" doctor 2>&1)
if echo "$output" | grep -q "Running diagnostics"; then
  pass "doctor runs successfully"
else
  fail "doctor did not run"
fi

if echo "$output" | grep -q "settings.json exists"; then
  pass "doctor detects settings.json"
else
  fail "doctor did not detect settings.json"
fi

if echo "$output" | grep -q "OK.*bash-guard"; then
  pass "doctor detects installed hook"
else
  fail "doctor did not detect installed hook"
fi

if echo "$output" | grep -qi "not installed"; then
  pass "doctor shows uninstalled hooks"
else
  fail "doctor did not show uninstalled hooks"
fi

# Doctor with no settings.json
mv "$TEST_HOME/.claude/settings.json" "$TEST_HOME/.claude/settings.json.bak"
output=$(bash "$SCRIPT_DIR/install.sh" doctor 2>&1 || true)
if echo "$output" | grep -qi "error.*settings.json not found"; then
  pass "doctor reports missing settings.json"
else
  fail "doctor did not report missing settings.json"
fi
mv "$TEST_HOME/.claude/settings.json.bak" "$TEST_HOME/.claude/settings.json"

# Doctor with broken JSON
echo "{{invalid json" > "$TEST_HOME/.claude/settings.json"
output=$(bash "$SCRIPT_DIR/install.sh" doctor 2>&1 || true)
if echo "$output" | grep -qi "error.*not valid"; then
  pass "doctor reports invalid JSON"
else
  fail "doctor did not report invalid JSON"
fi

# Doctor with JSONC (comments in settings.json)
cat > "$TEST_HOME/.claude/settings.json" <<'JSONC_EOF'
{
  // This is a comment
  "hooks": {}
}
JSONC_EOF
output=$(bash "$SCRIPT_DIR/install.sh" doctor 2>&1 || true)
if echo "$output" | grep -qi "warn.*jsonc\|warn.*comment"; then
  pass "doctor warns about JSONC comments"
else
  fail "doctor did not warn about JSONC comments"
fi

# Restore valid settings for remaining tests
cat > "$TEST_HOME/.claude/settings.json" <<'EOF'
{"hooks": {}}
EOF

# Doctor with orphaned entry (hook in settings.json but no files)
cat > "$TEST_HOME/.claude/settings.json" <<'EOF'
{"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "/nonexistent/hook.sh", "timeout": 5000}]}]}}
EOF
output=$(bash "$SCRIPT_DIR/install.sh" doctor 2>&1 || true)
if echo "$output" | grep -qi "orphan"; then
  pass "doctor detects orphaned entries"
else
  fail "doctor did not detect orphaned entries"
fi

# Doctor with non-executable hook.sh
chmod -x "$TEST_HOME/.claude/bash-guard/hook.sh" 2>/dev/null || true
cat > "$TEST_HOME/.claude/settings.json" <<'EOF'
{"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "placeholder", "timeout": 5000}]}]}}
EOF
# Re-create a proper settings entry for bash-guard
bash "$SCRIPT_DIR/install.sh" bash-guard >/dev/null 2>&1
chmod -x "$TEST_HOME/.claude/bash-guard/hook.sh"
output=$(bash "$SCRIPT_DIR/install.sh" doctor 2>&1 || true)
if echo "$output" | grep -qi "not executable"; then
  pass "doctor detects non-executable hook"
else
  fail "doctor did not detect non-executable hook"
fi
chmod +x "$TEST_HOME/.claude/bash-guard/hook.sh" 2>/dev/null || true

# Doctor with hook not registered in settings.json
cat > "$TEST_HOME/.claude/settings.json" <<'EOF'
{"hooks": {}}
EOF
output=$(bash "$SCRIPT_DIR/install.sh" doctor 2>&1 || true)
if echo "$output" | grep -qi "not registered"; then
  pass "doctor detects unregistered hooks"
else
  fail "doctor did not detect unregistered hooks"
fi

# Doctor with backup check
if echo "$output" | grep -qi "backup"; then
  pass "doctor checks backups"
else
  fail "doctor did not check backups"
fi

# Doctor exit code on errors
cat > "$TEST_HOME/.claude/settings.json" <<'EOF'
not valid json at all
EOF
if bash "$SCRIPT_DIR/install.sh" doctor >/dev/null 2>&1; then
  fail "doctor should exit non-zero on errors"
else
  pass "doctor exits non-zero on errors"
fi

echo ""
echo "=== Check Subcommand Tests ==="

# Check subcommand appears in help
output=$(bash "$SCRIPT_DIR/install.sh" help 2>&1)
if echo "$output" | grep -q "check"; then
  pass "help lists check subcommand"
else
  fail "help does not list check subcommand"
fi

if echo "$output" | grep -q "safety audit"; then
  pass "help describes check as safety audit"
else
  fail "help missing safety audit description for check"
fi

# Check subcommand requires network (will fail in test env, but should not crash)
output=$(bash "$SCRIPT_DIR/install.sh" check 2>&1 || true)
# It should either run safety-check or show a network error, not crash
if echo "$output" | grep -qi "safety audit\|Running\|Warning.*network\|Warning.*download"; then
  pass "check subcommand runs without crash"
else
  fail "check subcommand did not produce expected output: $output"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed (total $((PASS + FAIL)))"
[ "$FAIL" -eq 0 ] || exit 1
