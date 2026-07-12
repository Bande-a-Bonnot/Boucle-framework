# Safe support evidence

Use this when a safety-check result looks wrong and you need help in a public
issue, chat thread, or support channel. The goal is to share enough evidence to
debug the hook boundary without leaking private settings, paths, prompts, or
secrets.

## 1. Run verification

Run the checker from the project where Claude Code will work:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify
```

On native Windows, use the PowerShell installer verification path:

```powershell
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } verify"
```

If the command hangs, rerun with the default timeout. Do not raise
`HOOK_VERIFY_TIMEOUT_SECONDS` for a public support report unless you know a
local hook is intentionally slow.

## 2. Copy only the summary block

Near the end of the output, copy the block that starts with:

```text
--- Safety Summary (copy/paste) ---
```

That block is designed for public triage. It includes the grade, hook inventory,
`Issue:` lines, verification counts, and the current trust boundary.

It should not include raw `settings.json`, hook script contents, shell history,
session logs, `.env` values, tokens, private file paths, or proprietary
`CLAUDE.md` rules.

## 3. Add the minimum context

Add these short details above the summary block:

```text
OS: macOS / Linux / WSL / native Windows
Shell: bash / zsh / PowerShell 7 / Git Bash
Claude Code version: output of claude --version, if it returns quickly
Where hooks are installed: user settings / project settings / both / not sure
What changed recently: fresh install / Claude Code update / settings edit / moved hook files
```

If `claude --version` hangs, write `Claude Code version: version probe hangs`.
Do not paste a full terminal transcript.

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
| `FAIL-OPEN` | A configured hook did not block a representative dangerous payload. |

If the grade is still C after `Verify: 0 FAIL-OPEN`, do not keep reinstalling
hooks. The local hook boundary may be working while platform warnings remain as
residual risk.

## 5. What not to share

Do not post:

- Full `~/.claude/settings.json` or `.claude/settings.json` files.
- Hook source from private repositories.
- Session logs, shell history, prompts, transcripts, or screenshots with paths.
- Tokens, API keys, `.env` contents, OAuth files, SSH keys, or private URLs.
- Proprietary `CLAUDE.md` rules unless you have reviewed and redacted them.

If a maintainer needs raw files, share a minimal reproduction in a temporary
directory instead of your real workspace.

## 6. Minimal public report template

```text
OS:
Shell:
Claude Code version:
Where hooks are installed:
What changed recently:

--- Safety Summary (copy/paste) ---
...
```

For a full repair path before asking for help, start with the
[safety-check quickstart](QUICKSTART.md). For failures after Claude Code
updates, use the [update checklist](UPDATE_CHECKLIST.md).
