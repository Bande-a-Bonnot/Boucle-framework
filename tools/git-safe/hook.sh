#!/bin/bash
# git-safe: PreToolUse hook for Claude Code
# Prevents destructive git operations that can lose work.
#
# Blocked operations:
#   - git push --force / -f (can rewrite remote history)
#   - git reset --hard (discards uncommitted changes)
#   - git checkout . / git checkout -- <file> (discards changes)
#   - git checkout <ref> -- <path> (overwrites files from ref)
#   - git restore without --staged (discards working tree changes)
#   - git restore --source / -s (overwrites from arbitrary ref)
#   - git clean -f (deletes untracked files permanently)
#   - git branch -D (force-deletes unmerged branches)
#   - git stash drop / clear (permanently deletes stashed work)
#   - git commit --no-verify / -n (skips pre-commit hooks)
#   - git push --delete / origin :branch (removes remote refs)
#   - git rebase without safeguards
#   - git reflog expire (destroys recovery data)
#
# Install:
#   curl -sL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/git-safe/install.sh | bash
#
# Config (.git-safe):
#   allow: push --force    # whitelist specific operations
#   allow: reset --hard
#
# Env vars:
#   GIT_SAFE_DISABLED=1    Disable the hook entirely
#   GIT_SAFE_LOG=1         Log all checks to stderr

set -euo pipefail

if [ "${GIT_SAFE_DISABLED:-0}" = "1" ]; then
  exit 0
fi

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only check Bash commands
if [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
if [ -z "$COMMAND" ]; then
  exit 0
fi

log() {
  if [ "${GIT_SAFE_LOG:-0}" = "1" ]; then
    echo "[git-safe] $*" >&2
  fi
}

# Check if command contains git
if ! echo "$COMMAND" | grep -q 'git\b' 2>/dev/null; then
  log "SKIP: no git command"
  exit 0
fi

# Load allowlist from .git-safe config
ALLOWED=()
CONFIG="${GIT_SAFE_CONFIG:-.git-safe}"
if [ -f "$CONFIG" ]; then
  while IFS= read -r line; do
    line=$(echo "$line" | sed 's/#.*//' | xargs)
    [ -z "$line" ] && continue
    if [[ "$line" == allow:* ]]; then
      pattern=$(echo "$line" | sed 's/^allow:\s*//' | xargs)
      ALLOWED+=("$pattern")
    fi
  done < "$CONFIG"
fi

# Check if an operation is allowed via config
is_allowed() {
  local op="$1"
  for a in "${ALLOWED[@]+"${ALLOWED[@]}"}"; do
    if [ "$a" = "$op" ]; then
      log "ALLOWED by config: $op"
      return 0
    fi
  done
  return 1
}

block() {
  local reason="$1"
  local suggestion="${2:-}"
  local msg="git-safe: $reason"
  if [ -n "$suggestion" ]; then
    msg="$msg Suggestion: $suggestion"
  fi
  jq -cn --arg r "$msg" '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":$r}}'
  exit 0
}

# --- Destructive operation checks ---

# git commit/merge/push --no-verify / -n (skips safety hooks like pre-commit, pre-push)
# See: https://github.com/anthropics/claude-code/issues/40117
if echo "$COMMAND" | grep -qE 'git\s+(commit|merge|push|cherry-pick|revert|am)\s.*--no-verify' 2>/dev/null; then
  is_allowed "no-verify" || block "git --no-verify skips pre-commit/pre-push hooks, bypassing safety checks like linting, tests, and secret scanning." "Remove --no-verify and let hooks run. Fix any issues they report. Add 'allow: no-verify' to .git-safe only if you understand the risk."
fi
# Also catch -n shorthand for commit (git commit -n is --no-verify)
if echo "$COMMAND" | grep -qE 'git\s+commit\s+(-[a-zA-Z]*n[a-zA-Z]*\b|.*\s-[a-zA-Z]*n[a-zA-Z]*\b)' 2>/dev/null; then
  # Don't false-positive on --dry-run (-n for some commands) — commit's -n IS --no-verify
  if ! echo "$COMMAND" | grep -q '\-\-no-verify' 2>/dev/null; then
    is_allowed "no-verify" || block "git commit -n skips pre-commit hooks (same as --no-verify)." "Remove -n and let pre-commit hooks run. Add 'allow: no-verify' to .git-safe only if you understand the risk."
  fi
fi

# git push --force / -f (but not --force-with-lease which is safer)
if echo "$COMMAND" | grep -qE 'git\s+push\s.*--force(\s|$)' 2>/dev/null; then
  if echo "$COMMAND" | grep -q '\-\-force-with-lease' 2>/dev/null; then
    log "ALLOW: --force-with-lease is safe"
  else
    is_allowed "push --force" || block "Force push can rewrite remote history and lose commits for other collaborators." "Use --force-with-lease instead, or add 'allow: push --force' to .git-safe."
  fi
fi
if echo "$COMMAND" | grep -qE 'git\s+push\s+(-[a-zA-Z]*f\b|.*\s-[a-zA-Z]*f\b)' 2>/dev/null; then
  if ! echo "$COMMAND" | grep -q '\-\-force' 2>/dev/null; then
    is_allowed "push --force" || block "Force push (-f) can rewrite remote history and lose commits." "Use --force-with-lease instead, or add 'allow: push --force' to .git-safe."
  fi
fi

# git reset --hard
if echo "$COMMAND" | grep -qE 'git\s+reset\s.*--hard' 2>/dev/null; then
  is_allowed "reset --hard" || block "git reset --hard discards all uncommitted changes permanently." "Commit or stash changes first, or add 'allow: reset --hard' to .git-safe."
fi

# git checkout . / git checkout -- (discards working tree changes)
if echo "$COMMAND" | grep -qE 'git\s+checkout\s+\.\s*$' 2>/dev/null; then
  is_allowed "checkout ." || block "git checkout . discards all uncommitted changes in the working tree." "Commit or stash changes first, or add 'allow: checkout .' to .git-safe."
fi
if echo "$COMMAND" | grep -qE 'git\s+checkout\s+--\s' 2>/dev/null; then
  is_allowed "checkout --" || block "git checkout -- discards uncommitted changes to specified files." "Commit or stash first, or add 'allow: checkout --' to .git-safe."
fi

# git checkout <ref> -- <path> (overwrites working tree from a specific ref)
# Catches: git checkout HEAD -- src/, git checkout main -- file.js, git checkout abc123 -- .
# Does NOT catch: git checkout -- file (no ref; already caught above)
# Does NOT catch: git checkout -b branch (flag, not ref)
if echo "$COMMAND" | grep -qE 'git\s+checkout\s+[^-][^ ]*\s+--\s' 2>/dev/null; then
  is_allowed "checkout ref --" || block "git checkout <ref> -- <path> overwrites working tree files with the version from that ref, discarding local changes." "Commit or stash changes first, or add 'allow: checkout ref --' to .git-safe."
fi

# git restore (various destructive forms)
if echo "$COMMAND" | grep -qE 'git\s+restore\s' 2>/dev/null; then
  # Always block --source/-s (restoring from arbitrary ref)
  if echo "$COMMAND" | grep -qE '(--source|-s\s)' 2>/dev/null; then
    is_allowed "restore --source" || block "git restore --source overwrites files from a specific ref, discarding local changes." "Commit or stash first, or add 'allow: restore --source' to .git-safe."
  # Block --worktree/-W (explicitly discards working tree)
  elif echo "$COMMAND" | grep -qE '(--worktree|-W\b)' 2>/dev/null; then
    is_allowed "restore" || block "git restore --worktree discards uncommitted working tree changes." "Commit or stash first, or add 'allow: restore' to .git-safe."
  # Block if no --staged flag (default = working tree restore = destructive)
  elif ! echo "$COMMAND" | grep -qE '\-\-staged' 2>/dev/null; then
    is_allowed "restore" || block "git restore without --staged discards uncommitted working tree changes." "Use git restore --staged to unstage only, or commit/stash first. Add 'allow: restore' to .git-safe."
  fi
fi

# git clean -f (deletes untracked files)
if echo "$COMMAND" | grep -qE 'git\s+clean\s.*-[a-zA-Z]*f' 2>/dev/null; then
  is_allowed "clean -f" || block "git clean -f permanently deletes untracked files." "Use git clean -n (dry run) first, or add 'allow: clean -f' to .git-safe."
fi

# git branch -D (force-delete unmerged branch)
if echo "$COMMAND" | grep -qE 'git\s+branch\s.*-[a-zA-Z]*D' 2>/dev/null; then
  is_allowed "branch -D" || block "git branch -D force-deletes a branch even if not fully merged." "Use -d (lowercase) which only deletes merged branches, or add 'allow: branch -D' to .git-safe."
fi

# git stash drop / clear
if echo "$COMMAND" | grep -qE 'git\s+stash\s+drop' 2>/dev/null; then
  is_allowed "stash drop" || block "git stash drop permanently deletes stashed changes." "Add 'allow: stash drop' to .git-safe to permit this."
fi
if echo "$COMMAND" | grep -qE 'git\s+stash\s+clear' 2>/dev/null; then
  is_allowed "stash clear" || block "git stash clear permanently deletes all stashed changes." "Add 'allow: stash clear' to .git-safe to permit this."
fi

# git reflog expire / delete
if echo "$COMMAND" | grep -qE 'git\s+reflog\s+(expire|delete)' 2>/dev/null; then
  is_allowed "reflog expire" || block "git reflog expire/delete destroys recovery data." "This is almost never needed. Add 'allow: reflog expire' to .git-safe if you really need it."
fi

# git push --delete (removes remote branches/tags)
if echo "$COMMAND" | grep -qE 'git\s+push\s.*--delete\s' 2>/dev/null; then
  is_allowed "push --delete" || block "git push --delete permanently removes remote branches or tags." "Use 'git branch -d' for local cleanup instead, or add 'allow: push --delete' to .git-safe."
fi
# git push origin :branch (alternate delete syntax)
if echo "$COMMAND" | grep -qE 'git\s+push\s+\S+\s+:[^/\s]' 2>/dev/null; then
  is_allowed "push --delete" || block "git push origin :branch permanently removes a remote branch." "Use 'git branch -d' for local cleanup instead, or add 'allow: push --delete' to .git-safe."
fi

# Force push to main/master (extra protection)
if echo "$COMMAND" | grep -qE 'git\s+push\s.*--force.*\s(main|master)(\s|$)' 2>/dev/null; then
  block "Force push to main/master is extremely dangerous." "This is blocked even with 'allow: push --force'. Never force push to main."
fi
if echo "$COMMAND" | grep -qE 'git\s+push\s.*\s(main|master)\s.*--force' 2>/dev/null; then
  block "Force push to main/master is extremely dangerous." "This is blocked even with 'allow: push --force'. Never force push to main."
fi

log "ALLOW: $COMMAND"
exit 0
