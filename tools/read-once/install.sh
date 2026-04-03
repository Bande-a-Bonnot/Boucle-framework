#!/bin/bash
# read-once installer — download and configure in one step
# Usage: curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/read-once/install.sh | bash
set -euo pipefail

REPO="https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/read-once"
INSTALL_DIR="${HOME}/.claude/read-once"
SETTINGS="${HOME}/.claude/settings.json"

echo "read-once: installing to ${INSTALL_DIR}"

# Check jq (needed at runtime to parse Claude Code hook input)
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq not found. read-once requires jq at runtime." >&2
    echo "  Install: brew install jq (macOS) or apt install jq (Linux)" >&2
    exit 1
fi

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

# Download hook, compact hook, and CLI
if ! $DL "${REPO}/hook.sh" > "${INSTALL_DIR}/hook.sh" 2>/dev/null; then
    echo "Error: download of hook.sh failed. Check your internet connection." >&2
    exit 1
fi
if ! $DL "${REPO}/compact.sh" > "${INSTALL_DIR}/compact.sh" 2>/dev/null; then
    echo "Error: download of compact.sh failed. Check your internet connection." >&2
    exit 1
fi
if ! $DL "${REPO}/read-once" > "${INSTALL_DIR}/read-once" 2>/dev/null; then
    echo "Error: download of read-once CLI failed. Check your internet connection." >&2
    exit 1
fi
chmod +x "${INSTALL_DIR}/hook.sh" "${INSTALL_DIR}/compact.sh" "${INSTALL_DIR}/read-once"

# Verify downloads are not empty
if [ ! -s "${INSTALL_DIR}/hook.sh" ] || [ ! -s "${INSTALL_DIR}/compact.sh" ] || [ ! -s "${INSTALL_DIR}/read-once" ]; then
    echo "Error: downloaded file(s) are empty. The URL may have changed." >&2
    exit 1
fi

echo "read-once: downloaded hook.sh, compact.sh, and read-once CLI"

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
    ],
    "PostCompact": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/read-once/compact.sh"
          }
        ]
      }
    ]
  }
}
SETTINGS_EOF
  echo "read-once: created settings with hooks configured (PreToolUse + PostCompact)"
else
  # Handle JSONC comments in settings.json (prevents silent failures)
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$SETTINGS" 2>/dev/null; then
    if command -v python3 >/dev/null 2>&1; then
      python3 - "$SETTINGS" << 'JSONC_FIX'
import json, sys, shutil
path = sys.argv[1]
with open(path) as f: raw = f.read()
o, i, n, q = [], 0, len(raw), False
while i < n:
    if q:
        if raw[i] == '\\' and i+1<n: o.append(raw[i:i+2]); i+=2; continue
        if raw[i] == '"': q=False
        o.append(raw[i]); i+=1
    elif raw[i] == '"': q=True; o.append(raw[i]); i+=1
    elif i+1<n and raw[i:i+2]=='//':
        while i<n and raw[i]!='\n': i+=1
    elif i+1<n and raw[i:i+2]=='/*':
        i+=2
        while i+1<n and raw[i:i+2]!='*/': i+=1
        i+=2
    else: o.append(raw[i]); i+=1
clean = ''.join(o)
try:
    json.loads(clean)
    shutil.copy2(path, path + '.bak')
    with open(path, 'w') as f: f.write(clean)
    print('read-once: JSONC comments stripped from settings.json (backup: .bak)')
except: print('read-once: Error: settings.json is not valid JSON. Please fix manually.'); sys.exit(1)
JSONC_FIX
    else
      echo "read-once: Warning: settings.json may contain JSONC comments. Remove them if hooks fail."
    fi
  fi

  # Check if hook already configured
  if grep -q "read-once" "$SETTINGS" 2>/dev/null; then
    echo "read-once: hooks already in settings.json"
    # Upgrade: add PostCompact if missing (existing installs only have PreToolUse)
    if ! grep -q "compact.sh" "$SETTINGS" 2>/dev/null && command -v jq &>/dev/null; then
      UPDATED=$(jq --arg hook "~/.claude/read-once/compact.sh" '
        .hooks //= {} |
        .hooks.PostCompact //= [] |
        if (.hooks.PostCompact | map(select(.hooks[]?.command == $hook)) | length) == 0 then
          .hooks.PostCompact += [{
            "matcher": "",
            "hooks": [{
              "type": "command",
              "command": $hook
            }]
          }]
        else . end
      ' "$SETTINGS")
      echo "$UPDATED" > "$SETTINGS"
      echo "read-once: added PostCompact hook (upgrade from previous install)"
    fi
  elif command -v jq &>/dev/null; then
    # Auto-merge into existing settings using jq
    UPDATED=$(jq --arg hook "~/.claude/read-once/hook.sh" --arg compact "~/.claude/read-once/compact.sh" '
      .hooks //= {} |
      .hooks.PreToolUse //= [] |
      .hooks.PreToolUse += [{
        "matcher": "Read",
        "hooks": [{
          "type": "command",
          "command": $hook
        }]
      }] |
      .hooks.PostCompact //= [] |
      .hooks.PostCompact += [{
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": $compact
        }]
      }]
    ' "$SETTINGS")
    echo "$UPDATED" > "$SETTINGS"
    echo "read-once: hooks added to existing settings.json (PreToolUse + PostCompact)"
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
# Download PS1 CLI for Windows users (best-effort, non-fatal)
$DL "${REPO}/read-once.ps1" > "${INSTALL_DIR}/read-once.ps1" 2>/dev/null || true

echo ""
echo "read-once: installed. Start a new Claude Code session to activate."
echo "  Stats:     ~/.claude/read-once/read-once stats"
echo "  Uninstall: ~/.claude/read-once/read-once uninstall"
