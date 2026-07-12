# Claude Code update checklist

Use this when Claude Code changes version, updates itself, or starts behaving
differently after an IDE or plugin update. The goal is to prove that hooks still
fire before trusting a session with real work.

## Before updating

Snapshot the user-level settings file:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- backup
```

If this repository has project-local settings, keep a project backup too:

```sh
test -f .claude/settings.json && cp .claude/settings.json .claude/settings.json.bak
```

On native Windows with PowerShell 7:

```powershell
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } backup"
if (Test-Path .claude/settings.json) { Copy-Item .claude/settings.json .claude/settings.json.bak }
```

## After updating

Run these from the project root:

```sh
unset IS_DEMO CLAUDE_CODE_SIMPLE
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- upgrade
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- doctor
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify --strict
```

On native Windows:

```powershell
Remove-Item Env:IS_DEMO -ErrorAction SilentlyContinue
Remove-Item Env:CLAUDE_CODE_SIMPLE -ErrorAction SilentlyContinue
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } upgrade"
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } doctor"
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } verify"
```

Trust the hook layer only if verification reports zero `FAIL-OPEN` payload
checks, hook files are healthy, and the summary does not say `Verify: not run`,
`no hooks found`, or `no payload checks ran`.

## If verification fails

Run `doctor` first. Do not reinstall repeatedly until you know which boundary
failed.

Common fixes:

- If `settings.json` is invalid, remove comments or trailing commas from the
  reported file.
- If hook files are missing or not executable, run `upgrade`, then `doctor`
  again.
- If hooks disappeared after the update, restore the settings backup, then
  verify again.
- If `IS_DEMO` or `CLAUDE_CODE_SIMPLE` is set, unset it and start a fresh Claude
  Code session.
- If native Windows hook firing is inconsistent, verify in WSL before relying on
  hooks for destructive or autonomous work.

Restore the user-level settings backup:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- restore
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify
```

On native Windows:

```powershell
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } restore"
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } verify"
```

If the project backup is needed, restore it manually:

```sh
cp .claude/settings.json.bak .claude/settings.json
```

## Safe support evidence

When asking for help, share only the block that starts with:

```text
--- Safety Summary (copy/paste) ---
```

Do not share raw `settings.json`, hook scripts, shell history, session logs,
private paths, tokens, `.env` contents, or proprietary `CLAUDE.md` rules in
public threads. The [safe support evidence guide](SUPPORT_EVIDENCE.md) gives a
short public-report template and explains the common summary lines.
