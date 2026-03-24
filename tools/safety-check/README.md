# Claude Code Safety Check

Audit your Claude Code setup in 5 seconds. No installation required.

## Run it

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash
```

## What it checks

| Check | Weight | What it detects |
|-------|--------|-----------------|
| Claude Code installed | 5 | CLI available on PATH |
| Settings file exists | 5 | `~/.claude/settings.json` present |
| bash-guard | 20 | Blocks `rm -rf /`, `sudo`, `curl\|bash` |
| git-safe | 15 | Blocks force push, hard reset |
| file-guard | 15 | Protects `.env`, keys, secrets |
| branch-guard | 10 | Prevents commits to main/master |
| session-log | 15 | Audit trail of all tool calls |
| read-once | 10 | Prevents redundant file reads |
| Permission rules | 5 | Allow/deny rules in settings |

## Grades

| Score | Grade | Meaning |
|-------|-------|---------|
| 90-100 | A | Well-protected |
| 70-89 | B | Good, minor gaps |
| 50-69 | C | Fair, several gaps |
| 30-49 | D | Poor, too much unguarded access |
| 0-29 | F | Unsafe |

## Example output

```
Claude Code Safety Check
━━━━━━━━━━━━━━━━━━━━━━━━

Setup
  ✓ Claude Code installed (+5)
  ✓ Settings file exists (+5)

Destructive Command Protection
  ✗ bash-guard (blocks rm -rf /, sudo, curl|bash) (0/20)
  ✓ git-safe (blocks force push, hard reset) (+15)

...

Safety Score: 45/100 (45%) — Grade D
```

Each failed check shows a one-liner fix command.

## Verify mode

The basic check only confirms hooks are registered. Use `--verify` to send real test payloads and confirm hooks actually block what they claim to:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify
```

This sends dangerous payloads (like `rm -rf /`) to each installed hook and checks the response. Hooks that fail to block are flagged as **FAIL-OPEN**.

```
Hook Verification (sending test payloads)
  ✓ bash-guard blocks rm -rf / — blocks correctly
  ✓ bash-guard passes safe commands — passes safe payload
  ✓ git-safe blocks force push — blocks correctly
  ✓ git-safe passes safe commands — passes safe payload
  ✗ custom-hook — did NOT block (FAIL-OPEN)

  1/5 hooks FAIL-OPEN
```

Why this matters: a hook can be registered in `settings.json` but silently fail open if the script is missing, uses the wrong JSON field name, or outputs invalid responses ([claude-code#37597](https://github.com/anthropics/claude-code/issues/37597), [Boucle-framework#2](https://github.com/Bande-a-Bonnot/Boucle-framework/pull/2)).

## CLAUDE.md rule coverage

When a `CLAUDE.md` exists in the current directory, safety-check scans it for rules that could be enforced by hooks but currently aren't. This helps bridge the gap between "I wrote rules" and "rules are actually enforced."

```
Rules in CLAUDE.md that could be enforced:
  → file-guard — your CLAUDE.md mentions sensitive files (.env, keys, credentials)
  → git-safe — your CLAUDE.md mentions destructive git operations
  These are advisory until backed by hooks. Install the hooks above or use enforce-hooks.
```

Rules are matched by keyword (`.env`, `force push`, `rm -rf`, `feature branch`, etc). Only missing hooks are suggested. If all relevant hooks are installed, no suggestions appear.

## No dependencies

- Bash 4+
- Python 3 (for JSON parsing of settings.json)
- Works on macOS and Linux
