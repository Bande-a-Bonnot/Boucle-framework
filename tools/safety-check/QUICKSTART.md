# Safety-check quickstart

Use this when you want to know whether a Claude Code setup can actually block
dangerous tool calls. The goal is not a perfect grade. The goal is a verified
trust boundary before you let Claude edit a real project.

If you want to try the checker without reading your real Claude Code settings
first, run the [temporary first test](FIRST_TEST.md), then come back here for the
real audit and install path. On native Windows, use WSL or Git Bash for that
isolated first test; `install.ps1 verify` inspects hooks under your real
`$HOME/.claude` directory.

## 0. Choose the path

Use the first row that matches why you are here:

| Situation | Start here | Stop when |
|-----------|------------|-----------|
| You have never run safety-check on this machine | [Temporary first test](FIRST_TEST.md) | The isolated summary says `Verify: not run \| no hooks found \| 0 payload checks`. |
| You want to audit your current Claude Code setup | [Run the audit](#1-run-the-audit) | You understand the first missing hook, settings, or environment issue. |
| You want a minimal personal workstation baseline | [Install the baseline hooks](#2-install-the-baseline-hooks) | `install.sh verify` or `install.ps1 verify` reports the recommended hooks blocking their test payloads. |
| You need proof before a risky session, CI job, or team handoff | [Verify the hooks fire](#3-verify-the-hooks-fire) | The summary reports zero `FAIL-OPEN` checks, zero skipped boundary hooks, and a fresh Claude Code session has started from the same root. |
| You are preparing a public support request | [Share safe support evidence](#7-share-safe-support-evidence) | You have only the bounded summary block and the minimum redacted context. |

## 1. Run the audit

Prerequisites:

- macOS, Linux, WSL, or Git Bash: `bash`, `python3`, and either `curl` or
  `wget` for the audit command.
- Shell hooks on macOS, Linux, WSL, or Git Bash: install `jq` before trusting
  hook enforcement. Most standalone shell hooks need it to parse Claude Code
  hook payloads.
- Native Windows hooks: run the PowerShell installer from PowerShell 7
  (`pwsh`), not Windows PowerShell 5.

Run it from the project root you use to start Claude Code, especially when the
repository has `.claude/settings.json`. Running from a subdirectory can miss
project-level hooks that live at the repo root.

If you are inside a git checkout, move to the repo root first. If not, stay in
the directory you use to launch Claude Code:

```sh
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"
```

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash
```

Read the result as a repair list. A low grade usually means one of these is
missing or broken:

- `bash-guard` for destructive shell commands.
- `git-safe` for force pushes, hard resets, and other destructive git commands.
- `file-guard` for secrets such as `.env`, private keys, and credentials.
- `session-log` for a local audit trail.
- Valid `~/.claude/settings.json` and `.claude/settings.json` files.

Do not paste private settings or full hook output into a public issue. If you
need support, share only the final `--- Safety Summary (copy/paste) ---` block
from the audit output, stopping at `--- End Safety Summary ---`. The
[safe support evidence guide](SUPPORT_EVIDENCE.md) has a short public-report
template and a list of fields to redact. To print only that bounded block:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify --summary-only
```

## 2. Install the baseline hooks

Pick the smallest hook layer that matches the boundary you need:

| Need | Install path | What it covers |
|------|--------------|----------------|
| Block the most dangerous shell, git, and secret-file operations | `install.sh recommended` or `install.ps1 recommended` | `bash-guard`, `git-safe`, and `file-guard`. Start here for most personal workstations. |
| Add the full standalone hook suite | `install.sh all` or `install.ps1 all` | The recommended hooks plus read-once, branch-guard, worktree-guard, and session-log. |
| Enforce project rules from `CLAUDE.md` | `tools/enforce/install.sh` | One dynamic hook that reads `@enforced` rules from the current repo. Use this when prompt rules need to become runtime blocks. |

If this is a personal workstation, start with the recommended hook set:

```sh
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- recommended
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- verify
```

If you want the full hook suite:

```sh
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- all
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- verify
```

The installer verifier sends representative payloads to the installed hooks and
confirms the expected blocks. The full safety-check verification in the next
section adds the copy/paste summary, strict mode, environment warnings, and
project-settings inventory.

Both `recommended` and `all` install user-level hooks under
`~/.claude/<hook-name>/` and register them in `~/.claude/settings.json`. They do
not create repo-local `.claude/settings.json` policy for the current project.
The project root still matters for the audit because safety-check also inspects
checked-in project settings when they already exist.

On Windows, use PowerShell 7 or WSL. Native Windows hook behavior can vary by
Claude Code version, so verify immediately after installing:

```powershell
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } recommended"
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } verify"
```

The native PowerShell installer covers the standalone hooks. The `enforce-hooks`
installer is a bash/Python tool; run it from WSL or Git Bash on Windows.

If you are only testing the hook suite, keep the rollback command handy. It
removes Boucle hook files and their `settings.json` registrations. If you want
the trial to be fully reversible, snapshot your Claude Code user settings before
installing hooks:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- backup
```

On native Windows:

```powershell
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } backup"
```

Then remove the hooks when the trial is over:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- uninstall all
```

On native Windows:

```powershell
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } uninstall all"
```

On a borrowed machine, client repository, CI runner, or any other temporary
environment, inspect the backup list and restore the pre-trial snapshot if you
want the exact previous settings file, then verify cleanup before you leave it:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- backup list
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- restore
```

On native Windows:

```powershell
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } backup list"
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } restore"
```

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify --summary-only
```

The expected cleanup result is no Boucle hook inventory and a summary such as
`Verify: not run | no hooks found | 0 payload checks`. On native Windows, run
`install.ps1 verify` and expect `No hooks installed. Run: install.ps1
recommended` when only the native user-level hooks were present.

## 3. Verify the hooks fire

The basic audit can confirm that hooks are registered. Verification mode sends
representative Claude-style JSON payloads to installed `PreToolUse` hooks and
checks whether they block. It invokes the hook scripts; it does not execute the
dangerous shell or git commands named inside those payloads:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify
```

For CI or a scripted workstation check, fail the command when verification is
inconclusive:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify --strict
```

For a copy-paste GitHub Actions workflow and strict-mode exit code table, see
the [scripted checks guide](CI.md).
For help choosing what to repair first from the copy/paste summary, use the
[safety summary triage guide](TRIAGE.md).

On native Windows, verify through the PowerShell installer instead of piping the
Bash checker:

```powershell
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } verify"
```

`install.ps1 verify` uses native PowerShell hook payload checks. The
`install.ps1 check` command delegates to this bash-based safety-check script, so
it needs Git Bash, WSL, or another `bash` on PATH.

Trust the hook layer only when the summary says there are zero `FAIL-OPEN`
results and the hook files are healthy. If no payload checks ran, you have not
verified enforcement yet.

After a clean verification, start a fresh Claude Code session from that same
project root before trusting the new boundary. A running session may have
loaded the previous settings or hook files.

For a usable result, look at the copy/paste summary near the end. A verified
baseline looks like this:

```text
Verify: 0 FAIL-OPEN | 8 payload checks | 0 skipped
Boundary: hooks passed representative checks; document residual platform warnings.
```

If the summary says `Verify: not run`, `no hooks found`, or `no hook payload
checks ran`, treat the hook layer as unverified even when the grade looks high.
If it warns about ancestor project settings, rerun from the directory that
contains that `.claude/settings.json` before trusting the result.
The `N/8 hooks` inventory counts the 7 standalone hooks plus `enforce-hooks`;
`install.sh all` installs the standalone suite, and `enforce-hooks` is installed
separately when you want CLAUDE.md rules enforced at tool-call time.

Use the first matching row from the summary as your next repair:

| Summary evidence | First repair |
|------------------|--------------|
| `Issue: IS_DEMO is set` or `Issue: CLAUDE_CODE_SIMPLE is set` | Unset the environment variable, restart the shell that launches Claude Code, then rerun `--verify`. |
| `Issue: invalid settings JSON` | Validate the named settings file with `python3 -m json.tool`, remove comments or trailing commas, then rerun `--verify`. |
| `Verify: not run`, `no hooks found`, or `0 payload checks` | Install the recommended hooks or replace dynamic hook snippets with direct script paths, then rerun from the same project root. |
| `FAIL-OPEN` | Run `install.sh doctor`, inspect or reinstall the named hook, then rerun `--verify` before trusting the session. |
| `skipped PreToolUse` | Point the hook command at a verifiable script path such as `bash ./hooks/name.sh` or `python ./hooks/name.py`. |
| Ancestor project settings warning | `repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"` then `cd "$repo_root"`, or start Claude Code from the directory that owns `.claude/settings.json`. |
| `Verify: 0 FAIL-OPEN` with a Grade C or warnings | Keep the verified hook boundary and document the residual platform warnings. Do not reinstall hooks just to chase an A. |

## 4. Fix the common blockers

Run these checks before reinstalling hooks repeatedly:

```sh
unset IS_DEMO CLAUDE_CODE_SIMPLE
command -v python3 >/dev/null || { echo "Install python3 before validating settings.json"; exit 1; }
test ! -f ~/.claude/settings.json || python3 -m json.tool ~/.claude/settings.json >/dev/null
test ! -f .claude/settings.json || python3 -m json.tool .claude/settings.json >/dev/null
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- doctor
```

On native Windows:

```powershell
Remove-Item Env:IS_DEMO -ErrorAction SilentlyContinue
Remove-Item Env:CLAUDE_CODE_SIMPLE -ErrorAction SilentlyContinue
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } doctor"
```

If JSON validation fails, remove comments or trailing commas from the reported
settings file. If `python3` is missing, safety-check cannot validate
`settings.json` syntax or reliably inventory Python-backed hooks; install
Python 3, then rerun the audit before trusting the score. If `doctor` reports
missing or non-executable hook files, repair those before trusting `--verify`.

## 5. Recheck after Claude Code updates

Claude Code updates can change hook behavior or overwrite settings. Before
updating, snapshot the user-level settings file:

For a compact copy-paste flow, use the [Claude Code update checklist](UPDATE_CHECKLIST.md).

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- backup
```

On native Windows:

```powershell
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } backup"
```

After the update, refresh installed hook files and run the strict audit with
payload verification:

```sh
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- upgrade
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- check --verify --strict
```

On native Windows, use the native PowerShell hook verifier:

```powershell
$root = if (Get-Command git -ErrorAction SilentlyContinue) { git rev-parse --show-toplevel 2>$null }
if ($root) { Set-Location $root }
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } upgrade"
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } verify"
```

For native `install.ps1 verify`, there is no safety summary block. Share only
the final verifier count plus any `WARN` or `SKIP` lines.

If verification fails after the update, run `doctor` before reinstalling. If
hooks disappeared or `doctor` reports that `settings.json` was wiped, restore
the most recent backup, then run the strict audit again. Use `backup list`
first when you need to inspect which snapshot will be restored:

```sh
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- doctor
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- backup list
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- restore
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- check --verify --strict
```

To restore a specific backup from that list, pass the filename:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- restore settings.20260101_120000.json
```

On native Windows:

```powershell
$root = if (Get-Command git -ErrorAction SilentlyContinue) { git rev-parse --show-toplevel 2>$null }
if ($root) { Set-Location $root }
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } doctor"
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } backup list"
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } restore"
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } verify"
```

Specific backup restore works the same way in PowerShell:

```powershell
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } restore settings.20260101_120000.json"
```

## 6. Recheck after risky changes

Run `--verify` again after:

- Updating Claude Code.
- Editing `~/.claude/settings.json` or `.claude/settings.json`.
- Installing, removing, or moving hook scripts.
- Switching between macOS, Linux, WSL, Git Bash, and PowerShell.
- Starting Claude Code from a different subdirectory of the same repository.
- Starting a long-running autonomous or semi-autonomous session.

If verification passes but the grade is still C, treat the remaining warnings as
platform risk rather than a hook install failure. Document the warnings and keep
the verified boundary: no bypass flags, valid JSON, healthy hook files, and zero
`FAIL-OPEN` payload checks.
Use the [safety summary triage guide](TRIAGE.md) when the summary has multiple
issues and you need a repair order.
When a teammate, reviewer, or incident owner needs the result, use the
[team handoff report](TEAM_HANDOFF.md) to record the root checked, command
used, verification result, residual warnings, and next recheck trigger.

## 7. Share safe support evidence

Run verification before asking for help:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify
```

To avoid copying from the full local report, print only the bounded public
support block:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify --summary-only
```

Add the short context fields from the safe support evidence guide above the
summary block, including:

```text
Pre-update baseline: summary/version captured / not captured / not an update issue
```

For failures after a Claude Code update, this tells a maintainer whether the
new strict result is a regression from a known baseline or the first verified
result for an already-untrusted setup.

Copy the block that starts with:

```text
--- Safety Summary (copy/paste) ---
```

and ends with:

```text
--- End Safety Summary ---
```

That bounded block includes the grade, installed hook inventory, `Issue:` lines,
verify counts, and the current trust boundary. It does not include raw settings
files or hook source.

On native Windows with `install.ps1 verify`, copy only the final verifier count
plus any `WARN` or `SKIP` lines. The PowerShell verifier does not print the
`--- Safety Summary (copy/paste) ---` block.

Do not share raw `settings.json`, hook scripts, shell history, session logs,
private paths, tokens, `.env` contents, or proprietary `CLAUDE.md` rules in
public threads. Do not paste raw hook stderr from a live Claude Code session,
because the platform can prefix it with the hook command path. Use the
[safe support evidence guide](SUPPORT_EVIDENCE.md) when you need a copy/paste
report format or a temporary-directory reproduction instead of real workspace
files. For team handoffs that are not public support requests, use the
[team handoff report](TEAM_HANDOFF.md).
