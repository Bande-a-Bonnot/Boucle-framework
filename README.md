# Boucle

An opinionated framework for running autonomous AI agents in a loop.

Wake up. Think. Act. Learn. Repeat.

## What is this?

Boucle is a framework for building persistent AI agents that run on a schedule, maintain memory across iterations, and operate within clear human-defined boundaries. It's not a chatbot wrapper — it's infrastructure for agents that work autonomously over days, weeks, and months.

**Built by the agent that runs on it.** Boucle is developed and improved by an autonomous agent (also named Boucle) that uses the framework for its own operation. Every feature is dogfooded in production.

## Features

- **Structured loop runner** — Schedule agent iterations via cron/launchd with locking, logging, and error recovery
- **Persistent memory (Broca)** — File-based, git-native knowledge that compounds across iterations. No database required.
- **MCP server** — Expose Broca memory as a Model Context Protocol server for multi-agent collaboration
- **Goal tracking** — Define objectives, track progress, measure value across loop iterations
- **Approval gates** — Human-in-the-loop for anything with external consequences (spending money, posting publicly, contacting people)
- **Audit trail** — Every action logged, every decision traceable, every iteration committed to git
- **Identity system** — Configurable agent identity, boundaries, and permissions
- **Security architecture** — Defense-in-depth against prompt injection with trust boundaries, Haiku middleware, and pattern detection

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

# Start MCP server for other agents
./target/release/boucle mcp --stdio
```

## Real-World Examples

### Autonomous Monitoring Agent

```toml
# monitoring-agent/boucle.toml
[agent]
name = "monitor"
description = "Monitors system health and responds to issues"

[schedule]
interval = "5m"

[boundaries]
autonomous = ["read_logs", "analyze_metrics", "create_reports"]
requires_approval = ["restart_services", "alert_oncall", "modify_config"]
```

This agent continuously monitors system health, learns from patterns, and escalates issues that require human intervention.

### Repository Health Auditor

```bash
# Create specialized audit memories
./target/release/boucle memory remember "Critical security advisory in react@18.2.0" \
  --tags "security,react,audit" --type "threat"

# Agent recalls related knowledge when analyzing repos
./target/release/boucle memory recall "react security" --limit 5
```

The agent builds institutional knowledge about security issues, outdated dependencies, and maintenance patterns across your organization's repositories.

### Content Creation Pipeline

```bash
# Agent learns from successful content patterns
./target/release/boucle memory remember "Technical debugging posts get 3x engagement vs feature announcements" \
  --tags "content,strategy" --confidence 0.8

# Later iterations use this knowledge for content decisions
./target/release/boucle memory recall "content strategy"
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

## Why Boucle?

| Feature | Boucle | LangChain Agents | AutoGPT | Other Frameworks |
|---------|---------|------------------|---------|------------------|
| **Infrastructure** | Zero dependencies | Cloud/vector DB | Docker/Redis | Various |
| **Memory** | File-based, git-native | Vector embeddings | JSON/databases | Mixed |
| **Persistence** | Built-in across reboots | Manual implementation | Session-based | Varies |
| **Multi-agent** | MCP server included | Complex setup | Not supported | Plugin-based |
| **Approval Gates** | First-class feature | Not included | Not included | Rare |
| **Transparency** | Full audit trail | Limited logging | Basic logs | Varies |
| **Self-improvement** | Dogfooded daily | Theoretical | Not operational | Not demonstrated |

**The key difference:** Boucle is designed for agents that operate continuously over weeks and months, building institutional knowledge and maintaining consistent identity across reboots.

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

## MCP Server

Boucle exposes Broca's memory system as a Model Context Protocol (MCP) server, enabling other AI agents to use file-based memory as shared infrastructure.

```bash
# Start MCP server (stdio transport)
./target/release/boucle mcp --stdio

# Use with Claude Desktop, Continue, or any MCP-compatible client
```

**Available tools:**
- `broca_remember` — Store structured memories with tags and metadata
- `broca_recall` — Search memories with relevance ranking and fuzzy matching
- `broca_journal` — Add timestamped journal entries
- `broca_relate` — Create relationships between memories
- `broca_supersede` — Mark memories as superseded by newer information
- `broca_stats` — Get memory system statistics

This positions Broca as ecosystem infrastructure — a shared memory layer that multiple agents can use to build knowledge collectively while maintaining their individual workflows.

## Security

Boucle implements defense-in-depth security to protect against prompt injection and maintain trust boundaries:

### Trust Boundaries
All context is explicitly marked as trusted system data or potentially untrusted external content, with clear warnings about the source and security status of each section.

### Haiku Security Middleware
An intelligent security layer that analyzes external content before it reaches the agent:
- **Claude Haiku analysis** for sophisticated threat detection
- **Pattern-based fallback** for reliable protection when Haiku unavailable
- **Nonce verification** prevents attacks on the middleware itself
- **Transparent filtering** with clear security warnings

### Secure Context Loading
The `secure-context-loader.py` tool integrates security analysis with the context plugin system, automatically filtering dangerous content while preserving safe information.

See [SECURITY.md](SECURITY.md) for complete security architecture documentation.

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

## Development

### Building from Source

```bash
git clone https://github.com/Bande-a-Bonnot/Boucle-framework.git
cd Boucle-framework
cargo build --release
```

### Running Tests

```bash
# Run all tests
cargo test

# Run with verbose output
cargo test -- --nocapture

# Run specific test
cargo test test_memory_operations
```

### Code Quality

```bash
# Format code
cargo fmt

# Run linter
cargo clippy -- -D warnings

# Check formatting without modifying files
cargo fmt -- --check
```

### Development Workflow

1. **Fork and clone** the repository
2. **Create a feature branch** from main
3. **Make your changes** with tests
4. **Run the full test suite** (`cargo test`)
5. **Format and lint** (`cargo fmt && cargo clippy`)
6. **Submit a pull request**

All tests must pass and code must be formatted before merging.

### Directory Structure

```
src/
├── main.rs           # CLI entry point
├── agent/            # Core agent runtime
├── memory/           # Broca memory system
├── mcp/             # Model Context Protocol server
├── scheduler/       # Cron/launchd integration
├── security/        # Prompt injection protection
└── runner/          # Loop execution engine
```

## Troubleshooting

### Agent Won't Start

**Problem:** `boucle run` exits immediately without output.

**Solutions:**
- Check if another instance is running: `ps aux | grep boucle`
- Remove stale lock file: `rm your-agent/.boucle.lock` (if agent crashed)
- Verify config file: `your-agent/boucle.toml` exists and is valid TOML
- Check permissions on agent directory

### Memory Corruption

**Problem:** Memory recall returns unexpected or corrupted entries.

**Solutions:**
- Validate memory files: `find your-agent/memory -name "*.md" -exec head -1 {} \;`
- Check for invalid YAML frontmatter in memory entries
- Restore from git: `git checkout HEAD -- your-agent/memory/`
- Run memory stats: `boucle memory stats` to check for issues

### Scheduling Problems

**Problem:** Agent doesn't run on schedule.

**Solutions:**

For macOS (launchd):
```bash
# Check if agent is loaded
launchctl list | grep boucle

# Check agent status
launchctl list com.boucle.your-agent-name

# Reload agent definition
launchctl unload ~/Library/LaunchAgents/com.boucle.your-agent-name.plist
launchctl load ~/Library/LaunchAgents/com.boucle.your-agent-name.plist

# Check system logs
log show --predicate 'subsystem == "com.boucle.your-agent-name"' --last 1h
```

For Linux (systemd):
```bash
# Check service status
systemctl --user status boucle-your-agent-name

# View service logs
journalctl --user -u boucle-your-agent-name -f

# Restart service
systemctl --user restart boucle-your-agent-name
```

### Performance Issues

**Problem:** Agent iterations take too long or use too much memory.

**Solutions:**
- Check memory directory size: `du -sh your-agent/memory`
- Review context plugins: disable expensive ones in `context.d/`
- Reduce memory recall limit in configurations
- Monitor with: `time boucle run --dry-run`

### MCP Server Issues

**Problem:** MCP server won't start or clients can't connect.

**Solutions:**
- Test stdio transport: `echo '{"jsonrpc":"2.0","id":1,"method":"ping"}' | boucle mcp --stdio`
- Verify MCP client configuration points to correct binary path
- Check that tools are properly exported: `boucle mcp --list-tools`
- Enable debug logging: `RUST_LOG=debug boucle mcp --stdio`

### Getting Help

- **Documentation**: Read this README and [SECURITY.md](SECURITY.md)
- **Issues**: Search existing issues before creating new ones
- **Discussions**: Use GitHub Discussions for questions and ideas
- **Discord/Slack**: Join community channels (links in GitHub)

## CLI Reference

### Agent Management

```bash
# Initialize new agent
boucle init --name my-agent [--path ./my-agent]

# Run one iteration
boucle run [--dry-run] [--verbose]

# Show agent status
boucle status

# Clean up (remove locks, temp files)
boucle clean
```

### Scheduling

```bash
# Set up scheduled execution
boucle schedule --interval 1h [--method launchd|systemd]
boucle schedule --cron "0 */6 * * *"  # Every 6 hours

# Remove scheduled execution
boucle unschedule

# Show schedule status
boucle schedule --status
```

### Memory Operations

```bash
# Store memories
boucle memory remember "Important fact" --tags "urgent,project"
boucle memory remember "Database URL changed" --confidence 0.9 --type "config"

# Retrieve memories
boucle memory recall "database" [--limit 5] [--tags "config"]
boucle memory recall --recent [--days 7]

# Memory management
boucle memory stats              # Show statistics
boucle memory validate          # Check for corrupted entries
boucle memory compact          # Remove superseded entries
boucle memory export [--format json|yaml]
```

### Goal Management

```bash
# Create goals
boucle goal create "Reduce response time by 50%" --priority high
boucle goal create "Implement caching" --parent goal-123

# Track progress
boucle goal list [--active] [--completed]
boucle goal show goal-123
boucle goal update goal-123 --status "in_progress" --progress 0.3
boucle goal complete goal-123
```

### MCP Server

```bash
# Start MCP server
boucle mcp --stdio              # Standard I/O transport
boucle mcp --port 8080          # HTTP transport
boucle mcp --socket /tmp/boucle.sock  # Unix socket

# Server management
boucle mcp --list-tools         # Show available tools
boucle mcp --validate          # Test server configuration
```

### Configuration

```bash
# Show current configuration
boucle config show

# Update configuration
boucle config set agent.name "new-name"
boucle config set schedule.interval "30m"
boucle config set boundaries.autonomous "read,write,research"

# Configuration templates
boucle config template monitoring  # Create monitoring agent config
boucle config template content     # Create content agent config
boucle config template security    # Create security agent config
```

### Debugging

```bash
# Verbose execution
RUST_LOG=debug boucle run --verbose

# Show context without running
boucle run --dry-run --show-context

# Validate agent setup
boucle doctor                   # Check configuration, permissions, dependencies

# Show loop history
boucle log --recent [--lines 100]
boucle log --since "2026-03-01"
```

### Global Options

| Flag | Description |
|------|-------------|
| `--agent-dir DIR` | Use specific agent directory (default: current) |
| `--config FILE` | Use specific config file (default: boucle.toml) |
| `--verbose, -v` | Enable verbose output |
| `--quiet, -q` | Suppress non-error output |
| `--help, -h` | Show command help |

## Status

**v0.3.0 — Production ready.** Originally prototyped in bash, Boucle is now rewritten in Rust for reliability, proper testing, and cross-platform support.

### Proven in Production

- **85 passing tests** — Comprehensive test coverage for all components
- **83+ loop iterations** — Running continuously in production since February 2026
- **Self-healing infrastructure** — Automatically diagnosed and fixed its own timing issues ([read the story](https://bande-a-bonnot.github.io/boucle-blog/technical/debugging/autonomous-systems/2026/03/02/autonomous-debugging.html))
- **Zero-downtime operation** — Handles errors gracefully with automatic retry and recovery
- **Git-native audit trail** — Every decision and change is tracked and reversible

Built in public by the agent that uses it. Current iteration count: **83+ loops** and growing daily.

### Reliability Features

- **Process locking** prevents concurrent execution
- **Stale lock detection** recovers from crashes automatically
- **Error recovery** with exponential backoff
- **Resource cleanup** ensures clean shutdowns
- **Dead man's switch** for safe self-modification

## Contributing

Contributions welcome. Please open an issue first to discuss what you'd like to change.

## License

MIT

## Credits

Built by [Boucle](https://github.com/Bande-a-Bonnot/boucle-blog), an autonomous agent by [Bande-a-Bonnot](https://github.com/Bande-a-Bonnot).
