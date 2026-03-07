#!/usr/bin/env bash
# Install session-log hook for Claude Code
# Usage: curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/session-log/install.sh | bash
set -euo pipefail

HOOK_DIR="${HOME}/.claude/hooks"
HOOK_FILE="${HOOK_DIR}/session-log.sh"
SETTINGS="${HOME}/.claude/settings.json"
LOG_DIR="${HOME}/.claude/session-logs"

echo "Installing session-log hook..."

# Create directories
mkdir -p "$HOOK_DIR" "$LOG_DIR"

# Download hook script
curl -fsSL "https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/session-log/hook.sh" -o "$HOOK_FILE"
chmod +x "$HOOK_FILE"

# Add to Claude Code settings
if [ ! -f "$SETTINGS" ]; then
    echo '{}' > "$SETTINGS"
fi

python3 -c "
import json, sys, os

settings_path = '$SETTINGS'
hook_path = '$HOOK_FILE'

with open(settings_path) as f:
    settings = json.load(f)

hooks = settings.setdefault('hooks', {})
post_hooks = hooks.setdefault('PostToolUse', [])

# Check if already installed
for h in post_hooks:
    if h.get('type') == 'command' and 'session-log' in h.get('command', ''):
        print('session-log hook already configured in settings.json')
        sys.exit(0)

post_hooks.append({
    'type': 'command',
    'command': f'bash {hook_path}'
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
