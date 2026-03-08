#!/bin/bash
# branch-guard installer for Claude Code
# Usage: curl -sL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/branch-guard/install.sh | bash

set -euo pipefail

HOOK_NAME="branch-guard"
HOOK_URL="https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/branch-guard/hook.sh"
HOOK_DIR="$HOME/.claude/$HOOK_NAME"
HOOK_PATH="$HOOK_DIR/hook.sh"
SETTINGS_FILE="$HOME/.claude/settings.json"

echo "Installing $HOOK_NAME for Claude Code..."

# Create hook directory
mkdir -p "$HOOK_DIR"

# Download hook
echo "  Downloading hook..."
if command -v curl &>/dev/null; then
  curl -fsSL "$HOOK_URL" -o "$HOOK_PATH"
elif command -v wget &>/dev/null; then
  wget -q "$HOOK_URL" -O "$HOOK_PATH"
else
  echo "Error: curl or wget required" >&2
  exit 1
fi
chmod +x "$HOOK_PATH"

# Register in settings.json
echo "  Registering hook..."
if [ -f "$SETTINGS_FILE" ]; then
  python3 -c "
import json, sys
with open('$SETTINGS_FILE') as f:
    s = json.load(f)
hooks = s.setdefault('hooks', {})
pre = hooks.setdefault('PreToolUse', [])

# Check for existing entry
found = False
for h in pre:
    cmd = h.get('command', '')
    if '$HOOK_NAME' in cmd:
        if cmd == '$HOOK_PATH':
            found = True
        # else: legacy entry, keep it (or remove if you want migration)

if not found:
    pre.append({'type': 'command', 'command': '$HOOK_PATH'})
    print('  Hook registered')
else:
    print('  Already installed')

hooks['PreToolUse'] = pre
s['hooks'] = hooks
with open('$SETTINGS_FILE', 'w') as f:
    json.dump(s, f, indent=2)
    f.write('\n')
" 2>/dev/null || {
    echo "  Warning: Could not auto-register. Add manually to $SETTINGS_FILE:"
    echo "  hooks.PreToolUse: [{\"type\": \"command\", \"command\": \"$HOOK_PATH\"}]"
  }
else
  mkdir -p "$(dirname "$SETTINGS_FILE")"
  cat > "$SETTINGS_FILE" <<SETTINGS
{
  "hooks": {
    "PreToolUse": [
      {
        "type": "command",
        "command": "$HOOK_PATH"
      }
    ]
  }
}
SETTINGS
  echo "  Created settings with hook"
fi

echo ""
echo "Done! branch-guard is now active."
echo ""
echo "Protected branches (default): main, master, production, release"
echo "Commits to these branches will be blocked."
echo ""
echo "To customize protected branches, create .branch-guard:"
echo "  protect: main"
echo "  protect: staging"
echo ""
echo "Or use env var:"
echo "  BRANCH_GUARD_PROTECTED=main,master,staging"
echo ""
echo "Config:"
echo "  Hook: $HOOK_PATH"
echo "  Disable: BRANCH_GUARD_DISABLED=1"
echo "  Debug: BRANCH_GUARD_LOG=1"
