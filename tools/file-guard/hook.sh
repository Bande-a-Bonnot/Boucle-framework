#!/bin/bash
# file-guard: PreToolUse hook for Claude Code
# Protects specified files and directories from being accessed or modified.
#
# Two protection levels:
#   - Write protection (default): blocks Write, Edit, and modifying Bash commands
#   - Access denial ([deny] section): blocks Read, Grep, Glob, and all Bash access
#
# Protects against:
#   - Write/Edit tool targeting protected paths
#   - Read tool targeting denied paths
#   - Grep/Glob searching denied paths
#   - Bash commands containing protected/denied paths
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
#   - [deny] section header: blocks ALL access (reads too)
#
# Example .file-guard:
#   # Write-protected (Claude can read but not modify)
#   .env
#   secrets/*.key
#
#   # Deny all access (Claude cannot read, search, or modify)
#   [deny]
#   codegen/
#   generated/
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

# Reject relative paths in Write/Edit (always active, no config needed)
# Claude Code's Write/Edit tools require absolute paths. When a confused model
# provides a relative path, the write lands in the wrong location.
# See: https://github.com/anthropics/claude-code/issues/38270
if [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ]; then
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
  if [ -n "$FILE_PATH" ] && [[ "$FILE_PATH" != /* ]]; then
    ABSOLUTE_HINT="$(pwd)/$FILE_PATH"
    jq -cn --arg p "$FILE_PATH" --arg hint "$ABSOLUTE_HINT" \
      '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":("file-guard: relative path \"" + $p + "\" rejected. Write/Edit require absolute paths to prevent writing to the wrong location. Try: " + $hint)}}'
    exit 0
  fi
fi

# Find config file
CONFIG="${FILE_GUARD_CONFIG:-.file-guard}"
if [ ! -f "$CONFIG" ]; then
  # No config = nothing to protect
  exit 0
fi

# Parse protected patterns from config (two sections)
WRITE_PATTERNS=()
DENY_PATTERNS=()
CURRENT_SECTION="write"

while IFS= read -r line; do
  # Skip comments and blank lines
  line=$(echo "$line" | sed 's/#.*//' | xargs)
  [ -z "$line" ] && continue

  # Section headers
  if [[ "$line" == "[deny]" ]]; then
    CURRENT_SECTION="deny"
    continue
  fi
  if [[ "$line" == "[write]" ]] || [[ "$line" == "[protect]" ]]; then
    CURRENT_SECTION="write"
    continue
  fi

  case "$CURRENT_SECTION" in
    write) WRITE_PATTERNS+=("$line") ;;
    deny) DENY_PATTERNS+=("$line") ;;
  esac
done < "$CONFIG"

# Nothing to protect
if [ ${#WRITE_PATTERNS[@]} -eq 0 ] && [ ${#DENY_PATTERNS[@]} -eq 0 ]; then
  exit 0
fi

# Determine which tools to intercept
case "$TOOL_NAME" in
  Write|Edit|Bash)
    # Always check (write protection + deny)
    ;;
  Read|Grep|Glob)
    # Only check if deny patterns exist
    if [ ${#DENY_PATTERNS[@]} -eq 0 ]; then
      exit 0
    fi
    ;;
  *)
    exit 0
    ;;
esac

log() {
  if [ "${FILE_GUARD_LOG:-0}" = "1" ]; then
    echo "[file-guard] $*" >&2
  fi
}

# Normalize a path: resolve ./ and .. components to prevent traversal bypass
normalize_path() {
  local p="$1"
  p="${p#./}"

  # Make absolute path relative to project root
  if [[ "$p" == /* ]]; then
    local root
    root=$(pwd)
    p="${p#"$root"/}"
    # Still absolute = outside project root, return as-is
    if [[ "$p" == /* ]]; then
      echo "$p"
      return
    fi
  fi

  # Collapse .. segments (pure bash, compatible with bash 3.2/macOS + set -u)
  if [[ "$p" == */../* ]] || [[ "$p" == ../* ]] || [[ "$p" == */.. ]]; then
    local oldifs="$IFS"
    IFS='/'
    local -a parts=()
    local -a result=()
    read -ra parts <<< "$p"
    IFS="$oldifs"
    for part in "${parts[@]+"${parts[@]}"}"; do
      if [ "$part" = ".." ]; then
        local len=${#result[@]}
        if [ "$len" -gt 0 ]; then
          local last="${result[$((len-1))]}"
          if [ "$last" != ".." ]; then
            unset "result[$((len-1))]"
            # Re-index: bash 3.2 leaves gaps after unset
            if [ ${#result[@]} -gt 0 ]; then
              result=("${result[@]}")
            else
              result=()
            fi
          else
            result+=("..")
          fi
        else
          result+=("..")
        fi
      elif [ "$part" != "." ] && [ -n "$part" ]; then
        result+=("$part")
      fi
    done
    local out=""
    for part in "${result[@]+"${result[@]}"}"; do
      out="${out:+$out/}$part"
    done
    p="${out:-.}"
  fi

  echo "$p"
}

# Resolve symlinks to their real target path.
# Prevents bypass where a symlink to a protected file is accessed via the link name.
# See: GHSA-4q92-rfm6-2cqx (Permission Deny Bypass Through Symbolic Links)
resolve_symlinks() {
  local p="$1"
  # Only resolve if path exists as a symlink or has symlink components
  [ -e "$p" ] || [ -L "$p" ] || { echo "$p"; return; }
  # readlink -f: GNU coreutils (Linux) and macOS 13+
  local resolved
  resolved=$(readlink -f "$p" 2>/dev/null) && { echo "$resolved"; return; }
  # Fallback: follow symlink chain (max 10 hops, prevents infinite loops)
  local count=0
  while [ -L "$p" ] && [ $count -lt 10 ]; do
    local link_dir
    link_dir=$(cd "$(dirname "$p")" 2>/dev/null && pwd) || break
    p=$(readlink "$p" 2>/dev/null) || break
    [[ "$p" != /* ]] && p="$link_dir/$p"
    count=$((count + 1))
  done
  echo "$p"
}

# Check if a path matches any pattern in a list
# Usage: matches_any "target/path" "pattern1" "pattern2" ...
# Outputs the matched pattern on stdout (return 0), or returns 1
matches_any() {
  local target="$1"
  shift

  # Normalize target to prevent traversal bypass
  target=$(normalize_path "$target")

  for pattern in "$@"; do
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

# Extract target path based on tool and check against patterns
case "$TOOL_NAME" in
  Write|Edit)
    RAW_TARGET=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
    if [ -z "$RAW_TARGET" ]; then
      exit 0
    fi

    TARGET=$(normalize_path "$RAW_TARGET")

    # Resolve symlinks to prevent bypass (GHSA-4q92-rfm6-2cqx)
    SYM_RESOLVED=$(resolve_symlinks "$RAW_TARGET")
    SYM_TARGET=""
    if [ "$SYM_RESOLVED" != "$RAW_TARGET" ]; then
      SYM_TARGET=$(normalize_path "$SYM_RESOLVED")
      [ "$SYM_TARGET" = "$TARGET" ] && SYM_TARGET=""
    fi

    # Check deny patterns first (blocks all access)
    if [ ${#DENY_PATTERNS[@]} -gt 0 ]; then
      if matched=$(matches_any "$TARGET" "${DENY_PATTERNS[@]}"); then
        jq -cn --arg t "$TARGET" --arg p "$matched" \
          '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":("file-guard: access to \"" + $t + "\" is denied (matches [deny] pattern \"" + $p + "\"). Check .file-guard config.")}}'
        exit 0
      fi
      if [ -n "$SYM_TARGET" ] && matched=$(matches_any "$SYM_TARGET" "${DENY_PATTERNS[@]}"); then
        jq -cn --arg t "$TARGET" --arg r "$SYM_TARGET" --arg p "$matched" \
          '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":("file-guard: \"" + $t + "\" is a symlink to denied path \"" + $r + "\" (matches [deny] pattern \"" + $p + "\"). Check .file-guard config.")}}'
        exit 0
      fi
    fi

    # Check write-protect patterns
    if [ ${#WRITE_PATTERNS[@]} -gt 0 ]; then
      if matched=$(matches_any "$TARGET" "${WRITE_PATTERNS[@]}"); then
        jq -cn --arg t "$TARGET" --arg p "$matched" \
          '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":("file-guard: \"" + $t + "\" is protected (matches pattern \"" + $p + "\"). Check .file-guard config to modify protections.")}}'
        exit 0
      fi
      if [ -n "$SYM_TARGET" ] && matched=$(matches_any "$SYM_TARGET" "${WRITE_PATTERNS[@]}"); then
        jq -cn --arg t "$TARGET" --arg r "$SYM_TARGET" --arg p "$matched" \
          '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":("file-guard: \"" + $t + "\" is a symlink to protected path \"" + $r + "\" (matches pattern \"" + $p + "\"). Check .file-guard config.")}}'
        exit 0
      fi
    fi
    ;;

  Read)
    RAW_TARGET=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
    if [ -z "$RAW_TARGET" ]; then
      exit 0
    fi

    TARGET=$(normalize_path "$RAW_TARGET")

    # Resolve symlinks to prevent bypass (GHSA-4q92-rfm6-2cqx)
    SYM_RESOLVED=$(resolve_symlinks "$RAW_TARGET")
    SYM_TARGET=""
    if [ "$SYM_RESOLVED" != "$RAW_TARGET" ]; then
      SYM_TARGET=$(normalize_path "$SYM_RESOLVED")
      [ "$SYM_TARGET" = "$TARGET" ] && SYM_TARGET=""
    fi

    # Only deny patterns block reads (write-protect allows reading)
    if matched=$(matches_any "$TARGET" "${DENY_PATTERNS[@]}"); then
      jq -cn --arg t "$TARGET" --arg p "$matched" \
        '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":("file-guard: reading \"" + $t + "\" is denied (matches [deny] pattern \"" + $p + "\"). Check .file-guard config.")}}'
      exit 0
    fi
    if [ -n "$SYM_TARGET" ] && matched=$(matches_any "$SYM_TARGET" "${DENY_PATTERNS[@]}"); then
      jq -cn --arg t "$TARGET" --arg r "$SYM_TARGET" --arg p "$matched" \
        '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":("file-guard: reading \"" + $t + "\" is denied (symlink to \"" + $r + "\", matches [deny] pattern \"" + $p + "\"). Check .file-guard config.")}}'
      exit 0
    fi
    ;;

  Grep)
    RAW_TARGET=$(echo "$INPUT" | jq -r '.tool_input.path // empty')
    if [ -z "$RAW_TARGET" ]; then
      # No explicit path = searching cwd, don't block
      exit 0
    fi

    TARGET=$(normalize_path "$RAW_TARGET")

    # Resolve symlinks to prevent bypass (GHSA-4q92-rfm6-2cqx)
    SYM_RESOLVED=$(resolve_symlinks "$RAW_TARGET")
    SYM_TARGET=""
    if [ "$SYM_RESOLVED" != "$RAW_TARGET" ]; then
      SYM_TARGET=$(normalize_path "$SYM_RESOLVED")
      [ "$SYM_TARGET" = "$TARGET" ] && SYM_TARGET=""
    fi

    if matched=$(matches_any "$TARGET" "${DENY_PATTERNS[@]}"); then
      jq -cn --arg t "$TARGET" --arg p "$matched" \
        '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":("file-guard: searching \"" + $t + "\" is denied (matches [deny] pattern \"" + $p + "\"). Check .file-guard config.")}}'
      exit 0
    fi
    if [ -n "$SYM_TARGET" ] && matched=$(matches_any "$SYM_TARGET" "${DENY_PATTERNS[@]}"); then
      jq -cn --arg t "$TARGET" --arg r "$SYM_TARGET" --arg p "$matched" \
        '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":("file-guard: searching \"" + $t + "\" is denied (symlink to \"" + $r + "\", matches [deny] pattern \"" + $p + "\"). Check .file-guard config.")}}'
      exit 0
    fi
    ;;

  Glob)
    RAW_TARGET=$(echo "$INPUT" | jq -r '.tool_input.path // empty')
    if [ -z "$RAW_TARGET" ]; then
      exit 0
    fi

    TARGET=$(normalize_path "$RAW_TARGET")

    # Resolve symlinks to prevent bypass (GHSA-4q92-rfm6-2cqx)
    SYM_RESOLVED=$(resolve_symlinks "$RAW_TARGET")
    SYM_TARGET=""
    if [ "$SYM_RESOLVED" != "$RAW_TARGET" ]; then
      SYM_TARGET=$(normalize_path "$SYM_RESOLVED")
      [ "$SYM_TARGET" = "$TARGET" ] && SYM_TARGET=""
    fi

    if matched=$(matches_any "$TARGET" "${DENY_PATTERNS[@]}"); then
      jq -cn --arg t "$TARGET" --arg p "$matched" \
        '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":("file-guard: listing \"" + $t + "\" is denied (matches [deny] pattern \"" + $p + "\"). Check .file-guard config.")}}'
      exit 0
    fi
    if [ -n "$SYM_TARGET" ] && matched=$(matches_any "$SYM_TARGET" "${DENY_PATTERNS[@]}"); then
      jq -cn --arg t "$TARGET" --arg r "$SYM_TARGET" --arg p "$matched" \
        '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":("file-guard: listing \"" + $t + "\" is denied (symlink to \"" + $r + "\", matches [deny] pattern \"" + $p + "\"). Check .file-guard config.")}}'
      exit 0
    fi
    ;;

  Bash)
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
    if [ -z "$COMMAND" ]; then
      exit 0
    fi

    # Check deny patterns: ANY reference to denied paths blocks the command
    for pattern in "${DENY_PATTERNS[@]+"${DENY_PATTERNS[@]}"}"; do
      pattern="${pattern#./}"

      if [[ "$pattern" == */ ]]; then
        # Directory pattern: check if dir name appears in command
        dir="${pattern%/}"
        if echo "$COMMAND" | grep -qF "$dir" 2>/dev/null; then
          log "BASH DENY: command references denied directory '$pattern'"
          jq -cn --arg p "$pattern" \
            '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":("file-guard: command references denied path \"" + $p + "\" (matches [deny] in .file-guard). Check .file-guard config.")}}'
          exit 0
        fi
      else
        # File pattern: check if it appears in command
        if echo "$COMMAND" | grep -qF "$pattern" 2>/dev/null; then
          log "BASH DENY: command references denied file '$pattern'"
          jq -cn --arg p "$pattern" \
            '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":("file-guard: command references denied path \"" + $p + "\" (matches [deny] in .file-guard). Check .file-guard config.")}}'
          exit 0
        fi
      fi
    done

    # Check write-protect patterns: only modifying operations (existing behavior)
    MODIFY_PATTERNS='(rm|mv|cp|chmod|chown|truncate|shred)\s|>\s*|>>'

    for pattern in "${WRITE_PATTERNS[@]+"${WRITE_PATTERNS[@]}"}"; do
      pattern="${pattern#./}"

      # Skip directory patterns for bash check (too many false positives)
      [[ "$pattern" == */ ]] && continue

      # Check if the command contains both a modify operator AND a protected filename
      if echo "$COMMAND" | grep -qE "$MODIFY_PATTERNS" 2>/dev/null; then
        if echo "$COMMAND" | grep -qF "$pattern" 2>/dev/null; then
          log "BASH MATCH: command contains modifier + pattern '$pattern'"
          jq -cn --arg p "$pattern" \
            '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":("file-guard: command may modify protected path \"" + $p + "\" (matches .file-guard config). Use FILE_GUARD_DISABLED=1 to override.")}}'
          exit 0
        fi
      fi
    done
    ;;
esac

# No match — allow
log "ALLOW: $TOOL_NAME"
exit 0
