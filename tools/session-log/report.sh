#!/usr/bin/env bash
# session-report: Summarize Claude Code session activity from session-log data
# Reads ~/.claude/session-logs/*.jsonl and produces a human-readable report
#
# Usage:
#   session-report.sh              # Today's activity
#   session-report.sh 2026-03-07   # Specific date
#   session-report.sh --all        # All time
#   session-report.sh --week       # Last 7 days trend comparison
#   session-report.sh --days 14    # Last N days trend comparison
#
# MIT License - https://github.com/Bande-a-Bonnot/Boucle-framework

set -euo pipefail

LOG_DIR="${HOME}/.claude/session-logs"

if [ ! -d "$LOG_DIR" ]; then
    echo "No session logs found at $LOG_DIR"
    echo "Install session-log first: https://github.com/Bande-a-Bonnot/Boucle-framework/tree/main/tools/session-log"
    exit 1
fi

# Handle --week / --days mode (multi-day trend comparison)
DATE_ARG="${1:-today}"
if [ "$DATE_ARG" = "--week" ] || [ "$DATE_ARG" = "--days" ]; then
    if [ "$DATE_ARG" = "--days" ]; then
        NUM_DAYS="${2:-7}"
    else
        NUM_DAYS=7
    fi
    python3 -c "
import json, sys, os
from collections import Counter
from datetime import datetime, timedelta

log_dir = '$LOG_DIR'
num_days = int('$NUM_DAYS')

# Generate date range
today = datetime.utcnow().date()
dates = [(today - timedelta(days=i)).isoformat() for i in range(num_days - 1, -1, -1)]

rows = []
for date in dates:
    path = os.path.join(log_dir, f'{date}.jsonl')
    if not os.path.isfile(path):
        rows.append({'date': date, 'calls': 0, 'sessions': 0, 'errors': 0, 'reads': 0, 'writes': 0, 'commands': 0})
        continue
    entries = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    entries.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    calls = len(entries)
    sessions = len(set(e.get('session', '') for e in entries))
    errors = sum(1 for e in entries if (e.get('exit_code') not in (None, 0)) or e.get('status') == 'error')
    reads = len(set(e.get('detail', '') for e in entries if e.get('tool') == 'Read' and e.get('detail')))
    writes = len(set(e.get('detail', '') for e in entries if e.get('tool') in ('Write', 'Edit') and e.get('detail')))
    commands = sum(1 for e in entries if e.get('tool') == 'Bash' and e.get('detail'))
    rows.append({'date': date, 'calls': calls, 'sessions': sessions, 'errors': errors, 'reads': reads, 'writes': writes, 'commands': commands})

active_rows = [r for r in rows if r['calls'] > 0]

print(f'Session Trends: Last {num_days} days')
print('=' * 72)
print(f'{\"Date\":12s} {\"Calls\":>6s} {\"Sess\":>5s} {\"Errors\":>7s} {\"Rate\":>6s} {\"Reads\":>6s} {\"Writes\":>7s} {\"Cmds\":>5s}')
print('-' * 72)
for r in rows:
    if r['calls'] == 0:
        print(f'{r[\"date\"]:12s} {\"--\":>6s} {\"--\":>5s} {\"--\":>7s} {\"--\":>6s} {\"--\":>6s} {\"--\":>7s} {\"--\":>5s}')
    else:
        rate = f'{r[\"errors\"] * 100.0 / r[\"calls\"]:.1f}%'
        print(f'{r[\"date\"]:12s} {r[\"calls\"]:6d} {r[\"sessions\"]:5d} {r[\"errors\"]:7d} {rate:>6s} {r[\"reads\"]:6d} {r[\"writes\"]:7d} {r[\"commands\"]:5d}')

print('=' * 72)
if active_rows:
    tc = sum(r['calls'] for r in active_rows)
    ts = sum(r['sessions'] for r in active_rows)
    te = sum(r['errors'] for r in active_rows)
    tr = sum(r['reads'] for r in active_rows)
    tw = sum(r['writes'] for r in active_rows)
    tcmd = sum(r['commands'] for r in active_rows)
    ad = len(active_rows)
    rate = f'{te * 100.0 / tc:.1f}%' if tc > 0 else '0.0%'
    print(f'{\"Total\":12s} {tc:6d} {ts:5d} {te:7d} {rate:>6s} {tr:6d} {tw:7d} {tcmd:5d}')
    print(f'{\"Avg/day\":12s} {tc/ad:6.1f} {ts/ad:5.1f} {te/ad:7.1f} {\"\":>6s} {tr/ad:6.1f} {tw/ad:7.1f} {tcmd/ad:5.1f}')
    busiest = max(active_rows, key=lambda r: r['calls'])
    quietest = min(active_rows, key=lambda r: r['calls'])
    print(f'Busiest:  {busiest[\"date\"]} ({busiest[\"calls\"]} calls)')
    print(f'Quietest: {quietest[\"date\"]} ({quietest[\"calls\"]} calls)')
    print(f'Active days: {ad}/{num_days}')
else:
    print('No activity in this period.')
"
    exit $?
fi

# Determine which files to read
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

# Failures and errors
failures = []
error_count = 0
for e in entries:
    ec = e.get('exit_code')
    st = e.get('status')
    if (ec is not None and ec != 0) or st == 'error':
        error_count += 1
        failures.append(e)

# Print report
label = '$LABEL'
print(f'Session Report: {label}')
print('=' * 50)
print(f'Total tool calls: {total}')
print(f'Sessions: {len(sessions)}')
print(f'Time range: {first_ts} to {last_ts}')
if error_count > 0:
    pct = error_count * 100.0 / total
    print(f'Errors: {error_count}/{total} ({pct:.0f}%)')
else:
    print(f'Errors: none')
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

if failures:
    print('Failed operations:')
    for e in failures[:15]:
        tool = e.get('tool', '?')
        detail = e.get('detail', '')[:70]
        ec = e.get('exit_code', '')
        ts = e.get('ts', '')[11:19]
        code_str = f' (exit {ec})' if ec != '' else ''
        print(f'  {ts}  {tool:8s}  {detail}{code_str}')
    if len(failures) > 15:
        print(f'  ... and {len(failures) - 15} more')
    print()

if hours:
    print('Activity by hour (UTC):')
    for h in sorted(hours.keys()):
        bar = '#' * min(hours[h], 40)
        print(f'  {h}:00  {hours[h]:4d}  {bar}')
" $EXISTING_FILES
