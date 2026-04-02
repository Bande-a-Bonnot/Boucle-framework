#!/bin/bash
# worktree-guard: PreToolUse hook for Claude Code
# Prevents worktree exit when there are uncommitted changes or unmerged commits.
# Without this, worktree cleanup silently deletes branches with all their commits.
#
# Addresses: https://github.com/anthropics/claude-code/issues/38287
#   "Worktree cleanup silently deletes branches with unmerged commits"
#
# What it checks:
#   - Uncommitted changes (staged or unstaged)
#   - Untracked files (new files not yet added)
#   - Commits on current branch not merged into base (main/master)
#   - Commits not pushed to remote (if upstream is set)
#
# Install:
#   curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/worktree-guard/install.sh | bash
#
# Config (.worktree-guard):
#   allow: uncommitted     # skip uncommitted changes check
#   allow: untracked       # skip untracked files check
#   allow: unmerged        # skip unmerged commits check
#   allow: unpushed        # skip unpushed commits check
#   base: develop          # override base branch detection
#
# Env vars:
#   WORKTREE_GUARD_DISABLED=1    Disable the hook entirely
#   WORKTREE_GUARD_LOG=1         Log all checks to stderr

set -euo pipefail

if [ "${WORKTREE_GUARD_DISABLED:-0}" = "1" ]; then
  exit 0
fi

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only check ExitWorktree
if [ "$TOOL_NAME" != "ExitWorktree" ]; then
  exit 0
fi

log() {
  if [ "${WORKTREE_GUARD_LOG:-0}" = "1" ]; then
    echo "[worktree-guard] $*" >&2
  fi
}

block() {
  local reason="$1"
  local suggestion="${2:-}"
  local msg="$reason"
  if [ -n "$suggestion" ]; then
    msg="$msg $suggestion"
  fi
  log "BLOCK: $msg"
  jq -cn --arg r "$msg" '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":$r}}'
  exit 0
}

# Load config from .worktree-guard (project root or home)
ALLOWED=""
BASE_OVERRIDE=""
for cfg in ".worktree-guard" "$HOME/.worktree-guard"; do
  if [ -f "$cfg" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line=$(echo "$line" | sed 's/#.*//' | xargs)
      [ -z "$line" ] && continue
      key=$(echo "$line" | cut -d: -f1 | xargs)
      val=$(echo "$line" | cut -d: -f2- | xargs)
      case "$key" in
        allow) ALLOWED="$ALLOWED $val" ;;
        base) BASE_OVERRIDE="$val" ;;
      esac
    done < "$cfg"
  fi
done

is_allowed() {
  echo "$ALLOWED" | grep -qw "$1" 2>/dev/null
}

# Not inside a git repo? Nothing to check.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log "SKIP: not in a git repo"
  exit 0
fi

CURRENT=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
log "Current branch: $CURRENT"

# Check 1: Uncommitted changes (staged or unstaged)
if ! is_allowed "uncommitted"; then
  DIRTY=$(git diff --name-only 2>/dev/null || echo "")
  STAGED=$(git diff --cached --name-only 2>/dev/null || echo "")
  if [ -n "$DIRTY" ] || [ -n "$STAGED" ]; then
    COUNT=0
    [ -n "$DIRTY" ] && COUNT=$(echo "$DIRTY" | wc -l | tr -d ' ')
    [ -n "$STAGED" ] && COUNT=$((COUNT + $(echo "$STAGED" | wc -l | tr -d ' ')))
    block "Working tree has $COUNT uncommitted change(s)." "Commit or stash before exiting worktree, or add 'allow: uncommitted' to .worktree-guard."
  fi
fi

# Check 2: Untracked files
if ! is_allowed "untracked"; then
  UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null || echo "")
  if [ -n "$UNTRACKED" ]; then
    COUNT=$(echo "$UNTRACKED" | wc -l | tr -d ' ')
    block "$COUNT untracked file(s) will be lost on worktree exit." "Add them with git add, or add 'allow: untracked' to .worktree-guard."
  fi
fi

# Detect base branch
if [ -n "$BASE_OVERRIDE" ]; then
  BASE="$BASE_OVERRIDE"
elif git rev-parse --verify origin/main >/dev/null 2>&1; then
  BASE="origin/main"
elif git rev-parse --verify origin/master >/dev/null 2>&1; then
  BASE="origin/master"
elif git rev-parse --verify main >/dev/null 2>&1; then
  BASE="main"
elif git rev-parse --verify master >/dev/null 2>&1; then
  BASE="master"
else
  log "SKIP: no base branch found"
  exit 0
fi

log "Base branch: $BASE"

# Check 3: Unmerged commits (commits on current branch not in base)
# Two-tier detection to handle squash merges correctly:
#   Tier 1: git cherry for patch-level equivalence (single-commit squash, cherry-pick, rebase)
#   Tier 2: per-file comparison for multi-commit squash merges where individual
#           patches differ but the combined result matches base
# See: https://github.com/anthropics/claude-code/issues/40137
if ! is_allowed "unmerged"; then
  if [ -n "$CURRENT" ] && [ "$CURRENT" != "HEAD" ]; then
    # Tier 1: git cherry compares individual patches
    TRULY_UNMERGED=$(git cherry "$BASE" "$CURRENT" 2>/dev/null | grep '^\+' || true)

    if [ -n "$TRULY_UNMERGED" ]; then
      # Tier 2: fallback for multi-commit squash merges.
      # git cherry compares per-commit patches, so a 3-commit branch
      # squash-merged into 1 commit won't match. Check if all files
      # changed on the branch match their version on base.
      MB=$(git merge-base "$BASE" "$CURRENT" 2>/dev/null || echo "")
      if [ -n "$MB" ]; then
        BRANCH_FILES=$(git diff --name-only "$MB" "$CURRENT" 2>/dev/null || true)
        if [ -n "$BRANCH_FILES" ]; then
          STILL_UNMERGED=false
          while IFS= read -r changed_file; do
            [ -z "$changed_file" ] && continue
            if ! git diff --quiet "$BASE" "$CURRENT" -- "$changed_file" 2>/dev/null; then
              STILL_UNMERGED=true
              break
            fi
          done <<< "$BRANCH_FILES"
          if ! $STILL_UNMERGED; then
            log "SKIP: all branch changes present on $BASE (squash merge)"
            TRULY_UNMERGED=""
          fi
        fi
      fi
    fi

    if [ -n "$TRULY_UNMERGED" ]; then
      COUNT=$(echo "$TRULY_UNMERGED" | wc -l | tr -d ' ')
      FIRST_SHA=$(echo "$TRULY_UNMERGED" | head -1 | awk '{print $2}')
      FIRST=$(git log --oneline -1 "$FIRST_SHA" 2>/dev/null || echo "$FIRST_SHA")
      block "$COUNT unmerged commit(s) on $CURRENT will be lost. Latest: $FIRST." "Merge or cherry-pick into $BASE before exiting, or add 'allow: unmerged' to .worktree-guard."
    fi
  fi
fi

# Check 4: Unpushed commits (if upstream tracking branch exists)
if ! is_allowed "unpushed"; then
  UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name "@{upstream}" 2>/dev/null || echo "")
  if [ -n "$UPSTREAM" ]; then
    UNPUSHED=$(git log --oneline "$UPSTREAM..HEAD" 2>/dev/null || echo "")
    if [ -n "$UNPUSHED" ]; then
      COUNT=$(echo "$UNPUSHED" | wc -l | tr -d ' ')
      block "$COUNT unpushed commit(s) on $CURRENT." "Push before exiting worktree, or add 'allow: unpushed' to .worktree-guard."
    fi
  fi
fi

log "ALLOW: all checks passed"
exit 0
