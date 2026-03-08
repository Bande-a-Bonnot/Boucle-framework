# session-log

Audit trail for Claude Code sessions. Logs every tool call so you can see exactly what Claude did.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/session-log/install.sh | bash
```

Or via the unified installer:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- session-log
```

## What it does

Hooks into PostToolUse and appends one JSON line per tool call to `~/.claude/session-logs/YYYY-MM-DD.jsonl`.

Each entry records:
- **ts** — UTC timestamp
- **session** — session identifier
- **tool** — which tool was called (Read, Write, Bash, Grep, etc.)
- **detail** — key parameter (file path, command, search pattern)
- **cwd** — working directory
- **exit_code** — Bash command exit code (0 for success, non-zero for failure)
- **status** — `"error"` when the tool response contains error signals (fatal, permission denied, etc.)

## Use cases

- **Audit**: Review what Claude Code did while you were away
- **Debug**: Trace which files were read/written during a broken change
- **Cost insight**: See how many tool calls a task actually takes
- **Autonomous agents**: Full audit trail for unattended sessions

## Example output

```jsonl
{"ts":"2026-03-07T22:15:00Z","session":"abc123","tool":"Read","detail":"/src/main.rs","cwd":"/project"}
{"ts":"2026-03-07T22:15:01Z","session":"abc123","tool":"Bash","detail":"cargo test","cwd":"/project","exit_code":0}
{"ts":"2026-03-07T22:15:05Z","session":"abc123","tool":"Write","detail":"/src/lib.rs","cwd":"/project"}
{"ts":"2026-03-07T22:15:08Z","session":"abc123","tool":"Bash","detail":"git push origin main","cwd":"/project","exit_code":128,"status":"error"}
```

## Verify agent claims

When Claude says "pushed to origin," the log shows whether `git push` actually ran and whether it succeeded:

```sh
# Find all git push attempts and their exit codes
grep '"git push' ~/.claude/session-logs/*.jsonl | python3 -c "
import sys, json
for l in sys.stdin:
    e = json.loads(l.split(':', 1)[1] if ':' in l else l)
    ec = e.get('exit_code', '?')
    print(f\"{e['ts']}  exit={ec}  {e.get('detail','')}\")"
```

## Viewing logs

```sh
# Today's raw log
cat ~/.claude/session-logs/$(date -u +%Y-%m-%d).jsonl

# Pretty print
cat ~/.claude/session-logs/$(date -u +%Y-%m-%d).jsonl | python3 -m json.tool

# Count tool calls per type
cat ~/.claude/session-logs/*.jsonl | python3 -c "
import sys, json
from collections import Counter
tools = Counter(json.loads(l)['tool'] for l in sys.stdin)
for tool, count in tools.most_common():
    print(f'  {tool}: {count}')
"

# List files touched in a session
cat ~/.claude/session-logs/*.jsonl | python3 -c "
import sys, json
files = set()
for l in sys.stdin:
    e = json.loads(l)
    if e['tool'] in ('Read', 'Write', 'Edit') and 'detail' in e:
        files.add(e['detail'])
for f in sorted(files):
    print(f)
"
```

## Session report

A companion script that summarizes your session logs:

```sh
# Today's activity
bash ~/.claude/hooks/session-report.sh

# Specific date
bash ~/.claude/hooks/session-report.sh 2026-03-07

# All time
bash ~/.claude/hooks/session-report.sh --all

# Last 7 days trend comparison
bash ~/.claude/hooks/session-report.sh --week

# Last N days trend comparison
bash ~/.claude/hooks/session-report.sh --days 14
```

Or run directly from the repo:

```sh
bash tools/session-log/report.sh
```

**Single-day mode** shows: tool calls by type, error rate with failed operations listed, files read/written, commands run with frequency, and hourly activity distribution.

**Trend mode** (`--week` / `--days N`) shows a day-by-day comparison table:

```
Session Trends: Last 7 days
========================================================================
Date          Calls  Sess   Errors   Rate  Reads  Writes  Cmds
------------------------------------------------------------------------
2026-03-02        42     2       1   2.4%     15       8    12
2026-03-03        --    --      --     --     --      --    --
2026-03-04        87     5       3   3.4%     34      12    28
...
========================================================================
Total           129     7       4   3.1%     49      20    40
Avg/day          64.5   3.5     2.0          24.5    10.0  20.0
Busiest:  2026-03-04 (87 calls)
Quietest: 2026-03-02 (42 calls)
Active days: 2/7
```

Spot trends: increasing error rates, unusually busy days, activity gaps.

## Configuration

**Log location**: `~/.claude/session-logs/` (one file per day, JSONL format)

**Retention**: Logs accumulate indefinitely. Clean up old logs with:

```sh
# Delete logs older than 30 days
find ~/.claude/session-logs/ -name "*.jsonl" -mtime +30 -delete
```

## Uninstall

Remove the hook entry from `~/.claude/settings.json` (delete the PostToolUse entry containing `session-log`) and delete the hook file:

```sh
rm ~/.claude/hooks/session-log.sh
```

## License

MIT
