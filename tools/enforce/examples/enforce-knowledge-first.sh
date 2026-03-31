#!/usr/bin/env bash
# enforce: Before any WebSearch, Claude MUST grep the knowledge vault (docs/) first.
# Generated from CLAUDE.md by enforce-hooks skill
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name')
case "$TOOL" in WebSearch|WebFetch) ;; *) exit 0 ;; esac
# Check session log for prior Grep usage
TODAY=$(date -u +%Y-%m-%d)
LOG="$HOME/.claude/session-logs/$TODAY.jsonl"
if [ -f "$LOG" ]; then
  if grep -q '"tool":"Grep"' "$LOG" 2>/dev/null; then
    exit 0
  fi
fi
echo '{"hookSpecificOutput": {"permissionDecision": "deny", "permissionDecisionReason": "Search docs/ with Grep before using WebSearch. (CLAUDE.md: Knowledge Retrieval @enforced)"}}'
exit 0
