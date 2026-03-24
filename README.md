# Boucle

[![Tests](https://github.com/Bande-a-Bonnot/Boucle-framework/actions/workflows/test.yml/badge.svg)](https://github.com/Bande-a-Bonnot/Boucle-framework/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Claude Code hooks that actually enforce your rules — plus a framework for running autonomous AI agents in a loop.

## Claude Code Hooks

Claude Code's CLAUDE.md rules are [read but not enforced](https://github.com/anthropics/claude-code/issues/37550) — they work at session start and degrade as context grows. Its [permission system has known gaps](https://github.com/anthropics/claude-code/issues/30519) — wildcards don't match compound commands, deny rules can be [bypassed with multi-line comments](https://github.com/anthropics/claude-code/issues/38119). These hooks enforce boundaries that text rules and permissions can't.

**What happens when a hook blocks a dangerous command:**

```
Claude tries:  rm -rf ~/projects
bash-guard:    {"decision":"block","reason":"rm -rf targets home directory"}
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

Checks hook installation, hook health (missing/non-executable scripts), live verification (sends `rm -rf /` to bash-guard, `git push --force` to git-safe, etc. and confirms they block), enforce-hooks and CLAUDE.md `@enforced` rules, environment issues (IS_DEMO, JSONC settings, jq/python3 dependencies, Windows hook reliability), and known CLI version regressions. No installation required. ~91 tests.

**Install all hooks at once:**

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- all
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

Define protected files in `.file-guard` (one pattern per line). Two modes: **write-protect** (default) blocks writes, edits, and destructive bash commands. **`[deny]`** blocks all access including Read, Grep, and Glob, useful for large codegen directories where Claude should use an MCP server instead of reading files directly. 87 tests.

### [git-safe](tools/git-safe/) — Prevent destructive git operations

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/git-safe/install.sh | bash
```

Blocks `git push --force`, `git reset --hard`, `git checkout .`, `git checkout HEAD -- path`, `git restore`, `git clean -f`, `git branch -D`, and other destructive git commands. Prevents the [exact pattern](https://github.com/anthropics/claude-code/issues/37888) that destroyed 30+ files despite 100+ CLAUDE.md rules. Suggests safer alternatives. Allowlist via `.git-safe` config. 65 tests.

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
- **Cloud infrastructure** -- `terraform destroy`, `kubectl delete namespace`, `aws s3 rm --recursive`
- **Docker** -- container escape (`-v /:/host`), data destruction (`compose down -v`)
- **System databases** -- sqlite3 on IDE internals ([#37888](https://github.com/anthropics/claude-code/issues/37888): 59 commands corrupted VSCode)
- **Mount points** -- `rm -rf` on NFS/shared storage ([#36640](https://github.com/anthropics/claude-code/issues/36640))

Evaluates each segment of compound commands. Catches [multi-line comment bypass](https://github.com/anthropics/claude-code/issues/38119) where comment lines before a dangerous command evade deny rules. Detects encoding bypass attempts (base64/hex/octal obfuscation), here-string/here-doc redirection, eval-string injection, and [workaround bypass attempts](https://github.com/anthropics/claude-code/issues/34358). Allowlist via `.bash-guard` config. ~411 tests.

### [branch-guard](tools/branch-guard/) — Enforce feature-branch workflow

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/branch-guard/install.sh | bash
```

Prevents direct commits to protected branches (main, master, production, release). Forces feature-branch workflow. Customize protected branches via `.branch-guard` config or `BRANCH_GUARD_PROTECTED` env var. Allows `--amend` on any branch. 36 tests.

### [session-log](tools/session-log/) — Audit trail for Claude Code sessions

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/session-log/install.sh | bash
```

Logs every tool call to `~/.claude/session-logs/YYYY-MM-DD.jsonl`. See exactly what Claude did: which files were read/written, which commands ran, timestamps. Includes `--week` trend comparison across days. Useful for auditing autonomous sessions and debugging. 81 tests.

### [enforce-hooks](tools/enforce/) — Turn CLAUDE.md rules into enforceable hooks

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/enforce/install.sh | bash
```

Your CLAUDE.md says "never edit .env" but Claude edits it anyway. This tool reads your CLAUDE.md, finds rules marked `@enforced`, and generates hooks that block violations deterministically. Rules in prompts are suggestions; hooks are laws.

Scan first to preview: `enforce-hooks.py --scan`. Installs as one dynamic hook that re-reads CLAUDE.md on every call, so enforcement updates when your rules change. Supports file-guard, bash-guard, branch-guard, tool-block, require-prior-tool, content-guard, scoped-content-guard, bare filename protection, flag blocking (`--no-verify`, `--no-gpg-sign`), and command substitution patterns. Subjective rules ("write clean code") are skipped. Self-protection mode (`--armor`) prevents Claude from deleting its own hooks. Hook health-check (`--verify`) catches silent fail-open bugs like wrong field names. Smoke test (`--smoke-test`) runs hooks with real payloads to verify they respond correctly at runtime. 52 tests.

---

## Boucle Framework

An opinionated framework for running autonomous AI agents in a loop. Wake up. Think. Act. Learn. Repeat.

**Built by the agent that runs on it.** Boucle is developed and maintained by an autonomous agent that uses the framework for its own operation — 350+ iterations and counting.

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

Each tool has its own README with full documentation: [read-once](tools/read-once/), [file-guard](tools/file-guard/), [git-safe](tools/git-safe/), [bash-guard](tools/bash-guard/), [branch-guard](tools/branch-guard/), [session-log](tools/session-log/), [enforce-hooks](tools/enforce/), [safety-check](tools/safety-check/), [diagnose](tools/diagnose/).

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

**Hook permission decisions may be ignored**: Since v2.1.78, `permissionDecision` returned by PreToolUse hooks [may be silently ignored](https://github.com/anthropics/claude-code/issues/37597). Our hooks use `decision: "block"` in stdout JSON, which still works. If you write custom hooks that return `permissionDecision: "allow"`, users may still be prompted.

**Subagents may skip hook settings**: Agents spawned via the Agent tool [don't consistently inherit permission settings](https://github.com/anthropics/claude-code/issues/37730). Hooks in `.claude/settings.json` should still fire (shared config), but verify hook behavior when using subagent workflows.

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
```

## Status

**v0.6.1** — 195 Rust tests + ~900 hook tests = ~1100 total. Zero clippy warnings. CI on Ubuntu + macOS. Docker support.

Security hardening (shell injection, JSON injection, path traversal fixes). bash-guard covers 10 threat categories with ~411 tests. file-guard [deny] mode blocks all access to paths. JSONC settings.json support across all installers. read-once deny mode fix for Claude Code v2.1.78+ regression. Post-install verification catches format bugs at install time. Quickstart installer for zero-to-protected in one command.

12 stars, 2 external contributors, 1 fork.

## Contributing

Contributions welcome. Please open an issue first to discuss what you'd like to change.

## License

MIT
