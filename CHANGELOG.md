# Changelog

All notable changes to Boucle are documented here.

## [Unreleased]

### Added
- **`boucle validate`** — Semantic config validation: catches unknown/misspelled TOML keys, invalid intervals, unreasonable max_tokens, unknown model prefixes, path traversal, and common misconfigurations. Complements `doctor` (which checks prerequisites exist) by checking config *content*.
- **`boucle stats`** — Aggregate loop statistics: total loops, success/failure rate, average context size, throughput (loops/day), and date range. Parses log files to give operators insight into their agent's behavior.
- **`boucle doctor`** — New command that checks prerequisites and agent health: config parsing, memory directories, system prompt, hooks executability, claude CLI availability, and git status. Helps new users debug setup issues.
- Config now accepts `agent.description`, `agent.version`, and `schedule.method` fields.

## [0.4.1] - 2026-03-07

### Added
- **Dockerfile** — Multi-stage build for MCP server container deployment
- **Docker image CI** — Release workflow now publishes to `ghcr.io` on tagged releases
- **`boucle init` scaffolding** — New agents get a useful system prompt (iteration cycle, rules, memory vs state) and a structured state template (goals, last iteration, next actions)
- **read-once diff mode** — When a file changes between reads, show only the diff instead of the full file. Opt-in via `READ_ONCE_DIFF=1`. Saves 80-95% tokens on edit-verify-edit workflows.
- **read-once cost estimates** — `stats` and `deny` messages now show estimated token savings
- **read-once one-liner install** — `curl -fsSL ... | bash` installs the hook and merges it into your existing settings.json
- **Runnable examples** — `hello-world` and `daily-digest` examples include all config files needed to actually run them

### Fixed
- read-once installer uses portable `~` path instead of hardcoded absolute paths
- read-once installer merges into existing `settings.json` instead of overwriting
- `boucle init` no longer silently overwrites existing agent files

## [0.4.0] - 2026-03-01

First public release.

### Added
- **BM25 search** — Relevance-ranked recall that normalizes by document length and term rarity, replacing naive keyword counting
- **Temporal decay** — Recent memories score higher in search results; access frequency tracked automatically
- **Garbage collection** — `boucle memory gc` archives superseded, low-confidence, or stale entries. Reversible. Dry-run by default.
- **Cross-reference boost** — Related entries surface together in search results
- **Memory consolidation** — `boucle memory consolidate` detects and merges near-duplicate entries using Jaccard similarity
- **Dry-run mode** — `boucle run --dry-run` previews assembled context without calling the LLM
- **Release binaries** — Pre-built binaries for macOS (aarch64, x86_64) and Linux (x86_64) via GitHub Releases
- **read-once hook** — Claude Code hook that prevents redundant file re-reads within a session (~2000 tokens saved per prevented read)
- **MCP server** — Expose Broca memory via Model Context Protocol (stdio and HTTP transports)
- **Plugin system** — Plugins in `plugins/` are auto-discovered as both CLI subcommands and MCP tools
- **Lifecycle hooks** — `pre-run`, `post-context`, `post-llm`, `post-commit`
- **Context plugins** — Executable scripts in `context.d/` inject context into each iteration
- **Approval gates** — Human-in-the-loop for actions with external consequences
- **Scheduling** — `boucle schedule` sets up launchd/cron for recurring iterations

### Architecture
- File-based, git-native memory (Broca) — no database required
- TOML configuration with sensible defaults
- Full audit trail — every action logged, every iteration committed to git
- 161 passing tests, zero clippy warnings
- CI on Ubuntu + macOS

[Unreleased]: https://github.com/Bande-a-Bonnot/Boucle-framework/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/Bande-a-Bonnot/Boucle-framework/releases/tag/v0.4.0
