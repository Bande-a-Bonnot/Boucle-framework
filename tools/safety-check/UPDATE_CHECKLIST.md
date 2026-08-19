# Claude Code update checklist

Use this when Claude Code changes version, updates itself, or starts behaving
differently after an IDE or plugin update. The goal is to prove that hooks still
fire before trusting a session with real work.

Run the checklist when any of these changes:

- Claude Code CLI, desktop app, IDE extension, or plugin version.
- `~/.claude/settings.json` or project `.claude/settings.json`.
- Shell profile, terminal app, WSL distribution, or PowerShell version used to
  launch Claude Code.
- Hook files, hook permissions, or the directory where Claude Code is started.

Use the same terminal profile and project root you use for real Claude Code
sessions. A clean check from a different shell or subdirectory does not prove
the session you are about to trust.

## Minimum recheck

If Claude Code already updated and you need the shortest useful answer, run the
strict verifier from the same root and terminal profile you use for real work:

```sh
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"
unset IS_DEMO CLAUDE_CODE_SIMPLE
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify --strict
```

On native Windows with PowerShell 7, use the native verifier:

```powershell
$root = if (Get-Command git -ErrorAction SilentlyContinue) { git rev-parse --show-toplevel 2>$null }
if ($root) { Set-Location $root }
Remove-Item Env:IS_DEMO -ErrorAction SilentlyContinue
Remove-Item Env:CLAUDE_CODE_SIMPLE -ErrorAction SilentlyContinue
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } verify"
```

Treat a non-zero strict result, `FAIL-OPEN`, skipped boundary hook, missing hook
inventory, or `Verify: not run` as a stop signal. Run the longer repair path
below before trusting the updated session. Treat a passing result as fresh
boundary evidence only after starting a new Claude Code session from the same
root.

If this is a git checkout, move to the repo root first; otherwise stay in the
directory you use for Claude Code:

```sh
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"
```

On native Windows:

```powershell
$root = if (Get-Command git -ErrorAction SilentlyContinue) { git rev-parse --show-toplevel 2>$null }
if ($root) { Set-Location $root }
```

## Before updating

Capture the current version and bounded summary before changing anything from
that same root. Those two lines make post-update regressions easier to compare
or report:

```sh
claude --version 2>/dev/null || printf 'claude CLI not found on PATH\n'
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify --summary-only
```

Command boundary: this downloads `tools/safety-check/check.sh` from GitHub raw
content and runs it locally on your current project and Claude Code settings.
The checker does not upload your `settings.json`, hook files, shell history,
repository contents, session logs, or safety summary output.

On native Windows, record the Claude Code version and the native verifier count:

```powershell
$root = if (Get-Command git -ErrorAction SilentlyContinue) { git rev-parse --show-toplevel 2>$null }
if ($root) { Set-Location $root }
claude --version 2>$null
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } verify"
```

Then snapshot the user-level settings file:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- backup
```

If this repository has project-local settings, keep a project backup too:

```sh
backup_stamp="$(date +%Y%m%d_%H%M%S)"
test -f .claude/settings.json && cp -p .claude/settings.json ".claude/settings.json.${backup_stamp}.bak"
```

On native Windows with PowerShell 7:

```powershell
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } backup"
$stamp = Get-Date -Format yyyyMMdd_HHmmss
if (Test-Path .claude/settings.json) { Copy-Item .claude/settings.json ".claude/settings.json.$stamp.bak" }
```

## After updating

Run these from the same project root you use to start Claude Code. If this is a
git checkout, get there first; otherwise stay in the directory you use for
Claude Code:

```sh
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"
```

Then verify the updated hook boundary:

```sh
unset IS_DEMO CLAUDE_CODE_SIMPLE
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- upgrade
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- doctor
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify --strict
```

On native Windows:

```powershell
$root = if (Get-Command git -ErrorAction SilentlyContinue) { git rev-parse --show-toplevel 2>$null }
if ($root) { Set-Location $root }
Remove-Item Env:IS_DEMO -ErrorAction SilentlyContinue
Remove-Item Env:CLAUDE_CODE_SIMPLE -ErrorAction SilentlyContinue
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } upgrade"
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } doctor"
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } verify"
```

Start a fresh Claude Code session after the check. Updated settings and hook
files are not enough if an existing session already loaded the old boundary.
Compare the new version and verification result with the pre-update notes
before deciding whether a failure is a new regression or an old unverified
setup.

Trust the hook layer only if all of these are true:

- Verification reports zero `FAIL-OPEN` payload checks.
- Hook files are healthy.
- The summary does not say `Verify: not run`, `no hooks found`, or
  `no payload checks ran`.
- Any skipped `PreToolUse` checks are understood and are not part of the
  boundary you rely on for blocking destructive tool calls.

A passing summary usually includes a line like:

```text
Verify: 0 FAIL-OPEN | 8 payload checks | 0 skipped
```

## If verification fails

Run `doctor` first. Do not reinstall repeatedly until you know which boundary
failed.

Common fixes:

- If `settings.json` is invalid, remove comments or trailing commas from the
  reported file.
- If hook files are missing or not executable, run `upgrade`, then `doctor`
  again.
- If hooks disappeared after the update, inspect the backup list, restore the
  named settings backup you meant to use, then verify again. Use bare `restore`
  only when the newest backup is the exact snapshot you want back.
- If `IS_DEMO` or `CLAUDE_CODE_SIMPLE` is set, unset it and start a fresh Claude
  Code session.
- If native Windows hook firing is inconsistent, verify in WSL before relying on
  hooks for destructive or autonomous work.

Restore the user-level settings backup. Use `backup list` first, then restore
the named snapshot you intend to use:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- backup list
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- restore settings.20260101_120000.json
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify --strict
```

To restore the most recent backup only if you meant it:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- restore
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify
```

On native Windows:

```powershell
$root = if (Get-Command git -ErrorAction SilentlyContinue) { git rev-parse --show-toplevel 2>$null }
if ($root) { Set-Location $root }
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } backup list"
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } restore settings.20260101_120000.json"
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } verify"
```

To restore the most recent backup only if you meant it in PowerShell:

```powershell
$root = if (Get-Command git -ErrorAction SilentlyContinue) { git rev-parse --show-toplevel 2>$null }
if ($root) { Set-Location $root }
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } restore"
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } verify"
```

If a project-local backup is needed, restore the exact snapshot you selected:

```sh
cp .claude/settings.json.20260101_120000.bak .claude/settings.json
```

On native Windows:

```powershell
Copy-Item .claude/settings.json.20260101_120000.bak .claude/settings.json
```

After any restore, run the same strict verification again from the project root
and start a fresh Claude Code session before trusting the hook layer. Restored
settings only prove the file is back on disk; they do not prove the updated
Claude Code process loaded it or that hooks still block representative payloads.

## Safe support evidence

When asking for help, share only the block that starts with:

```text
--- Safety Summary (copy/paste) ---
```

and ends with:

```text
--- End Safety Summary ---
```

Do not share raw `settings.json`, hook scripts, shell history, session logs,
private paths, tokens, `.env` contents, or proprietary `CLAUDE.md` rules in
public threads. The [safe support evidence guide](SUPPORT_EVIDENCE.md) gives a
short public-report template and explains the common summary lines.

Include the support template's pre-update baseline line:

```text
Pre-update baseline: summary/version captured / not captured / not an update issue
```

For an update failure, set this to `summary/version captured` only when you
recorded both the old Claude Code version and the bounded summary before the
update. Otherwise say `not captured`, so maintainers know the new strict result
may be the first verified result for an already-untrusted setup.

For native Windows `install.ps1 verify`, there is no safety summary block.
Share only the final verifier count plus any `WARN` or `SKIP` lines.
