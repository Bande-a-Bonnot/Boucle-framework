#!/bin/bash
# branch-guard: PreToolUse hook for Claude Code
# Prevents commits directly to protected branches (main, master, etc.).
# Forces feature-branch workflow.
#
# Protected branches (default): main, master, production, release
#
# Install:
#   curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/branch-guard/install.sh | bash
#
# Config (.branch-guard):
#   protect: main
#   protect: master
#   protect: staging
#   allow-merge: true     # allow merge commits on protected branches
#
# Env vars:
#   BRANCH_GUARD_DISABLED=1       Disable the hook entirely
#   BRANCH_GUARD_PROTECTED=main,master   Override protected branch list
#   BRANCH_GUARD_LOG=1            Log all checks to stderr

set -euo pipefail

if [ "${BRANCH_GUARD_DISABLED:-0}" = "1" ]; then
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
  if [ "${BRANCH_GUARD_LOG:-0}" = "1" ]; then
    echo "[branch-guard] $*" >&2
  fi
}

# Only check git commit commands
if ! echo "$COMMAND" | grep -qE 'git\s+commit' 2>/dev/null; then
  log "SKIP: not a git commit"
  exit 0
fi

# Skip --amend (amending existing commits is OK on any branch — the original
# commit was already allowed or made outside Claude Code)
if echo "$COMMAND" | grep -qE '\-\-amend' 2>/dev/null; then
  log "SKIP: amend (not a new commit)"
  exit 0
fi

block() {
  local reason="$1"
  local suggestion="${2:-}"
  local msg="branch-guard: $reason"
  if [ -n "$suggestion" ]; then
    msg="$msg Suggestion: $suggestion"
  fi
  jq -cn --arg r "$msg" '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":$r}}'
  exit 0
}

# Build protected branches list
PROTECTED=()

# 1. Check env var override
if [ -n "${BRANCH_GUARD_PROTECTED:-}" ]; then
  IFS=',' read -ra PROTECTED <<< "$BRANCH_GUARD_PROTECTED"
  log "Protected branches from env: ${PROTECTED[*]}"
else
  # 2. Check config file
  CONFIG="${BRANCH_GUARD_CONFIG:-.branch-guard}"
  if [ -f "$CONFIG" ]; then
    while IFS= read -r line; do
      line=$(echo "$line" | sed 's/#.*//' | xargs)
      [ -z "$line" ] && continue
      if [[ "$line" == protect:* ]]; then
        branch=$(echo "$line" | sed 's/^protect:\s*//' | xargs)
        PROTECTED+=("$branch")
      fi
    done < "$CONFIG"
    log "Protected branches from config: ${PROTECTED[*]+"${PROTECTED[*]}"}"
  fi

  # 3. Defaults if nothing configured
  if [ ${#PROTECTED[@]} -eq 0 ]; then
    PROTECTED=("main" "master" "production" "release")
    log "Protected branches (defaults): ${PROTECTED[*]}"
  fi
fi

# Get current branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [ -z "$CURRENT_BRANCH" ]; then
  log "SKIP: not in a git repo or detached HEAD"
  exit 0
fi

log "Current branch: $CURRENT_BRANCH"

# Check if current branch is protected
for protected in "${PROTECTED[@]}"; do
  if [ "$CURRENT_BRANCH" = "$protected" ]; then
    block \
      "Direct commit to '$CURRENT_BRANCH' is not allowed. Protected branches require feature-branch workflow." \
      "Create a feature branch first: git checkout -b feature/your-change"
  fi
done

log "ALLOW: branch '$CURRENT_BRANCH' is not protected"
exit 0
