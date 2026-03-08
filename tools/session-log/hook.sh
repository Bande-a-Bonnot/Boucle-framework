#!/usr/bin/env bash
# session-log: Audit trail for Claude Code sessions
# Logs every tool call with timestamp, tool name, and key parameters
# Helps answer "what did Claude do while I was away?"
#
# Hook type: PostToolUse (fires after every tool call)
# Output: ~/.claude/session-logs/YYYY-MM-DD.jsonl
#
# MIT License - https://github.com/Bande-a-Bonnot/Boucle-framework

set -euo pipefail

# All processing in Python to avoid shell quoting issues
python3 -c "
import json, sys, os
from datetime import datetime, timezone

# Read event from stdin
try:
    event = json.load(sys.stdin)
except (json.JSONDecodeError, EOFError):
    sys.exit(0)

# Extract tool name
tool = event.get('tool_name', 'unknown')

# Extract the most useful detail per tool type
ti = event.get('tool_input', {})
detail = ''
if isinstance(ti, dict):
    if 'file_path' in ti:
        detail = ti['file_path']
    elif 'command' in ti:
        detail = ti['command'][:200]
    elif 'pattern' in ti:
        path = ti.get('path', '.')
        detail = f'{ti[\"pattern\"]} in {path}'
    elif 'file' in ti:
        detail = ti['file']
    elif 'query' in ti:
        detail = str(ti['query'])[:200]
    elif ti:
        k, v = next(iter(ti.items()))
        detail = f'{k}={str(v)[:100]}'
else:
    detail = str(ti)[:200]

# Extract tool response status (exit codes, errors)
tr = event.get('tool_response', '')
status = None
exit_code = None

if isinstance(tr, str):
    # Bash tool: check for exit code errors
    if tr.startswith('Exit code '):
        try:
            exit_code = int(tr.split('\\n')[0].replace('Exit code ', ''))
        except (ValueError, IndexError):
            pass
    # General error detection
    lower = tr[:500].lower()
    if any(sig in lower for sig in ['error:', 'fatal:', 'permission denied', 'not found',
                                     'exit code ', 'command not found', 'failed']):
        status = 'error'

if tool == 'Bash' and exit_code is None and tr and not status:
    # Bash with output and no error signals: likely success
    exit_code = 0

# Timestamp
now = datetime.now(timezone.utc)
ts = now.strftime('%Y-%m-%dT%H:%M:%SZ')
date_str = now.strftime('%Y-%m-%d')

# Session ID
session = os.environ.get('CLAUDE_SESSION_ID',
          os.environ.get('CLAUDE_CODE_SESSION',
          str(int(now.timestamp()))))

# Log directory
log_dir = os.path.join(os.path.expanduser('~'), '.claude', 'session-logs')
os.makedirs(log_dir, exist_ok=True)

# Build entry
entry = {'ts': ts, 'session': session, 'tool': tool}
if detail:
    entry['detail'] = detail
entry['cwd'] = os.getcwd()
if exit_code is not None:
    entry['exit_code'] = exit_code
if status:
    entry['status'] = status

# Append to daily log
log_file = os.path.join(log_dir, f'{date_str}.jsonl')
with open(log_file, 'a') as f:
    f.write(json.dumps(entry, ensure_ascii=False) + '\n')
" < /dev/stdin

# Always exit 0 — logging should never block Claude
exit 0
