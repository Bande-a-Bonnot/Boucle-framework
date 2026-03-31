#!/usr/bin/env bash
# enforce: Run cargo test before committing any Rust code changes.
# Generated from CLAUDE.md by enforce-hooks skill
INPUT=$(cat)
[ "$(echo "$INPUT" | jq -r '.tool_name')" != "Bash" ] && exit 0
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[[ "$CMD" != *"git commit"* ]] && exit 0
# Check session log for prior cargo test
TODAY=$(date -u +%Y-%m-%d)
LOG="$HOME/.claude/session-logs/$TODAY.jsonl"
if [ -f "$LOG" ]; then
  if grep -q '"command":"cargo test' "$LOG" 2>/dev/null; then
    exit 0
  fi
fi
echo '{"hookSpecificOutput": {"permissionDecision": "deny", "permissionDecisionReason": "Run cargo test before committing. (CLAUDE.md: Testing @required)"}}'
exit 0
