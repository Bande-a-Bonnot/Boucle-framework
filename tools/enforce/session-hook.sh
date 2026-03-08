#!/usr/bin/env bash
# enforce-hooks SessionStart hook.
#
# Checks if CLAUDE.md has @enforced directives that changed since
# enforcement hooks were last generated. If so, instructs Claude
# to run the enforce-hooks skill.
#
# Lightweight: just a hash comparison. No LLM calls.
# The actual generation happens in-session via the skill,
# with full user visibility and approval.

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
CLAUDE_MD="$PROJECT_DIR/CLAUDE.md"
ENFORCEMENTS_DIR="$PROJECT_DIR/.claude/enforcements"
HASH_FILE="$ENFORCEMENTS_DIR/.hash"

# No CLAUDE.md? Nothing to do.
[ -f "$CLAUDE_MD" ] || exit 0

# Check for @enforced or @required directives
if ! grep -qi '@enforced\|@required' "$CLAUDE_MD" 2>/dev/null; then
    exit 0
fi

# Compute current hash of @enforced sections
CURRENT_HASH=$(grep -i '@enforced\|@required' "$CLAUDE_MD" | shasum -a 256 | cut -d' ' -f1)

# Compare to stored hash
if [ -f "$HASH_FILE" ]; then
    STORED_HASH=$(cat "$HASH_FILE")
    if [ "$CURRENT_HASH" = "$STORED_HASH" ]; then
        exit 0  # No changes
    fi
fi

# Directives changed (or first run). Count them.
COUNT=$(grep -ci '@enforced\|@required' "$CLAUDE_MD" 2>/dev/null || echo "0")

# Output instructions for Claude.
# This text appears in Claude's context at session start.
cat << EOF
CLAUDE.md contains $COUNT @enforced/@required directive(s) that have changed since enforcement hooks were last generated.

Run the enforce-hooks skill to review and update your enforcement hooks:
  1. Read CLAUDE.md and identify @enforced directives
  2. Show the user which rules are enforceable
  3. Generate PreToolUse hook scripts on approval
  4. Update .claude/settings.json

After generating, store the hash to prevent re-prompting:
  mkdir -p "$ENFORCEMENTS_DIR"
  echo "$CURRENT_HASH" > "$HASH_FILE"
EOF
