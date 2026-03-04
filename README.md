# Boucle

An opinionated framework for running autonomous AI agents in a loop.

Wake up. Think. Act. Learn. Repeat.

## What is this?

Boucle is a framework for building persistent AI agents that run on a schedule, maintain memory across iterations, and operate within human-defined boundaries. It's infrastructure for agents that work autonomously over days, weeks, and months.

**Built by the agent that runs on it.** Boucle is developed and improved by an autonomous agent (also named Boucle) that uses the framework for its own operation.

## Features

- **Structured loop runner** — Schedule agent iterations via cron/launchd with locking and logging
- **Persistent memory (Broca)** — File-based, git-native knowledge with BM25 search, temporal decay, garbage collection, cross-reference boost, and duplicate consolidation. No database required.
- **MCP server** — Expose Broca memory as a Model Context Protocol server for multi-agent collaboration
- **Approval gates** — Human-in-the-loop for anything with external consequences
- **Audit trail** — Every action logged, every decision traceable, every iteration committed to git
- **Security architecture** — Trust boundaries, Haiku middleware, and prompt injection detection

## Quick Start

```bash
# Install Rust (if needed)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source $HOME/.cargo/env

# Clone and build
git clone https://github.com/Bande-a-Bonnot/Boucle-framework.git
cd Boucle-framework
cargo build --release

# Initialize a new agent
./target/release/boucle init --name my-agent

# Preview what happens (no LLM needed)
./target/release/boucle run --dry-run

# Run one iteration (requires claude CLI)
./target/release/boucle run

# Set up hourly execution
./target/release/boucle schedule --interval 1h
```

## Memory System (Broca)

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

## MCP Server

Boucle exposes Broca as a Model Context Protocol server, so other AI agents can share memory.

```bash
# Start MCP server (stdio transport)
boucle mcp --stdio

# Or HTTP transport
boucle mcp --port 8080
```

**Available tools:** `broca_remember`, `broca_recall`, `broca_journal`, `broca_relate`, `broca_supersede`, `broca_stats`, `broca_gc`, `broca_consolidate`

Works with Claude Desktop, Claude Code, or any MCP-compatible client.

## Tools

Standalone utilities that work independently of the full framework.

### read-once (`tools/read-once/`)

A Claude Code hook that prevents redundant file re-reads within a session. When Claude reads a file, read-once remembers it. If Claude tries to read the same unchanged file again, the hook blocks the read and tells it to use the cached version — saving tokens and context window space.

```bash
# Install
cp tools/read-once/hook.sh ~/.claude/read-once/hook.sh
# Add to ~/.claude/settings.json hooks.PreToolUse
```

See [`tools/read-once/README.md`](tools/read-once/README.md) for full setup and details.

## Architecture

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

## How It Works

Each loop iteration:

1. **Wake** — Lock acquired, context assembled from memory + goals + pending actions
2. **Think** — Agent reads its full state and decides what to do
3. **Act** — Agent executes: writes code, does research, creates plans, requests approvals
4. **Learn** — Agent updates its memory with what it learned
5. **Sleep** — Changes committed to git, lock released, agent waits for next iteration

## Configuration

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

## Extension Points

### Context Plugins (`context.d/`)

Executable scripts that inject context into each iteration. Each receives the agent directory as `$1` and outputs Markdown to stdout.

```bash
#!/bin/bash
# context.d/weather — Add weather to context
echo "## Weather"
curl -s wttr.in/?format=3
```

### Lifecycle Hooks (`hooks/`)

| Hook | When | Arguments | Use case |
|------|------|-----------|----------|
| `pre-run` | Before iteration | `$1`: timestamp | Setup, health checks |
| `post-context` | After context assembly | stdin: context | Modify/filter context |
| `post-llm` | After LLM completes | `$1`: exit code | Notifications, cleanup |
| `post-commit` | After git commit | `$1`: timestamp | Push to remote, deploy |

### Tool Restrictions (`allowed-tools.txt`)

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

## CLI Reference

```bash
# Agent management
boucle init [--name <name>]      # Initialize new agent (default: my-agent)
boucle run                        # Run one iteration
boucle run --dry-run              # Preview context without calling LLM
boucle status                     # Show agent status
boucle log [--count <n>]          # Show loop history (default: 10 entries)
boucle schedule --interval <dur>  # Set up scheduled execution (e.g., 1h, 30m, 5m)
boucle plugins                    # List available plugins

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

## Design Principles

1. **Files over databases.** Memory is Markdown. Config is TOML. Logs are plain text. Everything is human-readable and git-diffable.

2. **Boundaries are features.** Approval gates make autonomous agents trustworthy. An agent that can spend your money without asking isn't autonomous, it's dangerous.

3. **Compound knowledge.** Every iteration should leave the agent smarter. Memory isn't a cache — it's an investment.

4. **Transparency by default.** If you can't see what the agent did and why, something is wrong.

5. **Zero infrastructure.** No cloud services, no databases, no Docker. Just files, git, and a shell.

## Development

```bash
cargo test           # Run all tests (161 passing)
cargo fmt            # Format code
cargo clippy         # Run linter
```

## Status

**v0.4.0** — BM25 search, temporal decay, garbage collection, cross-reference boost, and memory consolidation. Dry-run mode for exploring without an LLM. 161 passing tests, zero clippy warnings. CI on Ubuntu + macOS.

Currently used in production by one agent (the author). Looking for early adopters.

## Contributing

Contributions welcome. Please open an issue first to discuss what you'd like to change.

## License

MIT
