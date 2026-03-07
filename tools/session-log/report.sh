#!/usr/bin/env bash
# session-report: Summarize Claude Code session activity from session-log data
# Reads ~/.claude/session-logs/*.jsonl and produces a human-readable report
#
# Usage:
#   session-report.sh              # Today's activity
#   session-report.sh 2026-03-07   # Specific date
#   session-report.sh --all        # All time
#
# MIT License - https://github.com/Bande-a-Bonnot/Boucle-framework

set -euo pipefail

LOG_DIR="${HOME}/.claude/session-logs"

if [ ! -d "$LOG_DIR" ]; then
    echo "No session logs found at $LOG_DIR"
    echo "Install session-log first: https://github.com/Bande-a-Bonnot/Boucle-framework/tree/main/tools/session-log"
    exit 1
fi

# Determine which files to read
DATE_ARG="${1:-today}"
if [ "$DATE_ARG" = "--all" ]; then
    FILES=$(find "$LOG_DIR" -name "*.jsonl" -type f 2>/dev/null | sort)
    LABEL="all time"
elif [ "$DATE_ARG" = "today" ]; then
    TODAY=$(date -u +%Y-%m-%d)
    FILES="$LOG_DIR/$TODAY.jsonl"
    LABEL="$TODAY"
else
    FILES="$LOG_DIR/$DATE_ARG.jsonl"
    LABEL="$DATE_ARG"
fi

# Check if any files exist
EXISTING_FILES=""
for f in $FILES; do
    [ -f "$f" ] && EXISTING_FILES="$EXISTING_FILES $f"
done

if [ -z "$EXISTING_FILES" ]; then
    echo "No logs found for $LABEL"
    exit 0
fi

# Process with Python
python3 -c "
import json, sys
from collections import Counter, defaultdict

files = sys.argv[1:]
entries = []
for f in files:
    with open(f) as fh:
        for line in fh:
            line = line.strip()
            if line:
                try:
                    entries.append(json.loads(line))
                except json.JSONDecodeError:
                    pass

if not entries:
    print('No entries found.')
    sys.exit(0)

# Basic stats
total = len(entries)
sessions = set(e.get('session', '') for e in entries)
tools = Counter(e.get('tool', 'unknown') for e in entries)

# Time range
timestamps = sorted(e.get('ts', '') for e in entries if e.get('ts'))
first_ts = timestamps[0] if timestamps else '?'
last_ts = timestamps[-1] if timestamps else '?'

# Files touched
reads = set()
writes = set()
for e in entries:
    detail = e.get('detail', '')
    tool = e.get('tool', '')
    if tool == 'Read' and detail:
        reads.add(detail)
    elif tool in ('Write', 'Edit') and detail:
        writes.add(detail)

# Commands run
commands = []
for e in entries:
    if e.get('tool') == 'Bash' and e.get('detail'):
        commands.append(e['detail'])

# Hourly distribution
hours = Counter()
for e in entries:
    ts = e.get('ts', '')
    if len(ts) >= 13:
        hours[ts[11:13]] += 1

# Print report
label = '$LABEL'
print(f'Session Report: {label}')
print('=' * 50)
print(f'Total tool calls: {total}')
print(f'Sessions: {len(sessions)}')
print(f'Time range: {first_ts} to {last_ts}')
print()

print('Tool calls by type:')
for tool, count in tools.most_common():
    bar = '#' * min(count, 40)
    print(f'  {tool:12s} {count:4d}  {bar}')
print()

if reads or writes:
    print(f'Files read: {len(reads)}')
    print(f'Files written/edited: {len(writes)}')
    if writes:
        print('  Modified:')
        for f in sorted(writes)[:20]:
            print(f'    {f}')
        if len(writes) > 20:
            print(f'    ... and {len(writes) - 20} more')
    print()

if commands:
    print(f'Commands run: {len(commands)}')
    cmd_counts = Counter(commands)
    print('  Most frequent:')
    for cmd, count in cmd_counts.most_common(10):
        display = cmd[:60] + '...' if len(cmd) > 60 else cmd
        print(f'    {count:3d}x  {display}')
    print()

if hours:
    print('Activity by hour (UTC):')
    for h in sorted(hours.keys()):
        bar = '#' * min(hours[h], 40)
        print(f'  {h}:00  {hours[h]:4d}  {bar}')
" $EXISTING_FILES
