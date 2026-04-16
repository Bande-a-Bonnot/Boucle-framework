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
assert_allowed "git push to SSH remote URL (not a refspec)" \
  '{"tool_name":"Bash","tool_input":{"command":"git push git@github.com:org/repo.git feature-branch"}}'
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

# --- git checkout <ref> -- <path> (issue #37888 pattern) ---
echo ""
echo "Checkout from ref (issue #37888):"
assert_blocked "git checkout HEAD -- src/" \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout HEAD -- src/"}}'
assert_blocked "git checkout HEAD -- ." \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout HEAD -- ."}}'
assert_blocked "git checkout main -- file.js" \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout main -- file.js"}}'
assert_blocked "git checkout origin/main -- path/to/file" \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout origin/main -- path/to/file"}}'
assert_blocked "git checkout abc123 -- ." \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout abc123 -- ."}}'
assert_blocked "git checkout HEAD~3 -- src/main.rs" \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout HEAD~3 -- src/main.rs"}}'

# --- git restore expanded coverage ---
echo ""
echo "Restore expanded coverage:"
assert_blocked "git restore src/main.rs (no --staged)" \
  '{"tool_name":"Bash","tool_input":{"command":"git restore src/main.rs"}}'
assert_blocked "git restore --source=HEAD ." \
  '{"tool_name":"Bash","tool_input":{"command":"git restore --source=HEAD ."}}'
assert_blocked "git restore --source=main file.js" \
  '{"tool_name":"Bash","tool_input":{"command":"git restore --source=main file.js"}}'
assert_blocked "git restore -s HEAD file.js" \
  '{"tool_name":"Bash","tool_input":{"command":"git restore -s HEAD file.js"}}'
assert_blocked "git restore --worktree ." \
  '{"tool_name":"Bash","tool_input":{"command":"git restore --worktree ."}}'
assert_blocked "git restore --staged --worktree ." \
  '{"tool_name":"Bash","tool_input":{"command":"git restore --staged --worktree ."}}'
assert_allowed "git restore --staged file.js (safe: just unstages)" \
  '{"tool_name":"Bash","tool_input":{"command":"git restore --staged file.js"}}'
assert_allowed "git restore --staged . (safe: just unstages)" \
  '{"tool_name":"Bash","tool_input":{"command":"git restore --staged ."}}'
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
assert_blocked "git push --delete branch" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --delete origin feature-branch"}}'
assert_blocked "git push --delete tag" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --delete origin v1.0.0"}}'
assert_blocked "git push origin :branch (alternate delete syntax)" \
  '{"tool_name":"Bash","tool_input":{"command":"git push origin :feature-branch"}}'
assert_allowed "git push origin branch (normal, not delete)" \
  '{"tool_name":"Bash","tool_input":{"command":"git push origin feature-branch"}}'

# --- --no-verify (skips pre-commit hooks) ---
echo ""
echo "No-verify detection:"
assert_blocked "git commit --no-verify" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit --no-verify -m \"skip hooks\""}}'
assert_blocked "git commit -n (shorthand)" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -n -m \"skip hooks\""}}'
assert_blocked "git commit -an (combined flags)" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -an -m \"skip hooks\""}}'
assert_blocked "git commit -anm (combined with message)" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -anm \"skip hooks\""}}'
assert_blocked "git merge --no-verify" \
  '{"tool_name":"Bash","tool_input":{"command":"git merge --no-verify feature-branch"}}'
assert_blocked "git push --no-verify" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --no-verify origin main"}}'
assert_blocked "git cherry-pick --no-verify" \
  '{"tool_name":"Bash","tool_input":{"command":"git cherry-pick --no-verify abc123"}}'
assert_blocked "git revert --no-verify" \
  '{"tool_name":"Bash","tool_input":{"command":"git revert --no-verify HEAD"}}'
assert_blocked "git am --no-verify" \
  '{"tool_name":"Bash","tool_input":{"command":"git am --no-verify patch.mbox"}}'
assert_allowed "git commit (normal, no skip)" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"normal commit\""}}'
assert_allowed "git commit -a (all, not -n)" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -a -m \"stage and commit\""}}'
assert_allowed "git commit --amend (no skip)" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit --amend -m \"amend\""}}'

# --- Force push to main/master (always blocked) ---
echo ""
echo "Force push to main/master (always blocked):"
assert_blocked "force push to main" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}'
assert_blocked "force push to master" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --force origin master"}}'
assert_blocked "push later refspec to protected branch" \
  '{"tool_name":"Bash","tool_input":{"command":"git push origin feature:dev hotfix:main"}}'

# --- Additional destructive operations ---
echo ""
echo "Additional destructive operations:"
assert_blocked "git filter-repo (bare command)" \
  '{"tool_name":"Bash","tool_input":{"command":"git filter-repo"}}'
assert_blocked "git filter-branch (bare command)" \
  '{"tool_name":"Bash","tool_input":{"command":"git filter-branch"}}'
assert_blocked "git tag -d v1.0.0" \
  '{"tool_name":"Bash","tool_input":{"command":"git tag -d v1.0.0"}}'
assert_blocked "git tag --delete v1.0.0" \
  '{"tool_name":"Bash","tool_input":{"command":"git tag --delete v1.0.0"}}'
assert_allowed "git tag --merged main" \
  '{"tool_name":"Bash","tool_input":{"command":"git tag --merged main"}}'
assert_blocked "git config --global user.name test" \
  '{"tool_name":"Bash","tool_input":{"command":"git config --global user.name test"}}'
assert_blocked "git config --system user.name test" \
  '{"tool_name":"Bash","tool_input":{"command":"git config --system user.name test"}}'

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

echo "allow: no-verify" >> "$TMPDIR/.git-safe"
echo "allow: push --delete" >> "$TMPDIR/.git-safe"
echo "allow: config --system" >> "$TMPDIR/.git-safe"

GIT_SAFE_CONFIG="$TMPDIR/.git-safe" assert_allowed "no-verify allowed by config" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit --no-verify -m \"allowed\""}}'

GIT_SAFE_CONFIG="$TMPDIR/.git-safe" assert_allowed "push --delete allowed by config" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --delete origin old-branch"}}'
GIT_SAFE_CONFIG="$TMPDIR/.git-safe" assert_allowed "config --system allowed by config" \
  '{"tool_name":"Bash","tool_input":{"command":"git config --system user.name test"}}'
GIT_SAFE_CONFIG="$TMPDIR/.git-safe" assert_blocked "config --global still blocked without explicit allow" \
  '{"tool_name":"Bash","tool_input":{"command":"git config --global user.name test"}}'

# Force push to main still blocked even with config
GIT_SAFE_CONFIG="$TMPDIR/.git-safe" assert_blocked "force push to main still blocked with allowlist" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}'

# Disabled via env var
echo ""
echo "Disable via env var:"
TOTAL=$((TOTAL + 1))
result=$(echo '{"tool_name":"Bash","tool_input":{"command":"git push --force origin feature"}}' | GIT_SAFE_DISABLED=1 bash "$HOOK" 2>/dev/null || true)
if echo "$result" | grep -q '"permissionDecision":"deny"'; then
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
