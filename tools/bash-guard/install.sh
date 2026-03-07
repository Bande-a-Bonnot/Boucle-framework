#!/bin/bash
# bash-guard installer for Claude Code
# Installs the PreToolUse hook that prevents dangerous bash commands.
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/bash-guard/install.sh | bash
#
# What it does:
#   1. Downloads hook.sh to ~/.claude/hooks/
#   2. Adds it to ~/.claude/settings.json as a PreToolUse hook

set -euo pipefail

HOOK_NAME="bash-guard"
HOOK_DIR="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"
RAW_BASE="https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/bash-guard"

echo "Installing $HOOK_NAME for Claude Code..."

# Create hooks directory
mkdir -p "$HOOK_DIR"

# Download hook
echo "  Downloading hook..."
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$RAW_BASE/hook.sh" -o "$HOOK_DIR/$HOOK_NAME.sh"
elif command -v wget >/dev/null 2>&1; then
  wget -q "$RAW_BASE/hook.sh" -O "$HOOK_DIR/$HOOK_NAME.sh"
else
  echo "Error: curl or wget required" >&2
  exit 1
fi
chmod +x "$HOOK_DIR/$HOOK_NAME.sh"

# Update settings.json
echo "  Configuring Claude Code..."
HOOK_CMD="bash $HOOK_DIR/$HOOK_NAME.sh"

if [ -f "$SETTINGS" ]; then
  # Check if hook already registered
  if grep -q "$HOOK_NAME" "$SETTINGS" 2>/dev/null; then
    echo "  Hook already registered in settings.json"
  else
    # Add to existing hooks array or create it
    python3 -c "
import json, sys
with open('$SETTINGS') as f:
    settings = json.load(f)
hooks = settings.get('hooks', {})
pre = hooks.get('PreToolUse', [])
pre.append({'type': 'command', 'command': '$HOOK_CMD'})
hooks['PreToolUse'] = pre
settings['hooks'] = hooks
with open('$SETTINGS', 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
" 2>/dev/null || {
      echo "  Warning: Could not update settings.json automatically."
      echo "  Add this to your ~/.claude/settings.json manually:"
      echo "    {\"hooks\": {\"PreToolUse\": [{\"type\": \"command\", \"command\": \"$HOOK_CMD\"}]}}"
    }
  fi
else
  # Create settings.json
  cat > "$SETTINGS" << SETTINGS_EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "type": "command",
        "command": "$HOOK_CMD"
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
