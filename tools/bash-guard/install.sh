#!/bin/bash
# bash-guard installer for Claude Code
# Installs the PreToolUse hook that prevents dangerous bash commands.
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/bash-guard/install.sh | bash
#
# What it does:
#   1. Downloads hook.sh to ~/.claude/bash-guard/
#   2. Adds it to ~/.claude/settings.json as a PreToolUse hook

set -euo pipefail

HOOK_NAME="bash-guard"
HOOK_DIR="$HOME/.claude/$HOOK_NAME"
HOOK_PATH="$HOOK_DIR/hook.sh"
SETTINGS="$HOME/.claude/settings.json"
RAW_BASE="https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/bash-guard"

echo "Installing $HOOK_NAME for Claude Code..."

# Create hook directory
mkdir -p "$HOOK_DIR"

# Download hook
echo "  Downloading hook..."
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$RAW_BASE/hook.sh" -o "$HOOK_PATH"
elif command -v wget >/dev/null 2>&1; then
  wget -q "$RAW_BASE/hook.sh" -O "$HOOK_PATH"
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

# Update settings.json
echo "  Configuring Claude Code..."

if [ -f "$SETTINGS" ]; then
  # Check if hook already registered (at either old or new path)
  if python3 -c "
import json, sys
with open('$SETTINGS') as f:
    settings = json.load(f)
hooks = settings.get('hooks', {})
pre = hooks.get('PreToolUse', [])

def get_cmd(entry):
    cmd = entry.get('command', '')
    if not cmd:
        for hk in entry.get('hooks', []):
            c = hk.get('command', '')
            if c: return c
    return cmd

# Remove legacy/flat entries and check for current path
found = False
cleaned = []
for h in pre:
    cmd = get_cmd(h)
    if '$HOOK_NAME' in cmd:
        if '$HOOK_PATH' in cmd:
            found = True
            # Migrate flat to nested if needed
            if 'hooks' not in h:
                cleaned.append({'hooks': [{'type': 'command', 'command': '$HOOK_PATH'}]})
            else:
                cleaned.append(h)
        # else: skip legacy entry (different path)
    else:
        cleaned.append(h)

if not found:
    cleaned.append({'hooks': [{'type': 'command', 'command': '$HOOK_PATH'}]})
    print('  Hook registered')
else:
    print('  Already installed')

hooks['PreToolUse'] = cleaned
settings['hooks'] = hooks
with open('$SETTINGS', 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
" 2>/dev/null; then
    :
  else
    echo "  Warning: Could not update settings.json automatically."
    echo "  Add this to your ~/.claude/settings.json manually:"
    echo "    {\"hooks\": {\"PreToolUse\": [{\"type\": \"command\", \"command\": \"$HOOK_PATH\"}]}}"
  fi
else
  # Create settings.json
  mkdir -p "$(dirname "$SETTINGS")"
  cat > "$SETTINGS" << SETTINGS_EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$HOOK_PATH"
          }
        ]
      }
    ]
  }
}
SETTINGS_EOF
fi

echo ""
echo "bash-guard installed!"
echo ""
echo "What it blocks:"
echo "  - rm -rf on critical paths (/, ~, /usr, etc.)"
echo "  - chmod -R 777/000 (dangerous permissions)"
echo "  - curl|bash (pipe to shell)"
echo "  - sudo (privilege escalation)"
echo "  - kill -9 on broad targets"
echo "  - dd/mkfs on disk devices"
echo "  - Writes to system directories"
echo "  - eval on variables"
echo "  - npm install -g (global installs)"
echo ""
echo "Configure exceptions in .bash-guard:"
echo "  echo 'allow: sudo' > .bash-guard"
echo ""
echo "Disable temporarily:"
echo "  export BASH_GUARD_DISABLED=1"
