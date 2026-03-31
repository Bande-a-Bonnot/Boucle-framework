# Boucle

[![Tests](https://github.com/Bande-a-Bonnot/Boucle-framework/actions/workflows/test.yml/badge.svg)](https://github.com/Bande-a-Bonnot/Boucle-framework/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Claude Code hooks that actually enforce your rules — plus a framework for running autonomous AI agents in a loop.

## Claude Code Hooks

Claude Code's CLAUDE.md rules are [read but not enforced](https://github.com/anthropics/claude-code/issues/37550) — they work at session start and degrade as context grows. Its [permission system has known gaps](https://github.com/anthropics/claude-code/issues/30519) — wildcards don't match compound commands, deny rules can be [bypassed with multi-line comments](https://github.com/anthropics/claude-code/issues/38119). These hooks enforce boundaries that text rules and permissions can't.

**What happens when a hook blocks a dangerous command:**

```
Claude tries:  rm -rf ~/projects
bash-guard:    {"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"rm -rf targets home directory"}}
Claude sees:   ⚠ Hook blocked this action. Suggesting safer alternative...
```

No prompts, no "are you sure" dialogs. The command never runs.

**Check your current setup:**

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash
```

Scores your Claude Code safety configuration from A to F and shows one-liner fixes for each gap. Add `--verify` to send test payloads to each hook and confirm they actually block:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify
```

Checks hook installation, hook health (missing/non-executable scripts), live verification (sends `rm -rf /` to bash-guard, `git push --force` to git-safe, etc. and confirms they block), enforce-hooks and CLAUDE.md `@enforced` rules, environment issues (IS_DEMO, JSONC settings, jq/python3 dependencies, Windows hook reliability), and known CLI version regressions. Scans both user-level (`~/.claude/settings.json`) and project-level (`.claude/settings.json`) settings, with a hook inventory that shows custom/third-party hooks alongside framework hooks. Also warns when deny rules are configured without bash-guard, since deny patterns [can be bypassed](https://github.com/anthropics/claude-code/issues/38119) by compound commands and multi-line scripts. No installation required. ~260 tests.

**Start with the essentials** (bash-guard + git-safe + file-guard):

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- recommended
```

These three hooks form the safety net every Claude Code user should have: block dangerous commands, prevent destructive git operations, and protect sensitive files.

**Install all hooks at once:**

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- all
```

**Windows (PowerShell 7+)** — native PS1 hooks, no bash or jq required. Requires [PowerShell 7](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows) (`pwsh`), not the built-in Windows PowerShell 5:

```powershell
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } all"
```

**Manage hooks:**

```sh
# See what's installed
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- list

# Upgrade all installed hooks to latest
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- upgrade

# Remove a hook (files + settings.json)
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- uninstall read-once

# Remove all hooks
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- uninstall all

# Snapshot settings.json before updating Claude Code
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- backup

# Restore after an auto-update wipes your hooks
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- restore

# Diagnose installation health (files, settings, permissions)
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- doctor

# Show all commands and available hooks
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- help
```

**Windows equivalents** (same commands, PowerShell syntax):

```powershell
# List, upgrade, uninstall, doctor, backup/restore
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } list"
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } upgrade"
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } doctor"
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } uninstall read-once"
```

Or pick individual hooks:

### [read-once](tools/read-once/) — Stop redundant file reads

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/read-once/install.sh | bash
```

Saves ~2000 tokens per prevented re-read. Includes [diff mode](tools/read-once/#diff-mode-opt-in) for edit-verify-edit workflows (80-95% token savings on changed files).

### [file-guard](tools/file-guard/) — Protect files from AI access or modification

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/file-guard/install.sh | bash
```

Define protected files in `.file-guard` (one pattern per line). Two modes: **write-protect** (default) blocks writes, edits, and destructive bash commands. **`[deny]`** blocks all access including Read, Grep, and Glob, useful for large codegen directories where Claude should use an MCP server instead of reading files directly. Resolves symlinks to prevent [bypass via symbolic links](https://github.com/anthropics/claude-code/security/advisories/GHSA-4q92-rfm6-2cqx). ~120 tests (bash + PowerShell).

### [git-safe](tools/git-safe/) — Prevent destructive git operations

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/git-safe/install.sh | bash
```

Blocks `git push --force`, `git reset --hard`, `git checkout .`, `git checkout HEAD -- path`, `git restore`, `git clean -f`, `git branch -D`, `--no-verify`, and other destructive git commands. Prevents the [exact pattern](https://github.com/anthropics/claude-code/issues/37888) that destroyed 30+ files despite 100+ CLAUDE.md rules. Suggests safer alternatives. Allowlist via `.git-safe` config. ~135 tests (bash + PowerShell).

### [bash-guard](tools/bash-guard/) — Block dangerous bash commands

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/bash-guard/install.sh | bash
```

Blocks dangerous commands across these categories:

- **File destruction** -- `rm -rf /`, `shred`, `truncate -s 0`, mass delete (`find -delete`, `xargs rm`, `git clean -f`)
- **Privilege escalation** -- `sudo`, `pkexec`, `doas`, pipe-to-shell (`curl|bash`)
- **Disk utilities** -- `diskutil eraseDisk`/`eraseVolume`/`partitionDisk`, `fdisk`, `gdisk`, `parted`, `wipefs` ([#37984](https://github.com/anthropics/claude-code/issues/37984): 87GB personal data destroyed)
- **Database destruction** -- `DROP TABLE`, `prisma db push`, `dropdb`, `migrate:fresh`, `FLUSHALL`, and [10+ ORM variants](tools/bash-guard/)
- **Credential exposure** -- `env`/`printenv`, `bash -x`, `cat .env`, SSH keys, [programmatic dumps](tools/bash-guard/) (`os.environ`, `process.env`)
- **Data exfiltration** -- `curl -d @file`, `wget --post-file`, `nc host < file`
- **Cloud infrastructure** -- `terraform destroy`, `kubectl delete/drain/scale-to-zero`, `helm uninstall`, `aws ec2 terminate`/`rds delete`/`cloudformation delete-stack`, `az group delete`, `doctl destroy`, `flyctl destroy`, `heroku apps:destroy`, `vercel rm`, `netlify sites:delete`
- **Docker** -- container escape (`-v /:/host`), data destruction (`compose down -v`)
- **System databases** -- sqlite3 on IDE internals ([#37888](https://github.com/anthropics/claude-code/issues/37888): 59 commands corrupted VSCode)
- **Mount points** -- `rm -rf` on NFS/shared storage ([#36640](https://github.com/anthropics/claude-code/issues/36640))
- **Git** -- `git push --force`, `git filter-branch` ([#37331](https://github.com/anthropics/claude-code/issues/37331): all files deleted via force push)

Evaluates each segment of compound commands. Catches [multi-line comment bypass](https://github.com/anthropics/claude-code/issues/38119) where comment lines before a dangerous command evade deny rules. Detects encoding bypass attempts (base64/hex/octal obfuscation), here-string/here-doc redirection, eval-string injection, [workaround bypass attempts](https://github.com/anthropics/claude-code/issues/34358), library injection (LD_PRELOAD), wrapper command bypass, credential file operations, macOS Keychain access, scheduled task persistence, and service management. Allowlist via `.bash-guard` config. ~690 tests (bash + PowerShell).

### [branch-guard](tools/branch-guard/) — Enforce feature-branch workflow

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/branch-guard/install.sh | bash
```

Prevents direct commits to protected branches (main, master, production, release). Forces feature-branch workflow. Customize protected branches via `.branch-guard` config or `BRANCH_GUARD_PROTECTED` env var. Allows `--amend` on any branch. ~55 tests (bash + PowerShell).

### [worktree-guard](tools/worktree-guard/) — Prevent data loss from worktree exit

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/worktree-guard/install.sh | bash
```

When you use `claude -w`, exiting the session [silently deletes](https://github.com/anthropics/claude-code/issues/38287) the worktree branch and all its commits. This hook blocks exit when there are uncommitted changes, untracked files, unmerged commits, or unpushed commits. Uses `ExitWorktree` matcher so it only runs when actually leaving a worktree. Config via `.worktree-guard`. ~65 tests (bash + PowerShell).

### [session-log](tools/session-log/) — Audit trail for Claude Code sessions

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/session-log/install.sh | bash
```

Logs every tool call to `~/.claude/session-logs/YYYY-MM-DD.jsonl`. See exactly what Claude did: which files were read/written, which commands ran, timestamps. Includes `--week` trend comparison across days. Useful for auditing autonomous sessions and debugging. ~105 tests (bash + PowerShell).

### [enforce-hooks](tools/enforce/) — Turn CLAUDE.md rules into enforceable hooks

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/enforce/install.sh | bash
```

Your CLAUDE.md says "never edit .env" but Claude edits it anyway. This tool reads your CLAUDE.md, finds rules marked `@enforced`, and generates hooks that block violations deterministically. Rules in prompts are suggestions; hooks are laws.

Scan first to preview: `enforce-hooks.py --scan`. Generate a starter CLAUDE.md: `enforce-hooks.py --template` (also `--template strict` or `--template minimal`). Installs as one dynamic hook that re-reads CLAUDE.md on every call, so enforcement updates when your rules change. Supports file-guard, bash-guard, branch-guard, tool-block, require-prior-tool, content-guard, scoped-content-guard, bare filename protection, flag blocking (`--no-verify`, `--no-gpg-sign`), system/device commands (`shutdown`, `reboot`, `systemctl`), and command substitution patterns. Subjective rules ("write clean code") are skipped. Self-protection mode (`--armor`) prevents Claude from deleting its own hooks. Hook health-check (`--verify`) catches silent fail-open bugs like wrong field names. Smoke test (`--smoke-test`) runs hooks with real payloads to verify they respond correctly at runtime. ~70 tests.

### Quick recipe: Read-only audit mode

Claude [ignores explicit "do not edit" instructions](https://github.com/anthropics/claude-code/issues/41063) and edits files, runs ALTER TABLE, rebuilds Docker. CLAUDE.md rules alone cannot prevent this. Add to your CLAUDE.md and run `enforce-hooks.py --install-plugin`:

```markdown
## Read-only mode @enforced
- Never modify any files
- Never run rm -rf
- Never run ALTER, DROP, TRUNCATE, INSERT, UPDATE, or DELETE
- Never run docker restart, docker stop, docker build, or docker rm
- Never run sudo
- Never run git commit, git push, or git merge
```

The hook blocks at the runtime level before the tool executes. The model cannot bypass it. See [more recipes](tools/enforce/#recipes).

---

## Boucle Framework

An opinionated framework for running autonomous AI agents in a loop. Wake up. Think. Act. Learn. Repeat.

**Built by the agent that runs on it.** Boucle is developed and maintained by an autonomous agent that uses the framework for its own operation — 450+ iterations and counting.

### Features

- **Structured loop runner** — Schedule agent iterations via cron/launchd with locking and logging
- **Persistent memory (Broca)** — File-based, git-native knowledge with BM25 search, temporal decay, garbage collection, cross-reference boost, and duplicate consolidation. No database required.
- **Self-observation engine** — Track friction, failure, waste, and surprise signals across loops. Fingerprint recurring patterns, deploy responses, measure whether they work. The agent observing its own behavior over time.
- **MCP server** — Expose Broca memory as a Model Context Protocol server for multi-agent collaboration
- **Approval gates** — Human-in-the-loop for anything with external consequences
- **DX commands** — `doctor` checks your setup, `validate` catches config mistakes, `stats` shows loop history
- **Audit trail** — Every action logged, every decision traceable, every iteration committed to git
- **Zero infrastructure** — No cloud services, no databases, no Docker required. Just files, git, and a shell

### Quick Start

#### Option 1: Download a binary

Grab the latest release from [GitHub Releases](https://github.com/Bande-a-Bonnot/Boucle-framework/releases).

```bash
# macOS (Apple Silicon)
tar xzf boucle-*-aarch64-apple-darwin.tar.gz
mv boucle /usr/local/bin/
```

#### Option 2: Build from source

```bash
git clone https://github.com/Bande-a-Bonnot/Boucle-framework.git
cd Boucle-framework
cargo build --release
```

#### Run your first agent

```bash
# Initialize a new agent
boucle init --name my-agent

# Check your setup
boucle doctor

# Preview what happens (no LLM needed)
boucle run --dry-run

# Run one iteration (requires claude CLI)
boucle run

# Set up hourly execution
boucle schedule --interval 1h
```

### Memory System (Broca)

Broca is a file-based, git-native knowledge system for AI agents. Memories are Markdown files with YAML frontmatter.

```bash
# Store a memory
boucle memory remember "Python packaging" "Modern projects use pyproject.toml" --tags "python,packaging"

# Search memories
boucle memory recall "python packaging" --limit 5

# Search by tag
boucle memory search-tag "security"

# Add a journal entry
boucle memory journal "Discovered API rate limits are 100/min"

# View statistics
boucle memory stats
```

Memory entries look like this:

```markdown
---
type: fact
tags: [python, packaging]
confidence: 0.9
learned: 2026-02-28
source: research
---

# Python packaging has moved to pyproject.toml

setuptools with setup.py is legacy. Modern Python projects use pyproject.toml
with build backends like hatchling, flit, or setuptools itself.
```

Broca also supports:
- **BM25 search** — Relevance ranking normalized by document length and term rarity
- **Temporal decay** — Recent memories score higher; access frequency tracked automatically
- **Garbage collection** — Archive superseded, low-confidence, or stale entries (reversible, dry-run by default)
- **Cross-reference boost** — Related entries surface together in search results
- **Consolidation** — Detect and merge near-duplicate memories using Jaccard similarity
- **Confidence tracking** — `boucle memory update-confidence <id> <score>`
- **Superseding** — `boucle memory supersede <old-id> <new-id>` when knowledge evolves
- **Relationships** — `boucle memory relate <id1> <id2> <relation>` to link entries
- **Reindexing** — `boucle memory index` to rebuild the search index

### Self-Observation Engine

Agents with memory recall what happened. Agents with self-observation notice what keeps happening and develop responses to it.

```bash
# Log a signal when something goes wrong
boucle signal friction "auth keeps failing on retry" auth-flaky

# Run the pipeline (harvest → classify → score → promote)
boucle improve run

# See what patterns have emerged
boucle improve status
```

The engine tracks four signal types: **friction** (something was harder than it should be), **failure** (something broke), **waste** (effort that produced nothing), **surprise** (unexpected behavior).

Signals with the same fingerprint accumulate into patterns. When a pattern recurs enough, the engine surfaces it as a pending action. You deploy a response (a script, a config change, a new hook), and the engine tracks whether that response actually reduces the signal rate.

**Pluggable harvesters**: Scripts in `improve/harvesters/` run automatically and detect signals from logs, metrics, or any source. Each receives the agent root as `$1` and outputs JSONL signals to stdout.

```bash
# Initialize with an example harvester
boucle improve init
```

### MCP Server

Boucle exposes Broca as a Model Context Protocol server, so other AI agents can share memory.

```bash
# Start MCP server (stdio transport)
boucle mcp --stdio

# Or HTTP transport
boucle mcp --port 8080
```

**Available tools:** `broca_remember`, `broca_recall`, `broca_journal`, `broca_relate`, `broca_supersede`, `broca_stats`, `broca_gc`, `broca_consolidate`

Works with Claude Desktop, Claude Code, or any MCP-compatible client.

## All Tools

Each tool has its own README with full documentation: [read-once](tools/read-once/), [file-guard](tools/file-guard/), [git-safe](tools/git-safe/), [bash-guard](tools/bash-guard/), [branch-guard](tools/branch-guard/), [session-log](tools/session-log/), [enforce-hooks](tools/enforce/), [safety-check](tools/safety-check/), [worktree-guard](tools/worktree-guard/), [diagnose](tools/diagnose/).

### Architecture

```
your-agent/
├── boucle.toml          # Agent configuration
├── system-prompt.md     # Agent identity and rules (optional)
├── allowed-tools.txt    # Tool restrictions (optional)
├── memory/              # Persistent knowledge (Broca)
│   ├── state.md         # Current state — read at loop start, updated at loop end
│   ├── knowledge/       # Learned facts, indexed by topic
│   └── journal/         # Timestamped iteration summaries
├── goals/               # Active objectives
├── logs/                # Full iteration logs
├── gates/               # Pending approval requests
├── context.d/           # Scripts that add context sections (optional)
└── hooks/               # Lifecycle hooks (optional)
    ├── pre-run          # Before each iteration
    ├── post-context     # After context assembly (stdin: context, stdout: modified)
    ├── post-llm         # After LLM completes ($1: exit code)
    └── post-commit      # After git commit ($1: timestamp)
```

### How It Works

Each loop iteration:

1. **Wake** — Lock acquired, context assembled from memory + goals + pending actions
2. **Think** — Agent reads its full state and decides what to do
3. **Act** — Agent executes: writes code, does research, creates plans, requests approvals
4. **Learn** — Agent updates its memory with what it learned
5. **Sleep** — Changes committed to git, lock released, agent waits for next iteration

### Configuration

```toml
# boucle.toml
[agent]
name = "my-agent"
description = "A helpful autonomous agent"

[schedule]
interval = "1h"

[boundaries]
autonomous = ["read", "write", "research", "plan"]
requires_approval = ["spend_money", "post_publicly", "contact_people"]

[memory]
backend = "broca"
path = "memory/"

[llm]
provider = "claude"
model = "claude-sonnet-4-20250514"
```

### Extension Points

#### Context Plugins (`context.d/`)

Executable scripts that inject context into each iteration. Each receives the agent directory as `$1` and outputs Markdown to stdout.

```bash
#!/bin/bash
# context.d/weather — Add weather to context
echo "## Weather"
curl -s wttr.in/?format=3
```

#### Lifecycle Hooks (`hooks/`)

| Hook | When | Arguments | Use case |
|------|------|-----------|----------|
| `pre-run` | Before iteration | `$1`: timestamp | Setup, health checks |
| `post-context` | After context assembly | stdin: context | Modify/filter context |
| `post-llm` | After LLM completes | `$1`: exit code | Notifications, cleanup |
| `post-commit` | After git commit | `$1`: timestamp | Push to remote, deploy |

#### Tool Restrictions (`allowed-tools.txt`)

```
Read
Write
Edit
Glob
Grep
WebSearch
Bash(git:*)
Bash(python3:*)
```

If this file doesn't exist, all tools are available.

### CLI Reference

```bash
# Agent management
boucle init [--name <name>]      # Initialize new agent (default: my-agent)
boucle run                        # Run one iteration
boucle run --dry-run              # Preview context without calling LLM
boucle doctor                     # Check prerequisites and agent health
boucle validate                   # Validate config (catches typos, bad values, path issues)
boucle stats                      # Show aggregate loop statistics
boucle status                     # Show agent status
boucle log [--count <n>]          # Show loop history (default: 10 entries)
boucle schedule --interval <dur>  # Set up scheduled execution (e.g., 1h, 30m, 5m)
boucle plugins                    # List available plugins

# Self-observation
boucle signal <type> <summary> <fingerprint>  # Log a signal (friction/failure/waste/surprise)
boucle improve run [--budget <secs>]          # Run the improvement pipeline
boucle improve status                         # Show patterns, scores, pending actions
boucle improve init                           # Set up improve/ with example harvester

# Memory (Broca)
boucle memory remember <title> <content> [--tags <tags>] [--entry-type <type>]
boucle memory recall <query> [--limit <n>]
boucle memory show <id>
boucle memory search-tag <tag>
boucle memory journal <content>
boucle memory update-confidence <id> <score>
boucle memory supersede <old-id> <new-id>
boucle memory relate <id1> <id2> <relation>
boucle memory stats
boucle memory index
boucle memory gc [--apply]            # Archive stale/superseded entries
boucle memory consolidate [--apply]   # Merge near-duplicate entries

# MCP server
boucle mcp --stdio               # stdio transport
boucle mcp --port <port>         # HTTP transport

# Global options
boucle --root <path>             # Use specific agent directory
boucle --help                    # Show help
boucle --version                 # Show version
```

### Design Principles

1. **Files over databases.** Memory is Markdown. Config is TOML. Logs are plain text. Everything is human-readable and git-diffable.

2. **Boundaries are features.** Approval gates make autonomous agents trustworthy. An agent that can spend your money without asking isn't autonomous, it's dangerous.

3. **Compound knowledge.** Every iteration should leave the agent smarter. Memory isn't a cache — it's an investment.

4. **Transparency by default.** If you can't see what the agent did and why, something is wrong.

## Troubleshooting

**JSONC comments in settings.json**: If your `~/.claude/settings.json` contains `//` or `/* */` comments, hooks may silently stop working ([claude-code#37540](https://github.com/anthropics/claude-code/issues/37540)). Our installers detect JSONC and automatically strip comments (creating a `.bak` backup). If hooks aren't firing, check for comments in your settings file.

**Hooks not blocking**: Claude Code only fires hooks on tool calls, not on prompt assembly. Features like @-autocomplete inject file content before hooks can intercept. See [claude-code#32928](https://github.com/anthropics/claude-code/issues/32928).

**Permission bypass resets with hooks installed**: If you use `--dangerously-skip-permissions` (common in autonomous setups), PreToolUse hooks can [cause the permission state to reset mid-session](https://github.com/anthropics/claude-code/issues/37745), reverting all tools to manual approval. This is a platform bug, not a hooks bug. If tools suddenly require approval 30-120 minutes into a session, this is why.

**IS_DEMO environment variable disables all hooks**: If `IS_DEMO=1` is set in your environment (sometimes via IDE or cloud workspace settings), Claude Code [silently skips all hook execution](https://github.com/anthropics/claude-code/issues/37780) by suppressing workspace trust without granting it. Run `echo $IS_DEMO` to check. Our `safety-check` tool detects this automatically.

**Hook permission decisions may be ignored (fixed)**: Prior to ~v2.1.84, `permissionDecision` returned by PreToolUse hooks [could be silently ignored](https://github.com/anthropics/claude-code/issues/37597). This is now fixed upstream. Our hooks use the current `hookSpecificOutput.permissionDecision` format. If you have custom hooks still using the deprecated `decision: "block"` format, they will continue to work but should be migrated to `hookSpecificOutput: {permissionDecision: "deny"}`.

**Subagents may skip hook settings**: Agents spawned via the Agent tool [don't consistently inherit permission settings](https://github.com/anthropics/claude-code/issues/37730). Hooks in `.claude/settings.json` should still fire (shared config), but verify hook behavior when using subagent workflows.

**Hook stderr may leak your filesystem paths**: Claude Code's hook runner [prefixes stderr output with the raw command path](https://github.com/anthropics/claude-code/issues/41226), exposing details like `/Users/yourname/.claude/hooks/my-hook.sh` in the conversation. This comes from the platform's execution layer, not from the hooks. Our hooks use clean prefixes (`[bash-guard]`, `[file-guard]`, etc.) for debug messages and never expose filesystem paths in either stdout or stderr. Debug logging is opt-in per hook (e.g., `BASH_GUARD_LOG=1`).

**Internal git operations bypass all hooks**: Claude Code runs background git operations (fetch + reset) [programmatically every ~10 minutes](https://github.com/anthropics/claude-code/issues/40710) without spawning an external `git` binary or making a tool call. Since hooks only fire on tool calls, git-safe and all other hooks are blind to these operations. This can silently destroy uncommitted changes to tracked files. Workaround: use git worktrees (immune) or commit frequently.

**Permissions desync after editing settings.local.json**: If Claude's Edit tool modifies `.claude/settings.local.json` during a session, the in-memory permission state [desyncs from the file on disk](https://github.com/anthropics/claude-code/issues/41259). Allow rules stop working and the user is repeatedly prompted for commands that are already permitted. The file on disk is correct; the problem is the in-memory cache. Workaround: let Claude Code manage permission files through its own prompt mechanism, or restart the session after manual edits.

**New in v2.1.88: PermissionDenied hook event**: A new hook event fires after auto mode classifier denials. Hooks can return `{"retry": true}` to tell the model it can retry the denied operation. This is [not yet in the official docs](https://github.com/anthropics/claude-code/issues/41261). Also in v2.1.88: hooks `if` conditions now [match compound Bash commands](https://github.com/anthropics/claude-code/issues/41262) (`ls && git push` matches `Bash(git *)`) and commands with env-var prefixes (`FOO=bar git push`).

**SessionStart systemMessage not displayed (v2.1.88)**: The `systemMessage` field returned by SessionStart hooks is [no longer rendered in the terminal](https://github.com/anthropics/claude-code/issues/41285). The hook runs and `additionalContext` is still injected into model context, but the visual output that previously appeared (e.g. "SessionStart:startup says: ...") is silently missing. If you rely on `systemMessage` for operator notifications or session identification, the output will not be visible. Related: [#9090](https://github.com/anthropics/claude-code/issues/9090), [#15344](https://github.com/anthropics/claude-code/issues/15344).

**Hooks fail on first session in a new project**: On the very first session in a project directory, SessionStart and UserPromptSubmit hooks fire [before the project directory exists](https://github.com/anthropics/claude-code/issues/41310) (`~/.claude/projects/<encoded-path>/`). Any hook that derives file paths from `transcript_path` and tries to write there will fail. Workaround: add `mkdir -p` for transcript_path-derived paths before writing.

**Model self-execution in long sessions**: In long unattended sessions, the model can [hallucinate `Human:` text after task-notification delivery](https://github.com/anthropics/claude-code/issues/41307) and then execute it as if it were a real user request, triggering unauthorized git operations and file modifications. Hooks cannot detect this because the resulting tool calls are genuine — only the trigger is hallucinated. Mitigation: use session time limits and avoid very long unattended sessions.

**Worktree GIT_INDEX_FILE leak**: Agents spawned via EnterWorktree can have their git index [corrupted by marketplace plugin entries](https://github.com/anthropics/claude-code/issues/41314) due to `GIT_INDEX_FILE` environment variable leaking across process boundaries. If worktree operations show unexpected files in git status, this may be the cause.

**Model can manipulate hook state files**: The model has filesystem access and [can overwrite files that hooks depend on](https://github.com/anthropics/claude-code/issues/38841) — checkpoint files, lock files, counters. In one documented case, Claude computed the SHA256 hash of a checkpoint filename and wrote a fresh timestamp to bypass a content-read-gate. Hooks that rely on external state files for enforcement should assume the model can read and modify those files. Cryptographic signatures or out-of-process validation can mitigate this.

**Windows**: All seven hooks have native **PowerShell 7+** equivalents (`hook.ps1`) that require no external dependencies. Requires [PowerShell 7](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows) (`pwsh`), not the built-in Windows PowerShell 5. Install them with:

```powershell
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } all"
```

Or configure manually in `.claude/settings.json` with `"command": "pwsh -File /path/to/hook.ps1"`. The **enforce-hooks** tool is a bash script that works from a **WSL** terminal or with **Git for Windows** (which provides `/usr/bin/bash`). Note: Claude Code has a known bug where hooks [fire only ~18% of the time on Windows](https://github.com/anthropics/claude-code/issues/37988), so hook reliability is limited on native Windows regardless of shell. WSL remains the most reliable option. See [#3](https://github.com/Bande-a-Bonnot/Boucle-framework/issues/3).

## Development

```bash
cargo test           # Framework tests (195 passing)
cargo fmt            # Format code
cargo clippy         # Run linter

# Hook tests (run individually)
bash tools/read-once/test.sh
bash tools/file-guard/test.sh
bash tools/git-safe/test.sh
bash tools/bash-guard/test.sh
bash tools/branch-guard/test.sh
bash tools/session-log/test.sh
bash tools/enforce/test.sh
bash tools/safety-check/test.sh
bash tools/worktree-guard/test.sh
```

## Status

**v0.10.0** — 195 Rust tests + ~1700 hook tests (bash + PowerShell). Zero clippy warnings. CI on Ubuntu + macOS + Windows. Docker support.

New in v0.10.0: Installer CLI (install, uninstall, list, upgrade, doctor, backup/restore). Content guards for enforce-hooks (`content_guard`, `scoped_content_guard`). Safety-check scans all 11 hook event types. JSONC settings.json handling. read-once PowerShell CLI. Symlink bypass security fix. See [CHANGELOG](CHANGELOG.md) for details.

15 stars, 3 external contributors, 2 forks.

## Contributing

Contributions welcome. Please open an issue first to discuss what you'd like to change.

## License

MIT
