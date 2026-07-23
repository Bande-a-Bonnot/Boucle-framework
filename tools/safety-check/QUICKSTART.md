# Safety-check quickstart

Use this when you want to know whether a Claude Code setup can actually block
dangerous tool calls. The goal is not a perfect grade. The goal is a verified
trust boundary before you let Claude edit a real project.

## 1. Run the audit

Run it from the project root you use to start Claude Code, especially when the
repository has `.claude/settings.json`. Running from a subdirectory can miss
project-level hooks that live at the repo root.

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
from the audit output. The [safe support evidence guide](SUPPORT_EVIDENCE.md)
has a short public-report template and a list of fields to redact.

## 2. Install the baseline hooks

If this is a personal workstation, start with the recommended hook set:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- recommended
```

If you want the full hook suite:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- all
```

Both `recommended` and `all` install user-level hooks under
`~/.claude/<hook-name>/` and register them in `~/.claude/settings.json`. They do
not create repo-local `.claude/settings.json` policy for the current project.
The project root still matters for the audit because safety-check also inspects
checked-in project settings when they already exist.

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
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- upgrade
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- check --verify --strict
```

On native Windows, use the native PowerShell hook verifier:

```powershell
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } upgrade"
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } verify"
```

For native `install.ps1 verify`, there is no safety summary block. Share only
the final verifier count plus any `WARN` or `SKIP` lines.

If verification fails after the update, run `doctor` before reinstalling. If
hooks disappeared or `doctor` reports that `settings.json` was wiped, restore
the most recent backup, then run the strict audit again:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- doctor
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- restore
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- check --verify --strict
```

On native Windows:

```powershell
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } doctor"
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } restore"
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } verify"
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

## 7. Share safe support evidence

Run verification before asking for help:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify
```

Copy the block that starts with:

```text
--- Safety Summary (copy/paste) ---
```

That block includes the grade, installed hook inventory, `Issue:` lines, verify
counts, and the current trust boundary. It does not include raw settings files
or hook source.

On native Windows with `install.ps1 verify`, copy only the final verifier count
plus any `WARN` or `SKIP` lines. The PowerShell verifier does not print the
`--- Safety Summary (copy/paste) ---` block.

Do not share raw `settings.json`, hook scripts, shell history, session logs,
private paths, tokens, `.env` contents, or proprietary `CLAUDE.md` rules in
public threads. Do not paste raw hook stderr from a live Claude Code session,
because the platform can prefix it with the hook command path. Use the
[safe support evidence guide](SUPPORT_EVIDENCE.md) when you need a copy/paste
report format.
