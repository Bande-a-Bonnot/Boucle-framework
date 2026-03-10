#!/bin/bash
# Tests for git-safe hook
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/hook.sh"
PASS=0
FAIL=0
TOTAL=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_blocked() {
  local desc="$1"
  local input="$2"
  TOTAL=$((TOTAL + 1))

  result=$(echo "$input" | bash "$HOOK" 2>/dev/null || true)
  if echo "$result" | grep -q '"decision":"block"'; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}PASS${NC}: $desc"
  else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}FAIL${NC}: $desc (expected block, got: $result)"
  fi
}

assert_allowed() {
  local desc="$1"
  local input="$2"
  TOTAL=$((TOTAL + 1))

  result=$(echo "$input" | bash "$HOOK" 2>/dev/null || true)
  if echo "$result" | grep -q '"decision":"block"'; then
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}FAIL${NC}: $desc (expected allow, got: $result)"
  else
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}PASS${NC}: $desc"
  fi
}

echo "=== git-safe tests ==="
echo ""

# --- Non-git tools should pass through ---
echo "Tool filtering:"
assert_allowed "Write tool passes through" \
  '{"tool_name":"Write","tool_input":{"file_path":"test.txt","content":"hi"}}'
assert_allowed "Edit tool passes through" \
  '{"tool_name":"Edit","tool_input":{"file_path":"test.txt"}}'
assert_allowed "Read tool passes through" \
  '{"tool_name":"Read","tool_input":{"file_path":"test.txt"}}'

# --- Safe git commands ---
echo ""
echo "Safe git commands:"
assert_allowed "git status" \
  '{"tool_name":"Bash","tool_input":{"command":"git status"}}'
assert_allowed "git log" \
  '{"tool_name":"Bash","tool_input":{"command":"git log --oneline -10"}}'
assert_allowed "git diff" \
  '{"tool_name":"Bash","tool_input":{"command":"git diff HEAD~1"}}'
assert_allowed "git add" \
  '{"tool_name":"Bash","tool_input":{"command":"git add src/main.rs"}}'
assert_allowed "git commit" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"fix: update readme\""}}'
assert_allowed "git push (normal)" \
  '{"tool_name":"Bash","tool_input":{"command":"git push origin feature-branch"}}'
assert_allowed "git pull" \
  '{"tool_name":"Bash","tool_input":{"command":"git pull origin main"}}'
assert_allowed "git fetch" \
  '{"tool_name":"Bash","tool_input":{"command":"git fetch --all"}}'
assert_allowed "git branch -d (lowercase, safe)" \
  '{"tool_name":"Bash","tool_input":{"command":"git branch -d merged-branch"}}'
assert_allowed "git stash (save)" \
  '{"tool_name":"Bash","tool_input":{"command":"git stash"}}'
assert_allowed "git stash pop" \
  '{"tool_name":"Bash","tool_input":{"command":"git stash pop"}}'
assert_allowed "git reset (soft)" \
  '{"tool_name":"Bash","tool_input":{"command":"git reset --soft HEAD~1"}}'
assert_allowed "git reset (mixed, default)" \
  '{"tool_name":"Bash","tool_input":{"command":"git reset HEAD~1"}}'
assert_allowed "git checkout branch" \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout feature-branch"}}'
assert_allowed "git checkout -b new branch" \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout -b new-feature"}}'
assert_allowed "git clean -n (dry run)" \
  '{"tool_name":"Bash","tool_input":{"command":"git clean -n"}}'
assert_allowed "non-git command" \
  '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
assert_allowed "push --force-with-lease (safer)" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --force-with-lease origin feature"}}'

# --- Destructive operations (should be blocked) ---
echo ""
echo "Destructive operations (should block):"
assert_blocked "git push --force" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --force origin feature"}}'
assert_blocked "git push -f" \
  '{"tool_name":"Bash","tool_input":{"command":"git push -f origin feature"}}'
assert_blocked "git reset --hard" \
  '{"tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD~3"}}'
assert_blocked "git reset --hard HEAD" \
  '{"tool_name":"Bash","tool_input":{"command":"git reset --hard"}}'
assert_blocked "git checkout ." \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout ."}}'
assert_blocked "git checkout -- file" \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout -- src/main.rs"}}'
assert_blocked "git restore ." \
  '{"tool_name":"Bash","tool_input":{"command":"git restore ."}}'
assert_blocked "git clean -f" \
  '{"tool_name":"Bash","tool_input":{"command":"git clean -f"}}'
assert_blocked "git clean -fd" \
  '{"tool_name":"Bash","tool_input":{"command":"git clean -fd"}}'
assert_blocked "git clean -fdx" \
  '{"tool_name":"Bash","tool_input":{"command":"git clean -fdx"}}'
assert_blocked "git branch -D" \
  '{"tool_name":"Bash","tool_input":{"command":"git branch -D unmerged-feature"}}'
assert_blocked "git stash drop" \
  '{"tool_name":"Bash","tool_input":{"command":"git stash drop stash@{0}"}}'
assert_blocked "git stash clear" \
  '{"tool_name":"Bash","tool_input":{"command":"git stash clear"}}'
assert_blocked "git reflog expire" \
  '{"tool_name":"Bash","tool_input":{"command":"git reflog expire --expire=now --all"}}'
assert_blocked "git reflog delete" \
  '{"tool_name":"Bash","tool_input":{"command":"git reflog delete HEAD@{2}"}}'

# --- Force push to main/master (always blocked) ---
echo ""
echo "Force push to main/master (always blocked):"
assert_blocked "force push to main" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}'
assert_blocked "force push to master" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --force origin master"}}'

# --- Allowlist config ---
echo ""
echo "Allowlist config:"

# Create temp config
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

echo "allow: reset --hard" > "$TMPDIR/.git-safe"
echo "allow: push --force" >> "$TMPDIR/.git-safe"

GIT_SAFE_CONFIG="$TMPDIR/.git-safe" assert_allowed "reset --hard allowed by config" \
  '{"tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD~1"}}'

GIT_SAFE_CONFIG="$TMPDIR/.git-safe" assert_allowed "push --force allowed by config" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --force origin feature"}}'

# Force push to main still blocked even with config
GIT_SAFE_CONFIG="$TMPDIR/.git-safe" assert_blocked "force push to main still blocked with allowlist" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}'

# Disabled via env var
echo ""
echo "Disable via env var:"
TOTAL=$((TOTAL + 1))
result=$(echo '{"tool_name":"Bash","tool_input":{"command":"git push --force origin feature"}}' | GIT_SAFE_DISABLED=1 bash "$HOOK" 2>/dev/null || true)
if echo "$result" | grep -q '"decision":"block"'; then
  FAIL=$((FAIL + 1))
  echo -e "  ${RED}FAIL${NC}: disabled hook should allow everything"
else
  PASS=$((PASS + 1))
  echo -e "  ${GREEN}PASS${NC}: disabled hook allows everything"
fi

# --- Edge cases ---
echo ""
echo "Edge cases:"
assert_allowed "empty command" \
  '{"tool_name":"Bash","tool_input":{"command":""}}'
assert_allowed "git in non-git context" \
  '{"tool_name":"Bash","tool_input":{"command":"echo git is great"}}'
assert_allowed "piped git command (safe)" \
  '{"tool_name":"Bash","tool_input":{"command":"git log --oneline | head -5"}}'

# --- Results ---
echo ""
echo "========================================="
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} out of $TOTAL"
echo "========================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
