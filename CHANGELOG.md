# Changelog

All notable changes to Boucle are documented here.

## [Unreleased]

## [0.5.0] - 2026-03-09

### Added

#### Standalone Hooks
- **[enforce-hooks](tools/enforce/)** — Reads your CLAUDE.md, identifies enforceable rules, and generates PreToolUse hooks that block violations at the tool-call level. 12 pattern types (file-guard, bash-guard, branch-guard, git-safe, tool-block, require-prior-tool, bare filename protection, command substitution, read-verb, prefer-command, search-locally, multi-tool). Plugin mode (`--install-plugin`) installs a single dynamic hook that re-reads CLAUDE.md on every call. `--evaluate` audits your current setup. `--scan` shows what's enforceable. 134 tests.
- **[file-guard](tools/file-guard/)** — Protects files from AI modification. Define patterns in `.file-guard`. Blocks writes, edits, and destructive bash commands targeting sensitive files. Includes `init.sh` for auto-detecting sensitive files. 27 tests.
- **[git-safe](tools/git-safe/)** — Blocks destructive git operations: force push, hard reset, checkout ., clean -f, branch -D. Suggests safer alternatives. Allowlist via `.git-safe`. 45 tests.
- **[bash-guard](tools/bash-guard/)** — Blocks dangerous bash commands: `rm -rf /`, `sudo`, `curl|bash`, `chmod -R 777`, `kill -9 -1`, `dd`, `mkfs`, `eval` injection, global npm installs. Custom deny rules for granular blocking. Allowlist via `.bash-guard`. 56 tests.
- **[branch-guard](tools/branch-guard/)** — Prevents direct commits to protected branches (main, master, production, release). Forces feature-branch workflow. 35 tests.
- **[session-log](tools/session-log/)** — Logs every tool call to `~/.claude/session-logs/YYYY-MM-DD.jsonl`. Tracks exit codes and error status. 52 tests.
- **[safety-check](tools/safety-check/)** — Scores your Claude Code safety configuration from A to F. No installation required. One-liner curl.
- **[diagnose](tools/diagnose/)** — Agent operations intelligence: regime detection, feedback loop analysis, drift indicators, and recommendations from loop log data. 15 tests.
- **Unified hook installer** — `install.sh all` installs every hook at once. Per-hook install also available.
- **session-report** — Summarize session-log data. `--week` and `--days` for trend comparison across time periods.

#### Self-Observation Engine
- **`boucle signal`** — Log friction, failure, waste, or surprise signals with fingerprints for pattern detection.
- **`boucle improve run`** — Pipeline: harvest signals, classify patterns by fingerprint, score response effectiveness, promote top unaddressed pattern.
- **`boucle improve status`** — Show patterns, scores, and pending actions.
- **`boucle improve init`** — Set up improve/ directory with example harvester.
- **Pluggable harvesters** — Scripts in `improve/harvesters/` run automatically and detect signals from logs, metrics, or any source.

#### DX Commands
- **`boucle doctor`** — Check prerequisites and agent health: config, memory, hooks, claude CLI, git status.
- **`boucle validate`** — Semantic config validation: catches unknown keys, invalid intervals, bad values, path issues.
- **`boucle stats`** — Aggregate loop statistics: total loops, success rate, throughput, date range.
- Config now accepts `agent.description`, `agent.version`, and `schedule.method` fields.

#### Other
- `glama.json` for Glama MCP directory listing
- Tools directory README for visitors navigating from GitHub comments

### Fixed
- 3 hook test failures: read-once argument swap, bash-guard eval regex, permission bits
- Standardized install paths across all hook installers (portable `~` instead of hardcoded paths)
- README restructured: hooks first, framework second

### Stats
- 195 Rust tests plus per-hook test suites (counts listed per hook above)
- Zero clippy warnings
- CI on Ubuntu + macOS
- Docker support via `ghcr.io`

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

[Unreleased]: https://github.com/Bande-a-Bonnot/Boucle-framework/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/Bande-a-Bonnot/Boucle-framework/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/Bande-a-Bonnot/Boucle-framework/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/Bande-a-Bonnot/Boucle-framework/releases/tag/v0.4.0
