#!/usr/bin/env bash
# Install enforce-hooks: turn CLAUDE.md rules into PreToolUse hooks.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/enforce/install.sh | bash
#
# What it does:
#   1. Copies SKILL.md to .claude/skills/enforce-hooks/
#   2. Installs session-hook.sh to .claude/hooks/
#   3. Registers a SessionStart hook in .claude/settings.json
#   4. On next session, if CLAUDE.md has @enforced directives,
#      Claude is instructed to run the skill (with your approval)

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/enforce"
SKILL_DIR=".claude/skills/enforce-hooks"
HOOKS_DIR=".claude/hooks"
SETTINGS=".claude/settings.json"

# Check we're in a project root (has CLAUDE.md or .claude/)
if [ ! -f "CLAUDE.md" ] && [ ! -d ".claude" ]; then
    echo "No CLAUDE.md or .claude/ found in current directory."
    echo "Run this from your project root."
    exit 1
fi

echo "Installing enforce-hooks..."

# Create directories
mkdir -p "$SKILL_DIR"
mkdir -p "$HOOKS_DIR"

DL="curl -fsSL"
command -v curl >/dev/null 2>&1 || DL="wget -q -O -"

# Download skill and session hook
$DL "$REPO_RAW/SKILL.md" > "$SKILL_DIR/SKILL.md"
$DL "$REPO_RAW/session-hook.sh" > "$HOOKS_DIR/enforce-session.sh"
chmod +x "$HOOKS_DIR/enforce-session.sh"

# Register SessionStart hook in project settings
if [ -f "$SETTINGS" ]; then
    # Check if already registered
    if grep -q "enforce-session" "$SETTINGS" 2>/dev/null; then
        echo "SessionStart hook already registered."
    else
        # Merge into existing settings using python
        python3 -c "
import json
with open('$SETTINGS') as f:
    settings = json.load(f)
hooks = settings.setdefault('hooks', {})
session_hooks = hooks.setdefault('SessionStart', [])
session_hooks.append({
    'matcher': '',
    'hooks': [{'type': 'command', 'command': '$HOOKS_DIR/enforce-session.sh'}]
})
with open('$SETTINGS', 'w') as f:
    json.dump(settings, f, indent=2)
print('SessionStart hook registered in $SETTINGS')
"
    fi
else
    # Create new settings file
    python3 -c "
import json
settings = {
    'hooks': {
        'SessionStart': [{
            'matcher': '',
            'hooks': [{'type': 'command', 'command': '$HOOKS_DIR/enforce-session.sh'}]
        }]
    }
}
with open('$SETTINGS', 'w') as f:
    json.dump(settings, f, indent=2)
print('Created $SETTINGS with SessionStart hook')
"
fi

echo ""
echo "Installed:"
echo "  $SKILL_DIR/SKILL.md          (skill for generating hooks)"
echo "  $HOOKS_DIR/enforce-session.sh (auto-detects CLAUDE.md changes)"
echo ""
echo "How it works:"
echo "  1. Start a Claude Code session in this project"
echo "  2. If CLAUDE.md has @enforced directives, Claude will suggest"
echo "     generating enforcement hooks"
echo "  3. You review and approve each generated hook"
echo "  4. Hooks enforce your rules at the code level, every tool call"
echo ""
echo "All project-scoped. Nothing touches ~/.claude/ or other projects."
