# Safety summary triage

Use this after running `safety-check --verify`. The copy/paste summary is a
repair list, not a certificate. Start with the first item that proves hooks
could be skipped or fail open, then rerun verification from the same project
root.

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify
```

On native Windows, use the PowerShell verifier when you installed native
PowerShell hooks:

```powershell
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } verify"
```

## First pass

Read the `--- Safety Summary (copy/paste) ---` block from top to bottom:

1. Fix anything that can disable hooks for the whole session.
2. Fix invalid settings or missing hook files.
3. Fix `FAIL-OPEN` payload checks.
4. Treat skipped `PreToolUse` checks as unverified enforcement.
5. Document platform warnings after the hook boundary passes verification.

Do not trust a good letter grade by itself. A setup with Grade A and
`Verify: not run` has not proven that its hooks block dangerous tool calls.

## What to fix first

| Summary evidence | Priority | Why it matters | First fix |
|------------------|----------|----------------|-----------|
| `Issue: IS_DEMO is set` | Critical | Demo mode can prevent normal hook behavior. | `unset IS_DEMO`, restart the shell, rerun `--verify`. |
| `Issue: CLAUDE_CODE_SIMPLE is set` | Critical | Simple mode disables hooks and related features. | `unset CLAUDE_CODE_SIMPLE`, restart the shell, rerun `--verify`. |
| `Issue: invalid settings JSON` | Critical | Claude Code may ignore or misread hook settings. | Validate the named settings file with `python3 -m json.tool` and remove comments or trailing commas. |
| `no hooks found` | Critical | There is no hook layer to enforce the boundary. | Install the recommended hooks, then rerun verification. |
| `no payload checks ran` | Critical | Hooks may exist, but none were tested with representative `PreToolUse` payloads. | Replace dynamic hook snippets with direct script paths where possible. |
| `FAIL-OPEN` | High | A configured hook did not block its representative dangerous payload. | Inspect or reinstall that hook before trusting the session. |
| `skipped PreToolUse` | High | Safety-check could not prove that hook blocks anything. | Point the hook command at a script path that can be executed directly. |
| `missing` or `not executable` hook file | High | Claude Code can call a hook command that no longer exists or cannot run. | Run `install.sh doctor`, then repair or reinstall the hook. |
| Ancestor project settings warning | Medium | Starting Claude Code from a subdirectory can miss project hooks. | Rerun from the directory that owns `.claude/settings.json`. |
| Windows hook warning | Medium | Native Windows hook behavior varies by Claude Code version and shell. | Prefer WSL or verify with the native PowerShell path. |

## Repair commands

Run the common repair sequence before reinstalling repeatedly:

```sh
unset IS_DEMO CLAUDE_CODE_SIMPLE
command -v python3 >/dev/null || { echo "Install python3 before validating settings.json"; exit 1; }
test ! -f ~/.claude/settings.json || python3 -m json.tool ~/.claude/settings.json >/dev/null
test ! -f .claude/settings.json || python3 -m json.tool .claude/settings.json >/dev/null
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- doctor
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify
```

On native Windows:

```powershell
Remove-Item Env:IS_DEMO -ErrorAction SilentlyContinue
Remove-Item Env:CLAUDE_CODE_SIMPLE -ErrorAction SilentlyContinue
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } doctor"
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } verify"
```

If `doctor` reports that settings were removed or overwritten after a Claude
Code update, use the [update checklist](UPDATE_CHECKLIST.md) before restoring
backups.

## When verification passes

A useful baseline looks like this:

```text
Verify: 0 FAIL-OPEN | 8 payload checks | 0 skipped
Boundary: hooks passed representative checks; document residual platform warnings.
```

At that point, keep the verified boundary clear:

- No hook bypass flags in the shell that starts Claude Code.
- Valid user and project `settings.json`.
- Healthy hook files.
- Zero `FAIL-OPEN` payload checks.
- No skipped `PreToolUse` checks for hooks that enforce your boundary.

If the grade is still C after this, do not chase the letter grade by
reinstalling. The remaining issues are usually Claude Code platform limits or
environment warnings. Record them as residual risk and rerun verification after
Claude Code updates, shell profile changes, hook edits, and directory changes.

## Asking for help

Share only the copy/paste summary plus the minimum context from
[safe support evidence](SUPPORT_EVIDENCE.md). Do not share raw settings files,
hook source, shell history, session logs, screenshots with paths, `.env`
contents, tokens, SSH keys, OAuth files, private URLs, or proprietary
`CLAUDE.md` rules.
