#!/usr/bin/env bash
# Install session-log hook for Claude Code
# Usage: curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/session-log/install.sh | bash
set -euo pipefail

HOOK_DIR="${HOME}/.claude/hooks"
HOOK_FILE="${HOOK_DIR}/session-log.sh"
SETTINGS="${HOME}/.claude/settings.json"
LOG_DIR="${HOME}/.claude/session-logs"

echo "Installing session-log hook..."

# Check python3 (needed for settings.json management)
if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 not found. Install Python 3 and try again." >&2
    exit 1
fi

# Create directories
mkdir -p "$HOOK_DIR" "$LOG_DIR"

# Download hook script
HOOK_URL="https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/session-log/hook.sh"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$HOOK_URL" -o "$HOOK_FILE"
elif command -v wget >/dev/null 2>&1; then
  wget -q "$HOOK_URL" -O "$HOOK_FILE"
else
  echo "Error: curl or wget required" >&2
  exit 1
fi
chmod +x "$HOOK_FILE"

# Verify download is not empty
if [ ! -s "$HOOK_FILE" ]; then
    echo "Error: downloaded file is empty. The URL may have changed." >&2
    exit 1
fi

# Add to Claude Code settings
if [ ! -f "$SETTINGS" ]; then
    echo '{}' > "$SETTINGS"
fi

# Handle JSONC comments in settings.json (prevents silent failures)
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

python3 -c "
import json, sys, os

settings_path = '$SETTINGS'
hook_path = '$HOOK_FILE'

with open(settings_path) as f:
    settings = json.load(f)

hooks = settings.setdefault('hooks', {})
post_hooks = hooks.setdefault('PostToolUse', [])

# Check if already installed (handle both flat and nested formats)
for h in post_hooks:
    cmd = h.get('command', '')
    if not cmd:
        for hk in h.get('hooks', []):
            c = hk.get('command', '')
            if c: cmd = c; break
    if 'session-log' in cmd:
        print('session-log hook already configured in settings.json')
        sys.exit(0)

post_hooks.append({
    'hooks': [{
        'type': 'command',
        'command': f'bash {hook_path}'
    }]
})

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)

print(f'Added session-log hook to {settings_path}')
"

echo ""
echo "session-log installed!"
echo "  Hook: ${HOOK_FILE}"
echo "  Logs: ${LOG_DIR}/"
echo ""
echo "Every tool call is now logged. View today's log:"
echo "  cat ${LOG_DIR}/\$(date -u +%Y-%m-%d).jsonl | python3 -m json.tool --no-ensure-ascii"
echo ""
echo "Summary of a session:"
echo "  cat ${LOG_DIR}/\$(date -u +%Y-%m-%d).jsonl | python3 -c \"import sys,json; lines=[json.loads(l) for l in sys.stdin]; tools={l['tool'] for l in lines}; print(f'{len(lines)} tool calls: {', '.join(sorted(tools))}')\""
