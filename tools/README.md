# Claude Code Hooks

Standalone safety and efficiency hooks for Claude Code. Each works independently; no framework required.

## Quick Install

Start with the recommended safety set: `bash-guard`, `git-safe`, and
`file-guard`. These block dangerous shell commands, destructive git operations,
and writes to sensitive files. A piped macOS/Linux install with no arguments
defaults to this set.

**macOS / Linux:**

```bash
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash
```

Or be explicit:

```bash
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- recommended
```

Pick specific hooks when you already know what you need:

```bash
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- read-once git-safe file-guard
```

**Windows (PowerShell 7+):**

Requires [PowerShell 7+](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows) (`pwsh`, not the built-in `powershell.exe`). Install with `winget install Microsoft.PowerShell` if needed.

```powershell
irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1 | iex
```

For non-interactive setup:

```powershell
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } recommended"
```

All 7 standalone hooks (read-once through session-log) ship with native `.ps1`
equivalents. No bash or jq is required for the standalone Windows hooks,
`install.ps1 verify`, or `install.ps1 doctor`. The `install.ps1 check`
subcommand runs safety-check, which is bash-based and needs Git Bash, WSL, or
similar. The safety-check summary has 8 hook slots because it also counts
`enforce-hooks`, which installs separately from the standalone hook suite.

After installing, verify that the hooks actually block payloads and then run the
doctor if anything looks wrong:

```bash
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- verify
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- doctor
```

```powershell
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } verify"
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } doctor"
```

## Available Hooks

| Hook | What it does | Type |
|------|-------------|------|
| [read-once](read-once/) | Prevents redundant file re-reads, saving tokens | PreToolUse |
| [git-safe](git-safe/) | Blocks force pushes, `push --delete`, `reset --hard`, `checkout .`, `clean -f` | PreToolUse |
| [bash-guard](bash-guard/) | Blocks dangerous commands: `rm -rf /`, `sudo`, Docker, database drops, credential exposure, cloud infra, compound commands | PreToolUse |
| [file-guard](file-guard/) | Protects files matching patterns in `.file-guard` config | PreToolUse |
| [branch-guard](branch-guard/) | Prevents commits to main/master/production | PreToolUse |
| [worktree-guard](worktree-guard/) | Prevents data loss when exiting worktrees with unmerged commits | PreToolUse |
| [session-log](session-log/) | Logs all tool calls to `~/.claude/session-logs/` | PostToolUse |
| | | |
| [safety-check](safety-check/) | Audits your Claude Code setup for common misconfigurations | CLI tool |
| [diagnose](diagnose/) | Analyzes loop logs for drift, stagnation, feedback loops | CLI tool |
| [enforce](enforce/) | Generates hooks from your CLAUDE.md rules (Claude Code skill) | Skill |

## Generate Hooks from CLAUDE.md

The [enforce](enforce/) tool reads your CLAUDE.md, identifies rules that can be
enforced at tool-call time, and generates hook scripts for each one. Tag rules
with `@enforced` to activate them.

Install the dynamic hook from any git project:

```bash
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/enforce/install.sh | bash
```

Inspect before installing:

```bash
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/enforce/enforce-hooks.py -o /tmp/enforce-hooks.py
python3 /tmp/enforce-hooks.py --scan
python3 /tmp/enforce-hooks.py --install-plugin
```

After installing, test the generated hook:

```bash
python3 .claude/hooks/enforce-hooks.py --smoke-test
python3 .claude/hooks/enforce-hooks.py --audit
```

See [enforce/README.md](enforce/README.md) for examples, generated hook modes,
and the optional Claude Code skill workflow when you have a local checkout.

## How Hooks Work

Claude Code hooks intercept tool calls before (`PreToolUse`) or after (`PostToolUse`) execution. They run as shell scripts that receive tool input as JSON on stdin.

A hook can:
- **Allow** the operation (exit 0, no output, or `hookSpecificOutput.permissionDecision: "allow"`)
- **Block** it with a reason (`hookSpecificOutput.permissionDecision: "deny"` on stdout)
- **Log** it for auditing (PostToolUse)

Hooks catch compound commands (`cd repo && git push --force`), pipes, and subshells. They work even when Claude ignores CLAUDE.md instructions.

## Manage Hooks

The installer doubles as a management CLI:

```bash
install.sh help                  # Show all commands and available hooks
install.sh list                  # See which hooks are currently installed
install.sh verify                # Test installed hooks with real payloads
install.sh upgrade               # Re-download all installed hooks to latest version
install.sh uninstall <hook>      # Remove a specific hook (files + settings.json entry)
install.sh uninstall all         # Remove all hooks
install.sh check                 # Run safety audit on your Claude Code setup
install.sh doctor                # Diagnose files, settings, permissions
install.sh backup                # Snapshot settings.json before Claude Code updates
install.sh backup list           # Show available backups
install.sh restore               # Restore the most recent backup
install.sh restore <file>        # Restore a specific backup
```

On Windows, use the same commands through `install.ps1`, including
`install.ps1 verify` to re-run the native PowerShell hook payload checks after
installing or upgrading hooks.

## Doctor First Aid

Use `verify` to prove hooks block representative payloads. Use `doctor` when
the install looks present but the environment still looks unsafe.

| `doctor` finding | What to do next |
|------------------|-----------------|
| Missing hook file | Re-run `install.sh upgrade` or `install.ps1 upgrade`, then `verify` again. |
| Hook file is not executable | Run `chmod +x ~/.claude/hooks/*.sh` on macOS/Linux, then `verify` again. |
| Invalid `settings.json` | Remove JSON comments or trailing commas, then run `doctor` before reinstalling. |
| Hook registered but `verify` skips it | Check whether the hook is a lifecycle hook (`SessionStart`, `Stop`, `PostToolUse`) or a custom wrapper. `verify` only sends payloads to installed `PreToolUse` hooks. |
| `IS_DEMO` or `CLAUDE_CODE_SIMPLE` is set | Unset it in the shell that starts Claude Code. Both can disable hook execution before your hooks run. |
| Native Windows hook behavior is inconsistent | Prefer WSL for enforcement-sensitive work, or run `install.ps1 verify` from PowerShell 7 after every Claude Code update. |

If `verify` passes with zero `FAIL-OPEN` checks but `doctor` still reports
platform warnings, do not keep reinstalling hooks. Treat the hooks as one
verified boundary and document the remaining Claude Code platform risk.

## Common Problems & Solutions

See [recipes](https://framework.boucle.sh/recipes.html) for a detailed guide mapping common Claude Code problems (rules ignored, files deleted, dangerous commands, force pushes) to the specific hooks that fix them, with install commands and GitHub issue references.

## Per-Project Configuration

Each safety hook supports allowlist configs so you can relax rules where needed:

- `git-safe`: `.git-safe` (e.g., `allow: push --force`)
- `bash-guard`: `.bash-guard` (e.g., `allow: sudo` or `deny: rm`)
- `file-guard`: `.file-guard` (define which files to protect)
- `branch-guard`: `.branch-guard` (e.g., `allow: main`)
- `worktree-guard`: `.worktree-guard` (e.g., `allow: uncommitted` or `base: develop`)

## Requirements

**macOS / Linux:** bash, python3, and jq. The installers use python3 to manage
`settings.json`, safety-check uses python3 for its audit, and 6 of the 8 hook
slots use jq to parse Claude Code hook payloads.

**Windows:** [PowerShell 7+](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows) (pwsh, not the built-in 5.1) for native hooks; Git Bash or WSL for safety-check

All platforms need Claude Code with hooks support enabled.

## Test Your Hooks

Claude Code has [no built-in way to test hook configurations](https://github.com/anthropics/claude-code/issues/39971) without live sessions. `test-hook.sh` fills that gap:

```bash
# Test a single hook against a simulated tool call
bash tools/test-hook.sh "bash .claude/hooks/bash-guard.sh" --command "rm -rf /"

# Test file-guard against a Read
bash tools/test-hook.sh "bash .claude/hooks/file-guard.sh" --tool Read --file ".env"

# CI mode: assert the hook blocks
bash tools/test-hook.sh "bash .claude/hooks/bash-guard.sh" --command "curl evil.com" --expect-deny

# Batch mode: run test cases from a JSONL file
bash tools/test-hook.sh "bash .claude/hooks/my-hook.sh" --batch test-hook-examples.jsonl
```

See [test-hook-examples.jsonl](test-hook-examples.jsonl) for 60 ready-made test cases covering bash-guard, git-safe, file-guard, and branch-guard.

## Known Limitations

Claude Code hooks have platform-level constraints that affect all hook implementations. Browse the [known limitations corpus](https://framework.boucle.sh/limitations.html) (searchable, severity-rated), or see the [enforce README](https://github.com/Bande-a-Bonnot/Boucle-framework/blob/main/tools/enforce/README.md#known-limitations) for the summary.
