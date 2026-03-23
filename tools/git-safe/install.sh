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

# Check python3 (needed for settings.json management)
if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 not found. Install Python 3 and try again." >&2
    exit 1
fi

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

# Verify download is not empty
if [ ! -s "$HOOK_PATH" ]; then
    echo "Error: downloaded file is empty. The URL may have changed." >&2
    exit 1
fi

# Clean up legacy install location if present
LEGACY_PATH="$HOME/.claude/hooks/$HOOK_NAME.sh"
if [ -f "$LEGACY_PATH" ]; then
  echo "  Migrating from legacy location ($LEGACY_PATH)..."
  rm -f "$LEGACY_PATH"
fi

# Handle JSONC comments in settings.json (prevents silent failures)
if [ -f "$SETTINGS_FILE" ]; then
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$SETTINGS_FILE" 2>/dev/null; then
    python3 - "$SETTINGS_FILE" << 'JSONC_FIX'
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
    print('  Note: JSONC comments stripped from settings.json (backup: .bak)')
except: print('  Error: settings.json is not valid JSON. Please fix manually.'); sys.exit(1)
JSONC_FIX
  fi
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
            if 'hooks' not in h:
                cleaned.append({'hooks': [{'type': 'command', 'command': '$HOOK_PATH'}]})
            else:
                cleaned.append(h)
    else:
        cleaned.append(h)

if not found:
    cleaned.append({'hooks': [{'type': 'command', 'command': '$HOOK_PATH'}]})
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
SETTINGS
  echo "  Created settings with hook"
fi

echo ""
echo "Done! git-safe is now active."
echo ""
echo "Blocked operations:"
echo "  git push --force    (use --force-with-lease instead)"
echo "  git push --delete   (blocks remote branch/tag deletion)"
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
