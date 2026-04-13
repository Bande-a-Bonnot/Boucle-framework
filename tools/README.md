# Claude Code Hooks

Standalone safety and efficiency hooks for Claude Code. Each works independently; no framework required.

## Quick Install

**macOS / Linux:**

```bash
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash
```

Or pick specific hooks:

```bash
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- read-once git-safe file-guard
```

**Windows (PowerShell 7+):**

Requires [PowerShell 7+](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows) (`pwsh`, not the built-in `powershell.exe`). Install with `winget install Microsoft.PowerShell` if needed.

```powershell
irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1 | iex
```

All 7 hooks (read-once through session-log) ship with native `.ps1` equivalents. No bash or jq required on Windows.

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

The [enforce](enforce/) skill reads your CLAUDE.md, identifies rules that can be enforced at tool-call time, and generates hook scripts for each one. Tag rules with `@enforced` to activate them (run `--scan` to preview what's enforceable).

```
# Copy the skill to your project
mkdir -p .claude/skills/enforce-hooks
cp tools/enforce/SKILL.md .claude/skills/enforce-hooks/

# Then ask Claude: "Enforce my CLAUDE.md rules"
```

See [enforce/README.md](enforce/README.md) for details and examples.

## How Hooks Work

Claude Code hooks intercept tool calls before (`PreToolUse`) or after (`PostToolUse`) execution. They run as shell scripts that receive tool input as JSON on stdin.

A hook can:
- **Allow** the operation (exit 0, no output or `{"decision":"allow"}`)
- **Block** it with a reason (`{"decision":"block","reason":"..."}` on stdout)
- **Log** it for auditing (PostToolUse)

Hooks catch compound commands (`cd repo && git push --force`), pipes, and subshells. They work even when Claude ignores CLAUDE.md instructions.

## Manage Hooks

The installer doubles as a management CLI:

```bash
install.sh help                  # Show all commands and available hooks
install.sh list                  # See which hooks are currently installed
install.sh upgrade               # Re-download all installed hooks to latest version
install.sh uninstall <hook>      # Remove a specific hook (files + settings.json entry)
install.sh uninstall all         # Remove all hooks
```

Each hook also has a `verify` subcommand in its own installer that checks the installation is working correctly.

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

**macOS / Linux:** bash, jq

**Windows:** [PowerShell 7+](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows) (pwsh, not the built-in 5.1)

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

Claude Code hooks have platform-level constraints that affect all hook implementations. Browse all [932 known limitations](https://framework.boucle.sh/limitations.html) (searchable, severity-rated), or see the [enforce README](https://github.com/Bande-a-Bonnot/Boucle-framework/blob/main/tools/enforce/README.md#known-limitations) for the summary.
