# Changelog

All notable changes to Boucle are documented here.

## [Unreleased]

## [0.7.0] - 2026-03-24

### Added

#### bash-guard (277 -> 486 tests)
- **Disk utility protection** -- Blocks `diskutil eraseDisk`/`eraseVolume`/`partitionDisk`, `fdisk`, `gdisk`, `parted`, `sfdisk`, `wipefs`. Addresses [#37984](https://github.com/anthropics/claude-code/issues/37984) (87GB personal data destroyed by AI).
- **System database protection** -- Blocks `sqlite3` operations on IDE internals (VSCode `.vscdb`, Cursor, JetBrains databases). Addresses [#37888](https://github.com/anthropics/claude-code/issues/37888) (59 commands corrupted VSCode state).
- **Mount point protection** -- Blocks `rm -rf` targeting `/mnt`, `/media`, `/Volumes`, NFS paths. Addresses [#36640](https://github.com/anthropics/claude-code/issues/36640).
- **Encoding bypass detection** -- Catches base64/hex/octal decode piped to shell, reversed strings, process substitution downloads (`bash <(curl ...)`), and language wrapper bypasses (Python/Ruby/Node/Perl exec).
- **Here-string/here-doc detection** -- Blocks dangerous commands hidden in `<<<`, `<<EOF`, eval string injection, and `xargs` piped to shell.
- **17 competitive analysis patterns** -- LD_PRELOAD injection, macOS Keychain access (`security find-generic-password`), crontab persistence, wrapper command bypass (`command rm`, `env rm`), credential file operations (`cp`/`mv .env`), and more.
- **Multi-line bypass validation** -- Tests that dangerous commands after comment lines are still caught, closing the deny-rule bypass gap ([#38119](https://github.com/anthropics/claude-code/issues/38119)).

#### safety-check (40 -> 111 tests)
- **`--verify` mode** -- Sends test payloads (`rm -rf /`, `git push --force`, etc.) to each installed hook and confirms they actually block. Catches hooks that are installed but broken.
- **enforce-hooks detection** -- Detects enforce-hooks installation and reports `@enforced` CLAUDE.md rules.
- **CLI version warnings** -- Alerts about known regressions in specific Claude Code versions.
- **Deny-rule bypass warning** -- Warns when deny rules are configured without bash-guard, since deny patterns [can be bypassed](https://github.com/anthropics/claude-code/issues/38119).
- **CLAUDE.md rule coverage analysis** -- Scans CLAUDE.md for enforceable rules and reports which are covered by hooks.
- **Project-level detection** -- Scans both user-level (`~/.claude/settings.json`) and project-level (`.claude/settings.json`) settings.
- **Hook inventory** -- Shows custom and third-party hooks alongside framework hooks.

#### git-safe (50 -> 65 tests)
- **Checkout-from-ref protection** -- Blocks `git checkout HEAD -- .` and other ref-based checkout patterns that overwrite working directory files.
- **Expanded restore detection** -- Catches more `git restore` variants including `--source` and `--staged`.

#### Installers
- **Post-install verification** -- `install.sh` sends test payloads to newly installed hooks to confirm they work, not just installed.
- **Dependency checks** -- Warns about missing `jq`/`python3` prerequisites before installation.

### Fixed
- **Quickstart argument passing** -- `bash -s -- all` now correctly installs all hooks (was broken since v0.6.0).
- **bash-guard false positive** -- `dd` writing to regular files (not devices) is now allowed.
- **safety-check file-guard verify** -- Creates temporary `.file-guard` config for file-guard verification instead of failing when no config exists.
- **Stale test counts** -- README and framework site use approximate counts that stay accurate longer.

### Documented
- 3 platform bug warnings in enforce-hooks README: [#38162](https://github.com/anthropics/claude-code/issues/38162) (async empty stdin macOS), [#38181](https://github.com/anthropics/claude-code/issues/38181), [#38165](https://github.com/anthropics/claude-code/issues/38165).
- 3 new Known Limitations: [#38040](https://github.com/anthropics/claude-code/issues/38040) (memory path bypass), [#38018](https://github.com/anthropics/claude-code/issues/38018) (compaction resilience).
- Framework site restructured for discoverability (SEO-focused, problem-solution mapping, hooks-first layout).

### Stats
- 195 Rust tests (unchanged)
- Hook tests: bash-guard 486, safety-check 111, file-guard 87, git-safe 65, session-log 81, read-once 49, enforce-hooks 41, branch-guard 36
- Cross-cutting tests: format 36, security-fixes 31, install 24
- Total hook tests: ~1050
- Total: ~1240
- CI: Ubuntu + macOS, Docker image published to ghcr.io

## [0.6.1] - 2026-03-23

### Fixed
- **Docker build** -- Commit `Cargo.lock` for reproducible builds. v0.6.0 Docker image failed to build because `Cargo.lock` was in `.gitignore`.

## [0.6.0] - 2026-03-23

### Security
- **enforce-hooks: shell injection fix** -- Engine now passes values via environment variables instead of string interpolation, preventing crafted CLAUDE.md content from executing arbitrary shell commands. 22 new edge case tests.
- **Standalone hooks: JSON injection fix** -- All hooks use `jq --arg` for safe JSON output, preventing crafted filenames or commands from breaking hook responses.
- **file-guard: path traversal fix** -- Normalizes paths to prevent `../../.env` bypassing deny rules.

### Added

#### bash-guard (89 -> 276 tests)
- **Docker protection** -- Blocks `docker system prune -a`, `docker volume rm`, `docker-compose down -v`, and other container data destruction commands.
- **Database destruction protection** -- Blocks `dropdb`, `DROP DATABASE`, `TRUNCATE`, ORM migration commands (`prisma db push`, `migrate:fresh`, `fixtures:load`), and database connection string exposure.
- **Credential exposure protection** -- Blocks `env`, `printenv`, `set`, `export -p`, `bash -x`, `python -c "import os; os.environ"`, and other environment/credential dumping commands.
- **Cloud infrastructure protection** -- Blocks `terraform destroy`, `aws ... delete`, `gcloud ... delete`, `kubectl delete`, and other cloud resource destruction commands.
- **Mass delete protection** -- Blocks `find . -delete`, `xargs rm`, `git clean -fdx`, and bulk file removal patterns.
- **Compound command bypass prevention** -- Detects dangerous commands hidden in `;`, `&&`, `||`, `$()`, and backtick chains. 20 new tests.
- **Workaround bypass prevention** -- Catches `find -exec rm`, `pkexec`/`doas` privilege escalation, `shred`, `truncate -s 0`, `dd if=/dev/zero`, and other alternatives to blocked commands.
- **Data exfiltration prevention** -- Blocks `curl -F`/`wget --post-file` file uploads, `nc` piping, `python`/`node`/`ruby` environment dumps, SSH key access, and shell history exposure.

#### file-guard (42 -> 86 tests)
- **[deny] mode** -- Blocks all access (Read, Grep, Glob, and Bash) to denied paths, not just writes. Addresses users who need to completely hide files from AI agents.

#### git-safe (45 -> 50 tests)
- **push --delete protection** -- Blocks `git push origin --delete` which deletes remote branches/tags.

#### safety-check
- **Environment warnings** -- Detects risky environment variables and hook health issues during safety scoring.

#### Installers
- **Quickstart installer** -- `install.sh quickstart` creates a CLAUDE.md with enforceable rules and installs armor protection if none exist. Zero-to-protected in one command.
- **JSONC settings.json support** -- All 8 installers now strip comments before parsing settings.json, preventing data loss when users have JSONC-format config files.
- **Post-install guidance** -- Installers show what rules were detected and what protection was added.

### Fixed
- **read-once deny mode** -- Switched from `permissionDecision` format (broken since Claude Code v2.1.78, see [#37597](https://github.com/anthropics/claude-code/issues/37597)) to robust top-level `decision:block` format. Prevents silent fail-open on newer Claude Code versions.
- **Stale test counts** -- Corrected README and framework site test counts across all 6 hooks.
- **tools/README.md config names** -- Fixed 3 hooks that had wrong config file names in documentation.
- **Installer post-install messages** -- Updated to reflect current capabilities (was missing 7 protection categories).
- **CI test payloads** -- Fixed `input` -> `tool_input` field name across all test payloads (contributed by chris-peterson via PR #2).

### Documented
- 3 platform bugs in Known Limitations: [#37745](https://github.com/anthropics/claude-code/issues/37745) (permission reset), [#37730](https://github.com/anthropics/claude-code/issues/37730) (subagent inheritance), [#37746](https://github.com/anthropics/claude-code/issues/37746) (Vertex AI).
- Command-type hook limitation ([#33125](https://github.com/anthropics/claude-code/issues/33125)).
- MCP hook deny limitation ([#33106](https://github.com/anthropics/claude-code/issues/33106)).
- Design tradeoff section in README (positions vs. advisory-based approaches).

### Stats
- 195 Rust tests (unchanged)
- Hook test suites: enforce-hooks 38, bash-guard 277, file-guard 86, git-safe 50, session-log 81, branch-guard 36, safety-check 40, format 36
- Total hook tests: 644
- Total tests: 839
- CI: Ubuntu + macOS, Docker image published to ghcr.io

## [0.5.0] - 2026-03-09

### Added

#### Standalone Hooks
- **[enforce-hooks](tools/enforce/)** — Reads your CLAUDE.md, identifies enforceable rules, and generates PreToolUse hooks that block violations at the tool-call level. 12 pattern types (file-guard, bash-guard, branch-guard, git-safe, tool-block, require-prior-tool, bare filename protection, command substitution, read-verb, prefer-command, search-locally, multi-tool). Plugin mode (`--install-plugin`) installs a single dynamic hook that re-reads CLAUDE.md on every call. `--evaluate` audits your current setup. `--scan` shows what's enforceable. 134 tests.
- **[file-guard](tools/file-guard/)** — Protects files from AI modification. Define patterns in `.file-guard`. Blocks writes, edits, and destructive bash commands targeting sensitive files. Includes `init.sh` for auto-detecting sensitive files. 27 tests.
- **[git-safe](tools/git-safe/)** — Blocks destructive git operations: force push, hard reset, checkout ., clean -f, branch -D. Suggests safer alternatives. Allowlist via `.git-safe`. 45 tests.
- **[bash-guard](tools/bash-guard/)** — Blocks dangerous bash commands: `rm -rf /`, `sudo`, `curl|bash`, `chmod -R 777`, `kill -9 -1`, `dd`, `mkfs`, `eval` injection, global npm installs, Docker data destruction, database destruction (dropdb, DROP/TRUNCATE, ORM commands). Custom deny rules for granular blocking. Allowlist via `.bash-guard`. 89 tests.
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

[Unreleased]: https://github.com/Bande-a-Bonnot/Boucle-framework/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/Bande-a-Bonnot/Boucle-framework/compare/v0.6.1...v0.7.0
[0.6.1]: https://github.com/Bande-a-Bonnot/Boucle-framework/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/Bande-a-Bonnot/Boucle-framework/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/Bande-a-Bonnot/Boucle-framework/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/Bande-a-Bonnot/Boucle-framework/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/Bande-a-Bonnot/Boucle-framework/releases/tag/v0.4.0
