# enforce-hooks

Turn CLAUDE.md rules into PreToolUse hooks that actually block violations.

Claude Code's CLAUDE.md lets you write project rules, but Claude follows them on a best-effort basis. enforce-hooks reads your rules and generates hooks that deterministically block violations before they happen.

## Quick Start

**One command (recommended):**

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/enforce/install.sh | bash
```

This installs enforcement hooks, armor (self-protection), and creates a sensible CLAUDE.md if you don't have one. Works in any git repo.

**Or manually (inspect before installing):**

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/enforce/enforce-hooks.py -o /tmp/enforce-hooks.py
python3 /tmp/enforce-hooks.py --scan             # preview what's enforceable
python3 /tmp/enforce-hooks.py --install-plugin   # install
```

## Why Hooks Instead of Rules

CLAUDE.md rules rely on the model choosing to comply. That breaks down in several specific ways:

1. **Compliance decay**: As conversations grow and context compacts, CLAUDE.md directives lose influence. A "never modify .env" rule works at the start and [stops working later](https://github.com/anthropics/claude-code/issues/37550). Users report rules are "read at session start but systematically violated during execution."
2. **Subagent blindness**: Path-specific rules and some CLAUDE.md sections [don't load in subagents](https://github.com/anthropics/claude-code/issues/32906). Spawned agents [immediately violate rules](https://github.com/anthropics/claude-code/issues/37530) that the parent session respects correctly.
3. **No enforcement boundary**: Rules are suggestions. There is no mechanism to make the model fail when it violates one. It can read "never force push" and still run `git push --force`.
4. **Model regression**: Newer model versions can [degrade compliance](https://github.com/anthropics/claude-code/issues/34358) with rules that previously worked, requiring users to re-engineer their CLAUDE.md for each update.

PreToolUse hooks solve all three. They run as code before every tool call, they fire in every context (including subagents), and they return a hard block that the model cannot override.

## Design Tradeoff

enforce-hooks is deliberately deterministic. Every hook is a bash script with pattern matching. No LLM in the loop, no API key, no network call after install. Same tool call plus same rules equals the same decision, every time. You can read every generated hook (`cat .claude/hooks/*.sh`) and understand exactly what it blocks.

The tradeoff: hooks have no conversation context. "User asked for a discussion but Claude started coding" has no tool-call signal to match. Rules that require understanding intent need a different approach. enforce-hooks handles structural violations where the tool call itself is the signal.

## How It Works

**Plugin mode** (recommended): One hook enforces all your rules dynamically.

1. Run `enforce-hooks.py --install-plugin`
2. It copies itself into `.claude/hooks/` and registers a PreToolUse hook
3. On every tool call, it reads your CLAUDE.md and blocks violations
4. Change CLAUDE.md and rules update automatically (no re-install needed)

**Per-rule mode**: Generates individual hook scripts for each rule.

1. Run `enforce-hooks.py --install`
2. It generates one bash script per rule in `.claude/hooks/`
3. Re-run when you change CLAUDE.md

No runtime dependencies beyond Python 3.6+ and `jq` (for per-rule mode). Plugin mode needs only Python.

## What's Enforceable

| Your CLAUDE.md rule | Hook type | What it blocks |
|-----------|-----------|----------------|
| "Never modify .env @enforced" | file-guard | Write/Edit to .env |
| "Don't read files in secrets/ @enforced" | file-guard | Read/Write/Edit in secrets/ |
| "Protected files: package-lock.json, yarn.lock @enforced" | file-guard | Listed file patterns (lock files, configs) |
| "Don't force push @enforced" | bash-guard | `push --force`, `push -f` in Bash |
| "Never use --no-verify @enforced" | bash-guard | `--no-verify` flag in any Bash command |
| "Never run rm -rf @enforced" | bash-guard | dangerous command patterns |
| "Use pnpm instead of npm @enforced" | bash-guard | npm commands |
| "Don't commit directly to main @enforced" | branch-guard | git commit/push on main |
| "Don't use WebSearch @enforced" | tool-block | Block tool by name |
| "Always run tests before committing @enforced" | require-prior-tool | Commit without prior test run |
| "Read test file before editing source @enforced" | require-prior-tool | Edit without prior Read |
| "Never write `console.log` @enforced" | content-guard | Edit/Write containing banned pattern |
| "Don't use the `any` type @enforced" | content-guard | Edit/Write containing banned code |
| "Never use inline styles @enforced" | content-guard | Edit/Write containing `style=` |
| "No HEX color codes in CSS @enforced" | content-guard | Edit/Write containing `#[0-9a-fA-F]` |
| "No `!important` @enforced" | content-guard | Edit/Write containing `!important` |
| "Interfaces only in types/ @enforced" | scoped-content-guard | Edit/Write with `interface` outside `types/` |
| "No SQL queries in controllers/ @enforced" | scoped-content-guard | Edit/Write with SQL inside `controllers/` |

Rules like "write clean code" or "be concise" are skipped (subjective, no tool-call signal). The tool explains what it skips and why.

## Example

Given this CLAUDE.md:

```markdown
## Safety Rules @enforced
- Never modify .env files
- Don't run `rm -rf` or `sudo`
- Never commit to main

## Guidelines @enforced(warn)
- Always run tests before committing
- Don't commit to develop

## Code Style
- Use 4-space indentation and snake_case
```

```
$ python3 enforce-hooks.py --scan

Found 5 enforceable directive(s):

  #  Type                  What it does                              Severity  Source line
---  ----                  ---                                       ---       ---
  1  file-guard            Block Write/Edit to: .env                 block     L3
  2  bash-guard            Block commands: rm -rf, sudo              block     L4
  3  branch-guard          Block commits to: main                    block     L5
  4  require-prior-command Run tests before committing               warn      L8
  5  branch-guard          Block commits to: develop                 warn      L9
```

The `@enforced` tag tells enforce-hooks which rules to activate.

**Severity levels:**
- `@enforced` or `@enforced(block)` -- blocks the operation (default)
- `@enforced(warn)` -- prints a warning to stderr but allows the operation

Tag individual rules (`- Never modify .env @enforced(warn)`) or entire sections (`## Guidelines @enforced(warn)`).

### Not sure what's enforceable?

Run `--scan` without any `@enforced` tags. The tool shows suggestions:

```
$ python3 enforce-hooks.py --scan

No enforceable directives found.

Found 5 rule(s) that could be enforced:

  #  Type                  What it would block                       Source line
---  ----                  ---                                       ---
  1  file-guard            Block Write/Edit to: .env                 L4
  2  bash-guard            Block commands: rm -rf, rm -r             L6
  ...

To activate enforcement, add @enforced to each rule:
  - Never modify .env files @enforced
```

## Options

```
enforce-hooks.py [CLAUDE.md] [options]

  --scan              Show enforceable directives (default)
  --generate          Print hook scripts to stdout
  --install           Write per-rule hooks to .claude/hooks/
  --install-plugin    Install as one dynamic hook (recommended)
  --audit             Compare CLAUDE.md rules vs installed hooks
  --audit --strict    CI gate: exit 1 if any @enforced rules lack hooks
  --verify            Health-check installed hooks for correctness
  --verify --strict   CI gate: exit 1 if any hooks have errors
  --smoke-test        Execute hooks with test payloads, verify responses
  --smoke-test --strict  CI gate: exit 1 if any hooks fail at runtime
  --armor             Install self-protection hooks (no CLAUDE.md needed)
  --evaluate          PreToolUse mode: read tool call from stdin, output decision
  --json              Output as JSON (with --scan, --audit, or --verify)
  --hooks-dir         Directory for hooks (default: .claude/hooks)
  --settings          Path to settings.json (default: .claude/settings.json)
  --test              Run self-tests
```

Auto-detects CLAUDE.md in the current or parent directories if no file is specified.

## Plugin Mode vs Per-Rule Mode

| | Plugin mode (`--install-plugin`) | Per-rule mode (`--install`) |
|---|---|---|
| Files installed | 2 (engine + wrapper) | 1 per rule |
| Updates when CLAUDE.md changes | Automatic | Must re-run |
| Dependencies | Python 3.6+ | Python 3.6+ and jq |
| Hook evaluation | Python (cached) | Bash |

## As a Claude Code Skill

Copy `SKILL.md` to `.claude/skills/enforce-hooks/SKILL.md` in your project. Then tell Claude: **"enforce my CLAUDE.md rules"**. Claude reads your CLAUDE.md, shows you what it found, and generates hooks on confirmation.

## Audit Mode

Check whether your CLAUDE.md rules are actually being enforced:

```
$ python3 enforce-hooks.py --audit

enforce-hooks: ACTIVE (plugin mode)
  All @enforced rules are checked on every tool call.

Enforced (4):
  [ok]  file-guard          Block Write/Edit to: .env
  [ok]  bash-guard          Block commands: rm -rf /, rm -rf, rm -r
  [ok]  branch-guard        Block commits to: main
  [ok]  branch-guard        Block commits to: develop [warn]

Could be enforced (2):
  [--]  content-guard       Block writing: style=  (L10)
  [--]  file-guard          Block Write/Edit to: config.json  (L14)
  Add @enforced to activate: "Never modify .env files @enforced"

Coverage: 4/6 classifiable rules enforced (67%)
```

Rules marked `[warn]` print a warning to stderr but allow the operation. Use `@enforced(warn)` for guidelines you want to flag without blocking.

Reports:
- **Enforced** `[ok]`: Rules with active hooks
- **Not enforced** `[!!]`: Rules tagged `@enforced` but missing hooks
- **Could be enforced** `[--]`: Classifiable rules not tagged `@enforced`
- **Broken references** `[XX]`: settings.json entries pointing to missing files

Use `--audit --json` for machine-readable output.

### CI Gate (`--strict`)

Add `--strict` to fail your CI pipeline if any `@enforced` rules are missing hooks:

```sh
python3 enforce-hooks.py --audit --strict
```

Exits 0 if all `@enforced` rules have active hooks. Exits 1 if any are unenforced or if settings.json references missing hook files.

```yaml
# GitHub Actions example
- name: Verify hook enforcement
  run: python3 tools/enforce/enforce-hooks.py --audit --strict
```

## Hook Health Check (`--verify`)

Check installed hooks for correctness issues before they silently fail.

```sh
python3 enforce-hooks.py --verify
```

Example output:
```
Hook Health Check: 4 hook(s) scanned

  [FAIL]  bash-guard.sh
         [ERR ] Uses .input.X instead of .tool_input.X (1 occurrence(s)). Claude Code sends
                tool arguments in tool_input, not input. This hook silently fails open.
                L44: COMMAND=$(echo "$INPUT" | jq -r '.input.command // empty')
         [ERR ] Combines wrong field name with fail-open pattern (1 instance(s)).
  [  OK]  enforce-pretooluse.sh
  [WARN]  my-hook.sh
         [WARN] Not registered in .claude/settings.json. Hook will not fire.
  [  OK]  session-log.sh

Summary: 2 ok, 1 warning(s), 2 error(s)
```

**What it catches:**
- **Wrong field name**: `.input.command` instead of `.tool_input.command` (the most common hook bug; causes silent fail-open)
- **Fail-open on empty values**: Hook reads empty string from wrong field, exits 0, never blocks
- **Not executable**: Missing `chmod +x`
- **No shebang**: Hook may not execute correctly
- **Not registered**: Hook file exists but is not wired into `settings.json`
- **Missing references**: `settings.json` points to files that do not exist
- **No JSON parser**: Shell hook references tool data without using `jq` or `python`

Use `--verify --strict` as a CI gate (exits 1 on errors):

```sh
python3 enforce-hooks.py --verify --strict
```

**Why this exists:** Four of our own hooks shipped with `.input.X` instead of `.tool_input.X` and silently failed open for weeks. They never blocked anything. A user ([chris-peterson](https://github.com/chris-peterson)) found the bug in [PR #2](https://github.com/Bande-a-Bonnot/Boucle-framework/pull/2). This tool catches that class of issue before users get burned.

## Smoke Test (`--smoke-test`)

`--verify` checks hooks statically (file permissions, field names, code patterns). `--smoke-test` goes further: it actually runs each hook with test payloads and checks the output.

```sh
python3 enforce-hooks.py --smoke-test
```

Example output:
```
Smoke Test: 3 hook(s) tested

  [PASS]  enforce-pretooluse.sh  (PreToolUse)
         [  OK] Read a normal file  -> allow
         [  OK] Write to a temp file  -> allow
         [  OK] Run a safe Bash command  -> allow
  [FAIL]  my-custom-hook.sh  (PreToolUse)
         [ ERR] Read a normal file  -- No output (hook is fail-open: empty stdout = allow)
         [ ERR] Write to a temp file  -- No output (hook is fail-open: empty stdout = allow)
         [ ERR] Run a safe Bash command  -- No output (hook is fail-open: empty stdout = allow)
  [PASS]  file-guard-hook.sh  (PreToolUse)
         [  OK] Read a normal file  -> allow
         [  OK] Write to a temp file  -> allow
         [  OK] Run a safe Bash command  -> allow
         [  OK] Write to .env  -> block

Summary: 2 passed, 0 warning(s), 1 failed
```

**What it catches that `--verify` does not:**
- Hooks that crash at runtime (syntax errors, missing dependencies)
- Hooks that produce no output (silent fail-open)
- Hooks that output invalid JSON
- Hooks that block benign operations (false positives)
- Hooks that allow operations they should block (fail-open despite correct code)

Use `--smoke-test --strict` as a CI gate (exits 1 on failures):

```sh
python3 enforce-hooks.py --smoke-test --strict
```

**Why this exists:** Both of our first two external contributors found hooks that passed static analysis but failed at runtime. [Issue #1](https://github.com/Bande-a-Bonnot/Boucle-framework/issues/1) was a format bug, [PR #2](https://github.com/Bande-a-Bonnot/Boucle-framework/pull/2) was a wrong field name. In both cases, `--verify` would have caught them, but `--smoke-test` catches an even broader class: anything that makes a hook fail to respond correctly when actually executed.

## Armor Mode

Protect your hooks from being deleted or modified by Claude itself.

```sh
python3 enforce-hooks.py --armor
```

This installs two self-protection hooks that guard `.claude/hooks/` and `.claude/settings.json`:

- **armor_file_guard.sh**: Blocks Write/Edit/MultiEdit targeting hook files or settings
- **armor_bash_guard.sh**: Blocks `rm`, `mv`, `chmod`, `truncate`, `sed -i`, and similar commands targeting hooks or settings

The hooks protect each other. The file-guard blocks edits to the bash-guard, and the bash-guard blocks deletion of the file-guard. Neither requires a CLAUDE.md.

No CLAUDE.md needed. Works standalone or alongside `--install-plugin`.

**Why this exists:** A Claude Code session [deleted its own PreToolUse hook](https://github.com/anthropics/claude-code/issues/32990) to bypass a constraint it was blocking. With the hook file gone, `settings.json` still referenced it, but all tool calls silently proceeded unblocked. Armor prevents this by making hooks defend themselves.

## Known Limitations

**@-autocomplete bypasses hooks.** When a user types `@.env` in the prompt, Claude Code injects the file content directly into the conversation. No tool call happens, so PreToolUse hooks never fire. A file-guard rule for `.env` blocks `Read .env` and `Edit .env` but cannot block `@.env`. This is a [known gap](https://github.com/anthropics/claude-code/issues/32928) in the hook system. Workaround: use managed-settings.json `denyRead` patterns alongside hooks for defense in depth.

**Windows: hooks run via `/usr/bin/bash` regardless of shell setting.** On Windows, Claude Code [routes all hook commands through `/usr/bin/bash`](https://github.com/anthropics/claude-code/issues/32930) even when a different shell is configured. Bash-based hooks work if Git Bash is installed (it provides `/usr/bin/bash`), but PowerShell hooks are not supported yet.

**Hook deny is not enforced for MCP tool calls.** PreToolUse hooks fire correctly for MCP server tools, but [`permissionDecision: "deny"` is silently ignored](https://github.com/anthropics/claude-code/issues/33106) -- the MCP tool call proceeds anyway. This means hooks cannot block MCP tools. This is a platform bug, not an enforce-hooks limitation. Workaround: block the MCP server name in managed-settings.json `disallowedTools` instead.

**Only `command`-type hooks block tool calls.** Claude Code supports three hook types: `command`, `agent`, and `prompt`. Only `command` actually blocks execution. Agent and prompt hooks [fire but do not prevent the tool call](https://github.com/anthropics/claude-code/issues/33125) and cannot deliver feedback to the model. enforce-hooks generates command-type hooks exclusively. If you write custom hooks, use `"type": "command"` for any hook that needs to enforce rules.

**Silent JSONC parsing failure can disable hooks.** If your `.claude/settings.json` contains invalid JSONC (e.g., commented-out JSON blocks), Claude Code [silently falls back to default settings](https://github.com/anthropics/claude-code/issues/37540) with no hooks or rules loaded. If your hooks suddenly stop firing, check your settings.json syntax first.

**Hooks don't fire in pipe mode (`-p`).** When running Claude Code with `-p` (pipe/print mode), [hooks do not execute](https://github.com/anthropics/claude-code/issues/37559). This means automated testing workflows that use `claude -p "test prompt"` will not trigger PreToolUse hooks. Test hooks in interactive mode.

**PreToolUse hooks can reset permission bypass mode.** When `--dangerously-skip-permissions` is enabled, PreToolUse hooks can [cause the permission state to reset mid-session](https://github.com/anthropics/claude-code/issues/37745), reverting all tools to manual approval after 30 minutes to 2 hours. Disabling hooks is the only workaround. If you use hooks in autonomous mode and find tools suddenly requiring approval, this platform bug is the likely cause.

**Prompt-type hooks fail on Vertex AI.** Hooks configured with `"type": "prompt"` [return a 400 error on Vertex AI backends](https://github.com/anthropics/claude-code/issues/37746) ("output_config: Extra inputs"). enforce-hooks only generates command-type hooks so this does not affect it directly, but custom prompt hooks will silently fail on Vertex.

**Subagents may not inherit hook settings.** Agents spawned via the Agent tool [do not consistently inherit permission settings](https://github.com/anthropics/claude-code/issues/37730) from the parent session. Hooks configured at the project level should still fire for subagents (they share the same `.claude/settings.json`), but global permission preferences may not propagate. Verify hook behavior in subagent workflows.

**Memory paths auto-bypass approval.** File paths under `~/.claude/projects/*/memory/` [auto-bypass Edit/Write approval](https://github.com/anthropics/claude-code/issues/38040) with no opt-out. Claude can modify memory files without the user seeing a prompt. A PreToolUse hook returning `block` for writes to memory paths still works, but you must set it up explicitly. Add memory paths to your file-guard config or enforce-hooks rules if you want protection.

**Built-in skills wrap file operations opaquely.** Claude Code's built-in skills perform Write/Edit internally through the Skill tool wrapper. PreToolUse hooks fire on the `Skill` tool invocation, not on the individual file operations inside it. A hook checking "is this write targeting .env?" won't fire because the tool name is `Skill`, not `Write`. There is no workaround for this yet. See [#38040](https://github.com/anthropics/claude-code/issues/38040).

**Context compaction invalidates stateful hooks.** Hooks that track session state (e.g., "which files has Claude read?") break across [context compaction boundaries](https://github.com/anthropics/claude-code/issues/38018). After compaction, Claude's context no longer contains previously-read files, but hook state still shows them as "recently read." This can cause false gates (blocking a re-read Claude needs) or false passes (allowing an action the hook thinks Claude is informed about). There is no PostCompact hook event yet. Use conservative TTLs for stateful hooks.

**Async hooks receive empty stdin on macOS.** Hooks configured with `"async": true` [receive zero bytes on stdin](https://github.com/anthropics/claude-code/issues/38162) on macOS (works on Linux). Synchronous hooks work correctly on both platforms. enforce-hooks generates synchronous command hooks, so this does not affect it. If you add custom async hooks on macOS, remove the `"async": true` flag as a workaround.

**GIT_INDEX_FILE inherited from git hooks corrupts index.** When Claude Code is [launched from a git hook](https://github.com/anthropics/claude-code/issues/38181) (post-commit, pre-push, etc.), it inherits the `GIT_INDEX_FILE` environment variable. Plugin initialization then writes plugin file entries into the project's git index, silently corrupting it. Workaround: `unset GIT_INDEX_FILE` before invoking Claude from any git hook. This is a platform bug, not an enforce-hooks issue.

**Prompt-type hooks incur undocumented billing.** Hooks with `"type": "prompt"` send an LLM call per invocation, [adding token costs](https://github.com/anthropics/claude-code/issues/38165) that are not documented in the billing docs. enforce-hooks generates only `"type": "command"` hooks, which run as local processes with zero API cost. If you need reasoning-based enforcement, be aware that prompt hooks double your per-response cost.

**`permissionDecision: "ask"` permanently breaks bypass mode.** If a hook returns `{"permissionDecision": "ask"}` (intending to let the user decide), the session [permanently loses bypass mode](https://github.com/anthropics/claude-code/issues/37420) after the user responds to the prompt. The permission state machine does not restore the previous mode. All subsequent tool calls revert to manual approval for the rest of the session. Do not use `permissionDecision: "ask"` in any hook if you run with `--dangerously-skip-permissions` or `bypassPermissions`. Use `"decision": "block"` with a clear reason instead.

**EnterWorktree/ExitWorktree hooks may not fire for mid-session operations.** When Claude uses the Agent tool with `isolation: "worktree"` or the in-session EnterWorktree tool, configured [worktree hooks do not execute](https://github.com/anthropics/claude-code/issues/36205). Hooks that guard worktree creation or cleanup only fire for CLI-level worktree operations, not for mid-session agent-spawned worktrees. There is no workaround. If you use worktree-guard, be aware it protects ExitWorktree from the tool but not from internal session management.

**Background agent worktree can silently change parent session CWD.** After a background Agent with `isolation: "worktree"` completes, the parent session's working directory can [silently drift to the worktree path](https://github.com/anthropics/claude-code/issues/38448). Subsequent commands execute in the wrong directory without warning. No hook can detect this because the CWD change happens outside the tool-call lifecycle. Verify your working directory (`pwd`) after background worktree agents complete.

**Exit code 2 silently disables hooks for Edit/Write tools.** If a hook script exits with code 2, Claude Code [treats it as a crash](https://github.com/anthropics/claude-code/issues/37210). For Bash tool calls, crashed hooks still block. For Edit and Write tools, crashed hooks are silently ignored and the operation proceeds. enforce-hooks generates hooks that always exit 0, so this does not affect generated hooks. But custom hook scripts that use `exit 2` on the deny path will appear to work in Bash tests and silently fail on Edit/Write. Always use `exit 0` with `{"decision":"block","reason":"..."}` JSON on stdout.

**`updatedInput` silently ignored for Agent tool.** PreToolUse hooks can return `updatedInput` to rewrite tool inputs before execution. For most tools this works, but for the Agent tool, the [rewritten input is silently discarded](https://github.com/anthropics/claude-code/issues/39814) and the original prompt is used. Hooks that sanitize or modify subagent prompts will appear to succeed (exit 0, JSON accepted) but have no effect. There is no workaround. Use `"decision": "block"` to reject unsafe Agent prompts instead of trying to rewrite them.

**Stop hooks can block unrelated parallel sessions.** Stop hooks configured with a `session_id` guard intended to scope them to one session [still fire across all parallel sessions](https://github.com/anthropics/claude-code/issues/39530). A stop hook that terminates session A can kill session B if both sessions share the same `.claude/settings.json`. This affects autonomous loop architectures running multiple Claude instances. Workaround: use separate project directories with independent settings for parallel sessions, or make stop hooks check `$CLAUDE_SESSION_ID` explicitly.

**Hooks fail when working directory contains spaces.** If the project path contains spaces (e.g., `/Users/name/My Projects/app/`), hook scripts [fail with parse errors](https://github.com/anthropics/claude-code/issues/39478) because the path is passed unquoted in some internal contexts. All enforce-hooks generated hooks and Boucle-framework hooks quote their paths, but the platform itself may break path delivery. Workaround: avoid spaces in project directory paths.

**`--worktree --tmux` skips hook lifecycle entirely.** When Claude Code is launched with both `--worktree` and `--tmux`, it uses a [separate codepath that creates git worktrees directly](https://github.com/anthropics/claude-code/issues/39281), bypassing WorktreeCreate and WorktreeRemove hooks. Any hooks guarding worktree creation or cleanup will not fire in this mode. Workaround: use `--worktree` without `--tmux`.

**Disabled plugins still execute hooks.** Plugins set to `false` in `enabledPlugins` [still have their hooks executed](https://github.com/anthropics/claude-code/issues/39307) by Claude Code. Stop hooks, PreToolUse hooks, and other plugin-registered hooks fire even when the plugin is explicitly disabled. There is no workaround other than removing the plugin entirely.

**Tool-level hooks cannot prevent API exfiltration.** All tool-level hooks (PreToolUse, PostToolUse) operate after file contents have already entered the conversation context. A Read tool call returns file contents into the model's context, and [PostToolUse cannot modify tool output](https://github.com/anthropics/claude-code/issues/39882), only block. This means secrets in read files (API keys, credentials, PII) are sent to the API provider regardless of PostToolUse hooks. PreToolUse can prevent the Read from happening (file-guard does this), but once a file is read, its contents are in the API payload. For full exfiltration prevention, a PreApiCall hook or local proxy (`ANTHROPIC_BASE_URL`) is needed. See [#39882](https://github.com/anthropics/claude-code/issues/39882) for the feature request.

**Worktree isolation can silently fail for spawned agents.** The Agent tool's `isolation: "worktree"` option can [silently run the agent in the main repository](https://github.com/anthropics/claude-code/issues/39886) instead of creating an isolated worktree. The result metadata shows `worktreePath: done` and `worktreeBranch: undefined`. No hook can detect this because the worktree was never created. Combined with [#36205](https://github.com/anthropics/claude-code/issues/36205) (EnterWorktree ignores hooks) and [#38448](https://github.com/anthropics/claude-code/issues/38448) (CWD drift), worktree isolation has multiple failure modes that hooks cannot address.

**Stop hooks fail after worktree removal.** After a worktree is merged and deleted, stop hooks [fail with ENOENT](https://github.com/anthropics/claude-code/issues/39432) because the session's CWD no longer exists. Node.js reports the error as `/bin/sh` not found rather than the missing CWD. Any cleanup hooks registered for the session will not run.

**Worktree memory resolves to the wrong project directory.** When Claude Code launches from a linked git worktree, it uses `git rev-parse --git-common-dir` to derive the project path, which resolves to the [main worktree's directory](https://github.com/anthropics/claude-code/issues/39920). Both worktrees share the same memory and CLAUDE.md files, causing cross-contamination of project-specific rules. Hooks fire correctly in either worktree, but any `@enforced` rules loaded from the wrong CLAUDE.md may not match the project context. There is no workaround at the hook level; this requires a platform fix.

**Bash permission heuristic misparses escaped semicolons.** Claude Code's built-in bash permission system [misparses `\;` in find -exec](https://github.com/anthropics/claude-code/issues/39911) as a command separator, classifying the redirect suffix (e.g., `2` from `2>/dev/null`) as a standalone command. This does not affect hooks (bash-guard receives the full command string and parses it correctly), but it causes confusing permission prompts for safe find commands. If users report permission prompts for `2` as a command, this is the platform bug.

**Marketplace updates strip execute permissions from .sh hooks.** When a Claude Code plugin is updated through the marketplace, the update process [strips the execute bit from .sh files](https://github.com/anthropics/claude-code/issues/39954). Hook scripts that were `chmod +x` after install silently become non-executable, and Claude Code skips them without warning. This affects any bash-based hook delivered through the marketplace. Workaround: re-run `chmod +x` on your hook scripts after marketplace updates, or use safety-check to detect non-executable hooks.

**Stop hooks that intentionally block display "Hook Error" in the UI.** When a Stop hook returns `{"decision": "block"}` to prevent an action, Claude Code [displays "Hook Error" in the transcript](https://github.com/anthropics/claude-code/issues/39953) instead of showing the block reason. The model reads this label and may abandon the task prematurely, thinking a system error occurred rather than a deliberate enforcement. This is the same underlying issue as the [exit code 3 proposal](https://github.com/anthropics/claude-code/issues/38422), which would let hooks signal intentional blocks distinctly from errors. No workaround. Use PreToolUse hooks for enforcement where possible, since they show block reasons correctly.

**PostToolUse hooks skip some plan-mode transitions.** The PostToolUse event for ExitPlanMode [does not fire](https://github.com/anthropics/claude-code/issues/39950) when a user accepts a plan with "clear context." Hooks that track plan completion or trigger actions after plan acceptance will miss this transition. There is no workaround.

**`claude --test-permission` does not exist for dry-run testing.** There is [no way to unit-test hook configurations](https://github.com/anthropics/claude-code/issues/39971) without actually triggering tool calls. Iterating on hook logic requires live sessions with real tool invocations. Affects anyone developing or debugging custom hooks.

**Marketplace plugin sync strips execute permissions from .sh hooks.** When plugins are synced via the marketplace, hook files are [downloaded as 644 (non-executable)](https://github.com/anthropics/claude-code/issues/39964). Any `.sh` hooks delivered via marketplace plugins need manual `chmod +x` after every sync. Same root cause as [#39954](https://github.com/anthropics/claude-code/issues/39954).

**ExitPlanMode resets permission mode to acceptEdits.** When exiting plan mode, the permission state [resets to acceptEdits](https://github.com/anthropics/claude-code/issues/39973) instead of restoring the previous mode (e.g., `bypassPermissions`). Workflows that enter plan mode then resume with elevated permissions will find permissions unexpectedly downgraded.

**`settings.json` path deny rules do not apply to the Bash tool.** Path deny rules in `.claude/settings.json` only restrict Claude Code's built-in file tools (`Read`, `Write`, `Edit`, `Glob`, `Grep`). The Bash tool [executes commands as the user's OS process](https://github.com/anthropics/claude-code/issues/39987) with no path checking against deny rules. Claude can `cat`, `grep`, or `head` files in denied directories via shell commands, silently bypassing the restriction. Users relying on path deny for security have a false sense of protection. Workaround: use a PreToolUse hook on the Bash tool that checks command strings against denied paths. [bash-guard](../bash-guard/) does this among other protections. For defense in depth, also use OS-level file permissions to deny the user account access.

**Subagent output is trusted without verification by the parent agent.** When Claude spawns subagents via the Agent tool, the parent [treats subagent summaries as ground truth](https://github.com/anthropics/claude-code/issues/39981) without checking claims against actual tool output. Subagents can report inflated counts, phantom operations, or partial searches as exhaustive, and the parent relays these to the user. No hook can intercept the Agent tool's return value or validate subagent claims. This is an architecture-level gap, not a hook limitation.

**Semantic rules are not enforceable.** Rules like "write clean code," "use descriptive variable names," or "keep functions under 20 lines" have no tool-call signal to match against. The tool skips these and explains why during `--scan`.

## Tests

```sh
python3 enforce-hooks.py --test
```

Covers directive classification, hook generation, suggestion discovery, runtime evaluation, content-guard, scoped-content-guard, flag patterns, and cache invalidation.

## License

MIT
