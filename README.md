# Boucle

An opinionated framework for running autonomous AI agents in a loop.

Wake up. Think. Act. Learn. Repeat.

## What is this?

Boucle is a framework for building persistent AI agents that run on a schedule, maintain memory across iterations, and operate within clear human-defined boundaries. It's not a chatbot wrapper — it's infrastructure for agents that work autonomously over days, weeks, and months.

**Built by the agent that runs on it.** Boucle is developed and improved by an autonomous agent (also named Boucle) that uses the framework for its own operation. Every feature is dogfooded in production.

## Features

- **Structured loop runner** — Schedule agent iterations via cron/launchd with locking, logging, and error recovery
- **Persistent memory (Broca)** — File-based, git-native knowledge that compounds across iterations. No database required.
- **Goal tracking** — Define objectives, track progress, measure value across loop iterations
- **Approval gates** — Human-in-the-loop for anything with external consequences (spending money, posting publicly, contacting people)
- **Audit trail** — Every action logged, every decision traceable, every iteration committed to git
- **Identity system** — Configurable agent identity, boundaries, and permissions

## Quick Start

```bash
# Clone and build
git clone https://github.com/Bande-a-Bonnot/Boucle-framework.git
cd Boucle-framework
cargo build --release

# Initialize a new agent
./target/release/boucle init --name my-agent

# Run one iteration
./target/release/boucle run

# Set up hourly execution
./target/release/boucle schedule --interval 1h

# Memory operations
./target/release/boucle memory remember "API keys rotate monthly" --tags "security,ops"
./target/release/boucle memory recall "API keys"
./target/release/boucle memory stats
```

## Architecture

```
your-agent/
├── boucle.toml          # Agent configuration (identity, boundaries, schedule)
├── system-prompt.md     # Agent identity and rules (optional)
├── allowed-tools.txt    # Tools the agent can use, one per line (optional)
├── memory/              # Persistent knowledge (Broca)
│   ├── state.md         # Current state — read at loop start, updated at loop end
│   ├── knowledge/       # Learned facts, indexed by topic
│   └── journal/         # Timestamped iteration summaries
├── goals/               # Active objectives
├── logs/                # Full iteration logs
├── gates/               # Pending approval requests
├── context.d/           # Executable scripts that add context sections (optional)
└── hooks/               # Lifecycle hooks (optional)
    ├── pre-run          # Runs before each iteration
    ├── post-context     # Runs after context assembly (stdin: context, stdout: modified context)
    ├── post-llm         # Runs after LLM completes ($1: exit code)
    └── post-commit      # Runs after git commit ($1: timestamp)
```

## How It Works

Each loop iteration follows this cycle:

1. **Wake** — Lock acquired, context assembled from memory + goals + pending actions
2. **Think** — Agent reads its full state and decides what to do
3. **Act** — Agent executes: writes code, does research, creates plans, requests approvals
4. **Learn** — Agent updates its memory with what it learned
5. **Sleep** — Changes committed to git, lock released, agent waits for next iteration

## Design Principles

1. **Files over databases.** Memory is Markdown. Config is TOML. Logs are plain text. Everything is human-readable, git-diffable, and works anywhere.

2. **Boundaries are features.** Approval gates aren't limitations — they're what make autonomous agents trustworthy. An agent that can spend your money without asking isn't autonomous, it's dangerous.

3. **Compound knowledge.** Every iteration should leave the agent smarter. Memory isn't a cache — it's an investment.

4. **Transparency by default.** If you can't see what the agent did and why, something is wrong.

5. **Zero infrastructure.** No cloud services, no databases, no Docker. Just files, git, and a shell.

## Memory System (Broca)

Boucle's memory is powered by Broca — a file-based, git-native knowledge system designed for AI agents.

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

Broca provides:
- **Structured entries** with YAML frontmatter (tags, confidence, timestamps, relationships)
- **Smart retrieval** via tag-based + keyword search + recency weighting
- **Knowledge compounding** — entries can reference and build on each other
- **Zero dependencies** — just Markdown files in a directory

## Configuration

```toml
# boucle.toml
[agent]
name = "my-agent"
description = "A helpful autonomous agent"

[schedule]
interval = "1h"
method = "launchd"  # or "cron"

[boundaries]
autonomous = ["read", "write", "research", "plan"]
requires_approval = ["spend_money", "post_publicly", "contact_people", "push_code"]

[memory]
backend = "broca"
path = "memory/"

[llm]
provider = "claude"
model = "claude-sonnet-4-20250514"
```

## Extension Points

Boucle is designed to be extended without modifying the framework itself.

### Context Plugins (`context.d/`)

Add executable scripts to `context.d/` to inject custom context into each iteration. Each script receives the agent directory as `$1` and should output Markdown to stdout.

```bash
#!/bin/bash
# context.d/linear-issues — Fetch Linear issues
echo "## Linear Issues"
echo ""
# ... your logic to fetch and format issues
```

### Lifecycle Hooks (`hooks/`)

Add executable scripts to `hooks/` to run code at specific points in the loop:

| Hook | When | Arguments | Use case |
|------|------|-----------|----------|
| `pre-run` | Before iteration starts | `$1`: timestamp | Setup, health checks |
| `post-context` | After context assembly | stdin: context | Modify context (filter, augment) |
| `post-llm` | After LLM completes | `$1`: exit code | Notifications, cleanup |
| `post-commit` | After git commit | `$1`: timestamp | Push to remote, deploy |

### Tool Restrictions (`allowed-tools.txt`)

List one tool per line to restrict what the agent can use:

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

## Status

**v0.3.0 — Rust rewrite.** Originally prototyped in bash, Boucle is being rewritten in Rust for reliability, proper testing, and cross-platform support. The bash version remains in `bin/` and `lib/` for reference.

Built in public by the agent that uses it. Current iteration count: growing daily.

## Contributing

Contributions welcome. Please open an issue first to discuss what you'd like to change.

## License

MIT

## Credits

Built by [Boucle](https://github.com/Bande-a-Bonnot/boucle-blog), an autonomous agent by [Bande-a-Bonnot](https://github.com/Bande-a-Bonnot).
