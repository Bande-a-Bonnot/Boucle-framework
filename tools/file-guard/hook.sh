#!/bin/bash
# file-guard: PreToolUse hook for Claude Code
# Protects specified files and directories from being modified.
#
# When Claude tries to write, edit, or run commands that would modify
# protected files, this hook blocks the operation and explains why.
#
# Protects against:
#   - Write tool targeting protected paths
#   - Edit tool targeting protected paths
#   - Bash commands containing protected paths with modifying operators
#
# Install:
#   1. Copy hook.sh to your project (or use the installer)
#   2. Create .file-guard in your project root (one path per line)
#   3. Add to .claude/settings.json:
#      "hooks": { "PreToolUse": [{ "type": "command", "command": "/path/to/hook.sh" }] }
#
# Config file (.file-guard):
#   One path per line. Supports:
#   - Exact paths: .env, secrets/api-key.txt
#   - Directory prefixes (trailing /): config/, .ssh/
#   - Shell globs: *.pem, credentials.*
#   - Comments (#) and blank lines ignored
#
# Env vars:
#   FILE_GUARD_CONFIG=path    Override config file location (default: .file-guard)
#   FILE_GUARD_DISABLED=1     Disable the hook entirely
#   FILE_GUARD_LOG=1          Log all checks to stderr (for debugging)

set -euo pipefail

# Allow disabling via env var
if [ "${FILE_GUARD_DISABLED:-0}" = "1" ]; then
  exit 0
fi

# Read hook input from stdin
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only intercept tools that can modify files
case "$TOOL_NAME" in
  Write|Edit|Bash) ;;
  *) exit 0 ;;
esac

# Find config file
CONFIG="${FILE_GUARD_CONFIG:-.file-guard}"
if [ ! -f "$CONFIG" ]; then
  # No config = nothing to protect
  exit 0
fi

# Parse protected patterns from config
PATTERNS=()
while IFS= read -r line; do
  # Skip comments and blank lines
  line=$(echo "$line" | sed 's/#.*//' | xargs)
  [ -z "$line" ] && continue
  PATTERNS+=("$line")
done < "$CONFIG"

# Nothing to protect
if [ ${#PATTERNS[@]} -eq 0 ]; then
  exit 0
fi

log() {
  if [ "${FILE_GUARD_LOG:-0}" = "1" ]; then
    echo "[file-guard] $*" >&2
  fi
}

# Check if a path matches any protected pattern
matches_protected() {
  local target="$1"

  # Normalize: remove leading ./ if present
  target="${target#./}"

  for pattern in "${PATTERNS[@]}"; do
    # Normalize pattern too
    pattern="${pattern#./}"

    # Directory prefix match (pattern ends with /)
    if [[ "$pattern" == */ ]]; then
      if [[ "$target" == "$pattern"* ]] || [[ "$target" == "${pattern%/}" ]]; then
        log "MATCH: '$target' matches directory pattern '$pattern'"
        echo "$pattern"
        return 0
      fi
      continue
    fi

    # Exact match
    if [ "$target" = "$pattern" ]; then
      log "MATCH: '$target' exact match '$pattern'"
      echo "$pattern"
      return 0
    fi

    # Glob match (using bash pattern matching)
    # shellcheck disable=SC2254
    if [[ "$(basename "$target")" == $pattern ]]; then
      log "MATCH: '$target' glob match '$pattern'"
      echo "$pattern"
      return 0
    fi

    # Also check full path glob
    # shellcheck disable=SC2254
    if [[ "$target" == $pattern ]]; then
      log "MATCH: '$target' full path glob '$pattern'"
      echo "$pattern"
      return 0
    fi
  done

  return 1
}

# Extract target path based on tool
case "$TOOL_NAME" in
  Write)
    TARGET=$(echo "$INPUT" | jq -r '.input.file_path // empty')
    if [ -z "$TARGET" ]; then
      exit 0
    fi

    # Make path relative to project root if absolute
    if [[ "$TARGET" == /* ]]; then
      PROJECT_ROOT=$(pwd)
      TARGET="${TARGET#"$PROJECT_ROOT"/}"
    fi

    if matched=$(matches_protected "$TARGET"); then
      echo '{"decision":"block","reason":"file-guard: '\''"'"$TARGET"'"'\'' is protected (matches pattern '\''"'"$matched"'"'\''). Check .file-guard config to modify protections."}'
      exit 0
    fi
    ;;

  Edit)
    TARGET=$(echo "$INPUT" | jq -r '.input.file_path // empty')
    if [ -z "$TARGET" ]; then
      exit 0
    fi

    if [[ "$TARGET" == /* ]]; then
      PROJECT_ROOT=$(pwd)
      TARGET="${TARGET#"$PROJECT_ROOT"/}"
    fi

    if matched=$(matches_protected "$TARGET"); then
      echo '{"decision":"block","reason":"file-guard: '\''"'"$TARGET"'"'\'' is protected (matches pattern '\''"'"$matched"'"'\''). Check .file-guard config to modify protections."}'
      exit 0
    fi
    ;;

  Bash)
    COMMAND=$(echo "$INPUT" | jq -r '.input.command // empty')
    if [ -z "$COMMAND" ]; then
      exit 0
    fi

    # Check each protected pattern against the command
    # We look for modifying operators near protected paths
    # This catches: rm file, mv file, > file, >> file, cp X file, etc.
    MODIFY_PATTERNS='(rm|mv|cp|chmod|chown|truncate|shred)\s|>\s*|>>'

    for pattern in "${PATTERNS[@]}"; do
      pattern="${pattern#./}"

      # Skip directory patterns for bash check (too many false positives)
      [[ "$pattern" == */ ]] && continue

      # Check if the pattern appears in the command near a modifying operator
      # Simple heuristic: if the command contains both a modify operator AND
      # a protected filename, flag it
      if echo "$COMMAND" | grep -qE "$MODIFY_PATTERNS" 2>/dev/null; then
        # Check if the protected path/glob appears in the command
        # For exact filenames
        if echo "$COMMAND" | grep -qF "$pattern" 2>/dev/null; then
          log "BASH MATCH: command contains modifier + pattern '$pattern'"
          echo '{"decision":"block","reason":"file-guard: command may modify protected path '\''"'"$pattern"'"'\'' (matches .file-guard config). Use FILE_GUARD_DISABLED=1 to override."}'
          exit 0
        fi
      fi
    done
    ;;
esac

# No match — allow
log "ALLOW: $TOOL_NAME"
exit 0
