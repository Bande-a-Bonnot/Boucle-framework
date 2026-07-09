# Safety-check quickstart

Use this when you want to know whether a Claude Code setup can actually block
dangerous tool calls. The goal is not a perfect grade. The goal is a verified
trust boundary before you let Claude edit a real project.

## 1. Run the audit

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

Do not paste private settings or full hook output into a public issue. The final
copy/paste summary is designed for support triage because it avoids dumping the
whole settings file.

## 2. Install the baseline hooks

If this is a personal workstation, start with the recommended hook set:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- recommended
```

If you want the full hook suite:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- all
```

On Windows, use PowerShell 7 or WSL. Native Windows hook behavior can vary by
Claude Code version, so verify after installing:

```powershell
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } recommended"
```

## 3. Verify the hooks fire

The basic audit can confirm that hooks are registered. Verification mode sends
representative payloads to installed `PreToolUse` hooks and checks whether they
block:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify
```

For CI or a scripted workstation check, fail the command when verification is
inconclusive:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify --strict
```

Trust the hook layer only when the summary says there are zero `FAIL-OPEN`
results and the hook files are healthy. If no payload checks ran, you have not
verified enforcement yet.

For a usable result, look at the copy/paste summary near the end. A verified
baseline looks like this:

```text
Verify: 0 FAIL-OPEN | 8 payload checks | 0 skipped
Boundary: hooks passed representative checks; document residual platform warnings.
```

If the summary says `Verify: not run`, `no hooks found`, or `no hook payload
checks ran`, treat the hook layer as unverified even when the grade looks high.

## 4. Fix the common blockers

Run these checks before reinstalling hooks repeatedly:

```sh
unset IS_DEMO CLAUDE_CODE_SIMPLE
test ! -f ~/.claude/settings.json || python3 -m json.tool ~/.claude/settings.json >/dev/null
test ! -f .claude/settings.json || python3 -m json.tool .claude/settings.json >/dev/null
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- doctor
```

If JSON validation fails, remove comments or trailing commas from the reported
settings file. If `doctor` reports missing or non-executable hook files, repair
those before trusting `--verify`.

## 5. Recheck after risky changes

Run `--verify` again after:

- Updating Claude Code.
- Editing `~/.claude/settings.json` or `.claude/settings.json`.
- Installing, removing, or moving hook scripts.
- Switching between macOS, Linux, WSL, Git Bash, and PowerShell.
- Starting a long-running autonomous or semi-autonomous session.

If verification passes but the grade is still C, treat the remaining warnings as
platform risk rather than a hook install failure. Document the warnings and keep
the verified boundary: no bypass flags, valid JSON, healthy hook files, and zero
`FAIL-OPEN` payload checks.
