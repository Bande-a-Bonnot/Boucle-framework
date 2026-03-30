# read-once

Stop Claude Code from re-reading files it already has in context.

A PreToolUse hook that tracks file reads within a session. When Claude tries to re-read a file that hasn't changed, the hook tells Claude the content is already in context. Saves ~2000+ tokens per prevented re-read.

By default, read-once uses **warn mode**: it allows the read but attaches an advisory message. This prevents the Edit tool deadlock (Edit requires a prior Read) and parallel read cascade failures. Set `READ_ONCE_MODE=deny` for hard blocking if you want maximum token savings and don't use Edit frequently.

## Install

### macOS / Linux

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

### Windows (PowerShell 7+)

```powershell
irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1 | iex
```

Or clone and install manually:

```powershell
git clone https://github.com/Bande-a-Bonnot/Boucle-framework.git
cd Boucle-framework/tools/read-once
pwsh read-once.ps1 install
```

Requires PowerShell 7+ (`pwsh`), not the built-in Windows PowerShell 5.1. Install with `winget install Microsoft.PowerShell` if needed.

### Manual setup

Add to `.claude/settings.json` by hand:

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

On Windows, use `"command": "pwsh -File ~/.claude/read-once/hook.ps1"` instead.

## How it works

1. Hook intercepts every `Read` tool call
2. Partial reads (with `offset` or `limit`) always pass through — only full-file reads are cached
3. Checks a session-scoped cache: has this file been read before?
4. Compares file mtime — if unchanged, advises Claude the content is already in context
5. In warn mode (default): allows the read with advisory. In deny mode: blocks the read entirely
6. If the file changed since last read, allows it through (or shows just the diff — see below)
7. Cache entries expire after 20 minutes (configurable) to handle context compaction

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

There's no way to detect compaction events from a hook, so a time-based heuristic is the best available approach. If you know compaction just happened, you can manually reset the cache:

```sh
./read-once clear
```

## Stats

```sh
./read-once stats          # macOS/Linux
pwsh read-once.ps1 stats   # Windows
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
read-once verify      Full diagnostic with dry-run test
read-once status      Quick health check
read-once clear       Clear session cache
read-once install     Add hook to settings
read-once upgrade     Update installed hook to latest
read-once uninstall   Remove hook
```

On Windows, use `pwsh read-once.ps1 <command>` instead of `./read-once <command>`.

### Verify

After installing, run `read-once verify` to confirm everything works:

```
$ ./read-once verify

read-once verify

Dependencies:
  [ok]   jq found (jq-1.7.1)
  [ok]   bash 5.2.37 (4+ required)
  [ok]   python3 found (needed for diff mode)
  [ok]   stat found

Installation:
  [ok]   Hook file exists at ~/.claude/read-once/hook.sh
  [ok]   Hook file is executable
  [ok]   Installed hook matches source (up to date)
  [ok]   ~/.claude/settings.json exists
  [ok]   settings.json is valid JSON
  [ok]   PreToolUse Read matcher configured
  [ok]   Hook command path resolves (~/.claude/read-once/hook.sh)

Dry-run test:
  [ok]   First read: allowed (no output = pass-through)
  [ok]   Second read: produced valid JSON response
  [ok]   Second read: correctly detected re-read (mode: warn)

Configuration:
  Mode:     warn (READ_ONCE_MODE)
  TTL:      1200s (20m) (READ_ONCE_TTL)
  Diff:     0 (READ_ONCE_DIFF)
  Disabled: 0 (READ_ONCE_DISABLED)

13/13 checks passed. read-once is ready.
```

If any check fails, verify tells you exactly what to fix.

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `READ_ONCE_MODE` | `warn` | `warn` allows reads with advisory message. `deny` blocks reads entirely. Warn mode prevents Edit tool deadlock and parallel read cascade failures. |
| `READ_ONCE_TTL` | `1200` | Cache TTL in seconds. After this, re-reads are allowed (compaction safety). |
| `READ_ONCE_DIFF` | `0` | Set to `1` to show only diffs when files change (instead of full re-read). |
| `READ_ONCE_DIFF_MAX` | `40` | Max diff lines before falling back to full re-read. |
| `READ_ONCE_DISABLED` | `0` | Set to `1` to disable the hook entirely. |

## Requirements

**macOS / Linux:**
- `jq` (for JSON parsing)
- `bash` 4+
- `python3` (optional, for diff mode JSON escaping)
- Claude Code with hooks support

**Windows:**
- PowerShell 7+ (`pwsh`), not the built-in Windows PowerShell 5.1
- Claude Code with hooks support

## How much does it save?

Claude Code re-reads files more than you'd think. Common patterns:
- Reading a file, editing it, then reading it again to verify
- Re-reading config files across different parts of a task
- Reading the same file in subagents that share a session

Each blocked re-read saves the full file token cost (including the ~70% overhead from line numbers in `cat -n` format). Run `./read-once stats` after a session to see your actual savings.

## FAQ

**The Edit tool says "File has not been read yet" even though I already read it.**
This happens in deny mode (`READ_ONCE_MODE=deny`). Claude Code's Edit tool requires a successful Read before it will edit a file. When read-once blocks the Read, Edit thinks the file was never read. The fix: use the default warn mode (`READ_ONCE_MODE=warn`), which allows reads with an advisory instead of blocking them.

**Won't this break after context compaction?**
Cache entries expire after 20 minutes (configurable via `READ_ONCE_TTL`). After expiry, re-reads are allowed. You can also run `read-once clear` to reset the cache manually after compaction.

**Claude Code reads small chunks, not whole files — does this help?**
Partial reads with `offset` or `limit` are never cached. They always pass through. read-once only deduplicates full-file reads where the entire file is requested again.

**Isn't there a good reason Claude re-reads files?**
Yes — when the file changed, or when context compacted. read-once only blocks re-reads when the file hasn't changed (same mtime) and the cache is recent. Changed files always pass through. With diff mode enabled (`READ_ONCE_DIFF=1`), changed files show just the delta instead of the full content.

## Compatibility

Works alongside RTK (which handles Bash output) and Context-Mode (which handles large outputs). read-once operates on a different layer — the Read tool — so there's no conflict.

## License

MIT
