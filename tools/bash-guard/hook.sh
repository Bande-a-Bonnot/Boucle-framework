#!/bin/bash
# bash-guard: PreToolUse hook for Claude Code
# Prevents dangerous bash commands that can cause irreversible damage.
#
# Blocked operations:
#   - rm -rf on critical paths (/, ~, *, ..)
#   - chmod/chown -R with dangerous permissions
#   - Piping untrusted content to shell (curl|sh, wget|bash)
#   - sudo (privilege escalation)
#   - kill -9 on broad targets
#   - dd/mkfs targeting disks
#   - Overwriting system directories
#
# Install:
#   curl -sL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/bash-guard/install.sh | bash
#
# Config (.bash-guard):
#   allow: sudo           # whitelist specific operations
#   allow: rm -rf
#   allow: pipe-to-shell
#   deny: rm              # block ALL rm commands (not just rm -rf on critical paths)
#   deny: unlink          # block unlink commands
#   deny: find.*-delete   # block find with -delete flag (regex supported)
#
# Env vars:
#   BASH_GUARD_DISABLED=1    Disable the hook entirely
#   BASH_GUARD_LOG=1         Log all checks to stderr

set -euo pipefail

if [ "${BASH_GUARD_DISABLED:-0}" = "1" ]; then
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
  if [ "${BASH_GUARD_LOG:-0}" = "1" ]; then
    echo "[bash-guard] $*" >&2
  fi
}

# Load allowlist and denylist from .bash-guard config
ALLOWED=()
DENIED=()
CONFIG="${BASH_GUARD_CONFIG:-.bash-guard}"
if [ -f "$CONFIG" ]; then
  while IFS= read -r line; do
    line=$(echo "$line" | sed 's/#.*//' | xargs)
    [ -z "$line" ] && continue
    if [[ "$line" == allow:* ]]; then
      pattern=$(echo "$line" | sed 's/^allow:\s*//' | xargs)
      ALLOWED+=("$pattern")
    elif [[ "$line" == deny:* ]]; then
      pattern=$(echo "$line" | sed 's/^deny:\s*//' | xargs)
      DENIED+=("$pattern")
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
  local msg="bash-guard: $reason"
  if [ -n "$suggestion" ]; then
    msg="$msg Suggestion: $suggestion"
  fi
  jq -cn --arg r "$msg" '{"decision":"block","reason":$r}'
  exit 0
}

# --- Custom deny rules (from .bash-guard config) ---
for denied in "${DENIED[@]+"${DENIED[@]}"}"; do
  if echo "$COMMAND" | grep -qE "(^|\s|;|&&|\|\|)${denied}" 2>/dev/null; then
    block "Command matches deny rule '${denied}' in .bash-guard config." "Remove the deny rule or add a matching allow rule to override."
  fi
done

# --- Dangerous operation checks ---

# rm -rf on critical/broad paths
if echo "$COMMAND" | grep -qE 'rm\s+(-[a-zA-Z]*r[a-zA-Z]*f|(-[a-zA-Z]*f[a-zA-Z]*r))\s' 2>/dev/null; then
  # Check for critical targets
  if echo "$COMMAND" | grep -qE 'rm\s+-[rRf]+\s+(/(\s|$)|/\*|~(/|\s|$)|\.\.|/usr|/etc|/var|/home|/System|/Library|\$HOME)' 2>/dev/null; then
    is_allowed "rm -rf" || block "rm -rf targeting a critical system path. This would cause irreversible data loss." "Be specific about which files to delete, or add 'allow: rm -rf' to .bash-guard."
  fi
  # Check for wildcard-only targets
  if echo "$COMMAND" | grep -qE 'rm\s+-[rRf]+\s+\*\s*$' 2>/dev/null; then
    is_allowed "rm -rf" || block "rm -rf * would recursively delete everything in the current directory." "Be specific about which files to delete, or add 'allow: rm -rf' to .bash-guard."
  fi
fi

# chmod -R with dangerous permissions (777, 000)
if echo "$COMMAND" | grep -qE 'chmod\s+(-[a-zA-Z]*R|--recursive)\s' 2>/dev/null; then
  if echo "$COMMAND" | grep -qE 'chmod\s+.*\s(777|000|666)\s' 2>/dev/null; then
    is_allowed "chmod -R" || block "Recursive chmod with dangerous permissions (777/000/666) affects all files in the tree." "Apply permissions to specific files, or add 'allow: chmod -R' to .bash-guard."
  fi
fi

# chown -R to root or broad changes
if echo "$COMMAND" | grep -qE 'chown\s+(-[a-zA-Z]*R|--recursive)\s.*\s(/|~|/usr|/etc|/var|/home)' 2>/dev/null; then
  is_allowed "chown -R" || block "Recursive chown on a critical path can break system permissions." "Be specific about which directory to change, or add 'allow: chown -R' to .bash-guard."
fi

# Pipe to shell (curl|sh, wget|bash, curl|bash, etc.)
if echo "$COMMAND" | grep -qE '(curl|wget)\s.*\|\s*(sh|bash|zsh|dash|ksh|source|eval)' 2>/dev/null; then
  is_allowed "pipe-to-shell" || block "Piping downloaded content directly to a shell executes untrusted code." "Download the script first, review it, then run it. Or add 'allow: pipe-to-shell' to .bash-guard."
fi

# sudo (privilege escalation)
if echo "$COMMAND" | grep -qE '(^|\s|;|&&|\|\|)sudo\s' 2>/dev/null; then
  is_allowed "sudo" || block "sudo escalates to root privileges. AI agents should not run commands as root." "Run without sudo, or add 'allow: sudo' to .bash-guard."
fi

# kill -9 on broad targets (-1, 0, or no specific PID)
if echo "$COMMAND" | grep -qE 'kill\s+-9\s+(-1|0)\b' 2>/dev/null; then
  is_allowed "kill -9" || block "kill -9 -1 or kill -9 0 would kill all your processes." "Specify a specific PID, or add 'allow: kill -9' to .bash-guard."
fi
# killall without specific process
if echo "$COMMAND" | grep -qE 'killall\s+-9\s' 2>/dev/null; then
  is_allowed "kill -9" || block "killall -9 force-kills all matching processes without cleanup." "Use regular kill (without -9) to allow graceful shutdown, or add 'allow: kill -9' to .bash-guard."
fi

# dd targeting disk devices
if echo "$COMMAND" | grep -qE 'dd\s.*of=/dev/(sd|hd|nvme|disk|rdisk)' 2>/dev/null; then
  is_allowed "dd" || block "dd writing to a disk device can overwrite your entire drive." "Double-check the target device, or add 'allow: dd' to .bash-guard."
fi

# mkfs (format filesystem)
if echo "$COMMAND" | grep -qE 'mkfs' 2>/dev/null; then
  is_allowed "mkfs" || block "mkfs formats a filesystem, destroying all existing data on the device." "Add 'allow: mkfs' to .bash-guard if you really need to format a device."
fi

# Writing to system directories with redirects
if echo "$COMMAND" | grep -qE '>\s*/(etc|usr|System|Library|boot|sbin)/' 2>/dev/null; then
  is_allowed "system-write" || block "Redirecting output to a system directory can break your OS." "Write to a local project file instead, or add 'allow: system-write' to .bash-guard."
fi

# eval on variables (code injection risk)
if echo "$COMMAND" | grep -qE 'eval\s+.*\$[A-Za-z_]' 2>/dev/null; then
  is_allowed "eval" || block "eval on variables is a code injection risk — the variable content is executed as code." "Use the variable directly without eval, or add 'allow: eval' to .bash-guard."
fi

# npm global install
if echo "$COMMAND" | grep -qE 'npm\s+install\s+-g\b' 2>/dev/null; then
  is_allowed "global-install" || block "Global npm install modifies system-wide packages." "Use npx or local install instead, or add 'allow: global-install' to .bash-guard."
fi

log "ALLOW: $COMMAND"
exit 0
