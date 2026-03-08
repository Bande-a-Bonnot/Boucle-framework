# Claude Code Hooks

Standalone safety and efficiency hooks for Claude Code. Each works independently; no framework required.

## Quick Install

Install all hooks:

```bash
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash
```

Or pick specific hooks:

```bash
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- read-once git-safe file-guard
```

## Available Hooks

| Hook | What it does | Type |
|------|-------------|------|
| [read-once](read-once/) | Prevents redundant file re-reads, saving tokens | PreToolUse |
| [git-safe](git-safe/) | Blocks force pushes, `reset --hard`, `checkout .`, `clean -f` | PreToolUse |
| [bash-guard](bash-guard/) | Blocks `rm -rf /`, `sudo`, `curl\|bash`, system directory writes | PreToolUse |
| [file-guard](file-guard/) | Protects files matching patterns in `.file-guard` config | PreToolUse |
| [branch-guard](branch-guard/) | Prevents commits to main/master/production | PreToolUse |
| [session-log](session-log/) | Logs all tool calls to `~/.claude/session-logs/` | PostToolUse |
| [safety-check](safety-check/) | Audits your Claude Code setup for common misconfigurations | CLI tool |
| [diagnose](diagnose/) | Analyzes loop logs for drift, stagnation, feedback loops | CLI tool |

## How Hooks Work

Claude Code hooks intercept tool calls before (`PreToolUse`) or after (`PostToolUse`) execution. They run as shell scripts that receive tool input as JSON on stdin.

A hook can:
- **Allow** the operation (exit 0, no output)
- **Block** it with a reason (exit 2, reason on stdout)
- **Log** it for auditing (PostToolUse)

Hooks catch compound commands (`cd repo && git push --force`), pipes, and subshells. They work even when Claude ignores CLAUDE.md instructions.

## Per-Project Configuration

Each safety hook supports allowlist configs so you can relax rules where needed:

- `git-safe`: `.git-safe-allow` (e.g., allow force push in a specific repo)
- `bash-guard`: `.bash-guard-allow`
- `file-guard`: `.file-guard` (define which files to protect)
- `branch-guard`: `.branch-guard-allow`

## Requirements

- Claude Code with hooks support
- bash, jq
- No other dependencies
