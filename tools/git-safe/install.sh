#!/bin/bash
# git-safe installer for Claude Code
# Usage: curl -sL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/git-safe/install.sh | bash

set -euo pipefail

HOOK_NAME="git-safe"
HOOK_URL="https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/git-safe/hook.sh"
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

# Clean up legacy install location if present
LEGACY_PATH="$HOME/.claude/hooks/$HOOK_NAME.sh"
if [ -f "$LEGACY_PATH" ]; then
  echo "  Migrating from legacy location ($LEGACY_PATH)..."
  rm -f "$LEGACY_PATH"
fi

# Register in settings.json
echo "  Registering hook..."
if [ -f "$SETTINGS_FILE" ]; then
  python3 -c "
import json, sys
with open('$SETTINGS_FILE') as f:
    s = json.load(f)
hooks = s.setdefault('hooks', {})
pre = hooks.setdefault('PreToolUse', [])

# Remove any legacy entries and check for current path
found = False
cleaned = []
for h in pre:
    cmd = h.get('command', '')
    if '$HOOK_NAME' in cmd:
        if cmd == '$HOOK_PATH':
            found = True
            cleaned.append(h)
        # else: skip legacy entry
    else:
        cleaned.append(h)

if not found:
    cleaned.append({'type': 'command', 'command': '$HOOK_PATH'})
    print('  Hook registered')
else:
    print('  Already installed')

hooks['PreToolUse'] = cleaned
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
echo "Done! git-safe is now active."
echo ""
echo "Blocked operations:"
echo "  git push --force    (use --force-with-lease instead)"
echo "  git reset --hard    (commit or stash first)"
echo "  git checkout .      (discards all changes)"
echo "  git clean -f        (deletes untracked files)"
echo "  git branch -D       (use -d for merged branches)"
echo "  git stash drop/clear"
echo ""
echo "To allow specific operations, create .git-safe:"
echo "  allow: push --force"
echo "  allow: reset --hard"
echo ""
echo "Config:"
echo "  Hook: $HOOK_PATH"
echo "  Disable: GIT_SAFE_DISABLED=1"
echo "  Debug: GIT_SAFE_LOG=1"
