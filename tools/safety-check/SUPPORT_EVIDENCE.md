# Safe support evidence

Use this when a safety-check result looks wrong and you need help in a public
issue, chat thread, or support channel. The goal is to share enough evidence to
debug the hook boundary without leaking private settings, paths, prompts, or
secrets.

## 1. Run verification

Run the checker from the project where Claude Code will work. If you are inside
a git checkout, move to the repo root first so the summary matches the
project-level `.claude/settings.json` Claude Code can load. Outside git, stay
in the current project directory:

```sh
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"
```

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify
```

On native Windows PowerShell:

```powershell
$root = if (Get-Command git -ErrorAction SilentlyContinue) { git rev-parse --show-toplevel 2>$null }
if ($root) { Set-Location $root }
```

Use the project root that contains `.claude/settings.json` when one exists. If
the summary reports ancestor project settings, rerun from that root before
posting the report.

To print only the bounded public support block, add `--summary-only`:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify --summary-only
```

Command boundary: this downloads `tools/safety-check/check.sh` from GitHub raw
content, then runs it locally on your current project and Claude Code settings.
The checker does not upload your `settings.json`, hook files, shell history,
repository contents, session logs, or safety summary output.

On native Windows, use the PowerShell installer verification path when you
installed native `.ps1` hooks:

```powershell
$root = if (Get-Command git -ErrorAction SilentlyContinue) { git rev-parse --show-toplevel 2>$null }
if ($root) { Set-Location $root }
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } verify"
```

If Git Bash or WSL is available, you can also run `install.ps1 check --verify`
or the bash checker directly to get the full safety-check summary block. The
native PowerShell verifier does not emit that block; it prints hook-by-hook
verification plus a final count line.

If the command hangs, rerun with the default timeout. Do not raise
`HOOK_VERIFY_TIMEOUT_SECONDS` for a public support report unless you know a
local hook is intentionally slow.

## 2. Copy only the summary block

For `safety-check --verify` output, copy the block near the end that starts
with:

```text
--- Safety Summary (copy/paste) ---
```

and stops at:

```text
--- End Safety Summary ---
```

If you ran `--summary-only`, the command output is already limited to this
bounded block.

That bounded block is designed for public triage. It includes the grade, hook
inventory, `Issue:` lines, verification counts, and the current trust boundary.
Path-related summary issues redact your home directory as `~` and the current
checkout as `<project>`.

It should not include raw `settings.json`, hook script contents, shell history,
session logs, `.env` values, tokens, private file paths, or proprietary
`CLAUDE.md` rules.

Do not paste raw hook stderr from a live Claude Code session. Claude Code can
prefix hook stderr with the hook command path, so even a clean block message can
expose local usernames, repository names, or private hook locations. The
safety-check summary is the safer public artifact.

For native `install.ps1 verify` output, there is no `--- Safety Summary
(copy/paste) ---` block. Copy only:

- The final count line, such as `All 3 hooks verified, 0 skipped.` or
  `2 passed, 1 warnings, 1 skipped.`
- Any `WARN` or `SKIP` lines printed during verification.
- `No hooks installed. Run: install.ps1 recommended`, if that is the result.

Do not include the startup hook table if it exposes private paths or local hook
locations.

For concrete safe and unsafe report examples, see
[safe support examples](SUPPORT_EXAMPLES.md).

## 3. Add the minimum context

Add these short details above the summary block:

```text
OS: macOS / Linux / WSL / native Windows
Shell: bash / zsh / PowerShell 7 / Git Bash
Claude Code version: output of claude --version, if it returns quickly
Where hooks are installed: user settings / project settings / both / not sure
What changed recently: fresh install / Claude Code update / settings edit / moved hook files
Pre-update baseline: summary/version captured / not captured / not an update issue
```

If `claude --version` hangs, write `Claude Code version: version probe hangs`.
Do not paste a full terminal transcript.

When the issue appeared after a Claude Code update, say whether you captured
the pre-update version and bounded summary from the update checklist. Do not
paste both full command outputs. A maintainer usually needs to know whether the
new strict verification result is a regression from a known baseline or the
first verified result for an already-untrusted setup.

## 4. Read the summary before posting

Common summary lines have specific meanings:

| Summary line | What it means |
|--------------|---------------|
| `Verify: 0 FAIL-OPEN` | Representative payload checks did not find a hook that failed open. |
| `Verify: not run` | The basic audit ran, but runtime hook payload checks did not. |
| `no hooks found` | Claude Code has no configured hooks in the checked settings files. |
| `no payload checks ran` | Hooks may exist, but none were verified with `PreToolUse` payloads. |
| `Issue: IS_DEMO is set` | The current shell may disable hook execution before hooks can run. |
| `Issue: CLAUDE_CODE_SIMPLE is set` | Minimal Claude Code mode disables hooks and related features. |
| `Issue: invalid settings JSON` | Fix the reported settings file before reinstalling hooks. |
| `Issue: Ancestor project settings found above the current directory` | Rerun from the project root that owns `.claude/settings.json`. |
| `FAIL-OPEN` | A configured hook did not block a representative dangerous payload. |

If the grade is still C after `Verify: 0 FAIL-OPEN`, do not keep reinstalling
hooks. The local hook boundary may be working while platform warnings remain as
residual risk.

## 5. What not to share

Do not post:

- Full `~/.claude/settings.json` or `.claude/settings.json` files.
- Hook source from private repositories.
- Raw hook stderr from a live Claude Code session.
- Session logs, shell history, prompts, transcripts, or screenshots with paths.
- Tokens, API keys, `.env` contents, OAuth files, SSH keys, or private URLs.
- Proprietary `CLAUDE.md` rules unless you have reviewed and redacted them.

If a maintainer needs raw files, do not trim your real workspace into a public
zip. Build a minimal reproduction in a temporary directory, then run
`safety-check` there:

```sh
tmpdir="$(mktemp -d)"
tmp_home="$(mktemp -d)"
mkdir -p "$tmpdir/.claude/hooks"
printf '{"hooks":{}}\n' > "$tmpdir/.claude/settings.json"
cd "$tmpdir"
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | HOME="$tmp_home" bash -s -- --verify --summary-only
```

Replace the sample `.claude/settings.json` with the smallest redacted settings
file that reproduces the issue. Keep only throwaway hook scripts and placeholder
paths in the temporary directory. The temporary `HOME` keeps your real
user-level Claude Code hooks out of the reproduction. If the problem does not
reproduce there, say that; it usually means the remaining signal is in local
paths, environment variables, shell startup files, or private hook code that
should not be posted.

## 6. Minimal public report template

```text
OS:
Shell:
Claude Code version:
Where hooks are installed:
What changed recently:
Pre-update baseline:

--- Safety Summary (copy/paste) ---
...
--- End Safety Summary ---

Native Windows PowerShell verifier, if no Safety Summary block exists:
...
```

For a full repair path before asking for help, start with the
[safety-check quickstart](QUICKSTART.md). To decide which summary item to fix
first, use the [safety summary triage guide](TRIAGE.md). For failures after
Claude Code updates, use the [update checklist](UPDATE_CHECKLIST.md). For
copy/paste examples, use [safe support examples](SUPPORT_EXAMPLES.md).
