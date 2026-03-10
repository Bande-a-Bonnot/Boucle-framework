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

# Determine download command
DL="curl -fsSL"
if ! command -v curl >/dev/null 2>&1; then
  if command -v wget >/dev/null 2>&1; then
    DL="wget -q -O -"
  else
    echo "Error: curl or wget required" >&2
    exit 1
  fi
fi

# Download hook and CLI
if ! $DL "${REPO}/hook.sh" > "${INSTALL_DIR}/hook.sh" 2>/dev/null; then
    echo "Error: download of hook.sh failed. Check your internet connection." >&2
    exit 1
fi
if ! $DL "${REPO}/read-once" > "${INSTALL_DIR}/read-once" 2>/dev/null; then
    echo "Error: download of read-once CLI failed. Check your internet connection." >&2
    exit 1
fi
chmod +x "${INSTALL_DIR}/hook.sh" "${INSTALL_DIR}/read-once"

# Verify downloads are not empty
if [ ! -s "${INSTALL_DIR}/hook.sh" ] || [ ! -s "${INSTALL_DIR}/read-once" ]; then
    echo "Error: downloaded file(s) are empty. The URL may have changed." >&2
    exit 1
fi

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
  elif command -v jq &>/dev/null; then
    # Auto-merge into existing settings using jq
    UPDATED=$(jq --arg hook "~/.claude/read-once/hook.sh" '
      .hooks //= {} |
      .hooks.PreToolUse //= [] |
      .hooks.PreToolUse += [{
        "matcher": "Read",
        "hooks": [{
          "type": "command",
          "command": $hook
        }]
      }]
    ' "$SETTINGS")
    echo "$UPDATED" > "$SETTINGS"
    echo "read-once: hook added to existing settings.json"
  else
    echo "read-once: settings.json exists but jq not found for auto-merge."
    echo "  Install jq (brew install jq) and re-run, or add manually:"
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
