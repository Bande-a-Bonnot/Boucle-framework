#!/bin/bash
# Tests for branch-guard hook
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

# Create a temp git repo for testing (we need git rev-parse to work)
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT
git init -q "$TMPDIR/test-repo"
cd "$TMPDIR/test-repo"
git config user.email "test@test.local"
git config user.name "Test"
git checkout -q -b main 2>/dev/null || true
# Need at least one commit for branch operations
git commit -q --allow-empty -m "init"

assert_blocked() {
  local desc="$1"
  local input="$2"
  TOTAL=$((TOTAL + 1))

  result=$(echo "$input" | bash "$HOOK" 2>/dev/null || true)
  if echo "$result" | grep -q '"permissionDecision":"deny"'; then
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
  if echo "$result" | grep -q '"permissionDecision":"deny"'; then
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}FAIL${NC}: $desc (expected allow, got: $result)"
  else
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}PASS${NC}: $desc"
  fi
}

echo "=== branch-guard tests ==="
echo ""

# --- Non-commit tools should pass through ---
echo "Tool filtering:"
assert_allowed "Write tool passes through" \
  '{"tool_name":"Write","tool_input":{"file_path":"test.txt","content":"hi"}}'
assert_allowed "Edit tool passes through" \
  '{"tool_name":"Edit","tool_input":{"file_path":"test.txt"}}'
assert_allowed "Read tool passes through" \
  '{"tool_name":"Read","tool_input":{"file_path":"test.txt"}}'

# --- Non-commit git commands pass through ---
echo ""
echo "Non-commit git commands:"
assert_allowed "git status" \
  '{"tool_name":"Bash","tool_input":{"command":"git status"}}'
assert_allowed "git push" \
  '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
assert_allowed "git pull" \
  '{"tool_name":"Bash","tool_input":{"command":"git pull origin main"}}'
assert_allowed "git diff" \
  '{"tool_name":"Bash","tool_input":{"command":"git diff HEAD~1"}}'
assert_allowed "git add" \
  '{"tool_name":"Bash","tool_input":{"command":"git add ."}}'
assert_allowed "git log" \
  '{"tool_name":"Bash","tool_input":{"command":"git log --oneline"}}'
assert_allowed "git merge" \
  '{"tool_name":"Bash","tool_input":{"command":"git merge feature-branch"}}'
assert_allowed "git rebase" \
  '{"tool_name":"Bash","tool_input":{"command":"git rebase main"}}'
assert_allowed "git stash" \
  '{"tool_name":"Bash","tool_input":{"command":"git stash"}}'
assert_allowed "non-git command" \
  '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
assert_allowed "empty command" \
  '{"tool_name":"Bash","tool_input":{"command":""}}'

# --- Commits on main (should be blocked) ---
echo ""
echo "Commits on main (should block):"
git checkout -q main
assert_blocked "git commit on main" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"fix: something\""}}'
assert_blocked "git commit with heredoc on main" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"$(cat <<EOF\nfirst line\nsecond line\nEOF\n)\""}}'
assert_blocked "git commit --all on main" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit --all -m \"update\""}}'
assert_blocked "git commit -a on main" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -a -m \"update\""}}'
assert_blocked "git commit with long flags on main" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit --message=\"something\" --signoff"}}'

# --- Amend should be allowed (even on protected branches) ---
echo ""
echo "Amend allowed on protected branches:"
assert_allowed "git commit --amend on main" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit --amend -m \"fix typo\""}}'
assert_allowed "git commit --amend --no-edit on main" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit --amend --no-edit"}}'

# --- Commits on master (should be blocked) ---
echo ""
echo "Commits on master (should block):"
git checkout -q -b master
assert_blocked "git commit on master" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"fix\""}}'
git checkout -q main

# --- Commits on production (should be blocked) ---
echo ""
echo "Commits on production (should block):"
git checkout -q -b production
assert_blocked "git commit on production" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"deploy\""}}'
git checkout -q main

# --- Commits on release (should be blocked) ---
echo ""
echo "Commits on release (should block):"
git checkout -q -b release
assert_blocked "git commit on release" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"v1.0\""}}'
git checkout -q main

# --- Commits on feature branch (should be allowed) ---
echo ""
echo "Commits on feature branches (should allow):"
git checkout -q -b feature/my-change
assert_allowed "git commit on feature branch" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"add feature\""}}'
assert_allowed "git commit -a on feature branch" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -a -m \"update feature\""}}'
git checkout -q main

git checkout -q -b fix/bug-123
assert_allowed "git commit on fix branch" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"fix bug\""}}'
git checkout -q main

git checkout -q -b develop
assert_allowed "git commit on develop branch" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"work in progress\""}}'
git checkout -q main

# --- Env var override ---
echo ""
echo "Env var BRANCH_GUARD_PROTECTED:"
git checkout -q main
BRANCH_GUARD_PROTECTED="main,staging" assert_blocked "main still blocked with env override" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"test\""}}'

git checkout -q -b staging
BRANCH_GUARD_PROTECTED="main,staging" assert_blocked "staging blocked by env override" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"test\""}}'
git checkout -q main

git checkout -q production
BRANCH_GUARD_PROTECTED="main,staging" assert_allowed "production NOT blocked when env overrides" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"test\""}}'
git checkout -q main

# --- Config file ---
echo ""
echo "Config file .branch-guard:"
cat > .branch-guard <<CFG
# Custom protected branches
protect: main
protect: deploy
CFG

git checkout -q main
BRANCH_GUARD_CONFIG=".branch-guard" assert_blocked "main blocked by config" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"test\""}}'

git checkout -q -B deploy
BRANCH_GUARD_CONFIG=".branch-guard" assert_blocked "deploy blocked by config" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"test\""}}'
git checkout -q main

# With config, non-configured default branches should be allowed
git checkout -q master
BRANCH_GUARD_CONFIG=".branch-guard" assert_allowed "master allowed when config overrides defaults" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"test\""}}'
git checkout -q main

rm .branch-guard

# --- Disabled ---
echo ""
echo "Disable via env var:"
git checkout -q main
TOTAL=$((TOTAL + 1))
result=$(echo '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"test\""}}' | BRANCH_GUARD_DISABLED=1 bash "$HOOK" 2>/dev/null || true)
if echo "$result" | grep -q '"permissionDecision":"deny"'; then
  FAIL=$((FAIL + 1))
  echo -e "  ${RED}FAIL${NC}: disabled hook should allow everything"
else
  PASS=$((PASS + 1))
  echo -e "  ${GREEN}PASS${NC}: disabled hook allows everything"
fi

# --- Results ---
echo ""
echo "========================================="
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} out of $TOTAL"
echo "========================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
