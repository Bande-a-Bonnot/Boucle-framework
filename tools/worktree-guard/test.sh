#!/bin/bash
# Tests for worktree-guard hook
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

# Create a temporary git repo for testing
TMPDIR=$(mktemp -d)
cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

setup_clean_repo() {
  rm -rf "$TMPDIR/repo"
  mkdir -p "$TMPDIR/repo"
  cd "$TMPDIR/repo"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  git checkout -b main 2>/dev/null || true
  echo "initial" > file.txt
  git add file.txt
  git commit -q -m "initial"
}

echo "=== worktree-guard tests ==="
echo ""

# --- Tool filtering ---
echo "Tool filtering:"
assert_allowed "Bash tool passes through" \
  '{"tool_name":"Bash","tool_input":{"command":"echo hello"}}'
assert_allowed "Write tool passes through" \
  '{"tool_name":"Write","tool_input":{"file_path":"test.txt","content":"hi"}}'
assert_allowed "Read tool passes through" \
  '{"tool_name":"Read","tool_input":{"file_path":"test.txt"}}'
assert_allowed "Edit tool passes through" \
  '{"tool_name":"Edit","tool_input":{"file_path":"test.txt"}}'
assert_allowed "EnterWorktree passes through" \
  '{"tool_name":"EnterWorktree","tool_input":{}}'
assert_allowed "Empty tool name passes through" \
  '{"tool_name":"","tool_input":{}}'
assert_allowed "Missing tool name passes through" \
  '{"tool_input":{}}'

# --- Disabled mode ---
echo ""
echo "Disabled mode:"
TOTAL=$((TOTAL + 1))
result=$(echo '{"tool_name":"ExitWorktree","tool_input":{}}' | WORKTREE_GUARD_DISABLED=1 bash "$HOOK" 2>/dev/null || true)
if echo "$result" | grep -q '"decision":"block"'; then
  FAIL=$((FAIL + 1))
  echo -e "  ${RED}FAIL${NC}: disabled mode allows exit"
else
  PASS=$((PASS + 1))
  echo -e "  ${GREEN}PASS${NC}: disabled mode allows exit"
fi

# --- Clean repo ---
echo ""
echo "Clean repo (all checks pass):"
setup_clean_repo
assert_allowed "Clean repo allows exit" \
  '{"tool_name":"ExitWorktree","tool_input":{}}'

# --- Uncommitted changes ---
echo ""
echo "Uncommitted changes:"
setup_clean_repo
echo "modified" >> file.txt
assert_blocked "Modified file blocks exit" \
  '{"tool_name":"ExitWorktree","tool_input":{}}'

setup_clean_repo
echo "staged" >> file.txt
git add file.txt
assert_blocked "Staged changes block exit" \
  '{"tool_name":"ExitWorktree","tool_input":{}}'

setup_clean_repo
echo "both staged and unstaged" >> file.txt
git add file.txt
echo "more changes" >> file.txt
assert_blocked "Both staged and unstaged block exit" \
  '{"tool_name":"ExitWorktree","tool_input":{}}'

# --- Untracked files ---
echo ""
echo "Untracked files:"
setup_clean_repo
echo "new file" > new_file.txt
assert_blocked "Untracked file blocks exit" \
  '{"tool_name":"ExitWorktree","tool_input":{}}'

setup_clean_repo
mkdir -p subdir
echo "nested" > subdir/nested.txt
assert_blocked "Nested untracked file blocks exit" \
  '{"tool_name":"ExitWorktree","tool_input":{}}'

# --- Unmerged commits ---
echo ""
echo "Unmerged commits:"
setup_clean_repo
git checkout -b feature 2>/dev/null
echo "feature work" >> file.txt
git add file.txt
git commit -q -m "feature commit"
assert_blocked "Unmerged commit on feature branch blocks exit" \
  '{"tool_name":"ExitWorktree","tool_input":{}}'

setup_clean_repo
git checkout -b feature2 2>/dev/null
echo "commit 1" >> file.txt
git add file.txt
git commit -q -m "commit 1"
echo "commit 2" >> file.txt
git add file.txt
git commit -q -m "commit 2"
echo "commit 3" >> file.txt
git add file.txt
git commit -q -m "commit 3"
assert_blocked "Multiple unmerged commits block exit" \
  '{"tool_name":"ExitWorktree","tool_input":{}}'

# Merged branch should be allowed
setup_clean_repo
git checkout -b merged-feature 2>/dev/null
echo "merged work" >> file.txt
git add file.txt
git commit -q -m "merged commit"
git checkout main 2>/dev/null
git merge merged-feature -q
git checkout merged-feature 2>/dev/null
assert_allowed "Fully merged branch allows exit" \
  '{"tool_name":"ExitWorktree","tool_input":{}}'

# Squash-merged branch should be allowed (git cherry detects content equivalence)
# See: https://github.com/anthropics/claude-code/issues/40137
setup_clean_repo
git checkout -b squash-feature 2>/dev/null
echo "squash work" >> file.txt
git add file.txt
git commit -q -m "squash commit"
git checkout main 2>/dev/null
git merge --squash squash-feature -q
git commit -q -m "squash merge squash-feature"
git checkout squash-feature 2>/dev/null
assert_allowed "Squash-merged branch allows exit" \
  '{"tool_name":"ExitWorktree","tool_input":{}}'

# Squash merge with multiple commits
setup_clean_repo
git checkout -b multi-squash 2>/dev/null
echo "change 1" >> file.txt
git add file.txt
git commit -q -m "multi-squash commit 1"
echo "change 2" >> file.txt
git add file.txt
git commit -q -m "multi-squash commit 2"
echo "change 3" >> file.txt
git add file.txt
git commit -q -m "multi-squash commit 3"
git checkout main 2>/dev/null
git merge --squash multi-squash -q
git commit -q -m "squash merge multi-squash"
git checkout multi-squash 2>/dev/null
assert_allowed "Multi-commit squash-merged branch allows exit" \
  '{"tool_name":"ExitWorktree","tool_input":{}}'

# Partial squash: only some commits merged, rest still unmerged
setup_clean_repo
git checkout -b partial-squash 2>/dev/null
echo "merged part" >> file.txt
git add file.txt
git commit -q -m "will be squash-merged"
git checkout main 2>/dev/null
git merge --squash partial-squash -q
git commit -q -m "squash merge partial"
git checkout partial-squash 2>/dev/null
echo "unmerged addition" >> file.txt
git add file.txt
git commit -q -m "new work after squash merge"
assert_blocked "Partial squash with new commits blocks exit" \
  '{"tool_name":"ExitWorktree","tool_input":{}}'

# Cherry-picked commit should allow exit (same patch on base)
setup_clean_repo
git checkout -b cherry-feature 2>/dev/null
echo "cherry work" >> file.txt
git add file.txt
git commit -q -m "cherry commit"
CHERRY_SHA=$(git rev-parse HEAD)
git checkout main 2>/dev/null
git cherry-pick "$CHERRY_SHA" -q
git checkout cherry-feature 2>/dev/null
assert_allowed "Cherry-picked branch allows exit" \
  '{"tool_name":"ExitWorktree","tool_input":{}}'

# --- On main branch ---
echo ""
echo "Main branch:"
setup_clean_repo
assert_allowed "Clean main branch allows exit" \
  '{"tool_name":"ExitWorktree","tool_input":{}}'

# --- Config: allow directives ---
echo ""
echo "Config allow directives:"

# allow: uncommitted (commit config first to avoid untracked-file trigger)
setup_clean_repo
echo "allow: uncommitted" > .worktree-guard
git add .worktree-guard
git commit -q -m "add config"
echo "modified" >> file.txt
assert_allowed "allow: uncommitted skips dirty check" \
  '{"tool_name":"ExitWorktree","tool_input":{}}'

# allow: untracked (commit config first)
setup_clean_repo
echo "allow: untracked" > .worktree-guard
git add .worktree-guard
git commit -q -m "add config"
echo "new" > new_file.txt
assert_allowed "allow: untracked permits untracked files" \
  '{"tool_name":"ExitWorktree","tool_input":{}}'

# allow: unmerged
setup_clean_repo
git checkout -b feature3 2>/dev/null
echo "allow: unmerged" > .worktree-guard
git add .worktree-guard
echo "feature" >> file.txt
git add file.txt
git commit -q -m "feature with config"
assert_allowed "allow: unmerged permits unmerged commits" \
  '{"tool_name":"ExitWorktree","tool_input":{}}'
rm -f .worktree-guard

# --- Config: base override ---
echo ""
echo "Config base override:"
setup_clean_repo
git checkout -b develop 2>/dev/null
echo "develop" >> file.txt
git add file.txt
git commit -q -m "develop commit"
git checkout -b feature-from-develop 2>/dev/null
echo "feature" >> file.txt
git add file.txt
git commit -q -m "feature from develop"
echo "base: develop" > .worktree-guard
git add .worktree-guard
git commit -q -m "add config"
assert_blocked "Custom base branch detects unmerged commits" \
  '{"tool_name":"ExitWorktree","tool_input":{}}'
rm -f .worktree-guard

# --- Not a git repo ---
echo ""
echo "Non-git directory:"
TMPNOGIT=$(mktemp -d)
cd "$TMPNOGIT"
assert_allowed "Non-git directory allows exit" \
  '{"tool_name":"ExitWorktree","tool_input":{}}'
rm -rf "$TMPNOGIT"

# --- Block message quality ---
echo ""
echo "Block message quality:"
setup_clean_repo
echo "dirty" >> file.txt
TOTAL=$((TOTAL + 1))
result=$(echo '{"tool_name":"ExitWorktree","tool_input":{}}' | bash "$HOOK" 2>/dev/null || true)
if echo "$result" | grep -q "uncommitted"; then
  PASS=$((PASS + 1))
  echo -e "  ${GREEN}PASS${NC}: Block message mentions uncommitted changes"
else
  FAIL=$((FAIL + 1))
  echo -e "  ${RED}FAIL${NC}: Block message should mention uncommitted (got: $result)"
fi

setup_clean_repo
git checkout -b msg-test 2>/dev/null
echo "feature" >> file.txt
git add file.txt
git commit -q -m "test message"
TOTAL=$((TOTAL + 1))
result=$(echo '{"tool_name":"ExitWorktree","tool_input":{}}' | bash "$HOOK" 2>/dev/null || true)
if echo "$result" | grep -q "unmerged" && echo "$result" | grep -q "msg-test"; then
  PASS=$((PASS + 1))
  echo -e "  ${GREEN}PASS${NC}: Block message mentions branch name and unmerged"
else
  FAIL=$((FAIL + 1))
  echo -e "  ${RED}FAIL${NC}: Block message should mention branch name (got: $result)"
fi

# --- Multiple issues ---
echo ""
echo "Multiple issues (first hit blocks):"
setup_clean_repo
git checkout -b multi-issue 2>/dev/null
echo "uncommitted" >> file.txt
# Also has untracked
echo "untracked" > untracked.txt
TOTAL=$((TOTAL + 1))
result=$(echo '{"tool_name":"ExitWorktree","tool_input":{}}' | bash "$HOOK" 2>/dev/null || true)
if echo "$result" | grep -q '"decision":"block"'; then
  PASS=$((PASS + 1))
  echo -e "  ${GREEN}PASS${NC}: Multiple issues still blocks"
else
  FAIL=$((FAIL + 1))
  echo -e "  ${RED}FAIL${NC}: Should block with multiple issues"
fi

# --- JSON output format ---
echo ""
echo "JSON output format:"
setup_clean_repo
echo "dirty" >> file.txt
TOTAL=$((TOTAL + 1))
result=$(echo '{"tool_name":"ExitWorktree","tool_input":{}}' | bash "$HOOK" 2>/dev/null || true)
if echo "$result" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
  PASS=$((PASS + 1))
  echo -e "  ${GREEN}PASS${NC}: Output is valid JSON"
else
  FAIL=$((FAIL + 1))
  echo -e "  ${RED}FAIL${NC}: Output is not valid JSON (got: $result)"
fi

TOTAL=$((TOTAL + 1))
if echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['decision']=='block'" 2>/dev/null; then
  PASS=$((PASS + 1))
  echo -e "  ${GREEN}PASS${NC}: JSON has decision field"
else
  FAIL=$((FAIL + 1))
  echo -e "  ${RED}FAIL${NC}: JSON missing decision field"
fi

TOTAL=$((TOTAL + 1))
if echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); assert len(d['reason']) > 0" 2>/dev/null; then
  PASS=$((PASS + 1))
  echo -e "  ${GREEN}PASS${NC}: JSON has non-empty reason"
else
  FAIL=$((FAIL + 1))
  echo -e "  ${RED}FAIL${NC}: JSON missing or empty reason"
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
