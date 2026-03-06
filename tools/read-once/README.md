# read-once

Stop Claude Code from re-reading files it already has in context.

A PreToolUse hook that tracks file reads within a session. When Claude tries to re-read a file that hasn't changed, the hook blocks the read and tells Claude the content is already in context. Saves ~2000+ tokens per prevented re-read.

## Install

One command:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/read-once/install.sh | bash
```

This downloads `hook.sh` and `read-once` to `~/.claude/read-once/` and adds the hook to your settings.

Or clone and install manually:

```sh
git clone https://github.com/Bande-a-Bonnot/Boucle-framework.git
cd Boucle-framework/tools/read-once
./read-once install
```

Or add to `.claude/settings.json` by hand:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Read",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/read-once/hook.sh"
          }
        ]
      }
    ]
  }
}
```

## How it works

1. Hook intercepts every `Read` tool call
2. Checks a session-scoped cache: has this file been read before?
3. Compares file mtime — if unchanged, blocks the read
4. Claude sees: "file already in context, no need to re-read"
5. If the file changed since last read, allows it through (or shows just the diff — see below)
6. Cache entries expire after 20 minutes (configurable) to handle context compaction

### Diff mode (opt-in)

When you're iterating on a file — read it, edit it, read it again — Claude already has the old version in context. With diff mode enabled, read-once shows only what changed instead of the full file. A 3-line change in a 200-line file costs ~30 tokens instead of ~2000.

Enable with:

```sh
export READ_ONCE_DIFF=1
```

When a re-read is blocked with a diff, Claude sees:

```
read-once: app.py changed since last read. You already have the previous
version in context. Here are only the changes (saving ~1850 tokens):

--- previous
+++ current
@@ -45,3 +45,3 @@
-    return None
+    return default_value

Apply this diff mentally to your cached version of the file.
```

If the diff is too large (>40 lines by default), read-once falls back to allowing a full re-read. Configure the threshold with `READ_ONCE_DIFF_MAX`.

### What Claude sees

When a re-read is blocked, Claude receives:

```
read-once: schema.rb (~2,340 tokens) already in context (read 3m ago, unchanged).
Re-read allowed after 20m. Session savings: ~4,680 tokens.
```

Claude then proceeds without the redundant read. No loss of information — the file content is still in the context window from the first read.

### Compaction safety

Claude Code compacts the context window during long sessions, dropping older content. A file read 30 minutes ago might no longer be in the working context. read-once handles this with a TTL (time-to-live): cache entries expire after `READ_ONCE_TTL` seconds (default: 1200 = 20 minutes). After expiry, re-reads are allowed.

There's no way to detect compaction events from a hook, so a time-based heuristic is the best available approach.

## Stats

```sh
./read-once stats
```

```
read-once — file read deduplication for Claude Code

  Total file reads:    47
  Cache hits:          19 (blocked re-reads)
  Diff hits:           3 (changed files — sent diff only)
  First reads:         22
  Changed files:       1 (full re-read after modification)
  TTL expired:         2 (re-read after 20m — compaction safety)

  Tokens saved:        ~38400
  Read token total:    ~94200
  Savings:             40%
  Est. cost saved:     $0.1152 (Sonnet) / $0.5760 (Opus)

  Top re-read files:
    5x  schema.rb
    4x  routes.rb
    3x  application_controller.rb

  Sessions tracked:    3
  Cache TTL:           20 minutes (READ_ONCE_TTL=1200s)
```

## Commands

```
read-once stats       Show token savings
read-once gain        Same as stats
read-once clear       Clear session cache
read-once install     Add hook to settings
read-once uninstall   Remove hook
```

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `READ_ONCE_TTL` | `1200` | Cache TTL in seconds. After this, re-reads are allowed (compaction safety). |
| `READ_ONCE_DIFF` | `0` | Set to `1` to show only diffs when files change (instead of full re-read). |
| `READ_ONCE_DIFF_MAX` | `40` | Max diff lines before falling back to full re-read. |
| `READ_ONCE_DISABLED` | `0` | Set to `1` to disable the hook entirely. |

## Requirements

- `jq` (for JSON parsing)
- `bash` 4+
- `python3` (for diff mode JSON escaping — only needed if `READ_ONCE_DIFF=1`)
- Claude Code with hooks support

## How much does it save?

Claude Code re-reads files more than you'd think. Common patterns:
- Reading a file, editing it, then reading it again to verify
- Re-reading config files across different parts of a task
- Reading the same file in subagents that share a session

Each blocked re-read saves the full file token cost (including the ~70% overhead from line numbers in `cat -n` format). Run `./read-once stats` after a session to see your actual savings.

## Compatibility

Works alongside RTK (which handles Bash output) and Context-Mode (which handles large outputs). read-once operates on a different layer — the Read tool — so there's no conflict.

## License

MIT
