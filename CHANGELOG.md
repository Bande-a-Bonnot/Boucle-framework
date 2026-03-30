# Changelog

All notable changes to Boucle are documented here.

## [Unreleased]

## [0.10.0] - 2026-03-30

### Added

#### enforce-hooks
- **`content_guard` condition type** -- Blocks tool calls when the model's output text matches a pattern, catching prompt injection or policy violations in generated content before the tool executes.
- **`scoped_content_guard` condition type** -- Like `content_guard` but scoped to specific tools, so you can guard Write output differently from Bash output.

#### installer CLI
- **`uninstall` subcommand** -- Cleanly removes hook files and entries from settings.json. Bash and PowerShell.
- **`list` subcommand** -- Shows installed hooks, their event types, and file paths. Bash and PowerShell.
- **`upgrade` subcommand** -- Re-downloads hooks from the latest release without changing settings.json configuration. Bash and PowerShell.
- **`help` subcommand** -- Prints available commands and usage. Bash and PowerShell.
- **`doctor` subcommand** -- Diagnoses installation problems: checks settings.json validity, hook file existence, permission bits, and version consistency. Bash and PowerShell.
- **Backup and restore** -- Installer creates a `.bak` copy of settings.json before any modification. Restore on failure.
- **Robust JSONC handling** -- Both installers now handle Claude Code's JSONC format (settings.json with comments), stripping comments before JSON parsing.

#### read-once
- **PowerShell CLI** (`read-once.ps1`, 490 lines) -- Windows-native stats and management tool. View read counts, cache entries, token savings, and clear cache.
- **`verify` command** -- Full installation diagnostic with dry-run test. Checks hook presence, settings.json registration, file permissions, and cache directory access.

#### safety-check
- **All 11 hook event types** -- Expanded scanning from 4 types (PreToolUse, PostToolUse, Notification, Stop) to all 11 Claude Code event types: PreToolUse, PostToolUse, SessionStart, SessionEnd, Stop, SubagentStop, TaskCreated, WorktreeCreate, WorktreeRemove, UserPromptSubmit, Notification.
- **New warnings**: WorktreeCreate hooks ignored by EnterWorktree ([#36205](https://github.com/anthropics/claude-code/issues/36205)), TaskCreated is observe-only and cannot block, SubagentStop doesn't inherit parent allow-rules ([#40818](https://github.com/anthropics/claude-code/issues/40818)).

#### documentation
- **Copy-paste recipes** for 5 common enforcement scenarios in README: block force-push, protect secrets, enforce branching, prevent mass deletion, guard production configs.

### Security
- **file-guard: symlink bypass fix** -- Resolves symlinks before checking deny rules, preventing `ln -s /etc/passwd allowed-path` bypass. Mitigates [GHSA-4q92-rfm6-2cqx](https://github.com/anthropics/claude-code/security/advisories/GHSA-4q92-rfm6-2cqx).

### Fixed
- **3 Windows CI failures** -- bash-guard false positive on Windows paths, read-once cache directory handling, worktree-guard git config detection.
- **install.ps1** -- Missing worktree-guard matcher, missing bash-guard verification step, missing read-once.ps1 CLI download.
- **install.ps1** -- Now requires PowerShell 7+ with a clear error message instead of silent failures.
- **Stale documentation** -- Corrected test counts, removed broken cargo install instructions, fixed stale PowerShell limitation claims.

### Documented
- **100+ known platform limitations** in enforce-hooks README, up from ~80 in v0.9.3. Notable additions: stop hook reads stale transcript ([#40655](https://github.com/anthropics/claude-code/issues/40655)), model deliberately evades text-matching hooks ([#29689](https://github.com/anthropics/claude-code/issues/29689)), auto-update wipes settings.json ([#40714](https://github.com/anthropics/claude-code/issues/40714)), background agents lose allow-rules ([#40818](https://github.com/anthropics/claude-code/issues/40818)), Opus ignores 15+ CLAUDE.md rules ([#40867](https://github.com/anthropics/claude-code/issues/40867)), model tried to disable sandbox ([#40882](https://github.com/anthropics/claude-code/issues/40882)), CLAUDE.md rules ignored costing $850+ ([#40801](https://github.com/anthropics/claude-code/issues/40801)).

### Stats
- 195 Rust tests (unchanged)
- Hook tests (bash + PowerShell combined): bash-guard ~690, safety-check ~233, git-safe ~135, file-guard ~121, session-log ~107, installer ~81, read-once ~77, enforce-hooks ~71, worktree-guard ~64, branch-guard ~57, diagnose ~40, security/format/misc ~25
- Total: ~1900 tests

## [0.9.3] - 2026-03-29

### Added

#### Windows parity: 7/7 hooks now have native PowerShell equivalents
- **bash-guard PS1** (`bash-guard.ps1`) -- 849 lines, 112 check rules, 51 pattern categories. Largest PS1 port. Covers cloud infrastructure, encoding bypasses, disk utilities, and all bash-guard patterns.
- **worktree-guard PS1** (`worktree-guard.ps1`) -- 208 lines. Blocks ExitWorktree on uncommitted, untracked, unmerged, or unpushed changes. Two-tier squash merge detection.
- **read-once PS1** (`read-once.ps1`) -- 264 lines. Token-saving hook that blocks redundant file re-reads within a configurable window.

#### bash-guard
- **Cloud infrastructure protection** -- 15+ cloud platforms: AWS (EC2, S3, IAM, RDS, Lambda, ECS, EKS, CloudFormation), Azure (az vm, az storage, az aks), GCP (gcloud compute, gcloud storage, gcloud container), DigitalOcean, Linode, Vultr, Hetzner, OVH, Scaleway, Fly.io, Railway, Render, Vercel, Netlify, Heroku. Blocks destructive operations (delete, destroy, terminate, scale-to-zero) on production resources. 48 new tests.

#### installer
- **bash-guard added to Windows installer** -- `install.ps1` now includes bash-guard in the PS1 hook catalog.

### Documented
- **~80 known platform limitations** in enforce-hooks README, up from 72 in v0.9.2. New entries: bypass permission mode still prompts ([#40552](https://github.com/anthropics/claude-code/issues/40552)), model executes physical device commands without permission ([#40537](https://github.com/anthropics/claude-code/issues/40537)), cowork ignores all user hooks ([#40495](https://github.com/anthropics/claude-code/issues/40495)), model ignores startup sequences ([#40489](https://github.com/anthropics/claude-code/issues/40489)), background agents deny writes ([#40502](https://github.com/anthropics/claude-code/issues/40502)), model ignores negative feedback ([#40499](https://github.com/anthropics/claude-code/issues/40499)), Write guard pushes to Bash ([#40517](https://github.com/anthropics/claude-code/issues/40517)), ExitPlanMode crashes on auto-compact ([#40519](https://github.com/anthropics/claude-code/issues/40519)), self-modification guard ignores bypass ([#40463](https://github.com/anthropics/claude-code/issues/40463)), subagents lose CLAUDE.md ([#40459](https://github.com/anthropics/claude-code/issues/40459)).

### Stats
- 195 Rust tests (unchanged)
- Hook tests: bash-guard ~561, safety-check ~146, PS1 hooks ~248 (132 bash-guard + 116 prior), file-guard 91, git-safe 65, session-log 50, read-once 48, enforce-hooks ~52, branch-guard 35, worktree-guard 33, format ~36
- Total: ~1810+ tests

## [0.9.2] - 2026-03-29

### Added

#### bash-guard
- **In-place file editing bypass detection** -- Blocks `perl -i`, `ruby -i`, `sed -i`, and `ed` commands that modify files directly, bypassing all Write/Edit hook protections. Addresses [#40408](https://github.com/anthropics/claude-code/issues/40408) where `perl -i -pe` was discovered as a complete bypass of file-guard and all write-protection hooks.

#### safety-check
- **Glob wildcard injection detection** -- Warns when permission allowlist rules contain glob wildcards (`*`, `?`, `[`) that can be exploited to match unintended commands. Addresses [#40344](https://github.com/anthropics/claude-code/issues/40344) and [#40343](https://github.com/anthropics/claude-code/issues/40343).

#### installer
- **'recommended' preset** -- `bash install.sh recommended` installs the essential safety hooks (file-guard, git-safe, bash-guard, branch-guard) in a single command. Skips optional hooks (session-log, read-once, worktree-guard) for a minimal secure setup.
- **PowerShell installer** (`tools/install.ps1`) -- Windows-native installer for PS1 hooks. Downloads and configures file-guard, git-safe, branch-guard, and session-log without bash, jq, or WSL. Includes post-install verification.

### Fixed
- **Warn-level hook output** now uses `hookSpecificOutput` to avoid silent drop when hook returns a warning without `decision: "block"`. Fixes [#40380](https://github.com/anthropics/claude-code/issues/40380).
- **safety-check test reliability** -- Fixed false positive and case mismatch in 2 safety-check tests.

### Documented
- **72 known platform limitations** in enforce-hooks README, up from 53 in v0.9.1. Notable additions: glob wildcard injection in allowlists ([#40344](https://github.com/anthropics/claude-code/issues/40344)), bypassPermissions ignores allowlist ([#40343](https://github.com/anthropics/claude-code/issues/40343)), sandbox desync destroyed 2500 files ([#40321](https://github.com/anthropics/claude-code/issues/40321)), skip-permissions broken at runtime ([#40328](https://github.com/anthropics/claude-code/issues/40328)), plan mode not enforced at tool layer ([#40324](https://github.com/anthropics/claude-code/issues/40324)), permission prompt bypass ([#40302](https://github.com/anthropics/claude-code/issues/40302)), hook stdout corrupts worktree path ([#40262](https://github.com/anthropics/claude-code/issues/40262)), config race condition ([#40226](https://github.com/anthropics/claude-code/issues/40226)), iMessage relay attack ([#40221](https://github.com/anthropics/claude-code/issues/40221)), sandbox HTTP bypass ([#40213](https://github.com/anthropics/claude-code/issues/40213)), phantom SendMessage injection ([#40166](https://github.com/anthropics/claude-code/issues/40166)), and more.

### Stats
- 195 Rust tests (unchanged)
- Hook tests: bash-guard ~500, safety-check ~149, PS1 hooks 116, file-guard 91, git-safe 65, session-log 50, read-once 48, enforce-hooks ~52, branch-guard 35, worktree-guard 33, format ~36
- Total: ~1680+ tests

## [0.9.1] - 2026-03-28

### Added

#### git-safe
- **`--no-verify` bypass detection** -- Blocks `git commit --no-verify`, `git push --no-verify`, and `-n` shorthand in both bash and PowerShell hooks. Prevents agents from skipping pre-commit hooks and GPG signing. See [#40117](https://github.com/anthropics/claude-code/issues/40117).

#### worktree-guard (29 -> 33 tests)
- **Squash merge false positive fix** -- Two-tier detection replaces SHA-only comparison. Tier 1: `git cherry` for patch-level equivalence (single-commit squash, cherry-pick, rebase). Tier 2: per-file comparison for multi-commit squash where individual patches differ but combined result matches base. Fixes [#40137](https://github.com/anthropics/claude-code/issues/40137).

#### PowerShell hook tests
- **116 new tests** for file-guard, git-safe, branch-guard, and session-log PowerShell hooks. Tests run on Windows CI (GitHub Actions `windows-latest`). Caught 2 real bugs: case-insensitive `-match` needed in git-safe PS1, and `--force-with-lease` detection gap.

### Documented
- **53 known platform limitations** in enforce-hooks README, up from 48 in v0.9.0. New entries: hook input lacks agent context ([#40140](https://github.com/anthropics/claude-code/issues/40140)), ExitWorktree squash merge false positive ([#40137](https://github.com/anthropics/claude-code/issues/40137)), runtime deletes .kiro/ directories ([#40139](https://github.com/anthropics/claude-code/issues/40139)), failed marketplace auto-update deletes plugins ([#40153](https://github.com/anthropics/claude-code/issues/40153)), teammate SendMessage phantom messages ([#40166](https://github.com/anthropics/claude-code/issues/40166)), worktree isolation fails on Windows ([#40164](https://github.com/anthropics/claude-code/issues/40164)).

### Stats
- 195 Rust tests (unchanged)
- Hook tests: bash-guard ~500, safety-check ~146, PS1 hooks 116, file-guard 91, git-safe 65, session-log 50, read-once 48, enforce-hooks ~52, branch-guard 35, worktree-guard 33, format ~36
- Total: ~1670+ tests

## [0.9.0] - 2026-03-28

### Added

#### Windows PowerShell hooks (new)
- **file-guard.ps1** -- Native PowerShell equivalent. No external dependencies (no jq). Supports all features: write protection, [deny] sections, relative path rejection, path normalization, Bash command scanning.
- **git-safe.ps1** -- Native PowerShell equivalent. Blocks all destructive git operations. Supports .git-safe allowlist config. Extra protection for main/master force push.
- **branch-guard.ps1** -- Native PowerShell equivalent. Protected branch enforcement with config file and env var support.
- **session-log.ps1** -- Native PowerShell equivalent. Logs every tool call with timestamp, tool name, detail, exit codes, and error detection. Same JSONL output format as the bash version.

All four hooks use `ConvertFrom-Json`/`ConvertTo-Json` (built into PowerShell) instead of jq. Configure with `"command": "pwsh -File /path/to/hook.ps1"` in settings.json. See [#3](https://github.com/Bande-a-Bonnot/Boucle-framework/issues/3).

#### safety-check
- **Spaces in HOME path warning** -- Detects when `$HOME` contains spaces (e.g., Windows usernames like "Lea Chan"), which breaks all bash hooks due to word-splitting in Claude Code's hook runner ([#40084](https://github.com/anthropics/claude-code/issues/40084)).
- **companyAnnouncements spoofing detection** -- Warns when project-level `.claude/settings.json` contains `companyAnnouncements`, which can spoof enterprise messages ([#39998](https://github.com/anthropics/claude-code/issues/39998)).
- **Plugin hook detection** -- Warns when marketplace plugins include executable hooks installed without consent ([#40036](https://github.com/anthropics/claude-code/issues/40036)).
- **Non-enabled plugin hook detection** -- Warns when disabled marketplace plugins still have hooks that fire ([#40013](https://github.com/anthropics/claude-code/issues/40013)).
- **bypassPermissions settings warning** -- Warns that `bypassPermissions` in settings files is silently ignored ([#40014](https://github.com/anthropics/claude-code/issues/40014)).
- **Path deny bypass warning** -- Warns that `settings.json` path deny rules do not apply to the Bash tool ([#39987](https://github.com/anthropics/claude-code/issues/39987)).
- **Worktree isolation warning** -- Warns about worktree isolation failures ([#39886](https://github.com/anthropics/claude-code/issues/39886)).

#### bash-guard
- **find -exec regression tests** -- 4 tests verifying escaped semicolons are handled correctly, preventing false positives from [#39911](https://github.com/anthropics/claude-code/issues/39911).

### Documented
- **48 known platform limitations** in enforce-hooks README, up from 22 in v0.8.0. New entries cover: marketplace +x stripping ([#39954](https://github.com/anthropics/claude-code/issues/39954), [#39964](https://github.com/anthropics/claude-code/issues/39964), [#40086](https://github.com/anthropics/claude-code/issues/40086)), Stop hooks silent in VSCode ([#40029](https://github.com/anthropics/claude-code/issues/40029)), plugin install adds hooks silently ([#40036](https://github.com/anthropics/claude-code/issues/40036)), SessionEnd skips agent hooks ([#40010](https://github.com/anthropics/claude-code/issues/40010)), SDK Stop hook skip on resume ([#40022](https://github.com/anthropics/claude-code/issues/40022)), Bash bypasses path deny ([#39987](https://github.com/anthropics/claude-code/issues/39987)), subagent trust gap ([#39981](https://github.com/anthropics/claude-code/issues/39981)), companyAnnouncements spoofing ([#39998](https://github.com/anthropics/claude-code/issues/39998)), hooks fail with spaces in HOME ([#40084](https://github.com/anthropics/claude-code/issues/40084)), plugin hook +x cache loss ([#40086](https://github.com/anthropics/claude-code/issues/40086)), and more.

### Stats
- 195 Rust tests (unchanged)
- Hook tests: bash-guard ~500, safety-check ~146, file-guard 91, git-safe 65, session-log 50, read-once 48, enforce-hooks ~52, branch-guard 35, worktree-guard 29, format ~36
- Total: ~1550+ tests

## [0.8.0] - 2026-03-27

### Added

#### worktree-guard (new, 29 tests)
- **New hook** -- Blocks `ExitWorktree` when the worktree has uncommitted changes, untracked files, unmerged branches, or unpushed commits. Prevents data loss from [#38287](https://github.com/anthropics/claude-code/issues/38287).

#### bash-guard (486 -> ~495 tests)
- **git push --force detection** -- Blocks `git push --force`, `git push -f`, and `git push --force-with-lease`. Configurable via `allow: git-force-push`.

#### safety-check (111 -> ~124 tests)
- **7 new platform bug warnings** -- Detects permission pitfalls ([#38375](https://github.com/anthropics/claude-code/issues/38375), [#38372](https://github.com/anthropics/claude-code/issues/38372), [#38391](https://github.com/anthropics/claude-code/issues/38391), [#38409](https://github.com/anthropics/claude-code/issues/38409)), platform bugs ([#39478](https://github.com/anthropics/claude-code/issues/39478), [#39530](https://github.com/anthropics/claude-code/issues/39530), [#39814](https://github.com/anthropics/claude-code/issues/39814)), and exit-code-2 misconfiguration.
- **"ask" permission warning** -- Warns when `permissionDecision: "ask"` is used in hooks, which permanently breaks bypass mode per [#37420](https://github.com/anthropics/claude-code/issues/37420).

### Fixed
- **worktree-guard exit code 2 to 0** -- Exit code 2 is silently ignored for Edit/Write hooks per [#37210](https://github.com/anthropics/claude-code/issues/37210). All hooks now use exit 0 with JSON block decisions.
- **4 CI test suite failures** -- file-guard (relative path test fixtures), bash-guard (force push test ahead of implementation), worktree-guard (missing git config on Ubuntu), safety-check (bare return under set -e, broken pipe with pipefail, path collision in mixed settings test).

### Documented
- Windows compatibility notes and troubleshooting (WSL recommended)
- 22 known platform limitations in enforce-hooks README ([#37420](https://github.com/anthropics/claude-code/issues/37420), [#36205](https://github.com/anthropics/claude-code/issues/36205), [#38448](https://github.com/anthropics/claude-code/issues/38448), and more)
- Exit-code-2 warning in enforce Known Limitations

### Stats
- 195 Rust tests (unchanged)
- Hook tests: bash-guard ~495, safety-check ~124, file-guard 91, git-safe 65, session-log 81, read-once 49, enforce-hooks 41, branch-guard 36, worktree-guard 29
- Total: 1500+ tests

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
