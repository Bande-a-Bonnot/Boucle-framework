#!/bin/bash
# read-once installer — download and configure in one step
# Usage: curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/read-once/install.sh | bash
set -euo pipefail

REPO="https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/read-once"
INSTALL_DIR="${HOME}/.claude/read-once"
SETTINGS="${HOME}/.claude/settings.json"

echo "read-once: installing to ${INSTALL_DIR}"

# Create directory
mkdir -p "$INSTALL_DIR"

# Download hook and CLI
curl -fsSL "${REPO}/hook.sh" -o "${INSTALL_DIR}/hook.sh"
curl -fsSL "${REPO}/read-once" -o "${INSTALL_DIR}/read-once"
chmod +x "${INSTALL_DIR}/hook.sh" "${INSTALL_DIR}/read-once"

echo "read-once: downloaded hook.sh and read-once CLI"

# Add hook to settings.json
if [ ! -f "$SETTINGS" ]; then
  echo "read-once: creating ${SETTINGS}"
  mkdir -p "$(dirname "$SETTINGS")"
  cat > "$SETTINGS" << 'SETTINGS_EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Read",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/read-once/hook.sh"
          }
        ]
      }
    ]
  }
}
SETTINGS_EOF
  echo "read-once: created settings with hook configured"
else
  # Check if hook already configured
  if grep -q "read-once" "$SETTINGS" 2>/dev/null; then
    echo "read-once: hook already in settings.json"
  else
    echo "read-once: settings.json exists — add the hook manually:"
    echo ""
    echo '  "hooks": {'
    echo '    "PreToolUse": ['
    echo '      {'
    echo '        "matcher": "Read",'
    echo '        "hooks": ['
    echo '          {'
    echo '            "type": "command",'
    echo '            "command": "~/.claude/read-once/hook.sh"'
    echo '          }'
    echo '        ]'
    echo '      }'
    echo '    ]'
    echo '  }'
    echo ""
    echo "  Or run: ~/.claude/read-once/read-once install"
  fi
fi

echo ""
echo "read-once: installed. Start a new Claude Code session to activate."
echo "  Stats:     ~/.claude/read-once/read-once stats"
echo "  Uninstall: ~/.claude/read-once/read-once uninstall"
