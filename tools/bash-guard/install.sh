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

# Check python3 (needed for settings.json management)
if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 not found. Install Python 3 and try again." >&2
    exit 1
fi

# Check jq (needed at runtime to parse Claude Code hook input)
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq not found. $HOOK_NAME requires jq at runtime." >&2
    echo "  Install: brew install jq (macOS) or apt install jq (Linux)" >&2
    exit 1
fi

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

# Update settings.json
echo "  Configuring Claude Code..."

# Handle JSONC comments in settings.json (prevents silent failures)
if [ -f "$SETTINGS" ]; then
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$SETTINGS" 2>/dev/null; then
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
    print('  Note: JSONC comments stripped from settings.json (backup: .bak)')
except: print('  Error: settings.json is not valid JSON. Please fix manually.'); sys.exit(1)
JSONC_FIX
  fi
fi

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
echo "  - sudo/pkexec/doas (privilege escalation)"
echo "  - kill -9 on broad targets"
echo "  - dd/mkfs on disk devices"
echo "  - Disk utilities (diskutil erase, fdisk, parted, wipefs)"
echo "  - Writes to system directories"
echo "  - eval on variables"
echo "  - npm install -g (global installs)"
echo "  - Docker destruction (compose down -v, system prune)"
echo "  - Docker escape (run -v /:/host, exec on host)"
echo "  - Database drops (prisma db push, dropdb, DROP TABLE)"
echo "  - Credential exposure (env, printenv, set -x)"
echo "  - Cloud infra (terraform destroy, kubectl delete ns)"
echo "  - Mass file deletion (find -delete, find -exec rm, xargs rm)"
echo "  - File destruction (shred, truncate -s 0)"
echo "  - Data exfiltration (curl -d @file, wget --post-file, nc)"
echo "  - Programmatic env dumps (python os.environ, node process.env)"
echo "  - Sensitive files (.ssh keys, shell history, /proc/environ)"
echo "  - System database corruption (sqlite3 on VSCode .vscdb)"
echo "  - Mount point destruction (rm -rf /mnt, /Volumes, /nfs)"
echo "  - Compound commands (true && rm -rf /)"
echo "  - Encoding bypasses (base64 -d | bash, xxd | sh, rev | bash)"
echo "  - Process substitution downloads (bash <(curl ...), sh <(wget ...))"
echo "  - Language shell wrappers (python subprocess, ruby system)"
echo "  - Here-string/here-doc to shell (bash <<< cmd, sh << EOF)"
echo "  - eval with string literals (eval 'cmd')"
echo "  - xargs to shell (xargs bash -c)"
echo ""
echo "Configure exceptions in .bash-guard:"
echo "  echo 'allow: sudo' > .bash-guard"
echo ""
echo "Disable temporarily:"
echo "  export BASH_GUARD_DISABLED=1"
