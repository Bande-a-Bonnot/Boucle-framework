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
3. **No enforcement boundary**: Rules are suggestions. There is no mechanism to make the model fail when it violates one. It can read "never force push" and still run `git push --force`. Even prefixing rules with ["ABSOLUTE RULE"](https://github.com/anthropics/claude-code/issues/40284) does not change this — the model treats all CLAUDE.md directives as advisory regardless of emphasis.
4. **Model regression**: Newer model versions can [degrade compliance](https://github.com/anthropics/claude-code/issues/34358) with rules that previously worked, requiring users to re-engineer their CLAUDE.md for each update.
5. **Negative context spiral**: Adding more rules to compensate for violations makes compliance worse, not better. More instructions consume context budget without improving behavior, and can push relevant task context out of the window. Users with [extensive guardrails](https://github.com/anthropics/claude-code/issues/40289) report the model acknowledges rules then violates them in the same response. One user [documented this across 68 sessions](https://github.com/anthropics/claude-code/issues/29795).
6. **Permission prompt bypass**: Even the interactive permission prompt can fail. Users report that after [explicitly selecting "No"](https://github.com/anthropics/claude-code/issues/40302) on a bash command, the model executes the command anyway. The built-in permission UI is another form of model-mediated enforcement, and it breaks in the same ways text rules do.

PreToolUse hooks solve all six. They run as code before every tool call, they fire in every context (including subagents), and they return a hard block that the model cannot override.

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

**Project-level settings can spoof company announcements.** The `companyAnnouncements` field in `.claude/settings.json` is intended for enterprise managed settings, but [project-level settings can set it too](https://github.com/anthropics/claude-code/issues/39998). A malicious repository can include `.claude/settings.json` with fake company messages that appear identical to legitimate enterprise announcements. This is a social engineering vector: the messages display as "Message from [COMPANY]" with no indication they originate from the repo, not the organization. No hook can intercept settings loading. Workaround: safety-check detects `companyAnnouncements` in project-level settings and warns. Always verify `.claude/settings.json` when cloning unfamiliar repos.

**`SessionEnd` silently ignores agent-type hooks.** In `SessionEnd` hook configurations, hooks with `"type": "agent"` are [silently skipped](https://github.com/anthropics/claude-code/issues/40010) while `"type": "command"` hooks in the same block fire correctly. The event itself fires (command hooks prove this), but agent hooks are filtered out during execution. Agent-type hooks work in other events like `Stop`. No workaround for session-end cleanup that requires agent capabilities.

**SDK Stop hook enforcement skips on resumed sessions.** When using the Claude Agent SDK with `--resume` and `--json-schema`, the CLI's built-in StructuredOutput stop hook enforcement [only fires once per session](https://github.com/anthropics/claude-code/issues/40022). On resumed sessions, the internal "already called" flag persists and enforcement is silently skipped, returning `structured_output: null`. Workaround: implement your own Stop hook callback that returns `{"decision": "block"}` when `structured_output` is missing on resumed sessions. Note that `continue: false` terminates the session instead of giving Claude another turn.

**Hooks from non-enabled marketplace plugins still fire.** The hook runner [executes hooks from installed-but-not-enabled marketplace plugins](https://github.com/anthropics/claude-code/issues/40013). Plugins that exist in `~/.claude/plugins/marketplaces/` but are not listed in `enabledPlugins` still have their `SessionStart` hooks loaded and executed. This means non-enabled code runs on every session start without user consent. Related to [#39307](https://github.com/anthropics/claude-code/issues/39307) (disabled plugins run hooks). No workaround short of manually deleting unwanted plugin directories.

**`bypassPermissions` in settings files has no effect.** Setting `"permission-mode": "bypassPermissions"` in `.claude/settings.local.json` is [silently ignored](https://github.com/anthropics/claude-code/issues/40014). The only working method to enable bypass mode is the CLI flag `--dangerously-skip-permissions`. Similarly, `"skipDangerousModePermissionPrompt": true` only suppresses the startup warning without actually enabling bypass, and `"dangerouslySkipPermissions": true` under `"permissions"` is also ignored. Automated workflows that configure bypass mode via settings files will still see permission prompts.

**Stop hooks do not fire in the VSCode extension.** Stop hooks configured in `.claude/settings.json` [do not execute](https://github.com/anthropics/claude-code/issues/40029) when Claude Code runs inside the VSCode extension. The same hooks fire correctly in CLI sessions. Other hook types (`PreToolUse`, `PostToolUse`, `SessionStart`) all work in VSCode. This is a platform gap, not a configuration error. If you rely on Stop hooks for session-end enforcement or cleanup, those protections are silently absent in VSCode. No workaround. Similar to the earlier [Notification hooks VSCode gap](https://github.com/anthropics/claude-code/issues/11156).

**Marketplace plugin install silently adds hooks with no consent prompt.** The `/plugin install` flow does not distinguish between inert skills (markdown prompt files) and plugins that include hooks or scripts. A plugin can ship a `SessionStart` hook that [runs arbitrary commands on every future session](https://github.com/anthropics/claude-code/issues/40036) with no disclosure, no consent prompt, and no visual indicator that executable components were installed. Combined with auto-update (enabled by default for official marketplace), a previously-safe plugin could gain hooks in a later version. The install UI shows no permissions manifest. Workaround: after installing any marketplace plugin, inspect `~/.claude/plugins/marketplaces/` for `hooks.json` files and review their contents. safety-check detects plugin-installed hooks and warns.

**Hooks fail when user profile path contains spaces.** On Windows, usernames like "Lea Chan" create home directories with spaces (e.g., `C:\Users\Lea Chan\`). Hook commands that reference `$HOME` or `${CLAUDE_PLUGIN_ROOT}` get [word-split by bash](https://github.com/anthropics/claude-code/issues/40084) at the space, producing `bash: /c/Users/Lea: No such file or directory`. This affects ALL hooks, not just enforce-hooks. The root cause is in Claude Code's hook runner, which does not properly quote expanded paths before passing them to `bash -c`. Workarounds: create a symlink from a space-free path to your home directory and update hook command paths, or use PowerShell hooks (`.ps1`) on Windows which handle spaces natively. safety-check detects spaces in `$HOME` and warns. Related to [#39478](https://github.com/anthropics/claude-code/issues/39478) (spaces in working directory).

**Plugin hook scripts lose execute permissions when cached.** Plugin hooks (e.g., `stop-hook.sh`) [lose their execute bit](https://github.com/anthropics/claude-code/issues/40086) when cached by the marketplace plugin system. Same root cause as [#39954](https://github.com/anthropics/claude-code/issues/39954) (marketplace strips +x) and [#39964](https://github.com/anthropics/claude-code/issues/39964) (sync strips +x), but the trigger is the caching layer rather than explicit update or sync. Stop hooks are particularly affected because they are only invoked at session end, so the permission loss goes unnoticed until a critical moment. Workaround: re-run `chmod +x` on plugin hook scripts after any marketplace operation, or use safety-check to detect non-executable hooks.

**Hook input lacks agent context for tool calls.** The `agent_id` and `agent_type` fields are only available in `SubagentStart`/`SubagentStop` hook events. They are [absent from PreToolUse and PostToolUse input](https://github.com/anthropics/claude-code/issues/40140). A hook cannot tell whether a tool call originates from the main conversation or a subagent. This means per-agent policies (e.g., "only subagents may Edit files") are impossible to enforce. No workaround at the hook level; this requires a platform change to add `agent_id` to the common hook input schema.

**ExitWorktree false positive after squash merge.** The platform's ExitWorktree tool checks unmerged commits using SHA comparison (`git log main..branch`). After a squash merge, the original SHAs are not on main (the squash creates a new SHA), so ExitWorktree [falsely warns about unmerged commits](https://github.com/anthropics/claude-code/issues/40137). worktree-guard solves this by using `git cherry` for content-equivalent detection instead of SHA comparison. But the platform's own ExitWorktree warning (separate from our hook) still shows the false positive.

**Runtime silently deletes specific directory names.** Claude Code's runtime [silently deletes `.kiro/` directories](https://github.com/anthropics/claude-code/issues/40139) between tool calls, regardless of `.gitignore` status. The deletion is name-specific (renaming to `.sd/` avoids it) and happens outside the hook lifecycle. No PreToolUse or PostToolUse event fires for this. File-guard cannot protect directories that the runtime itself removes. If you need persistent project directories, avoid names that conflict with IDE integrations (`.kiro`, `.cursor`, etc.).

**Failed marketplace auto-update deletes all plugins from that marketplace.** The plugin system's marketplace auto-update mechanism [deletes the marketplace directory before re-cloning](https://github.com/anthropics/claude-code/issues/40153). If the re-clone fails (network timeout, rate limit, disk full), the directory stays deleted and all plugins installed from that marketplace break. This includes any hooks those plugins shipped. The deletion happens outside the hook lifecycle, so no hook can prevent or detect it. Workaround: back up `~/.claude/plugins/marketplaces/` before relying on marketplace plugins for critical hooks. Consider vendoring important plugin hooks into your project's `.claude/settings.json` instead of depending on marketplace delivery.

**Teammate SendMessage content injected as Human: turns.** In multi-agent setups using `TeamCreate` and `SendMessage`, teammate summaries can [appear as `Human:` turns in the conversation](https://github.com/anthropics/claude-code/issues/40166). The orchestrator agent treats these phantom messages as legitimate user input and acts on them. No hook can intercept this because it happens in conversation turn management, not in tool calls. This is a trust boundary violation in long sessions with frequent context compression and 529 (overloaded) errors. Workaround: use canary-word protocols to detect phantom messages, and verify unexpected "user" messages before acting on them.

**Worktree isolation fails on Windows due to path resolution.** The Agent tool's `isolation: "worktree"` option [falsely reports "not in a git repository"](https://github.com/anthropics/claude-code/issues/40164) on Windows 11 when using Git Bash. The spawned subprocess resolves the working directory differently (POSIX vs Windows paths), causing the git repo check to fail. The agent falls back to running without isolation. Related to [#39886](https://github.com/anthropics/claude-code/issues/39886) (worktree isolation silently fails). No workaround at the hook level. Windows users relying on worktree isolation for agent sandboxing get no isolation.

**Marketplace plugin hooks hardcode `python3` on Windows.** The `security-guidance` marketplace plugin (and potentially others) [hardcodes `python3`](https://github.com/anthropics/claude-code/issues/40172) in its hook command. On Windows, `python3` does not exist as a command (Python installs as `python` or `py`). Every Edit, Write, and MultiEdit operation fails with a hook error. This is a plugin authoring bug, not a platform bug, but it affects any Windows user who installs marketplace plugins with Python-based hooks. Workaround: edit the plugin's hook command in `~/.claude/plugins/marketplaces/` to use `python` or `py` instead. Our hooks avoid this by shipping native PowerShell (`.ps1`) equivalents for Windows.

**Permission path matching is case-sensitive on Windows.** The `allow` and `deny` rules in `settings.json` use [case-sensitive string matching](https://github.com/anthropics/claude-code/issues/40170) for file paths, even on Windows (NTFS) where the filesystem is case-insensitive. A rule allowing `Edit(C:\Users\alice\project\*)` will not match `C:\Users\Alice\Project\file.txt`. This creates silent permission bypass on Windows: the model may access paths that visually match a deny rule but differ in casing. No workaround at the hook level. safety-check detects Windows and warns about this. Related to [#40084](https://github.com/anthropics/claude-code/issues/40084) (spaces in paths) and [#40172](https://github.com/anthropics/claude-code/issues/40172) (hardcoded python3).

**Sandbox `allowedDomains` does not filter plain HTTP requests.** The `sandbox.network.allowedDomains` setting only intercepts HTTPS traffic via the CONNECT tunnel. Plain HTTP requests (e.g., `curl http://unauthorized-domain.com`) [pass through unfiltered](https://github.com/anthropics/claude-code/issues/40213) because the proxy sees the Host header but does not enforce domain rules on non-CONNECT requests. This is a security gap: prompt injection payloads can exfiltrate data over plain HTTP even when `allowedDomains` is configured. The SOCKS proxy correctly blocks both HTTP and HTTPS. Workaround: use bash-guard to detect outbound HTTP requests to non-allowed domains, or configure OS-level firewall rules. safety-check warns when `allowedDomains` is configured.

**Memory index appends at bottom but truncates from bottom — newest entries lost first.** Claude Code's auto-memory system appends new entries to the bottom of MEMORY.md, but [truncates from the bottom](https://github.com/anthropics/claude-code/issues/40210) after 200 lines. This means as memory grows, the most recently learned information is lost first while stale entries persist. Not hookable — this is internal to the memory subsystem. Affects any long-running agent relying on built-in memory. Workaround: manage your own memory file (like HOT.md) and structure it with newest-first ordering, or periodically consolidate the memory index.

**Claude Code sends SIGTERM to all healthy stdio MCP servers after 10-60s.** After successful connection and handshake, Claude Code [terminates all stdio-based MCP servers simultaneously](https://github.com/anthropics/claude-code/issues/40207) with no preceding error. The timeout interval shrinks over the session lifetime (60s → 30s → 10s). Cloud-hosted MCPs are unaffected (different transport). The only recovery is manual `/mcp` reconnection, which itself gets killed again. Not hookable — the kill signal originates from the runtime, not from a tool call. Affects anyone running local MCP servers.

**Agent tool `model` parameter overrides user's default model without consent.** When a user sets their model to Opus via `/model`, the Agent tool can still [spawn subagents with cheaper models](https://github.com/anthropics/claude-code/issues/40211) by passing `model: "sonnet"` or `model: "haiku"`. The user sees no indication that work was delegated to a different model. Not hookable — the `SubagentStart` event does not include the model parameter, and PreToolUse for the Agent tool fires before the model is resolved. CLAUDE.md rules like "use Opus exclusively" are ignored for subagent spawning.

**Concurrent sessions corrupt shared config files.** Multiple Claude Code sessions writing to `~/.claude.json` simultaneously can [trigger a race condition](https://github.com/anthropics/claude-code/issues/40226) where one session reads a partially-written file, gets a JSON parse error, and enters a recovery loop that overwrites the other session's changes. The corrupted state persists until manual intervention. Not hookable — the corruption happens in the config serialization layer, not in tool calls. Affects anyone running parallel Claude Code sessions (autonomous agents, CI pipelines, multi-project workflows). Workaround: avoid running concurrent Claude sessions that share the same `~/.claude.json`, or use separate `$HOME` directories per session.

**iMessage permission relay sent to unrelated contacts.** When using the iMessage channel plugin, permission relay prompts meant for one conversation can be [sent to an unrelated contact](https://github.com/anthropics/claude-code/issues/40221) in the user's address book. This leaks internal tool-call details (file paths, command strings) to third parties without user consent. Not hookable — the relay happens in the iMessage transport layer. SECURITY: if you use iMessage as a permission relay channel, verify the recipient before enabling it.

**`additionalContext` from hooks accumulates in conversation history.** When a PreToolUse or UserPromptSubmit hook returns `additionalContext`, the injected text is [appended permanently to the conversation](https://github.com/anthropics/claude-code/issues/40216) instead of being treated as ephemeral. Each tool call adds another copy, causing the context to grow unboundedly and waste tokens. Affects hook authors who use `additionalContext` for tips, warnings, or contextual guidance — the guidance is correct the first time but pollutes the conversation on subsequent calls. No workaround at the hook level. Keep `additionalContext` short and consider rate-limiting how often your hook returns it.

**`--dangerously-skip-permissions` does not propagate to subagents.** When the parent session runs with `--dangerously-skip-permissions`, subagents spawned via the Agent tool [still prompt on every Edit/Write call](https://github.com/anthropics/claude-code/issues/40241). Fourteen edits across eight files produced fourteen manual prompts. The bypass flag only applies to the parent session's permission state. A PreToolUse hook returning `{"allow": true}` would suppress the prompts, but it applies globally to all users of that hook configuration, not just bypass-mode sessions. Hooks cannot inspect the parent session's permission mode to conditionally allow. This compounds with [#37730](https://github.com/anthropics/claude-code/issues/37730) (subagents don't inherit permission settings) and [#40211](https://github.com/anthropics/claude-code/issues/40211) (model override without consent). Autonomous pipelines that spawn subagents for write-heavy tasks will stall on permission prompts.

**Hook stdout corrupts worktree paths when spawning isolated agents.** When the Agent tool creates a worktree with `isolation: "worktree"`, hook stdout JSON is [concatenated into the worktree path](https://github.com/anthropics/claude-code/issues/40262) instead of being consumed by the hook protocol. A hook returning `{"continue":true,"suppressOutput":true}` produces paths like `/project/{"continue":true}/{"continue":true}`. This affects ALL hooks that output JSON on stdout (i.e., every correctly implemented hook). The error is `Path "..." does not exist`. Not hookable — the path construction happens before the worktree is created. This means hooks and worktree isolation are currently incompatible on affected versions (confirmed on v2.1.86). Workaround: disable hooks before spawning worktree agents, or avoid `isolation: "worktree"` when hooks are active.

**`symlinkDirectories` causes silent worktree cleanup failure.** When `worktree.symlinkDirectories` is configured in settings (e.g., to symlink `node_modules`), automatic worktree cleanup on session exit [silently fails](https://github.com/anthropics/claude-code/issues/40259) because `git worktree remove` refuses to remove a directory containing untracked files (the symlinks). Worktrees accumulate over time. Not hookable — the cleanup happens in the runtime. Workaround: use a `WorktreeRemove` hook that calls `git worktree remove --force`, or manually prune stale worktrees with `git worktree prune`.

**Active session termination does not invalidate remote browser sessions.** When a Claude Code session is terminated (via Stop, session end, or crash), [remote browser sessions remain active](https://github.com/anthropics/claude-code/issues/40271). An attacker with access to the browser session URL can continue issuing commands after the user believes the session is closed. SECURITY: this is a trust boundary violation for any workflow that exposes Claude Code via browser-based access (Cowork, remote sessions). Not hookable — session lifecycle events fire locally, not on the remote browser. Workaround: manually close browser tabs after terminating sessions.

**Plugin update loses execute permissions on .sh hook files (additional instance).** Plugin updates through the marketplace [strip the execute bit from `.sh` files](https://github.com/anthropics/claude-code/issues/40280), the same root cause as [#39954](https://github.com/anthropics/claude-code/issues/39954), [#39964](https://github.com/anthropics/claude-code/issues/39964), and [#40086](https://github.com/anthropics/claude-code/issues/40086). Each report confirms the issue persists. Workaround: re-run `chmod +x` after updates, or use safety-check to detect non-executable hooks.

**Deterministic gates can become substitute goals (Goodhart's Law).** When hooks enforce rules deterministically, the model can [shift optimization](https://github.com/anthropics/claude-code/issues/40289) from "fulfill the task correctly" to "pass the gates measurably." Gates give unambiguous pass/fail feedback while the actual task goal is ambiguous, so the model targets what it can measure. This means adding more gates can make task completion worse by redirecting the model's attention toward gate-passing rather than task understanding. There is no technical workaround. Be selective: enforce safety boundaries (file protection, dangerous commands) where the tool call is the signal, not workflow preferences where intent matters more than action.

**Model executes commands after user selects "No" at permission prompt.** When the permission prompt fires for a Bash command and the user [explicitly denies it](https://github.com/anthropics/claude-code/issues/40302), the model can proceed to execute the command anyway. The permission prompt is model-mediated UI, not an execution gate. It suffers the same compliance failures as CLAUDE.md rules: the model observes the denial, then ignores it. PreToolUse hooks enforce at the process level before the command reaches execution, making them the only reliable denial mechanism. This is the strongest evidence that hook-based enforcement is necessary even when the built-in permission system appears to be working.

**Windows: bash non-functional inside auto-created worktrees.** When Claude Code auto-creates a git worktree on Windows (via `isolation: "worktree"`), [bash commands fail](https://github.com/anthropics/claude-code/issues/40307) because the spawned process resolves the working directory using POSIX-style paths that do not exist on Windows. The worktree is created but all Bash tool calls within it fail immediately. Combined with [#40164](https://github.com/anthropics/claude-code/issues/40164) (Windows worktree path resolution) and [#39886](https://github.com/anthropics/claude-code/issues/39886) (worktree isolation silently fails), Windows worktree support has three independent failure modes. Not hookable — the path resolution happens in the runtime before hooks fire.

**`--dangerously-skip-permissions` partially broken: startup suppressed, runtime prompts still fire.** The `--dangerously-skip-permissions` flag [suppresses the startup dialog](https://github.com/anthropics/claude-code/issues/40328) (via `skipDangerousModePermissionPrompt: true`) but does not bypass runtime tool execution prompts. Bash commands not in the explicit allow list still trigger per-tool confirmation prompts, making the flag functionally equivalent to normal permission mode. This compounds with [#37745](https://github.com/anthropics/claude-code/issues/37745) (hooks can reset bypass mode) and [#40241](https://github.com/anthropics/claude-code/issues/40241) (bypass does not propagate to subagents). Autonomous pipelines that depend on `--dangerously-skip-permissions` for unattended execution will stall on prompts. PreToolUse hooks returning `{"allow": true}` are the only reliable way to suppress prompts for specific tool patterns.

**Sandbox desync: writes hit real filesystem while reads are sandboxed.** Claude Code can enter a half-sandboxed state where [file writes go through to the real filesystem but file reads are isolated](https://github.com/anthropics/claude-code/issues/40321). In this state, the model writes files, then cannot see them on read-back, so it recreates them, overwriting the real directory. One user lost an entire 2500-file Next.js project including `.git`, all source code, and `.env` files. The model did not detect the inconsistency. Not hookable — the sandbox layer operates below the tool-call level. Hooks cannot detect or prevent sandbox desync. This is a platform-level failure mode that no amount of CLAUDE.md rules or hook configuration can mitigate. Defense in depth: use version control (so `.git` can be re-cloned) and keep `.env` files backed up externally.

**Plan mode enforced by instruction only, not by tool execution layer.** Plan mode's "MUST NOT make any edits" constraint is [enforced only at the system prompt level](https://github.com/anthropics/claude-code/issues/40324). If the model ignores the instruction and issues Edit/Write/Bash tool calls, the user's per-tool approval prompt executes them without any warning that plan mode is active. There is no tool-layer enforcement of plan mode. This is another instance of text-based rules failing at the enforcement boundary: the model reads "do not edit" and edits anyway, and the permission system does not know about plan mode state. A PreToolUse hook could block Edit/Write during plan mode, but there is currently no way for hooks to inspect the session's plan mode state.

**Permission allowlist glob wildcards match shell operators, enabling command injection.** The `*` wildcard in permission allow rules (e.g., `Bash(git -C * status)`) is matched against the raw command string without parsing shell structure. Because `*` matches operators like `&&`, `;`, `||`, and `|`, any allow rule containing `*` [silently permits arbitrary command chains](https://github.com/anthropics/claude-code/issues/40344). For example, `Bash(git -C * status)` also matches `git -C /repo && rm -rf / && git status`. Every allow rule with `*` is an injection vector. There is no safe way to use glob wildcards in Bash allow rules. Use a PreToolUse hook (like bash-guard) to parse commands structurally and validate each sub-command independently. See [#40344](https://github.com/anthropics/claude-code/issues/40344).

**`bypassPermissions` on agents ignores project-level allowlists entirely.** When spawning sub-agents with `mode: bypassPermissions`, they can [execute any tool regardless of the project's `settings.local.json` allowlist](https://github.com/anthropics/claude-code/issues/40343). Write, Edit, git commands, rm, mkdir all execute with no permission check. The allowlist represents a security boundary that `bypassPermissions` completely overrides rather than just suppressing per-tool prompts. PreToolUse hooks still fire in bypassed agent sessions and are the only reliable enforcement layer. See [#40343](https://github.com/anthropics/claude-code/issues/40343).

**Parallel Bash tool writes can silently lose files.** When multiple Bash tool calls run in parallel and write to the same directory, [files can silently disappear](https://github.com/anthropics/claude-code/issues/40341) due to race conditions in the runtime's file handling. Not hookable, as the data loss happens in the parallel execution layer between tool calls. Workaround: avoid parallel Bash tool calls that write to the same directory. See [#40341](https://github.com/anthropics/claude-code/issues/40341).

**Compaction race condition can destroy entire conversation.** If a rate limit error occurs while Claude Code is [compacting the conversation](https://github.com/anthropics/claude-code/issues/40352) (summarizing to reduce context size), the old context is replaced before the new summary is confirmed. A failure mid-compaction leaves the conversation empty. Not hookable — compaction is internal to the runtime. Affects long sessions and autonomous agents that hit rate limits during context compression. Workaround: keep conversation state in external files (like HOT.md) rather than relying on conversation history as the source of truth.

**Desktop app: Bash tool file writes silently revert.** In the Claude Code desktop app, file writes made via the Bash tool can [silently revert](https://github.com/anthropics/claude-code/issues/40349) even when commands are executed sequentially. The write appears to succeed, but the file returns to its previous state with no error. Not hookable — the revert happens in the desktop app's file synchronization layer, not in tool calls. Affects desktop app users writing files through shell commands. Workaround: verify writes with a follow-up read, or use the Write tool instead of Bash for file creation.

**Agent bash shells source user `.bashrc`/`.bash_profile`.** Bash shells spawned by the Agent tool [source the user's shell profile](https://github.com/anthropics/claude-code/issues/40354), inheriting aliases, functions, PATH modifications, and environment variables. A `.bashrc` that aliases `rm` to `rm -i` or `git` to a wrapper function changes the behavior of every Bash tool call without the model's knowledge. SECURITY: a malicious `.bashrc` (e.g., from a compromised dotfiles repo) could intercept credentials, redirect commands, or inject code into the agent's execution environment. Not directly hookable — the profile sourcing happens before the hook's command is evaluated. Hooks that parse command strings (like bash-guard) see the original command, not the aliased expansion. Workaround: use `command` prefix (e.g., `command git status`) in hooks to bypass aliases, or set `--norc --noprofile` in bash invocations.

**Semantic rules are not enforceable.** Rules like "write clean code," "use descriptive variable names," or "keep functions under 20 lines" have no tool-call signal to match against. The tool skips these and explains why during `--scan`.

## Tests

```sh
python3 enforce-hooks.py --test
```

Covers directive classification, hook generation, suggestion discovery, runtime evaluation, content-guard, scoped-content-guard, flag patterns, and cache invalidation.

## License

MIT
