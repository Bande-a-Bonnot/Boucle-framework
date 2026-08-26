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
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify
```

On native Windows PowerShell, use this root-selection prefix before native
installer commands. It only changes to the project root; use the
`install.ps1 verify` command below for the actual native hook verification:

```powershell
$root = if (Get-Command git -ErrorAction SilentlyContinue) { git rev-parse --show-toplevel 2>$null }
if ($root) { Set-Location $root }
```

Use the project root that contains `.claude/settings.json` when one exists. If
the summary reports ancestor project settings, rerun from that root before
posting the report.

To print only the bounded public support block, add `--summary-only`:

```sh
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"
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

Each verified hook payload has a 5-second default timeout. If a hook exceeds
that bound, the summary reports it as an `Issue:` line, for example
`hook payload check(s) timed out after 5 seconds`. For a public support report,
keep the default timeout and share that summary line. Do not raise
`HOOK_VERIFY_TIMEOUT_SECONDS` unless you know a local hook is intentionally
slow, and say so in the report if you changed it.

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
Command/scope: real project-root --verify / isolated first test / native install.ps1 verify
What changed recently: fresh install / Claude Code update / settings edit / moved hook files
Pre-update baseline: summary/version captured / not captured / not an update issue
Fresh Claude Code session from verified root: started / not yet / not changed
MCP servers involved: none / names from claude mcp list / not sure
Next intended action: audit only / local fix / commit / push / public report
```

If `claude --version` hangs, write `Claude Code version: version probe hangs`.
Do not paste a full terminal transcript.

When the issue appeared after a Claude Code update, say whether you captured
the pre-update version and bounded summary from the update checklist. Do not
paste both full command outputs. A maintainer usually needs to know whether the
new strict verification result is a regression from a known baseline or the
first verified result for an already-untrusted setup.

If you installed, upgraded, restored, or repaired hooks, restart Claude Code
from the same project root before writing `started` in the fresh-session field.
A clean shell-side `--verify` result proves the hook scripts and settings file
responded to representative payloads; it does not prove an already-running
Claude Code session has reloaded those files.

For MCP-related failures, add only the visible server names and connection
state from `claude mcp list`, plus whether a fresh session can run one harmless
read-only call against each critical server. Do not paste `claude mcp get`
output for HTTP servers into public reports, because headers, URLs, or command
arguments can include bearer tokens, private hosts, or local paths. Treat MCP
server URL, package, tool name, schema, description, prompt metadata, and plugin
channel changes as renewed approval events. A clean hook summary proves local
hooks responded to representative payloads; it does not prove a remote MCP
server kept the same tool surface or instructions.

The command/scope line keeps a first-test report from being mistaken for a real
hook-boundary check. If you ran the temporary first test, write
`Command/scope: isolated first test` and treat the result as startup evidence
only. The next useful support report is a real project-root `--verify
--summary-only` run from the directory where Claude Code will work.

If the next intended action is `commit`, `push`, or `public report`, inspect the
staged diff, destination branch, and remote target separately before approving
that action. A clean safety summary is evidence about the local hook boundary. It
is not evidence that the current staged content is safe to publish, that secrets
were not committed before hooks were installed, or that a remote push has been
approved.

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
- Raw `claude mcp get` output, MCP OAuth files, or HTTP headers.
- Tokens, API keys, `.env` contents, OAuth files, SSH keys, or private URLs.
- Proprietary `CLAUDE.md` rules unless you have reviewed and redacted them.

If a maintainer needs raw files, do not trim your real workspace into a public
zip. Build a minimal reproduction in a temporary directory, then run
`safety-check` there:

```sh
(
  tmpdir="$(mktemp -d)"
  tmp_home="$(mktemp -d)"
  cleanup() {
    if [ "${KEEP_BOUCLE_REPRO:-0}" != "1" ]; then
      rm -f "$tmpdir/.claude/settings.json"
      rmdir "$tmpdir/.claude/hooks" "$tmpdir/.claude" "$tmpdir" "$tmp_home" 2>/dev/null || {
        printf 'Temporary directories were not empty; inspect and remove manually:\n'
        printf '  %s\n  %s\n' "$tmp_home" "$tmpdir"
      }
    fi
  }
  trap cleanup EXIT

  mkdir -p "$tmpdir/.claude/hooks"
  printf '{"hooks":{}}\n' > "$tmpdir/.claude/settings.json"
  cd "$tmpdir"
  curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | PYTHONDONTWRITEBYTECODE=1 HOME="$tmp_home" bash -s -- --verify --summary-only
  if [ "${KEEP_BOUCLE_REPRO:-0}" = "1" ]; then
    printf 'Temporary HOME: %s\nTemporary project: %s\n' "$tmp_home" "$tmpdir"
  fi
)
```

Replace the sample `.claude/settings.json` with the smallest redacted settings
file that reproduces the issue. Keep only throwaway hook scripts and placeholder
paths in the temporary directory. The temporary `HOME` keeps your real
user-level Claude Code hooks out of the reproduction. The snippet removes the
known throwaway settings file and then removes the temporary directories only if
they are empty; set `KEEP_BOUCLE_REPRO=1` in the same shell before running it if
you need to inspect them afterward. If anything unexpected remains, the paths
are printed so you can inspect and remove them manually. If the problem does not
reproduce there, say that; it usually means the remaining signal is in local
paths, environment variables, shell startup files, or private hook code that
should not be posted.

## 6. Minimal public report template

```text
OS:
Shell:
Claude Code version:
Where hooks are installed:
Command/scope:
What changed recently:
Pre-update baseline:
Fresh Claude Code session from verified root:
MCP servers involved:
Next intended action:
Staged diff and destination reviewed separately: yes / no / not applicable

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
