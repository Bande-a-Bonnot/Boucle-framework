#!/usr/bin/env bash
# enforce: Never use git push --force or git push -f.
# Generated from CLAUDE.md by enforce-hooks skill
INPUT=$(cat)
[ "$(echo "$INPUT" | jq -r '.tool_name')" != "Bash" ] && exit 0
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
for pat in "push --force" "push -f"; do
  [[ "$CMD" == *"$pat"* ]] && echo '{"hookSpecificOutput": {"permissionDecision": "deny", "permissionDecisionReason": "Force push blocked. Use --force-with-lease instead. (CLAUDE.md: No Force Push @enforced)"}}' && exit 0
done
exit 0
