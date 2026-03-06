#!/bin/bash
# read-once: PreToolUse hook for Claude Code Read tool
# Prevents redundant file reads within a session by tracking what's been read.
# When a file is re-read and hasn't changed (same mtime), blocks the read
# and tells Claude the content is already in context.
#
# Diff mode: When a file HAS changed since the last read, instead of allowing
# a full re-read, shows only what changed (the diff). Claude already has the
# old content in context — it just needs the delta. Saves 80-95% of tokens
# when iterating on files. Enable with READ_ONCE_DIFF=1.
#
# Compaction-aware: cache entries expire after READ_ONCE_TTL seconds
# (default 1200 = 20 minutes). After expiry, re-reads are allowed because
# Claude may have compacted the context and lost the earlier content.
#
# Install: Add to .claude/settings.json hooks.PreToolUse
# Savings: ~2000+ tokens per prevented re-read
#
# Config (env vars):
#   READ_ONCE_TTL=1200      Seconds before a cached read expires (default: 1200)
#   READ_ONCE_DIFF=1        Show only diff when files change (default: 0)
#   READ_ONCE_DIFF_MAX=40   Max diff lines before falling back to full re-read (default: 40)
#   READ_ONCE_DISABLED=1    Disable the hook entirely

set -euo pipefail

# Allow disabling via env var
if [ "${READ_ONCE_DISABLED:-0}" = "1" ]; then
  exit 0
fi

# Read hook input from stdin
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only handle Read tool
if [ "$TOOL_NAME" != "Read" ]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
OFFSET=$(echo "$INPUT" | jq -r '.tool_input.offset // empty')
LIMIT=$(echo "$INPUT" | jq -r '.tool_input.limit // empty')

if [ -z "$FILE_PATH" ] || [ -z "$SESSION_ID" ]; then
  exit 0
fi

# Partial reads (offset/limit) are never cached — user is exploring
# a large file piece by piece, each chunk is different content
if [ -n "$OFFSET" ] || [ -n "$LIMIT" ]; then
  exit 0
fi

# Session-scoped cache directory
CACHE_DIR="${HOME}/.claude/read-once"
mkdir -p "$CACHE_DIR"

# Diff mode config
DIFF_MODE="${READ_ONCE_DIFF:-0}"
DIFF_MAX="${READ_ONCE_DIFF_MAX:-40}"

# Snapshot directory for diff mode
if [ "$DIFF_MODE" = "1" ]; then
  SNAP_DIR="${CACHE_DIR}/snapshots"
  mkdir -p "$SNAP_DIR"
fi

# TTL: how long a cached read stays valid before we allow re-reads.
# Accounts for context compaction — after this many seconds, Claude
# may have lost the content from its working context.
TTL="${READ_ONCE_TTL:-1200}"

NOW=$(date +%s)

# Auto-cleanup: remove session caches older than 24h (runs at most once per hour)
CLEANUP_MARKER="${CACHE_DIR}/.last-cleanup"
LAST_CLEANUP=$(cat "$CLEANUP_MARKER" 2>/dev/null || echo 0)
LAST_CLEANUP=${LAST_CLEANUP:-0}
if [ $(( NOW - LAST_CLEANUP )) -gt 3600 ]; then
  find "$CACHE_DIR" -name 'session-*.jsonl' -mtime +1 -delete 2>/dev/null || true
  find "${CACHE_DIR}/snapshots" -type f -mtime +1 -delete 2>/dev/null || true
  echo "$NOW" > "$CLEANUP_MARKER"
fi

# Session cache file (one per session)
SESSION_HASH=$(echo -n "$SESSION_ID" | shasum -a 256 | cut -c1-16)
CACHE_FILE="${CACHE_DIR}/session-${SESSION_HASH}.jsonl"
STATS_FILE="${CACHE_DIR}/stats.jsonl"

# Snapshot path for this file (used in diff mode)
if [ "$DIFF_MODE" = "1" ]; then
  PATH_HASH=$(echo -n "$FILE_PATH" | shasum -a 256 | cut -c1-16)
  SNAP_FILE="${SNAP_DIR}/${SESSION_HASH}-${PATH_HASH}"
fi

# Get current file mtime (portable macOS/Linux)
if [ ! -f "$FILE_PATH" ]; then
  # File doesn't exist — let Read handle the error
  exit 0
fi

if [[ "$OSTYPE" == "darwin"* ]]; then
  CURRENT_MTIME=$(stat -f '%m' "$FILE_PATH" 2>/dev/null || echo "")
else
  CURRENT_MTIME=$(stat -c '%Y' "$FILE_PATH" 2>/dev/null || echo "")
fi

if [ -z "$CURRENT_MTIME" ]; then
  exit 0
fi

# Get file size for token estimation (~4 chars per token, line numbers add ~70%)
FILE_SIZE=$(wc -c < "$FILE_PATH" 2>/dev/null | tr -d ' ')
ESTIMATED_TOKENS=$(( (FILE_SIZE / 4) * 170 / 100 ))

# Check if we've seen this file before in this session
CACHED_MTIME=""
CACHED_TS=""
if [ -f "$CACHE_FILE" ]; then
  # Find the most recent entry for this file path
  LAST_ENTRY=$(grep -F "\"path\":\"${FILE_PATH}\"" "$CACHE_FILE" 2>/dev/null | tail -1 || echo "")
  if [ -n "$LAST_ENTRY" ]; then
    CACHED_MTIME=$(echo "$LAST_ENTRY" | jq -r '.mtime // empty' 2>/dev/null || echo "")
    CACHED_TS=$(echo "$LAST_ENTRY" | jq -r '.ts // empty' 2>/dev/null || echo "")
  fi
fi

if [ -n "$CACHED_MTIME" ] && [ "$CACHED_MTIME" = "$CURRENT_MTIME" ]; then
  # File hasn't changed since last read. But has the cache expired?
  ENTRY_AGE=0
  if [ -n "$CACHED_TS" ]; then
    ENTRY_AGE=$(( NOW - CACHED_TS ))
  fi

  if [ "$ENTRY_AGE" -ge "$TTL" ]; then
    # Cache expired — allow re-read (context may have compacted)
    # Update the cache entry with fresh timestamp
    echo "{\"path\":\"${FILE_PATH}\",\"mtime\":\"${CURRENT_MTIME}\",\"ts\":${NOW},\"tokens\":${ESTIMATED_TOKENS}}" >> "$CACHE_FILE"
    echo "{\"ts\":${NOW},\"path\":\"${FILE_PATH}\",\"tokens\":${ESTIMATED_TOKENS},\"session\":\"${SESSION_HASH}\",\"event\":\"expired\"}" >> "$STATS_FILE"
    # Update snapshot for diff mode
    if [ "$DIFF_MODE" = "1" ]; then
      cp "$FILE_PATH" "$SNAP_FILE"
    fi
    exit 0
  fi

  # Cache hit — file unchanged and within TTL
  MINUTES_AGO=$(( ENTRY_AGE / 60 ))
  echo "{\"ts\":${NOW},\"path\":\"${FILE_PATH}\",\"tokens_saved\":${ESTIMATED_TOKENS},\"session\":\"${SESSION_HASH}\",\"event\":\"hit\"}" >> "$STATS_FILE"

  # Calculate cumulative session savings for the deny message
  SESSION_SAVED=$(grep "\"session\":\"${SESSION_HASH}\"" "$STATS_FILE" 2>/dev/null | grep '"event":"hit"' | jq -r '.tokens_saved' 2>/dev/null | paste -sd+ - | bc 2>/dev/null || echo "$ESTIMATED_TOKENS")

  # Block the read — Claude should still have this content
  BASENAME=$(basename "$FILE_PATH")
  TTL_MIN=$(( TTL / 60 ))
  cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "read-once: ${BASENAME} (~${ESTIMATED_TOKENS} tokens) already in context (read ${MINUTES_AGO}m ago, unchanged). Re-read allowed after ${TTL_MIN}m. Session savings: ~${SESSION_SAVED} tokens."
  }
}
EOF
  exit 0
fi

# Cache miss or file changed
if [ -n "$CACHED_MTIME" ] && [ "$DIFF_MODE" = "1" ] && [ -f "$SNAP_FILE" ]; then
  # File changed + diff mode enabled + we have a snapshot
  # Compute diff and deny with just the changes if small enough
  DIFF_OUTPUT=$(diff -u "$SNAP_FILE" "$FILE_PATH" 2>/dev/null || true)
  DIFF_LINES=$(echo "$DIFF_OUTPUT" | wc -l | tr -d ' ')

  if [ -n "$DIFF_OUTPUT" ] && [ "$DIFF_LINES" -le "$DIFF_MAX" ]; then
    # Diff is small enough — deny with diff in the reason
    # Update cache and snapshot
    echo "{\"path\":\"${FILE_PATH}\",\"mtime\":\"${CURRENT_MTIME}\",\"ts\":${NOW},\"tokens\":${ESTIMATED_TOKENS}}" >> "$CACHE_FILE"
    cp "$FILE_PATH" "$SNAP_FILE"

    DIFF_TOKENS=$(( DIFF_LINES * 10 ))
    TOKENS_SAVED=$(( ESTIMATED_TOKENS - DIFF_TOKENS ))
    if [ "$TOKENS_SAVED" -lt 0 ]; then TOKENS_SAVED=0; fi

    echo "{\"ts\":${NOW},\"path\":\"${FILE_PATH}\",\"tokens_saved\":${TOKENS_SAVED},\"session\":\"${SESSION_HASH}\",\"event\":\"diff\"}" >> "$STATS_FILE"

    BASENAME=$(basename "$FILE_PATH")
    # Build JSON with properly escaped diff
    REASON_PREFIX="read-once: ${BASENAME} changed since last read. You already have the previous version in context. Here are only the changes (saving ~${TOKENS_SAVED} tokens):\\n\\n"
    REASON_SUFFIX="\\n\\nApply this diff mentally to your cached version of the file."
    # Use python3 to safely escape the diff for JSON embedding
    REASON=$(echo "$DIFF_OUTPUT" | python3 -c "
import sys, json
diff = sys.stdin.read()
prefix = '''${REASON_PREFIX}'''
suffix = '''${REASON_SUFFIX}'''
# json.dumps gives us a quoted escaped string; strip the quotes
escaped_diff = json.dumps(diff)[1:-1]
print(prefix + escaped_diff + suffix)
" 2>/dev/null)

    if [ -z "$REASON" ]; then
      # Python failed — fall through to full re-read
      :
    else
      cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "${REASON}"
  }
}
EOF
      exit 0
    fi
    # Python failed — fall through to full re-read
  fi
  # Diff too large or Python failed — fall through to full re-read
fi

# Record the read
echo "{\"path\":\"${FILE_PATH}\",\"mtime\":\"${CURRENT_MTIME}\",\"ts\":${NOW},\"tokens\":${ESTIMATED_TOKENS}}" >> "$CACHE_FILE"

# Save snapshot for future diffs
if [ "$DIFF_MODE" = "1" ]; then
  cp "$FILE_PATH" "$SNAP_FILE"
fi

# Log the event
if [ -n "$CACHED_MTIME" ]; then
  EVENT="changed"
else
  EVENT="miss"
fi
echo "{\"ts\":${NOW},\"path\":\"${FILE_PATH}\",\"tokens\":${ESTIMATED_TOKENS},\"session\":\"${SESSION_HASH}\",\"event\":\"${EVENT}\"}" >> "$STATS_FILE"

# Allow the read
exit 0
