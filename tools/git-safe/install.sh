#!/bin/bash
# git-safe installer for Claude Code
# Usage: curl -sL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/git-safe/install.sh | bash

set -euo pipefail

HOOK_URL="https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/git-safe/hook.sh"
SETTINGS_DIR="$HOME/.claude"
SETTINGS_FILE="$SETTINGS_DIR/settings.json"
HOOK_DIR="$SETTINGS_DIR/hooks"
HOOK_PATH="$HOOK_DIR/git-safe.sh"

echo "Installing git-safe for Claude Code..."

# Create directories
mkdir -p "$HOOK_DIR"

# Download hook
echo "  Downloading hook..."
if command -v curl &>/dev/null; then
  curl -sL "$HOOK_URL" -o "$HOOK_PATH"
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
for h in pre:
    if 'git-safe' in h.get('command', ''):
        print('  Already installed')
        sys.exit(0)
pre.append({'type': 'command', 'command': '$HOOK_PATH'})
with open('$SETTINGS_FILE', 'w') as f:
    json.dump(s, f, indent=2)
print('  Hook registered')
" 2>/dev/null || {
    echo "  Warning: Could not auto-register. Add manually to $SETTINGS_FILE:"
    echo "  hooks.PreToolUse: [{\"type\": \"command\", \"command\": \"$HOOK_PATH\"}]"
  }
else
  mkdir -p "$SETTINGS_DIR"
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
