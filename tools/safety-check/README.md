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

## Environment warnings

Beyond the scored checks, safety-check detects platform bugs and configuration pitfalls that can silently break your setup:

| Warning | What it catches |
|---------|----------------|
| IS_DEMO | Silently disables all hooks ([#37780](https://github.com/anthropics/claude-code/issues/37780)) |
| GIT_INDEX_FILE | Git index corruption when Claude runs from git hooks ([#38181](https://github.com/anthropics/claude-code/issues/38181)) |
| JSONC comments | Invalid JSON in settings.json breaks hook loading ([#37540](https://github.com/anthropics/claude-code/issues/37540)) |
| deny + denyWrite | bwrap sandbox failures on Linux ([#38375](https://github.com/anthropics/claude-code/issues/38375)) |
| bypassPermissions | Mode resets to default in long sessions ([#38372](https://github.com/anthropics/claude-code/issues/38372)) |
| External Write allow | Absolute paths outside project ignored for Write/Edit ([#38391](https://github.com/anthropics/claude-code/issues/38391)) |
| Colon in filenames | Permission matching breaks on `:` in paths ([#38409](https://github.com/anthropics/claude-code/issues/38409)) |
| Windows | Hooks fire only ~18% of the time ([#37988](https://github.com/anthropics/claude-code/issues/37988)) |
| CLI version | Known regressions in specific versions ([#37597](https://github.com/anthropics/claude-code/issues/37597), [#37878](https://github.com/anthropics/claude-code/issues/37878)) |
| Hook "ask" permission | `permissionDecision: "ask"` permanently breaks bypass mode ([#37420](https://github.com/anthropics/claude-code/issues/37420)) |
| Hook exit code 2 | `exit 2` treated as crash, deny silently ignored for Edit/Write ([#37210](https://github.com/anthropics/claude-code/issues/37210)) |
| Spaces in workdir | Hooks fail when working directory contains spaces ([#39478](https://github.com/anthropics/claude-code/issues/39478)) |
| Spaces in HOME | Hook commands word-split when user profile path has spaces ([#40084](https://github.com/anthropics/claude-code/issues/40084)) |
| Stop hook isolation | Stop/PostToolUse hooks fire across all parallel sessions ([#39530](https://github.com/anthropics/claude-code/issues/39530)) |
| updatedInput + Agent | `updatedInput` silently ignored for Agent tool calls ([#39814](https://github.com/anthropics/claude-code/issues/39814)) |
| Worktree isolation | Agent `isolation: "worktree"` silently runs in main repo ([#39886](https://github.com/anthropics/claude-code/issues/39886)) |
| Subagent hook bypass | Hook exit codes silently ignored in subagent tool calls ([#40580](https://github.com/anthropics/claude-code/issues/40580)) |

## No dependencies

- Bash 4+
- Python 3 (for JSON parsing of settings.json)
- Works on macOS and Linux
