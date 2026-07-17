# Claude Code Safety Check

Audit your Claude Code setup in 5 seconds. No installation required.
The audit bounds the `claude --version` probe, so a stuck Claude CLI cannot block the safety report.

## Run it

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash
```

On native Windows, run the Bash checker from WSL or Git Bash. If you installed
the native PowerShell hooks, use `install.ps1 verify` for payload checks that do
not require bash:

```powershell
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } verify"
```

Run it from the same project root you use to start Claude Code. If a parent
directory has `.claude/settings.json` and the current directory does not,
safety-check warns because Claude Code may skip root project hooks when launched
from the subdirectory.

New to the tool? Start with the [safety-check quickstart](QUICKSTART.md) for the
short audit, install, verify, and repair loop.

Need help with a result? Use the [safe support evidence guide](SUPPORT_EVIDENCE.md)
to share the copy/paste summary without exposing private settings or secrets.

Updating Claude Code? Use the [update checklist](UPDATE_CHECKLIST.md) to back
up settings, refresh hooks, verify the boundary, and restore safely if hooks
disappear.

## Verify it

The default audit checks whether hooks are configured. Verification mode checks whether installed `PreToolUse` hooks actually block representative payloads:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify
```

Each hook payload check has a 5-second timeout, so a stuck hook is reported as `FAIL-OPEN` evidence instead of hanging the audit. Set `HOOK_VERIFY_TIMEOUT_SECONDS` only if a deliberately slow local hook needs a longer bound.

Use `--help` to check supported flags. Unknown flags fail closed instead of falling back to the basic audit, so a typo cannot make `--verify` look like it ran.

For CI or scripted checks, add `--strict`:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify --strict
```

Strict mode still prints the full audit, then exits `1` if verification finds a `FAIL-OPEN` hook, no hooks, no payload checks, a skipped `PreToolUse` hook check, or broken hook files. It exits `0` only when every configured `PreToolUse` hook was checked or explicitly passed representative payload checks, and hook files are healthy.

See [scripted checks](CI.md) for GitHub Actions, workstation scripts, exit
codes, and the limits of what repository CI can prove.

Read the result as a repair list, not as a badge. Fix these before trusting the session:

1. Bypass flags such as `IS_DEMO=1` or a non-empty `CLAUDE_CODE_SIMPLE`.
2. Invalid `settings.json` or JSONC comments.
3. Missing or non-executable hook scripts.
4. Any hook reported as `FAIL-OPEN`.
5. Ancestor project settings warnings. Rerun from the root that contains
   `.claude/settings.json`.

## Repair loop

Use this order after any failing audit:

```sh
unset IS_DEMO CLAUDE_CODE_SIMPLE
test ! -f ~/.claude/settings.json || python3 -m json.tool ~/.claude/settings.json >/dev/null
test -f .claude/settings.json && cp .claude/settings.json .claude/settings.json.bak
test ! -f .claude/settings.json || python3 -m json.tool .claude/settings.json >/dev/null
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- all
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify
```

`install.sh backup` protects the user-level `~/.claude/settings.json` only. If this project has repo-local settings, keep the `.claude/settings.json.bak` copy until the update or hook test is done.

If either `json.tool` command fails, remove comments or trailing commas from that settings file before installing hooks. A broken project `.claude/settings.json` can change hook behavior even when the user-level settings file is valid. If `--verify` still reports `FAIL-OPEN`, inspect that hook before trusting it.

## Residual warnings

After the recommended hooks are installed, a setup can still score Grade C while verification passes. That usually means the local hooks blocked the representative payloads, but safety-check still found Claude Code platform limits that hooks cannot repair.

Do not keep reinstalling hooks to chase an A. Treat these as the first trust boundary:

1. No hook bypass flags in the current shell.
2. Valid `settings.json`.
3. No missing or non-executable hook scripts.
4. `--verify` reports zero `FAIL-OPEN` hooks.

If those are clean, document the remaining platform warnings as residual risk. For strong native Windows enforcement, prefer WSL until Claude Code hook firing is proven reliable in the current setup.

## What it checks

| Check | Weight | What it detects |
|-------|--------|-----------------|
| Claude Code installed | 5 | CLI available on PATH |
| Settings file exists | 5 | `~/.claude/settings.json` or current `.claude/settings.json` present |
| bash-guard | 20 | Blocks `rm -rf /`, `sudo`, `curl\|bash` |
| git-safe | 15 | Blocks force push, hard reset |
| file-guard | 15 | Protects `.env`, keys, secrets |
| branch-guard | 10 | Prevents commits to main/master |
| worktree-guard | 10 | Prevents unsafe worktree exit when changes or commits are still unmerged |
| session-log | 15 | Audit trail of all tool calls |
| read-once | 5 | Prevents redundant file reads |
| Permission rules | 5 | Allow/deny rules in settings |
| enforce-hooks | 10 | Turns `CLAUDE.md` rules into hook checks |
| `@enforced` rules | 5 | Marks `CLAUDE.md` rules for deterministic enforcement |
| read-once PostCompact reset | 2 | Conditional check when read-once is installed |

## Grades

| Percent | Grade | Meaning |
|---------|-------|---------|
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

Safety Score: 45/120 (37%) - Grade D
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
  ✓ bash-guard blocks rm -rf / - blocks correctly
  ✓ bash-guard passes safe commands - passes safe payload
  ✓ git-safe blocks force push - blocks correctly
  ✓ git-safe passes safe commands - passes safe payload
  ✗ custom-hook - did NOT block (FAIL-OPEN)

  1/5 payload checks FAIL-OPEN
```

The copy/paste summary at the end includes setup blockers as `Issue:` lines, the verify result, for example `Verify: 0 FAIL-OPEN | 8 payload checks | 2 skipped`, plus the trust boundary to use when sharing an audit result. Its `N/8 hooks` inventory counts the 7 standalone hooks plus `enforce-hooks`, which installs separately. The summary includes hook-disabling environment flags, invalid user or project settings JSON, broken hook files, and timed-out hook payload checks so support triage can work from the summary without asking for private settings. See [safe support evidence](SUPPORT_EVIDENCE.md) for the short public-report template.
If no hooks are installed yet, verify mode still prints a summary, but it will say `Verify: not run | no hooks found | 0 payload checks` and `Boundary: install hooks before trusting the hook layer.`
Custom hook commands that are not direct script paths are skipped rather than reported as missing files. Interpreter-wrapped hook scripts such as `sh ./hook.sh`, `zsh ./hook.sh`, or `python ./hook.py` are file-checked and verified through that interpreter, so they do not need the executable bit. Lifecycle hooks such as `SessionStart` and `Stop` are also skipped because they do not receive PreToolUse tool payloads. If every hook is skipped, the summary says no payload checks ran instead of claiming the hook layer passed. In strict mode, any skipped `PreToolUse` hook check exits `1`; skipped lifecycle hooks remain informational unless no `PreToolUse` payload checks ran.

Why this matters: a hook can be registered in `settings.json` but silently fail open if the script is missing, uses the wrong JSON field name, or outputs invalid responses ([claude-code#37597](https://github.com/anthropics/claude-code/issues/37597), [Boucle-framework#2](https://github.com/Bande-a-Bonnot/Boucle-framework/pull/2)).

## CLAUDE.md rule coverage

When a `CLAUDE.md` exists in the current directory, safety-check scans it for rules that could be enforced by hooks but currently aren't. This helps bridge the gap between "I wrote rules" and "rules are actually enforced."

```
Rules in CLAUDE.md that could be enforced:
  → file-guard - your CLAUDE.md mentions sensitive files (.env, keys, credentials)
  → git-safe - your CLAUDE.md mentions destructive git operations
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
| WorktreeCreate ignored | EnterWorktree tool does not fire WorktreeCreate/WorktreeRemove hooks ([#36205](https://github.com/anthropics/claude-code/issues/36205)) |
| TaskCreated observe-only | TaskCreated hooks cannot block task creation; decision field is ignored |
| SubagentStop inheritance | Background agents may not inherit all hook configurations ([#40818](https://github.com/anthropics/claude-code/issues/40818)) |
| Plan-mode writes | Model writes and pushes code despite plan-mode read-only ([#41517](https://github.com/anthropics/claude-code/issues/41517), [#40324](https://github.com/anthropics/claude-code/issues/40324)) |
| Plugin scope leak | Project-scoped plugins fire in all directories ([#41523](https://github.com/anthropics/claude-code/issues/41523)) |
| MCP silent rejection | MCP tool calls silently rejected by parameter value ([#41528](https://github.com/anthropics/claude-code/issues/41528)) |
| Bash cd+pipe deadlock | `cd /path && cmd \| filter` auto-backgrounded, session hangs ([#41509](https://github.com/anthropics/claude-code/issues/41509)) |

### Hook event types scanned

safety-check detects hooks across all Claude Code event types: PreToolUse, PostToolUse, SessionStart, SessionEnd, Stop, SubagentStop, TaskCreated, WorktreeCreate, WorktreeRemove, UserPromptSubmit, and Notification.

## No dependencies

- Bash 4+
- Python 3 (for JSON parsing of settings.json)
- Works on macOS and Linux
- On Windows, run under WSL or Git Bash. The PowerShell installer can install,
  verify, and diagnose native `.ps1` hooks without bash, but its `check`
  subcommand delegates to this bash-based safety-check script.
