#!/bin/bash
# read-once: PostCompact hook — clears session cache after context compaction.
# When Claude compacts the conversation, it loses file contents from context.
# This hook resets the read-once cache so those files can be re-read immediately,
# replacing the TTL-based workaround (which could be up to 20 minutes late).
#
# Install: Add to .claude/settings.json hooks.PostCompact
# See also: hook.sh (the PreToolUse hook that tracks reads)

set -euo pipefail

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

if [ -z "$SESSION_ID" ]; then
  exit 0
fi

CACHE_DIR="${HOME}/.claude/read-once"

# Must hash session_id the same way hook.sh does
if command -v sha256sum >/dev/null 2>&1; then
  SESSION_HASH=$(echo -n "$SESSION_ID" | sha256sum | cut -c1-16)
else
  SESSION_HASH=$(echo -n "$SESSION_ID" | shasum -a 256 | cut -c1-16)
fi

CACHE_FILE="${CACHE_DIR}/session-${SESSION_HASH}.jsonl"
STATS_FILE="${CACHE_DIR}/stats.jsonl"

# Count entries being cleared (for stats)
CLEARED=0
if [ -f "$CACHE_FILE" ]; then
  CLEARED=$(wc -l < "$CACHE_FILE" | tr -d ' ')
  rm -f "$CACHE_FILE"
fi

# Clear snapshots for this session (diff mode)
if [ -d "${CACHE_DIR}/snapshots" ]; then
  find "${CACHE_DIR}/snapshots" -name "${SESSION_HASH}-*" -delete 2>/dev/null || true
fi

# Log the compaction event
NOW=$(date +%s)
if [ "$CLEARED" -gt 0 ]; then
  echo "{\"ts\":${NOW},\"session\":\"${SESSION_HASH}\",\"event\":\"compact\",\"cleared\":${CLEARED}}" >> "$STATS_FILE"
fi

exit 0
