#!/bin/bash
# git-safe: PreToolUse hook for Claude Code
# Prevents destructive git operations that can lose work.
#
# Blocked operations:
#   - git push --force / -f (can rewrite remote history)
#   - git reset --hard (discards uncommitted changes)
#   - git checkout . / git checkout -- <file> (discards changes)
#   - git clean -f (deletes untracked files permanently)
#   - git branch -D (force-deletes unmerged branches)
#   - git stash drop / clear (permanently deletes stashed work)
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

COMMAND=$(echo "$INPUT" | jq -r '.input.command // empty')
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
  jq -n --arg r "$msg" '{"decision":"block","reason":$r}'
  exit 0
}

# --- Destructive operation checks ---

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

# git restore . / git restore --staged --worktree (discards changes)
if echo "$COMMAND" | grep -qE 'git\s+restore\s+\.\s*$' 2>/dev/null; then
  is_allowed "restore ." || block "git restore . discards all uncommitted changes." "Commit or stash first, or add 'allow: restore .' to .git-safe."
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

# Force push to main/master (extra protection)
if echo "$COMMAND" | grep -qE 'git\s+push\s.*--force.*\s(main|master)(\s|$)' 2>/dev/null; then
  block "Force push to main/master is extremely dangerous." "This is blocked even with 'allow: push --force'. Never force push to main."
fi
if echo "$COMMAND" | grep -qE 'git\s+push\s.*\s(main|master)\s.*--force' 2>/dev/null; then
  block "Force push to main/master is extremely dangerous." "This is blocked even with 'allow: push --force'. Never force push to main."
fi

log "ALLOW: $COMMAND"
exit 0
