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
#   READ_ONCE_MODE=warn     "warn" (default) allows read with advisory, "deny" blocks it.
#                           warn mode prevents Edit deadlock and parallel read cascade failures.
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

find_python_cmd() {
  if [ -n "${READ_ONCE_PYTHON_CMD:-}" ] && command -v "$READ_ONCE_PYTHON_CMD" >/dev/null 2>&1; then
    printf '%s\n' "$READ_ONCE_PYTHON_CMD"
    return 0
  fi
  for _cmd in py python3 python; do
    if command -v "$_cmd" >/dev/null 2>&1; then
      printf '%s\n' "$_cmd"
      return 0
    fi
  done
  return 1
}

PYTHON_CMD=$(find_python_cmd || true)

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

# Claude Code on Windows can pass Git Bash hooks C:\style paths. Bash file
# tests need forward slashes, and Git Bash accepts C:/style paths.
FILE_PATH="${FILE_PATH//\\//}"

# Partial reads (offset/limit) are never cached — user is exploring
# a large file piece by piece, each chunk is different content
if [ -n "$OFFSET" ] || [ -n "$LIMIT" ]; then
  exit 0
fi

# Session-scoped cache directory
CACHE_DIR="${HOME}/.claude/read-once"
mkdir -p "$CACHE_DIR"

# Mode: "warn" (default) allows read with advisory message, "deny" blocks it.
# warn mode fixes: Edit tool deadlock, parallel read cascade failures.
MODE="${READ_ONCE_MODE:-warn}"

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
# Portable hash: sha256sum (Linux) or shasum (macOS)
if command -v sha256sum >/dev/null 2>&1; then
  SESSION_HASH=$(echo -n "$SESSION_ID" | sha256sum | cut -c1-16)
else
  SESSION_HASH=$(echo -n "$SESSION_ID" | shasum -a 256 | cut -c1-16)
fi
CACHE_FILE="${CACHE_DIR}/session-${SESSION_HASH}.jsonl"
STATS_FILE="${CACHE_DIR}/stats.jsonl"
TOKEN_CACHE_FILE="${CACHE_DIR}/token-estimates.jsonl"

# Snapshot path for this file (used in diff mode)
if [ "$DIFF_MODE" = "1" ]; then
  if command -v sha256sum >/dev/null 2>&1; then
    PATH_HASH=$(echo -n "$FILE_PATH" | sha256sum | cut -c1-16)
  else
    PATH_HASH=$(echo -n "$FILE_PATH" | shasum -a 256 | cut -c1-16)
  fi
  SNAP_FILE="${SNAP_DIR}/${SESSION_HASH}-${PATH_HASH}"
fi

write_cache_entry() {
  jq -cn \
    --arg path "$FILE_PATH" \
    --arg mtime "$CURRENT_MTIME" \
    --argjson ts "$NOW" \
    --argjson tokens "$ESTIMATED_TOKENS" \
    '{path:$path,mtime:$mtime,ts:$ts,tokens:$tokens}' >> "$CACHE_FILE"
}

is_binary_read_target() {
  case "${1##*.}" in
    7z|a|avif|bin|bmp|class|dll|dmg|exe|gif|gz|heic|ico|jar|jpeg|jpg|mov|mp3|mp4|o|pdf|png|pyc|rar|so|tar|tiff|webp|zip)
      return 0
      ;;
  esac
  return 1
}

estimate_read_tokens() {
  local file="$1"
  local cache_entry cached estimated

  if is_binary_read_target "$file"; then
    printf '0\n'
    return 0
  fi

  cache_entry=$(jq -Rrc \
    --arg path "$file" \
    --arg mtime "$CURRENT_MTIME" \
    'fromjson? | select(.path == $path and .mtime == $mtime)' \
    "$TOKEN_CACHE_FILE" 2>/dev/null | tail -1 || true)
  cached=$(printf '%s' "$cache_entry" | jq -r '.tokens // empty' 2>/dev/null || true)
  if [ -n "$cached" ]; then
    printf '%s\n' "$cached"
    return 0
  fi

  if [ -n "$PYTHON_CMD" ] && "$PYTHON_CMD" - "$file" >/dev/null 2>&1 <<'PY_CHECK'
import importlib.util
import sys
sys.exit(0 if importlib.util.find_spec("tiktoken") else 1)
PY_CHECK
  then
    estimated=$("$PYTHON_CMD" - "$file" <<'PY_ESTIMATE'
import sys
import tiktoken

path = sys.argv[1]
enc = tiktoken.get_encoding("cl100k_base")
parts = []
with open(path, "r", encoding="utf-8", errors="replace") as f:
    for idx, line in enumerate(f, 1):
        if idx > 2000:
            break
        parts.append(f"{idx:>6}\t{line}")
print(len(enc.encode("".join(parts))))
PY_ESTIMATE
)
    jq -cn --arg path "$file" --arg mtime "$CURRENT_MTIME" --argjson tokens "$estimated" \
      '{path:$path,mtime:$mtime,tokens:$tokens}' >> "$TOKEN_CACHE_FILE"
    printf '%s\n' "$estimated"
    return 0
  fi

  # Fallback: estimate only Claude Read's first 2000 displayed lines. This
  # avoids crediting token savings for file content Claude would not return.
  estimated=$(awk 'NR <= 2000 { printf "%6d\t%s\n", NR, $0 }' "$file" \
    | wc -c \
    | awk '{ n = int(($1 / 4) * 17 / 10); if (n < 1 && $1 > 0) n = 1; print n }')
  jq -cn --arg path "$file" --arg mtime "$CURRENT_MTIME" --argjson tokens "$estimated" \
    '{path:$path,mtime:$mtime,tokens:$tokens}' >> "$TOKEN_CACHE_FILE"
  printf '%s\n' "$estimated"
}

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

# Estimate token cost for what Claude Read would actually return.
ESTIMATED_TOKENS=$(estimate_read_tokens "$FILE_PATH")

# Check if we've seen this file before in this session
CACHED_MTIME=""
CACHED_TS=""
if [ -f "$CACHE_FILE" ]; then
  # Find the most recent entry for this file path
  LAST_ENTRY=$(jq -Rrc --arg path "$FILE_PATH" 'fromjson? | select(.path == $path)' "$CACHE_FILE" 2>/dev/null | tail -1 || echo "")
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
    write_cache_entry
    jq -cn \
      --arg path "$FILE_PATH" \
      --arg session "$SESSION_HASH" \
      --arg event "expired" \
      --argjson ts "$NOW" \
      --argjson tokens "$ESTIMATED_TOKENS" \
      '{ts:$ts,path:$path,tokens:$tokens,session:$session,event:$event}' >> "$STATS_FILE"
    # Update snapshot for diff mode
    if [ "$DIFF_MODE" = "1" ]; then
      cp "$FILE_PATH" "$SNAP_FILE"
    fi
    exit 0
  fi

  # Cache hit — file unchanged and within TTL
  MINUTES_AGO=$(( ENTRY_AGE / 60 ))
  jq -cn \
    --arg path "$FILE_PATH" \
    --arg session "$SESSION_HASH" \
    --arg event "hit" \
    --argjson ts "$NOW" \
    --argjson tokens_saved "$ESTIMATED_TOKENS" \
    '{ts:$ts,path:$path,tokens_saved:$tokens_saved,session:$session,event:$event}' >> "$STATS_FILE"

  # Calculate cumulative session savings for the deny message
  SESSION_SAVED=$(grep "\"session\":\"${SESSION_HASH}\"" "$STATS_FILE" 2>/dev/null | grep '"event":"hit"' | jq -r '.tokens_saved' 2>/dev/null | paste -sd+ - | bc 2>/dev/null || echo "$ESTIMATED_TOKENS")

  BASENAME=$(basename "$FILE_PATH")
  TTL_MIN=$(( TTL / 60 ))

  # Cost estimate (Sonnet $3/MTok)
  COST_INFO=""
  if command -v python3 &>/dev/null && [ "$SESSION_SAVED" -gt 0 ]; then
    COST_INFO=$(echo "$SESSION_SAVED" | python3 -c "import sys; t=int(sys.stdin.read().strip()); print(' (~\$%.4f saved at Sonnet rates)' % (t*3/1000000))" 2>/dev/null || echo "")
  fi

  REASON="read-once: ${BASENAME} (~${ESTIMATED_TOKENS} tokens) already in context (read ${MINUTES_AGO}m ago, unchanged). Re-read allowed after ${TTL_MIN}m. Session savings: ~${SESSION_SAVED} tokens${COST_INFO}."

  if [ "$MODE" = "deny" ]; then
    # Hard block — saves tokens but breaks Edit tool and parallel reads.
    # Use top-level decision:block so Claude reliably honors the deny path.
    jq -cn --arg r "$REASON" '{"decision":"block","reason":$r}'
  else
    # Warn mode (default) — allow the read with advisory message.
    # Prevents Edit tool deadlock (Edit requires a prior Read to succeed)
    # and parallel read cascade failures (one deny kills all parallel reads).
    jq -cn --arg r "$REASON" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":$r}}'
  fi
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
    write_cache_entry
    cp "$FILE_PATH" "$SNAP_FILE"

    DIFF_TOKENS=$(( DIFF_LINES * 10 ))
    TOKENS_SAVED=$(( ESTIMATED_TOKENS - DIFF_TOKENS ))
    if [ "$TOKENS_SAVED" -lt 0 ]; then TOKENS_SAVED=0; fi

    jq -cn \
      --arg path "$FILE_PATH" \
      --arg session "$SESSION_HASH" \
      --arg event "diff" \
      --argjson ts "$NOW" \
      --argjson tokens_saved "$TOKENS_SAVED" \
      '{ts:$ts,path:$path,tokens_saved:$tokens_saved,session:$session,event:$event}' >> "$STATS_FILE"

    BASENAME=$(basename "$FILE_PATH")
    REASON=$(printf 'read-once: %s changed since last read. You already have the previous version in context. Here are only the changes (saving ~%s tokens):\n\n%s\n\nApply this diff mentally to your cached version of the file.' "$BASENAME" "$TOKENS_SAVED" "$DIFF_OUTPUT")

    if [ "$MODE" = "deny" ]; then
      # Use top-level decision:block so Claude reliably honors the deny path.
      jq -cn --arg r "$REASON" '{"decision":"block","reason":$r}'
    else
      jq -cn --arg r "$REASON" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":$r}}'
    fi
    exit 0
  fi
  # Diff too large — fall through to full re-read
fi

# Record the read
write_cache_entry

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
jq -cn \
  --arg path "$FILE_PATH" \
  --arg session "$SESSION_HASH" \
  --arg event "$EVENT" \
  --argjson ts "$NOW" \
  --argjson tokens "$ESTIMATED_TOKENS" \
  '{ts:$ts,path:$path,tokens:$tokens,session:$session,event:$event}' >> "$STATS_FILE"

# Allow the read
exit 0
