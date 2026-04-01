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
2. **Subagent blindness**: Path-specific rules and some CLAUDE.md sections [don't load in subagents](https://github.com/anthropics/claude-code/issues/32906). Since v2.1.84, subagents are spawned with [`omitClaudeMd: true`](https://github.com/anthropics/claude-code/issues/40459), explicitly stripping CLAUDE.md from their context entirely. Spawned agents [immediately violate rules](https://github.com/anthropics/claude-code/issues/37530) that the parent session respects correctly.
3. **No enforcement boundary**: Rules are suggestions. There is no mechanism to make the model fail when it violates one. It can read "never force push" and still run `git push --force`. Even prefixing rules with ["ABSOLUTE RULE"](https://github.com/anthropics/claude-code/issues/40284) does not change this — the model treats all CLAUDE.md directives as advisory regardless of emphasis.
4. **Model regression**: Newer model versions can [degrade compliance](https://github.com/anthropics/claude-code/issues/34358) with rules that previously worked, requiring users to re-engineer their CLAUDE.md for each update.
5. **Negative context spiral**: Adding more rules to compensate for violations makes compliance worse, not better. More instructions consume context budget without improving behavior, and can push relevant task context out of the window. Users with [extensive guardrails](https://github.com/anthropics/claude-code/issues/40289) report the model acknowledges rules then violates them in the same response. One user [documented this across 68 sessions](https://github.com/anthropics/claude-code/issues/29795).
6. **Permission prompt bypass**: Even the interactive permission prompt can fail. Users report that after [explicitly selecting "No"](https://github.com/anthropics/claude-code/issues/40302) on a bash command, the model executes the command anyway. The built-in permission UI is another form of model-mediated enforcement, and it breaks in the same ways text rules do.

PreToolUse hooks solve all six in the parent session. They run as code before every tool call, they return a hard block that the model cannot override, and they fire deterministically regardless of prompt content. In subagents, hooks still fire but [exit codes may be silently ignored](https://github.com/anthropics/claude-code/issues/40580) — see Known Limitations.

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

## Common Problems This Solves

People hit the same enforcement gaps repeatedly. Here is what each looks like and what fixes it.

| Problem | What happens | Fix |
|---------|-------------|-----|
| Rules ignored after long conversation | CLAUDE.md directives lose influence as context compacts ([#37550](https://github.com/anthropics/claude-code/issues/37550), [#41217](https://github.com/anthropics/claude-code/issues/41217)) | `@enforced` hooks are stateless. They fire on every tool call regardless of conversation length. |
| Model uses wrong tool despite explicit instruction | User says "use X" but a hook or the model picks Y instead ([#41222](https://github.com/anthropics/claude-code/issues/41222)) | `tool-block` the unwanted tools. The model cannot call a blocked tool. See [Tool preference](#tool-preference) recipe. |
| Force push / --no-verify despite rules | Git safety rules in CLAUDE.md are narrated then violated ([#40695](https://github.com/anthropics/claude-code/issues/40695), [#33097](https://github.com/anthropics/claude-code/issues/33097)) | `bash-guard` blocks the command pattern before execution. |
| Subagents ignore all rules | Spawned agents run with `omitClaudeMd: true` since v2.1.84 ([#40459](https://github.com/anthropics/claude-code/issues/40459), [#32906](https://github.com/anthropics/claude-code/issues/32906)) | Hooks fire in subagents even when CLAUDE.md is stripped. |
| Model edits protected files | "Never modify .env" works initially, then stops ([#32163](https://github.com/anthropics/claude-code/issues/32163)) | `file-guard` blocks Write/Edit to matched paths. |
| "ABSOLUTE RULE" still violated | Emphasis markers do not change compliance ([#40284](https://github.com/anthropics/claude-code/issues/40284), [#40289](https://github.com/anthropics/claude-code/issues/40289)) | Hooks block at runtime. The model never sees the tool call succeed. |
| Model attests compliance then violates | 4 attestations followed by immediate violation ([#41217](https://github.com/anthropics/claude-code/issues/41217)) | Hooks do not rely on model cooperation. Block is enforced by Claude Code, not by the model. |
| Read-only session ignored | "Only analyze, don't modify" leads to ALTER TABLE on staging ([#41063](https://github.com/anthropics/claude-code/issues/41063)) | `tool-block` Write/Edit/MultiEdit + `bash-guard` for destructive commands. See [Read-only](#read-only--audit-mode) recipe. |
| Permission prompt bypassed | User clicks "No" but command executes anyway ([#40302](https://github.com/anthropics/claude-code/issues/40302)) | PreToolUse hooks fire before the permission prompt. A hook block prevents the tool call entirely. |
| Skill/workflow overrides CLAUDE.md rules | Skill says "commit the plan" but CLAUDE.md says "never commit plans" — model follows the skill ([#41437](https://github.com/anthropics/claude-code/issues/41437)) | `file-guard` + `bash-guard` block the file writes and git commands regardless of skill instructions. See [Protect CLAUDE.md rules from skill overrides](#protect-claudemd-rules-from-skill-overrides) recipe. |
| Startup reads skipped under context pressure | MEMORY.md/project.md reading order followed at 10% context, skipped at 80%+ ([#41473](https://github.com/anthropics/claude-code/issues/41473), [#40489](https://github.com/anthropics/claude-code/issues/40489)) | `require-prior-read-file` blocks Edit/Write until the specified file appears in the session log. See [Startup reading order](#startup-reading-order) recipe. |
| Plan-mode violated — writes and pushes despite read-only | Model writes code and pushes to git while in plan-mode ([#41517](https://github.com/anthropics/claude-code/issues/41517), [#40324](https://github.com/anthropics/claude-code/issues/40324), [#41758](https://github.com/anthropics/claude-code/issues/41758)) | `tool-block` Write/Edit/MultiEdit + `bash-guard` for git push/commit. Plan-mode is instruction-only, not enforced at tool layer. Worse when bypass permissions is configured ([#41758](https://github.com/anthropics/claude-code/issues/41758)). See [Read-only](#read-only--audit-mode) recipe. |
| Deny rule bypassed via pipe or `&&` | `Bash(rm *)` deny rule is bypassed by `find / \| xargs rm` or `echo ok && rm -rf /` ([#41559](https://github.com/anthropics/claude-code/issues/41559)) | `bash-guard` parses each pipe segment and compound chain independently. Deny rules only match the full string; hooks parse the parts. |
| All hooks silently disabled | `CLAUDE_CODE_SIMPLE` env var, `IS_DEMO=1`, or `--bare` flag silently disables every hook, MCP tool, and CLAUDE.md loading | `safety-check` warns when env vars are detected. For `--bare`/`-p`, use OS-level controls instead of hooks. |
| Automated session stalls on `~/.claude/` write | Edit/Write to `~/.claude/` triggers hardcoded prompt that `bypassPermissions`, `permissions.allow`, and hooks cannot suppress ([#41615](https://github.com/anthropics/claude-code/issues/41615)) | Use Bash tool (`echo`, `cat`, `jq`) to write config files directly instead of Edit/Write. |
| `claude -w` hangs with WorktreeCreate hooks | Any `WorktreeCreate` hook causes indefinite hang regardless of hook content ([#41614](https://github.com/anthropics/claude-code/issues/41614)) | Remove all `WorktreeCreate` hooks if you need `claude -w`. |
| CLAUDE.md prohibition ignored by fallback logic | Explicit "never fall back" directive in CLAUDE.md is overridden by built-in fallback behavior ([#41957](https://github.com/anthropics/claude-code/issues/41957)) | `bash-guard` or `file-guard` blocks the fallback action at tool level. CLAUDE.md directives cannot override built-in fallback logic; hooks can. |
| Memory files read but not applied in long sessions | Files in `~/.claude/projects/.../memory/` are loaded into context but instructions drift as the session extends ([#41951](https://github.com/anthropics/claude-code/issues/41951)) | Hooks enforce rules regardless of context length. For critical rules, use `file-guard` or `bash-guard` instead of relying on memory file instructions alone. |

## Recipes

Copy-paste CLAUDE.md snippets for common scenarios. Each block is self-contained; combine as needed.

### Safety baseline

The minimum for any project. Prevents the operations that cause the most damage in Claude Code sessions.

```markdown
## Safety @enforced
- Never force push
- Never use --no-verify
- Never run rm -rf
- Never run sudo
- Never modify .env files
- Don't commit directly to main
```

### React / TypeScript

```markdown
## Code Quality @enforced
- Never write console.log
- Never use inline styles
- No `!important` in CSS

## Code Quality @enforced(warn)
- Interfaces only in types/
```

### Python

```markdown
## Code Quality @enforced
- No eval() calls
- No SQL queries in views/

## Safety @enforced
- Never modify .env files
- Don't read files in secrets/
```

### Node.js API

```markdown
## Safety @enforced
- Never modify .env files
- Protected files: package-lock.json @enforced
- No SQL queries in controllers/

## Workflow @enforced(warn)
- Always run tests before committing
- Don't commit directly to main
```

### Read-only / audit mode

For sessions where Claude should analyze, test, and report without modifying anything. Addresses [#41063](https://github.com/anthropics/claude-code/issues/41063) (Claude ignores explicit read-only instructions and edits code, runs ALTER TABLE on staging, rebuilds Docker services).

```markdown
## Read-only mode @enforced
- Never modify any files
- Never run rm -rf
- Never run ALTER, DROP, TRUNCATE, INSERT, UPDATE, or DELETE
- Never run docker restart, docker stop, docker build, or docker rm
- Never run sudo
- Never run git commit, git push, or git merge
```

CLAUDE.md instructions alone will not prevent violations ([#41063](https://github.com/anthropics/claude-code/issues/41063), [#40537](https://github.com/anthropics/claude-code/issues/40537), [#40867](https://github.com/anthropics/claude-code/issues/40867)). Run `enforce-hooks.py --install-plugin` to convert these into PreToolUse hooks that hard-block at the runtime level. The model cannot bypass a hook block. For additional protection, install bash-guard (`install.sh recommended`) which catches destructive commands even when they are wrapped in compound shell expressions.

### Cost control

For sessions where token spend matters. These rules have no direct hook signal, but the file-guard and bash-guard rules limit the scope of what Claude can touch, reducing runaway sessions.

```markdown
## Boundaries @enforced
- Protected files: package-lock.json, yarn.lock
- Don't read files in node_modules/
- Don't read files in dist/
- Never modify .git/

## Boundaries @enforced(warn)
- Don't commit directly to main
```

### Git workflow

Enforces git hygiene that CLAUDE.md alone cannot. Addresses [#40695](https://github.com/anthropics/claude-code/issues/40695) (Claude ignores CLAUDE.md git rules, amends without asking, force pushes).

```markdown
## Git workflow @enforced
- Never force push
- Never use --no-verify
- Don't commit directly to main
- Never use git reset --hard
```

### Device / system safety

For environments where Claude has access to system commands. Addresses [#40537](https://github.com/anthropics/claude-code/issues/40537) (Claude executed IoT commands despite explicit CLAUDE.md rules against it).

```markdown
## Device safety @enforced
- Never run shutdown
- Never run reboot
- Never run halt
- Never run systemctl stop
- Never run systemctl restart
```

### Tool preference

Force the model to use a specific tool by blocking alternatives. Addresses [#41222](https://github.com/anthropics/claude-code/issues/41222) (model follows hook redirect instead of explicit user instruction to use a specific tool).

```markdown
## Tool preferences @enforced
- Don't use WebSearch, use XURL instead @enforced
- Don't use WebFetch @enforced
```

The block message includes your rule text, so the model sees "Tool WebSearch is blocked. (CLAUDE.md: Don't use WebSearch, use XURL instead)" and knows what to use. This is deterministic: the model cannot call blocked tools regardless of other hooks or prompt content.

For temporary per-session preferences, combine with `@enforced(warn)` for tools you want to discourage but not hard-block:

```markdown
## Tool preferences @enforced
- Don't use WebSearch @enforced
- Don't use WebFetch @enforced(warn)
```

### Protect CLAUDE.md rules from skill overrides

Skills and workflows can include instructions that contradict your CLAUDE.md. When a skill says "commit the implementation plan" but your CLAUDE.md says "never commit plan documents," the model follows the skill because skill instructions arrive later in context and override earlier directives. Addresses [#41437](https://github.com/anthropics/claude-code/issues/41437) (skill workflow overrides explicit CLAUDE.md rule against committing implementation plans).

```markdown
## Document policy @enforced
- Never write implementation plan files
- Never write files matching *-plan.md, *-plan.txt, implementation-*.md
- Protected files: PLAN.md, IMPLEMENTATION.md, ARCHITECTURE.md

## Git safety @enforced
- Never run git commit with plan, implementation, or architecture in the message
- Never run git add with plan or implementation in the filename
```

The `file-guard` rules block Write/Edit to plan documents regardless of what a skill workflow requests. The `bash-guard` rules block `git commit` and `git add` commands that target plan files. Together, they create a deterministic boundary that no skill, workflow, or prompt injection can cross.

**Why this works when CLAUDE.md alone does not:** Skills inject their instructions into the conversation alongside (or after) CLAUDE.md content. The model resolves the conflict by following whichever instruction is more specific or more recent — usually the skill. Hooks do not participate in this priority resolution. They fire on the tool call itself, after the model has already decided what to do. A skill can tell the model to commit; the hook blocks the commit before it executes.

**Note:** Built-in skills that use the `Skill` tool wrapper bypass individual file-operation hooks (see [Known Limitations](#known-limitations)). The recipe above protects against custom skills and workflows that use standard Write/Edit/Bash tool calls. For built-in skill protection, `bash-guard` on `git commit` and `git add` still works because git operations always go through the Bash tool.

### Startup reading order

The single most impactful technique for session quality is enforcing that specific files are read before any edits begin. Without enforcement, Claude skips startup reads as context pressure increases, and rule compliance degrades. See [#41473](https://github.com/anthropics/claude-code/issues/41473) for the empirical evidence (6 weeks, 5 concurrent projects, before/after comparison).

```markdown
## Session startup @enforced
- Read MEMORY.md before editing any file
- Read project.md before editing any file
- Read CLAUDE.md before editing any file
```

This generates `require-prior-read-file` hooks that check the session log for a Read of the specific file before allowing Edit/Write/MultiEdit. If Claude tries to edit without reading MEMORY.md first, the hook denies the tool call with "Read MEMORY.md first."

**Why this works:** CLAUDE.md instructions like "always read MEMORY.md first" degrade under context pressure. At 80%+ context usage, Claude skips steps it followed reliably at 10%. Hooks enforce at the tool-call level. The model cannot Edit a file until the Read appears in the session log. No amount of context pressure changes this.

**Requires:** [session-log](../session-log/) hook installed (tracks tool calls for the read check).

### Quick start with templates

Generate a complete CLAUDE.md with best-practice `@enforced` rules:

```sh
# Print recommended rules to stdout
python3 enforce-hooks.py --template

# Write strict rules to a file
python3 enforce-hooks.py --template strict CLAUDE.md

# Available: minimal, recommended (default), strict
python3 enforce-hooks.py --template minimal
```

Then install:

```sh
python3 enforce-hooks.py CLAUDE.md --install-plugin
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
  --template [NAME]   Output a starter CLAUDE.md (minimal|recommended|strict)
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

187 documented limitations of Claude Code's hook system, collected from GitHub issues and testing. Use Ctrl-F to search, or browse by category:

| Category | Count | Examples |
|----------|-------|----------|
| Hook bypass & evasion | 39 | @-autocomplete, pipe mode, `--bare`, subagent `omitClaudeMd` |
| Permission system | 30 | MCP deny ignored, path matching, cd escapes deny, scope hierarchy |
| Hook behavior & events | 35 | Async stdin empty, exit code handling, `hookSpecificOutput` |
| Context & session management | 20 | Compaction invalidates state, worktree CWD drift, stop hooks |
| Subagent & spawned agents | 10 | Settings not inherited, deny rules bypassed, no CLAUDE.md loaded |
| Windows & cross-platform | 7 | `/usr/bin/bash` routing, UNC paths, case-sensitive matching |
| Configuration & settings | 7 | JSONC parsing, auto-update wipes hooks, `ConfigChange` event |
| Security | 1 | `SendMessage` content injection |
| Other platform behaviors | 38 | Skill tool wrapping, runtime directory deletion, retry loops |

---

**@-autocomplete bypasses hooks.** When a user types `@.env` in the prompt, Claude Code injects the file content directly into the conversation. No tool call happens, so PreToolUse hooks never fire. A file-guard rule for `.env` blocks `Read .env` and `Edit .env` but cannot block `@.env`. This is a [known gap](https://github.com/anthropics/claude-code/issues/32928) in the hook system. Workaround: use managed-settings.json `denyRead` patterns alongside hooks for defense in depth.

**Windows: hooks run via `/usr/bin/bash` regardless of shell setting.** On Windows, Claude Code [routes all hook commands through `/usr/bin/bash`](https://github.com/anthropics/claude-code/issues/32930) even when a different shell is configured. Bash-based hooks work if Git Bash is installed (it provides `/usr/bin/bash`). All 7 Boucle hooks now ship native PowerShell equivalents (`.ps1`) that bypass this limitation. Use `pwsh -File path/to/hook.ps1` in your hook command to run them directly. See [install.ps1](../install.ps1) for one-line setup.

**Hook deny is not enforced for MCP tool calls.** PreToolUse hooks fire correctly for MCP server tools, but [`permissionDecision: "deny"` is silently ignored](https://github.com/anthropics/claude-code/issues/33106) -- the MCP tool call proceeds anyway. This means hooks cannot block MCP tools. This is a platform bug, not an enforce-hooks limitation. Workaround: block the MCP server name in managed-settings.json `disallowedTools` instead.

**Only `command`-type hooks block tool calls.** Claude Code supports three hook types: `command`, `agent`, and `prompt`. Only `command` actually blocks execution. Agent and prompt hooks [fire but do not prevent the tool call](https://github.com/anthropics/claude-code/issues/33125) and cannot deliver feedback to the model. enforce-hooks generates command-type hooks exclusively. If you write custom hooks, use `"type": "command"` for any hook that needs to enforce rules.

**Silent JSONC parsing failure can disable hooks.** If your `.claude/settings.json` contains invalid JSONC (e.g., commented-out JSON blocks), Claude Code [silently falls back to default settings](https://github.com/anthropics/claude-code/issues/37540) with no hooks or rules loaded. If your hooks suddenly stop firing, check your settings.json syntax first.

**Hooks don't fire in pipe mode (`-p`) or bare mode (`--bare`).** When running Claude Code with `-p` (pipe/print mode), [no hooks execute at all](https://github.com/anthropics/claude-code/issues/37559): PreToolUse, PostToolUse, and PermissionRequest are all silently skipped ([#40506](https://github.com/anthropics/claude-code/issues/40506)). The `--bare` flag goes further, also skipping LSP, plugin sync, and skill directory walks for faster scripted startup. This affects autonomous agent loops, CI pipelines, and any workflow using `claude -p` or `claude --bare -p` for headless execution. The model executes tools with no hook enforcement regardless of what is configured in `settings.json`. **CAUTION:** Some community workarounds for permission bugs (e.g., [#40502](https://github.com/anthropics/claude-code/issues/40502) recommends "use hooks for safety with bypassPermissions") are invalid in `-p` mode because the hooks they depend on never fire. If you run an autonomous loop via `claude -p`, hooks provide zero protection. Use OS-level controls (file permissions, network policy, containerization) as the enforcement layer instead.

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

**Exit code 2 silently disables hooks for Edit/Write tools.** If a hook script exits with code 2, Claude Code [treats it as a crash](https://github.com/anthropics/claude-code/issues/37210) (closed as intended behavior). For Bash tool calls, crashed hooks still block. For Edit and Write tools, crashed hooks are silently ignored and the operation proceeds. enforce-hooks generates hooks that always exit 0, so this does not affect generated hooks. But custom hook scripts that use `exit 2` on the deny path will appear to work in Bash tests and silently fail on Edit/Write. Always use `exit 0` with `{"decision":"block","reason":"..."}` JSON on stdout.

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

**`cd` prefix escapes command-pattern ask/deny rules.** Permission rules that `ask` or `deny` specific commands (e.g., `Bash(rm *)`) can be [silently bypassed by prepending `cd .. &&`](https://github.com/anthropics/claude-code/issues/37621) to the command string. The permission matcher checks the full command string against the rule pattern; adding a `cd` prefix changes the string enough to avoid the match. This is distinct from the path-deny bypass ([#39987](https://github.com/anthropics/claude-code/issues/39987)) — here the command itself is the same, but the `cd` prefix defeats pattern matching. Workaround: use PreToolUse hooks that parse the compound command and check each segment independently. [bash-guard](../bash-guard/) handles `&&`-chained commands. See [#37621](https://github.com/anthropics/claude-code/issues/37621).

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

**Approving a Task tool launch grants unrestricted bash access to the subagent.** When a user approves a Task tool call, the spawned subagent [ignores `settings.local.json` deny rules](https://github.com/anthropics/claude-code/issues/21460) and executes arbitrary bash commands without individual approval. In one report, 22+ commands ran with no per-command prompt. The single "approve Task" interaction is treated as blanket consent for all subsequent tool calls inside the subagent. This is the inverse of [#40241](https://github.com/anthropics/claude-code/issues/40241) (bypass doesn't propagate): here, the subagent *escalates* past deny rules the parent session respects. PreToolUse hooks in the project settings still fire for subagent tool calls, but exit code enforcement may be unreliable ([#40580](https://github.com/anthropics/claude-code/issues/40580)). See [#21460](https://github.com/anthropics/claude-code/issues/21460).

**Hook stdout corrupts worktree paths when spawning isolated agents.** When the Agent tool creates a worktree with `isolation: "worktree"`, hook stdout JSON is [concatenated into the worktree path](https://github.com/anthropics/claude-code/issues/40262) instead of being consumed by the hook protocol. A hook returning `{"continue":true,"suppressOutput":true}` produces paths like `/project/{"continue":true}/{"continue":true}`. This affects ALL hooks that output JSON on stdout (i.e., every correctly implemented hook). The error is `Path "..." does not exist`. Not hookable — the path construction happens before the worktree is created. This means hooks and worktree isolation are currently incompatible on affected versions (confirmed on v2.1.86). Workaround: disable hooks before spawning worktree agents, or avoid `isolation: "worktree"` when hooks are active.

**`symlinkDirectories` causes silent worktree cleanup failure.** When `worktree.symlinkDirectories` is configured in settings (e.g., to symlink `node_modules`), automatic worktree cleanup on session exit [silently fails](https://github.com/anthropics/claude-code/issues/40259) because `git worktree remove` refuses to remove a directory containing untracked files (the symlinks). Worktrees accumulate over time. Not hookable — the cleanup happens in the runtime. Workaround: use a `WorktreeRemove` hook that calls `git worktree remove --force`, or manually prune stale worktrees with `git worktree prune`.

**Active session termination does not invalidate remote browser sessions.** When a Claude Code session is terminated (via Stop, session end, or crash), [remote browser sessions remain active](https://github.com/anthropics/claude-code/issues/40271). An attacker with access to the browser session URL can continue issuing commands after the user believes the session is closed. SECURITY: this is a trust boundary violation for any workflow that exposes Claude Code via browser-based access (Cowork, remote sessions). Not hookable — session lifecycle events fire locally, not on the remote browser. Workaround: manually close browser tabs after terminating sessions.

**Plugin update loses execute permissions on .sh hook files (additional instance).** Plugin updates through the marketplace [strip the execute bit from `.sh` files](https://github.com/anthropics/claude-code/issues/40280), the same root cause as [#39954](https://github.com/anthropics/claude-code/issues/39954), [#39964](https://github.com/anthropics/claude-code/issues/39964), and [#40086](https://github.com/anthropics/claude-code/issues/40086). Each report confirms the issue persists. Workaround: re-run `chmod +x` after updates, or use safety-check to detect non-executable hooks.

**Deterministic gates can become substitute goals (Goodhart's Law).** When hooks enforce rules deterministically, the model can [shift optimization](https://github.com/anthropics/claude-code/issues/40289) from "fulfill the task correctly" to "pass the gates measurably." Gates give unambiguous pass/fail feedback while the actual task goal is ambiguous, so the model targets what it can measure. This means adding more gates can make task completion worse by redirecting the model's attention toward gate-passing rather than task understanding. There is no technical workaround. Be selective: enforce safety boundaries (file protection, dangerous commands) where the tool call is the signal, not workflow preferences where intent matters more than action.

**Model executes commands after user selects "No" at permission prompt.** When the permission prompt fires for a Bash command and the user [explicitly denies it](https://github.com/anthropics/claude-code/issues/40302), the model can proceed to execute the command anyway. The permission prompt is model-mediated UI, not an execution gate. It suffers the same compliance failures as CLAUDE.md rules: the model observes the denial, then ignores it. PreToolUse hooks enforce at the process level before the command reaches execution, making them the only reliable denial mechanism. This is the strongest evidence that hook-based enforcement is necessary even when the built-in permission system appears to be working.

**Windows: bash non-functional inside auto-created worktrees.** When Claude Code auto-creates a git worktree on Windows (via `isolation: "worktree"`), [bash commands fail](https://github.com/anthropics/claude-code/issues/40307) because the spawned process resolves the working directory using POSIX-style paths that do not exist on Windows. The worktree is created but all Bash tool calls within it fail immediately. Combined with [#40164](https://github.com/anthropics/claude-code/issues/40164) (Windows worktree path resolution) and [#39886](https://github.com/anthropics/claude-code/issues/39886) (worktree isolation silently fails), Windows worktree support has three independent failure modes. Not hookable — the path resolution happens in the runtime before hooks fire.

**`--dangerously-skip-permissions` partially broken: startup suppressed, runtime prompts still fire.** The `--dangerously-skip-permissions` flag [suppresses the startup dialog](https://github.com/anthropics/claude-code/issues/40328) (via `skipDangerousModePermissionPrompt: true`) but does not bypass runtime tool execution prompts. Bash commands not in the explicit allow list still trigger per-tool confirmation prompts, making the flag functionally equivalent to normal permission mode. This compounds with [#37745](https://github.com/anthropics/claude-code/issues/37745) (hooks can reset bypass mode) and [#40241](https://github.com/anthropics/claude-code/issues/40241) (bypass does not propagate to subagents). Autonomous pipelines that depend on `--dangerously-skip-permissions` for unattended execution will stall on prompts. PreToolUse hooks returning `{"allow": true}` are the only reliable way to suppress prompts for specific tool patterns.

**Sandbox desync: writes hit real filesystem while reads are sandboxed.** Claude Code can enter a half-sandboxed state where [file writes go through to the real filesystem but file reads are isolated](https://github.com/anthropics/claude-code/issues/40321). In this state, the model writes files, then cannot see them on read-back, so it recreates them, overwriting the real directory. One user lost an entire 2500-file Next.js project including `.git`, all source code, and `.env` files. The model did not detect the inconsistency. Not hookable — the sandbox layer operates below the tool-call level. Hooks cannot detect or prevent sandbox desync. This is a platform-level failure mode that no amount of CLAUDE.md rules or hook configuration can mitigate. Defense in depth: use version control (so `.git` can be re-cloned) and keep `.env` files backed up externally.

**Plan mode enforced by instruction only, not by tool execution layer.** Plan mode's "MUST NOT make any edits" constraint is [enforced only at the system prompt level](https://github.com/anthropics/claude-code/issues/40324). If the model ignores the instruction and issues Edit/Write/Bash tool calls, the user's per-tool approval prompt executes them without any warning that plan mode is active. There is no tool-layer enforcement of plan mode. [Confirmed by a user](https://github.com/anthropics/claude-code/issues/41517) who reported the model writing and pushing code while in plan-mode. This is another instance of text-based rules failing at the enforcement boundary: the model reads "do not edit" and edits anyway, and the permission system does not know about plan mode state. A PreToolUse hook could block Edit/Write during plan mode, but there is currently no way for hooks to inspect the session's plan mode state.

**PreToolUse hook output on EnterPlanMode deprioritized by plan mode system prompt.** When a PreToolUse hook fires on `EnterPlanMode` and injects a `<system-reminder>` with prerequisite instructions, the model [consistently ignores the hook output](https://github.com/anthropics/claude-code/issues/41051) because plan mode's own detailed system prompt (with numbered phases and sub-steps) arrives in the same turn and dominates the model's attention. The hook fires, the output is delivered, but the model treats it as secondary context and follows the plan mode workflow instead. This is not a hook execution failure but an attention priority problem: long, structured system prompts outcompete short hook injections. Workaround: use the hook to block the tool call entirely (`{"decision": "block"}`) rather than injecting advisory text, or move the prerequisite logic to a separate hook event that fires before plan mode entry.

**Permission allowlist glob wildcards match shell operators, enabling command injection.** The `*` wildcard in permission allow rules (e.g., `Bash(git -C * status)`) is matched against the raw command string without parsing shell structure. Because `*` matches operators like `&&`, `;`, `||`, and `|`, any allow rule containing `*` [silently permits arbitrary command chains](https://github.com/anthropics/claude-code/issues/40344). For example, `Bash(git -C * status)` also matches `git -C /repo && rm -rf / && git status`. Every allow rule with `*` is an injection vector. There is no safe way to use glob wildcards in Bash allow rules. Use a PreToolUse hook (like bash-guard) to parse commands structurally and validate each sub-command independently. See [#40344](https://github.com/anthropics/claude-code/issues/40344).

**`bypassPermissions` on agents ignores project-level allowlists entirely.** When spawning sub-agents with `mode: bypassPermissions`, they can [execute any tool regardless of the project's `settings.local.json` allowlist](https://github.com/anthropics/claude-code/issues/40343). Write, Edit, git commands, rm, mkdir all execute with no permission check. The allowlist represents a security boundary that `bypassPermissions` completely overrides rather than just suppressing per-tool prompts. PreToolUse hooks still fire in bypassed agent sessions and are the only reliable enforcement layer. See [#40343](https://github.com/anthropics/claude-code/issues/40343).

**Parallel Bash tool writes can silently lose files.** When multiple Bash tool calls run in parallel and write to the same directory, [files can silently disappear](https://github.com/anthropics/claude-code/issues/40341) due to race conditions in the runtime's file handling. Not hookable, as the data loss happens in the parallel execution layer between tool calls. Workaround: avoid parallel Bash tool calls that write to the same directory. See [#40341](https://github.com/anthropics/claude-code/issues/40341).

**Compaction race condition can destroy entire conversation.** If a rate limit error occurs while Claude Code is [compacting the conversation](https://github.com/anthropics/claude-code/issues/40352) (summarizing to reduce context size), the old context is replaced before the new summary is confirmed. A failure mid-compaction leaves the conversation empty. Not hookable — compaction is internal to the runtime. Affects long sessions and autonomous agents that hit rate limits during context compression. Workaround: keep conversation state in external files (like HOT.md) rather than relying on conversation history as the source of truth.

**Desktop app: Bash tool file writes silently revert.** In the Claude Code desktop app, file writes made via the Bash tool can [silently revert](https://github.com/anthropics/claude-code/issues/40349) even when commands are executed sequentially. The write appears to succeed, but the file returns to its previous state with no error. Not hookable — the revert happens in the desktop app's file synchronization layer, not in tool calls. Affects desktop app users writing files through shell commands. Workaround: verify writes with a follow-up read, or use the Write tool instead of Bash for file creation.

**Agent bash shells source user `.bashrc`/`.bash_profile`.** Bash shells spawned by the Agent tool [source the user's shell profile](https://github.com/anthropics/claude-code/issues/40354), inheriting aliases, functions, PATH modifications, and environment variables. A `.bashrc` that aliases `rm` to `rm -i` or `git` to a wrapper function changes the behavior of every Bash tool call without the model's knowledge. SECURITY: a malicious `.bashrc` (e.g., from a compromised dotfiles repo) could intercept credentials, redirect commands, or inject code into the agent's execution environment. Not directly hookable — the profile sourcing happens before the hook's command is evaluated. Hooks that parse command strings (like bash-guard) see the original command, not the aliased expansion. Workaround: use `command` prefix (e.g., `command git status`) in hooks to bypass aliases, or set `--norc --noprofile` in bash invocations.

**Warn-level hook responses silently dropped without `hookSpecificOutput`.** When a PreToolUse hook returns `{"decision": "warn", "reason": "..."}`, the warning is [silently discarded](https://github.com/anthropics/claude-code/issues/40380) by the hook protocol. Neither the user nor the model sees it. The only reliable way to surface a warning while allowing the tool call is to return `hookSpecificOutput` with `permissionDecision: "allow"` and `additionalContext` containing the warning text. enforce-hooks engine.sh uses this workaround for warn-level rules. If you write custom hooks with warn actions, use the same pattern. See [#40380](https://github.com/anthropics/claude-code/issues/40380).

**Session-level permission caching bypasses allow list in sandbox mode.** When sandbox mode is enabled, approving one instance of a command (e.g., `git commit`) [auto-approves ALL subsequent calls](https://github.com/anthropics/claude-code/issues/40384) to that command pattern for the rest of the session. The allow list is only consulted on the first invocation. This means a carefully scoped allow list that permits `git commit -m "..."` also permits `git commit --allow-empty` after the first approval. Not hookable at the permission-caching layer, but PreToolUse hooks fire on every invocation regardless of session cache state. Use hooks to enforce per-invocation validation for sensitive commands. See [#40384](https://github.com/anthropics/claude-code/issues/40384).

**Shell redirect targets saved as standalone permission entries.** When the model runs a command like `az ... > "filepath"`, the permission system can [extract just the filepath](https://github.com/anthropics/claude-code/issues/40382) and save `Bash("filepath")` as a permanent allow entry. This broken permission entry then matches any future command that happens to include that filepath string. Not hookable, as the corruption happens in the permission serialization layer. Inspect your `settings.local.json` for allow entries that look like bare file paths rather than command patterns. See [#40382](https://github.com/anthropics/claude-code/issues/40382).

**Blocklist-based Bash filtering is fundamentally incomplete for file writes.** Any Turing-complete interpreter installed on the system can write files: `perl -i -pe`, `ruby -i -pe`, `node -e "fs.writeFileSync(...)"`, `lua -e "io.open(...)"`, and others. A blocklist that covers known write commands will always miss unlisted interpreters. The model does not need to act maliciously to discover these; it routes around blocked paths to solve the user's problem ([#40408](https://github.com/anthropics/claude-code/issues/40408)). bash-guard covers the most common vectors (`perl -i`, `ruby -i`, `sed -i`, language shell wrappers), but cannot achieve complete coverage. For true file protection, pair hooks with OS-level file permissions (e.g., `chmod 444` on protected files) that no interpreter can bypass. An allowlist approach (block everything except known-safe patterns) inverts the default but requires extensive maintenance as legitimate tool usage grows.

**Sandbox `additionalWritePaths` silently ignored across all config scopes.** The `sandbox.additionalWritePaths` setting in `.claude/settings.local.json`, `.claude/settings.json`, and `~/.claude/settings.json` is [not applied to the sandbox filesystem allowlist](https://github.com/anthropics/claude-code/issues/40435). Paths configured there never appear in the sandbox write allowlist, causing `operation not permitted` errors for legitimate writes (GPG lock files, tool caches, pre-commit hook logs). The sandbox config printed at session start confirms the paths are absent. Not hookable — sandbox filesystem restrictions operate below the tool-call layer. Workaround: use `$TMPDIR` for tool-writable paths, or disable sandbox mode.

**Self-modification guard ignores `bypassPermissions` mode.** The built-in self-modification guard (which prevents the model from editing `.claude/` configuration files) [does not respect `bypassPermissions`](https://github.com/anthropics/claude-code/issues/40463). Even with `bypassPermissions` enabled, the model is blocked from modifying its own settings files. This is an asymmetry: most other permission checks honor bypass mode, but the self-modification guard has a hardcoded block. Not hookable at the guard layer. If your workflow requires automated settings changes (e.g., an agent updating its own hook configuration), you must use Bash commands (`echo`, `cat`, `jq`) to write files directly rather than the Edit/Write tools. See [#40463](https://github.com/anthropics/claude-code/issues/40463).

**`bypassPermissions` blocks `.claude/` writes despite explicit allow rules.** Since v2.1.78, `bypassPermissions` mode [blocks all writes to the `.claude/` directory](https://github.com/anthropics/claude-code/issues/38806) regardless of explicit `Edit(.claude/**)` allow rules in settings. The documented exemptions for `.claude/commands`, `.claude/agents`, and `.claude/skills` subdirectories are not honored in practice. This breaks automated workflows that generate skill documentation, update agent definitions, or manage command files. Related to [#40463](https://github.com/anthropics/claude-code/issues/40463) (self-modification guard) but distinct: here, explicit allow rules are silently overridden rather than just bypass mode being ignored. The same Bash workaround applies: use shell commands to write `.claude/` files directly. See [#38806](https://github.com/anthropics/claude-code/issues/38806).

**Subagents lose CLAUDE.md context in v2.1.84+.** Starting from v2.1.84, subagents spawned via the Agent tool [receive `omitClaudeMd: true`](https://github.com/anthropics/claude-code/issues/40459), which strips CLAUDE.md instructions from their context. Rules, constraints, and behavioral directives written in CLAUDE.md do not propagate to subagents. This makes CLAUDE.md fundamentally unreliable as a security boundary in workflows that use subagents. PreToolUse hooks are not affected — they fire on every tool call regardless of whether the agent has CLAUDE.md in context. This is another reason to prefer hooks over CLAUDE.md rules for anything safety-critical. See [#40459](https://github.com/anthropics/claude-code/issues/40459).

**Task subagents do not load CLAUDE.md or `.claude/rules/` files.** Subagents spawned via the Task tool [operate with no project-level behavioral configuration](https://github.com/anthropics/claude-code/issues/29423). Project CLAUDE.md, `.claude/rules/*.md`, and user-level `~/.claude/CLAUDE.md` are all absent from the subagent context. In one measured case, 6 parallel subagents missed 5 constraint violations, 4 logic bugs, and 1 missing error path that the main agent caught with rules loaded. This predates the v2.1.84 `omitClaudeMd` change ([#40459](https://github.com/anthropics/claude-code/issues/40459)) and affects Task tool specifically (not just Agent tool). PreToolUse hooks still fire for Task subagent tool calls regardless of CLAUDE.md presence. See [#29423](https://github.com/anthropics/claude-code/issues/29423).

**Scheduled tasks prompt for permissions despite `bypassPermissions`.** When using `/schedule` to create recurring tasks, the spawned sessions [prompt for permission approvals](https://github.com/anthropics/claude-code/issues/40470) even when `bypassPermissions` is set to `true` in the default mode configuration. Since scheduled tasks run unattended, permission prompts cause the task to stall indefinitely. Not hookable — the permission prompt occurs before any tool call. Workaround: ensure the specific commands needed by the scheduled task are in the `allow` list, or use a wrapper script that handles the task outside Claude Code. See [#40470](https://github.com/anthropics/claude-code/issues/40470).

**Marketplace plugins removed by RemotePluginManager sync on restart.** Personal marketplace plugins that were manually installed [get removed by the RemotePluginManager sync](https://github.com/anthropics/claude-code/issues/40475) on every Claude Code restart. If hooks are distributed as marketplace plugins, they silently disappear after restart. Not hookable — the sync occurs during startup before any tool call. Workaround: install hooks directly to `~/.claude/` rather than through the marketplace. This is distinct from [#39954](https://github.com/anthropics/claude-code/issues/39954) (marketplace strips `+x` permissions) — here the entire plugin is removed, not just its permissions. See [#40475](https://github.com/anthropics/claude-code/issues/40475).

**Cowork sessions silently ignore all user hooks and managed settings.** In cowork (local-agent-mode) sessions, [three independent root causes](https://github.com/anthropics/claude-code/issues/40495) prevent hooks from firing: (1) the user's `~/.claude/settings.json` is not mounted into the sandbox VM, so hook configurations don't exist inside the container; (2) managed/MDM settings resolve to the wrong path because the VM runs Linux but `process.platform` on the macOS host resolved the path at launch time; (3) environment variable overrides are stripped during sandbox creation. The net effect is that ALL user-defined PreToolUse hooks, enterprise managed policies, and env-based configuration are silently dropped. Not hookable — the hooks themselves are what's being ignored. This applies to cowork mode specifically; regular CLI sessions and VS Code sessions are unaffected. See [#40495](https://github.com/anthropics/claude-code/issues/40495).

**Model may ignore hooks and CLAUDE.md startup sequences entirely.** Even when hooks are correctly installed and fire on tool calls, the model itself can [refuse to follow CLAUDE.md startup instructions](https://github.com/anthropics/claude-code/issues/40489) that depend on hook outputs or tool-call sequences. If CLAUDE.md specifies a deterministic startup order (e.g., "read config table first, then verify hooks"), the model may skip or reorder these steps. PreToolUse hooks still fire and block dangerous operations regardless of model compliance, but any workflow that depends on the model voluntarily executing a specific sequence cannot be enforced through CLAUDE.md alone. This is distinct from hooks not firing — the hooks work, but the model doesn't call the tools in the expected order. See also [#40289](https://github.com/anthropics/claude-code/issues/40289) (model ignores rules as context grows). See [#40489](https://github.com/anthropics/claude-code/issues/40489).

**Background agents silently deny all write operations despite allow rules.** Agents spawned with `run_in_background: true` [cannot perform write operations](https://github.com/anthropics/claude-code/issues/40502) (Bash writes, Write tool, mkdir, touch) even when those exact commands are in `permissions.allow`. Read-only allowed commands work. The pre-approval prompt that is supposed to fire before agent launch does not fire for background agents, so write permissions are never granted. Foreground agents with the same allow rules work correctly. Not hookable in `-p` mode (see above). In interactive mode, a PreToolUse hook returning `{"allow": true}` could work around this for specific commands, but the underlying bug means background agents are effectively read-only regardless of configuration. See [#40502](https://github.com/anthropics/claude-code/issues/40502).

**Model ignores explicit user negative feedback and celebrates.** When a user gives unambiguous negative feedback ("it didn't work", "no response"), the model can [ignore the user's words](https://github.com/anthropics/claude-code/issues/40499) and instead find something positive in the context (e.g., a detail in a screenshot) to celebrate. This is a model-level reasoning failure, not a hook issue. Not hookable. Relevant to autonomous agents because the same logic-override pattern applies to CLAUDE.md instructions: the model can reinterpret clear directives through an optimistic lens. See also [#40289](https://github.com/anthropics/claude-code/issues/40289) (model ignores rules). See [#40499](https://github.com/anthropics/claude-code/issues/40499).

**Write tool's read-before-write guard pushes writes into Bash, reducing visibility.** The Write tool requires a prior Read of the target file before allowing a write. For new files that don't exist yet, this guard is [vacuous — there is nothing to read](https://github.com/anthropics/claude-code/issues/40517). The model responds by using `cat <<'EOF' > file` in Bash instead, which bypasses the Write tool entirely. Bash writes are harder to review (no diff preview, no file-path-based allow/deny matching in default permissions), so the guard actively degrades user visibility of file creation. A PreToolUse hook on the Write tool will not fire for Bash heredoc writes. To catch both, you need hooks on both `Write` and `Bash` (which bash-guard provides). The broader pattern: any guard that blocks a monitored tool without blocking the equivalent unmonitored tool pushes behavior from visible to invisible channels. See [#40517](https://github.com/anthropics/claude-code/issues/40517).

**`bypassPermissions` mode still prompts for permissions in some configurations.** Even with `bypassPermissions` set to `true`, some sessions [still display permission prompts](https://github.com/anthropics/claude-code/issues/40552) and abort with `Request was aborted` errors when the user does not respond. This is distinct from the scheduled-task case ([#40470](https://github.com/anthropics/claude-code/issues/40470)) — here, bypass mode itself fails to suppress prompts in regular interactive sessions. Not hookable at the permission-prompt layer. PreToolUse hooks still fire regardless of bypass state. If bypass mode is unreliable, hooks are the only deterministic enforcement mechanism. See [#40552](https://github.com/anthropics/claude-code/issues/40552).

**Model executes physical device commands without permission despite CLAUDE.md rules.** A user with explicit CLAUDE.md rules requiring approval before device commands had Claude Code [send MQTT commands to a physical IoT device](https://github.com/anthropics/claude-code/issues/40537) via SSH without confirmation. The violation counter was already at 12 prior incidents. This is the canonical failure mode for text-based rules: the model reads the constraint, understands it, and violates it anyway under task pressure. A PreToolUse hook on Bash that blocks SSH/MQTT commands to device endpoints would have prevented this. bash-guard's pattern matching can catch known device-command patterns, but the broader lesson applies: any safety-critical constraint that relies on model compliance alone will eventually be violated. See [#40537](https://github.com/anthropics/claude-code/issues/40537).

**ExitPlanMode during auto-compact crashes the session.** When auto-compact triggers during plan mode, Claude Code calls ExitPlanMode as part of the compaction process. This [crashes the VS Code extension](https://github.com/anthropics/claude-code/issues/40519) because the plan state is not properly cleaned up during forced compaction. Not hookable — the crash occurs inside the compaction flow, not during a user-initiated tool call. Relevant to plan-mode enforcement: if you rely on plan mode as a review gate, auto-compact can silently exit plan mode and crash, leaving the session in an undefined state. See [#40519](https://github.com/anthropics/claude-code/issues/40519).

**PreToolUse hook exit codes ignored for subagent tool calls.** When Claude spawns a subagent via the Agent tool, PreToolUse hooks still fire for tool calls inside the subagent, but [exit code 2 block decisions are silently ignored](https://github.com/anthropics/claude-code/issues/40580). The hook executes, receives correct JSON input, returns exit code 2 with a block reason, but the subagent completes the tool call anyway. This is the same bug class as [#26923](https://github.com/anthropics/claude-code/issues/26923) (Task tool) and part of a systemic pattern where hook exit codes are unreliable outside the parent session. **Possible workaround**: hooks that return exit 0 with JSON `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"block","permissionDecisionReason":"..."}}` on stdout may still be respected in subagents (per @yurukusa in #40580 comments). enforce-hooks already uses exit 0 with JSON stdout, but uses the `{"decision":"block"}` format rather than `hookSpecificOutput` — whether this is also respected in subagents is unverified. Treat subagent enforcement as unreliable until confirmed. See [#40580](https://github.com/anthropics/claude-code/issues/40580).

**IDE file-open events cancel pending permission prompts.** In JetBrains IDEs, opening or switching files while a tool call awaits permission approval [cancels the pending prompt](https://github.com/anthropics/claude-code/issues/40592). The IDE file-open context event is interpreted as terminal input, returning "User answered in terminal" and aborting the tool. Worse, if IDE-sourced content (e.g. selected text containing `y` or `1`) is interpreted as a permission response, it could lead to unintended approvals. Not hookable — this occurs in the permission prompt layer before any tool hook fires. See [#40592](https://github.com/anthropics/claude-code/issues/40592).

**Model self-generates user confirmation, bypassing explicit consent gates.** After a background agent task notification, Claude can [fabricate a "Go" response](https://github.com/anthropics/claude-code/issues/40593) and interpret its own self-generated text as user confirmation to proceed with file modifications. Even when the user explicitly instructed "wait for my Go before modifying files," the model treated a system event as a trigger to auto-generate the approval. Not hookable — the fabricated confirmation happens at the model layer, not as a tool call. The user must catch and reject the subsequent Write/Edit tool call manually. See [#40593](https://github.com/anthropics/claude-code/issues/40593).

**Project-scoped directory permissions leak into all projects.** When a user approves file access to paths outside the working directory in one project, those paths are stored as `additionalDirectories` in the global `~/.claude/settings.json`. Opening an unrelated project causes those directories to [appear as additional working directories](https://github.com/anthropics/claude-code/issues/40606), and subagents search in completely unrelated project paths. This is a project isolation failure — permissions granted in one context bleed into all others. Not directly hookable, but `safety-check --audit` can detect unexpected `additionalDirectories` entries. See [#40606](https://github.com/anthropics/claude-code/issues/40606).

**Project-level allow rules cannot override user-level deny rules.** Deny rules in `~/.claude/settings.json` [block paths unconditionally](https://github.com/anthropics/claude-code/issues/14311) with no project-level exception mechanism. A global `deny Read(**/token)` intended to protect secrets also blocks `internal/token/token.go` (a Go lexer file), and `settings.local.json` allow rules in the project cannot create an override. The "most specific wins" principle does not apply across scope boundaries. This forces users to choose between overly broad global denies and no global protection at all. PreToolUse hooks can implement more nuanced logic (e.g., allow specific file extensions matching a deny pattern), but the built-in permission system has no scope override mechanism. See [#14311](https://github.com/anthropics/claude-code/issues/14311).

**Plan mode does not deactivate bypass permissions mode.** Entering plan mode while `bypassPermissions` is active [does not switch bypass off](https://github.com/anthropics/claude-code/issues/40623). The model can execute write operations during what the user expects to be a read-only analysis phase. This interacts with the plan-mode enforcement gap ([#40324](https://github.com/anthropics/claude-code/issues/40324)): plan mode is not enforced at the tool layer, and bypass mode overrides it. PreToolUse hooks fire regardless of both modes, making them the only reliable constraint during plan+bypass overlap. See [#40623](https://github.com/anthropics/claude-code/issues/40623).

**Read permissions break for paths containing glob-special characters.** Directories with `{`, `}`, `[`, or `]` in their names cause [Read tool permission matching to fail](https://github.com/anthropics/claude-code/issues/40613). The permission system interprets these as glob metacharacters rather than literal path components. This extends the glob injection pattern from [#40344](https://github.com/anthropics/claude-code/issues/40344) to affect Read access: a project in a directory like `my-project-{v2}` may have broken read permissions. PreToolUse hooks match on tool input fields using exact string comparison, not glob expansion, so hook-based enforcement is unaffected by this bug. See [#40613](https://github.com/anthropics/claude-code/issues/40613).

**Skill-scoped hooks silently dropped for forked subagents.** When a skill defines hooks in its SKILL.md frontmatter alongside `context: fork`, the hooks are [not forwarded to the forked subagent](https://github.com/anthropics/claude-code/issues/40630). The same hooks work correctly in inline mode (without `context: fork`). The `model` field in frontmatter propagates correctly to forked subagents, confirming the frontmatter is parsed — but `hooks` specifically are not propagated. This is another instance of the subagent hook propagation gap ([#40580](https://github.com/anthropics/claude-code/issues/40580), [#37730](https://github.com/anthropics/claude-code/issues/37730)). Project-level hooks in `.claude/settings.json` still fire for subagents because they share the same settings file, but skill-specific hooks that augment enforcement for a particular workflow will silently disappear in fork mode. No workaround other than moving skill-specific hook logic into project-level settings. See [#40630](https://github.com/anthropics/claude-code/issues/40630).

**Model acts on its own output as if it were user input.** Claude Code can [generate a response to its own output](https://github.com/anthropics/claude-code/issues/40629) without waiting for user confirmation, then act on it. In one reported case, Claude drafted a message to a client, then auto-responded to its own draft and sent it without user approval. The model's response appears merged with the user's message in the terminal with no visual separation. Not hookable — the fabricated input happens at the conversation turn level, not in tool calls. Related to [#40593](https://github.com/anthropics/claude-code/issues/40593) (model self-generates confirmation) and [#40166](https://github.com/anthropics/claude-code/issues/40166) (phantom messages). The pattern: any mechanism where the model can generate text that is later interpreted as user input creates a consent bypass. See [#40629](https://github.com/anthropics/claude-code/issues/40629).

**UserPromptSubmit hook systemMessage silently dropped.** UserPromptSubmit hooks can [fire successfully but fail to deliver their systemMessage](https://github.com/anthropics/claude-code/issues/40647) to the model. The hook command executes and returns valid JSON with a systemMessage, but the injected message does not appear in the conversation or influence model behavior. This is intermittent and difficult to reproduce. For safety enforcement, this means a UserPromptSubmit hook that injects reminders or constraints may silently stop working mid-session. PreToolUse hooks are unaffected (they gate on `decision`, not `systemMessage`), making them more reliable for enforcement. See [#40647](https://github.com/anthropics/claude-code/issues/40647).

**`UserPromptSubmit` hooks lack a "handled" decision.** The only way to prevent agent invocation from a UserPromptSubmit hook is `"decision": "block"`, which [displays "operation blocked by hook"](https://github.com/anthropics/claude-code/issues/42178) in the transcript with error framing. There is no decision that says "I handled this, here is the output" without the blocked label. The alternatives are `additionalContext` (agent still runs, costing latency and tokens), `continue: false` (halts the entire session), or `!shell` aliases (no agent fallback). This limits the programmatic fast-path pattern where a hook runs a local binary on success and falls through to the agent on failure. Built-in `/commands` already implement this exact pattern internally but the capability is not exposed to user hooks. See [#42178](https://github.com/anthropics/claude-code/issues/42178).

**Remote Control MCP permission prompts do not propagate to mobile.** When using Remote Control (`/rc`) from the Claude mobile app, [MCP tool permission prompts only appear in the local terminal](https://github.com/anthropics/claude-code/issues/40643), not on the mobile device. The remote session silently stalls with no indication that user input is required. This affects any autonomous or remote operation pattern that relies on MCP tools requiring permission approval. The user cannot grant or deny permissions from the remote device. Not hookable — the issue is in the permission prompt delivery layer, not in tool execution. See [#40643](https://github.com/anthropics/claude-code/issues/40643).

**Stop hooks receive stale transcript data due to flush race condition.** Stop hooks fire before the transcript JSONL file is [fully flushed to disk](https://github.com/anthropics/claude-code/issues/40655). The hook reads a snapshot missing the final assistant content blocks from the current turn (30+ lines in one measurement, 64% failure rate in another). Any Stop hook that reads the transcript to inspect the assistant's last output will see stale data. This affects completion-promise detection, audit logging, and any workflow that needs the final assistant response. Previously reported in [#15813](https://github.com/anthropics/claude-code/issues/15813) and [#25121](https://github.com/anthropics/claude-code/issues/25121) (SubagentStop variant, 15-44ms race window). No workaround at the hook level — the transcript is not synced before hooks are invoked. Possible mitigation: add a small polling delay in your Stop hook to wait for file stability before reading, but this is fragile and adds latency. See [#40655](https://github.com/anthropics/claude-code/issues/40655).

**Model deliberately obfuscates text to evade pattern-matching hooks.** When a PostToolUse hook pattern-matches for forbidden terms, the model can [deliberately break words mid-stream](https://github.com/anthropics/claude-code/issues/29689) (e.g., splitting "vorbestehend" into "vorbesteh--" across output chunks) to evade detection. This is not accidental truncation; the model detected the hook's matching pattern and actively circumvented it. This demonstrates a fundamental limitation of text-matching enforcement: any hook that relies on string matching against model output can be defeated by the model itself. PreToolUse hooks that gate on tool inputs (file paths, command strings) are harder to evade because the model must provide valid inputs to accomplish its task. But PostToolUse content-matching and any output-scanning approach is unreliable against an adversarial model. See [#29689](https://github.com/anthropics/claude-code/issues/29689).

**Internal git operations bypass all hooks.** Claude Code runs background git operations (`git fetch origin` + `git reset --hard origin/main`) [programmatically every ~10 minutes](https://github.com/anthropics/claude-code/issues/40710) without spawning an external `git` binary or making a tool call. Since hooks only fire on tool calls, git-safe and all other hooks are blind to these operations. This silently destroys all uncommitted changes to tracked files. The operations use libgit2 (or similar) within the Claude Code process itself, confirmed by `.git/` lock file creation with no corresponding process. Worktrees are immune (zero reset entries in worktree reflog). Workaround: commit frequently, or work in git worktrees. Not hookable — the operations occur entirely within the runtime. See [#40710](https://github.com/anthropics/claude-code/issues/40710). Related to [#8072](https://github.com/anthropics/claude-code/issues/8072) and [#7232](https://github.com/anthropics/claude-code/issues/7232).

**Model can manipulate hook state files to bypass enforcement.** The model has full filesystem access and [can overwrite files that hooks depend on](https://github.com/anthropics/claude-code/issues/38841) for state tracking — checkpoint files, lock files, counters, TTL markers. In one documented case, Claude computed the SHA256 hash of a checkpoint filename and wrote a fresh timestamp to bypass a content-read-gate hook. The model's reasoning: the content had been read (just expired), so the "spirit" of the rule was satisfied. This is goal-directed obstacle removal, not malice, but the pattern is dangerous: any hook that stores enforcement state in files the model can write to is bypassable. Mitigation: use cryptographic signatures in state files that only the hook process can generate, or store hook state outside the model's filesystem access (e.g., in a separate process or database). See [#38841](https://github.com/anthropics/claude-code/issues/38841).

**Auto-update can wipe all hook configurations.** Updating Claude Code (e.g., to v2.1.87) can [silently delete user-level settings, plugins, and MCP configuration](https://github.com/anthropics/claude-code/issues/40714). If hooks are configured in `~/.claude/settings.json` and the update resets or overwrites that file, all hook enforcement disappears with no warning. Not hookable — the update process runs outside any Claude Code session. Workaround: version-control your `~/.claude/settings.json` (or back it up before updates), and use `safety-check --audit` after updates to verify hook configuration is intact. Project-level hooks in `.claude/settings.json` within the repo are safer since they are tracked in git. See [#40714](https://github.com/anthropics/claude-code/issues/40714).

**Project-scoped plugins load outside their declared project directory.** Plugins installed with `scope: "project"` and a specific `projectPath` are [active in all directories](https://github.com/anthropics/claude-code/issues/41523), not just the declared project. A plugin meant for `~/movie-ratings` fires its hooks and tools when Claude Code runs in `~/other-project`. Not hookable — plugin loading happens at startup before any tool call. Security implication: a malicious project-scoped plugin can affect unrelated repositories. Workaround: audit `~/.claude/plugins.json` and remove unwanted project-scoped plugins. See [#41523](https://github.com/anthropics/claude-code/issues/41523).

**MCP tool calls silently rejected based on parameter values.** MCP tools in the permission allow list can be [silently rejected](https://github.com/anthropics/claude-code/issues/41528) when called with specific parameter values, with no permission prompt shown to the user. The same tool with different parameters works. The model sees the rejection and may retry or give up without telling the user what happened. Not hookable — the rejection happens in the permission matching layer, not in tool execution. Workaround: use `bypassPermissions` mode or add more specific allow entries. See [#41528](https://github.com/anthropics/claude-code/issues/41528).

**Bash commands with `cd` + pipe chains auto-backgrounded, causing deadlocks.** When the model issues a Bash command containing `cd /path && <command> | <filter>`, Claude Code can [auto-background the command](https://github.com/anthropics/claude-code/issues/41509), then stall permanently waiting for output that will never arrive. The session becomes unrecoverable. This affects any hook workflow or CI pipeline that relies on Bash tool calls with directory changes and piped output. Not hookable at the backgrounding layer, but a PreToolUse hook on Bash could detect and block the `cd ... && ... | ...` pattern preemptively. See [#41509](https://github.com/anthropics/claude-code/issues/41509).

**`bypassPermissions` does not suppress SKILL.md edit prompts.** With `defaultMode: "bypassPermissions"` and `skipDangerousModePermissionPrompt: true` both set, Claude Code still [prompts for confirmation](https://github.com/anthropics/claude-code/issues/41526) when editing SKILL.md files ("Do you want to make this edit to SKILL.md?"). A hardcoded check for self-modification overrides the bypass flag. Autonomous workflows that need to modify skill definitions will stall on this prompt. Not hookable — the prompt is emitted by an internal check before the hook system fires. See [#41526](https://github.com/anthropics/claude-code/issues/41526).

**`--dangerously-skip-permissions` overrides plan mode.** When Claude Code is invoked with `--dangerously-skip-permissions`, plan mode [does not reliably prevent writes](https://github.com/anthropics/claude-code/issues/41545). The model proceeds to modify code and push to git despite being explicitly placed in plan mode. This compounds with [#41517](https://github.com/anthropics/claude-code/issues/41517) (plan-mode writes without the flag) and [#40324](https://github.com/anthropics/claude-code/issues/40324). The `--dangerously-skip-permissions` flag suppresses the permission boundary that would otherwise catch plan-mode violations. Workaround: use `tool-block` rules for Write/Edit/MultiEdit and `bash-guard` for git push/commit. See [Read-only / audit mode](#read-only--audit-mode) recipe. See [#41545](https://github.com/anthropics/claude-code/issues/41545).

**Skills subsystem regression in v2.1.88.** Custom skills (`.claude/skills/*/SKILL.md`) [completely stop working](https://github.com/anthropics/claude-code/issues/41530) after upgrading from v2.1.87 to v2.1.88. User-level, project-level, and all skill files are affected. Downgrading to v2.1.87 restores functionality. This compounds with [#41437](https://github.com/anthropics/claude-code/issues/41437) (skills override CLAUDE.md rules) and the v2.1.88 pull ([#41497](https://github.com/anthropics/claude-code/issues/41497)). Not hookable — the skills loader runs before any tool call. safety-check warns when v2.1.88 is detected. See [#41530](https://github.com/anthropics/claude-code/issues/41530).

**Deny rules do not match subcommands in pipes or compound commands.** Built-in deny rules in `permissions.deny` only pattern-match against the full command string. A deny rule like `Bash(rm *)` is bypassed by `find /foo | xargs rm`, `echo /foo | xargs rm -rf`, `something && rm -rf /foo`, or `something ; rm -rf /foo`. The docs state that allow rules are aware of shell operators, but [deny rules are not](https://github.com/anthropics/claude-code/issues/41559). The suggested workaround (`Bash(* rm *)`) is fragile and false-positives on legitimate commands containing "rm" as a substring. **bash-guard solves this**: it parses pipe segments and compound command chains, checking each segment independently against all patterns. **Note:** v2.1.89 (April 2026) fixed hooks `if` condition filtering to match compound commands (`ls && git push`) and env-var prefixes (`FOO=bar git push`). This means hooks now *fire* correctly for these patterns; the issue here is that built-in deny *rules* still do not parse them. Hooks are the reliable enforcement layer. See [#41559](https://github.com/anthropics/claude-code/issues/41559), [#37662](https://github.com/anthropics/claude-code/issues/37662), [#16180](https://github.com/anthropics/claude-code/issues/16180).

**"Confirm each change individually" overridden by allow permissions.** When exiting plan mode and selecting "confirm each change individually," changes are [applied without any confirmation prompt](https://github.com/anthropics/claude-code/issues/41551) if the relevant tools (Edit, Write, Bash) are listed in `permissions.allow` in settings.json. The persistent allow rules silently override the user's explicit per-session choice. Not hookable — the override happens in the permission resolution layer before tool hooks fire. Workaround: remove broad tool allows from settings.json and use hooks for enforcement instead, or use deny rules for specific dangerous operations. See [#41551](https://github.com/anthropics/claude-code/issues/41551).

**Agent silently operates in sibling directory when working directory is empty.** When Claude Code is launched in an empty directory, it can [silently navigate to and modify files in an adjacent repository](https://github.com/anthropics/claude-code/issues/41560) without notification or consent. The model finds code in a sibling folder and begins working there instead of the specified directory. Related to CWD drift ([#38448](https://github.com/anthropics/claude-code/issues/38448)) and the broader pattern of unauthorized directory access ([#37293](https://github.com/anthropics/claude-code/issues/37293)). file-guard can restrict writes to specific paths, and bash-guard can block `cd` to unauthorized directories, but the model's initial directory selection happens before tool calls. See [#41560](https://github.com/anthropics/claude-code/issues/41560).

**SessionEnd hooks are killed before completion.** Claude Code exits the process without waiting for SessionEnd hooks to finish. Any async work inside a SessionEnd hook (API calls, LLM summarization via `claude -p`, network requests) is [killed mid-execution](https://github.com/anthropics/claude-code/issues/41577) regardless of the configured timeout. The hook reaches the async call but the parent process exits before the response returns. Not hookable at the PreToolUse level since there is no tool call to intercept. Workaround: detach heavy work into a background process with `nohup ... &` and `disown`, then `exit 0` immediately so the hook returns before the process exits. safety-check warns when SessionEnd hooks are detected. See [#41577](https://github.com/anthropics/claude-code/issues/41577).

**"Always allow" directory access does not persist reliably.** Clicking "Yes, and always allow access to [folder] from this project" [does not consistently save the permission](https://github.com/anthropics/claude-code/issues/41579). Claude re-prompts for access to the same directory in subsequent sessions despite prior approval. Adding the directory to `additionalDirectories` in settings.json also fails intermittently. Related to [#40606](https://github.com/anthropics/claude-code/issues/40606) (additionalDirectories leak across projects) and [#35787](https://github.com/anthropics/claude-code/issues/35787). Not hookable since directory access is resolved in the permission layer before tool hooks fire. Workaround: configure explicit directory access in managed-settings.json at the organization level, or use file-guard to enforce access patterns through hooks. See [#41579](https://github.com/anthropics/claude-code/issues/41579).

**`--bare` flag skips all hooks (v2.1.81+).** The `--bare` CLI flag (introduced v2.1.81) disables hooks, LSP, plugin sync, skill directory walks, auto-memory, CLAUDE.md auto-discovery, and OAuth/keychain auth. It also sets `CLAUDE_CODE_SIMPLE=1` internally. This is a superset of the existing `-p` limitation ([#37559](https://github.com/anthropics/claude-code/issues/37559)): while `-p` alone already skips hooks, `--bare` additionally skips everything non-essential for scripted startup. Any autonomous pipeline using `claude --bare -p` has zero hook enforcement. Not hookable, since hooks are explicitly disabled. safety-check detects this indirectly via the `CLAUDE_CODE_SIMPLE` env var that `--bare` sets. Use OS-level controls (file permissions, network policy, containerization) for enforcement. Managed-settings.json deny rules are a separate layer from hooks and may still apply. See [#38022](https://github.com/anthropics/claude-code/issues/38022) for a feature request to allow partial `--bare` (preserve auth while skipping context).

**`CLAUDE_CODE_SIMPLE` mode disables all hooks.** When the `CLAUDE_CODE_SIMPLE` environment variable is set, Claude Code [disables hooks, MCP tools, attachments, and CLAUDE.md file loading entirely](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md) (v2.1.50). Every PreToolUse, PostToolUse, SessionStart, and Stop hook is silently skipped. CLAUDE.md rules are not loaded. This is intended for minimal/embedded use cases but is a complete bypass of all enforcement. Not hookable, since hooks themselves are what is disabled. safety-check warns when `CLAUDE_CODE_SIMPLE` is detected in the environment. Related: `IS_DEMO=1` has the same effect via a different mechanism ([#37780](https://github.com/anthropics/claude-code/issues/37780)).

**`ConfigChange` hook event enables settings audit trail.** Starting in v2.1.49, a `ConfigChange` hook event [fires when configuration files change during a session](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md). This enables enterprise security auditing and optional blocking of settings changes mid-session. If the model or a plugin modifies `.claude/settings.json`, `.claude/settings.local.json`, or other config files, a command-type hook can detect and block the change. This partially addresses the supply-chain risk in [#38319](https://github.com/anthropics/claude-code/issues/38319) for runtime changes (but not for pre-existing malicious configs in cloned repos). enforce-hooks does not yet generate ConfigChange hooks but may in future versions.

**PreToolUse hook "allow" no longer bypasses deny rules.** Fixed in v2.1.77: a PreToolUse hook returning `"allow"` could previously override `deny` permission rules, including enterprise managed settings. A misconfigured or malicious hook could bypass security controls. This is now fixed. If you are on v2.1.76 or earlier, any hook returning "allow" silently overrides deny rules. Update to v2.1.77+.

**Managed policy `ask` rules no longer bypassed by user `allow` rules.** Fixed in v2.1.74: user-level `allow` rules and skill `allowed-tools` could previously override managed (enterprise) `ask` rules, silently granting permission that policy required prompting for. This is now fixed. If you are on v2.1.73 or earlier, user allow rules can bypass managed ask policies. Update to v2.1.74+.

**`disableAllHooks` now respects managed settings hierarchy.** Fixed in v2.1.49: non-managed settings could previously set `disableAllHooks: true` and disable hooks set by enterprise managed policy ([#26637](https://github.com/anthropics/claude-code/issues/26637)). This is now fixed. Managed hooks cannot be disabled by project-level or user-level settings. If you are on v2.1.48 or earlier, any `.claude/settings.json` in a cloned repo can disable all hooks including enterprise-mandated ones.

**Hardcoded sensitive-file prompt blocks all writes to `~/.claude/` in automation.** When Claude Code writes to paths under `~/.claude/`, a hardcoded sensitive-file check triggers an interactive prompt that [cannot be suppressed](https://github.com/anthropics/claude-code/issues/41615) by any user-configurable mechanism: `permissions.allow` entries, PreToolUse hooks returning `permissionDecision: "allow"`, `bypassPermissions` mode, and `skipDangerousModePermissionPrompt` all fail to override it. This blocks any automated workflow (tmux sessions, CI pipelines, autonomous agent loops) that needs to modify Claude Code configuration files. The prompt is hardcoded in the runtime, not in the permission system, so hooks cannot intercept it. Workaround: use Bash tool commands (`echo`, `cat`, `jq`) to write files directly rather than the Edit/Write tools, since the sensitive-file check only applies to Claude Code's built-in file tools. See [#41615](https://github.com/anthropics/claude-code/issues/41615).

**`WorktreeCreate` hooks cause indefinite session hang.** Any `WorktreeCreate` hook configured in project settings causes [`claude -w` to hang forever](https://github.com/anthropics/claude-code/issues/41614). Even a trivial hook (`echo ok < /dev/null`) causes the session to freeze. The hook executes and returns successfully (verified by file logging), but Claude Code never proceeds past the hook invocation. This is distinct from the [EnterWorktree ignoring hooks](#known-limitations) issue ([#36205](https://github.com/anthropics/claude-code/issues/36205)) — here the hook fires but the response is never consumed. Remove all `WorktreeCreate` hooks if you need `claude -w` to function. See [#41614](https://github.com/anthropics/claude-code/issues/41614).

**Plan mode auto-approves all tools when bypass permissions is configured (not active).** The permissions layer checks `isBypassPermissionsModeAvailable` rather than whether bypass mode is currently active. If `--dangerously-skip-permissions` has been configured (e.g., in VS Code settings or CLI flags), plan mode [auto-approves all tool calls](https://github.com/anthropics/claude-code/issues/41758) including Edit, Write, and Bash, even during normal non-bypass sessions. The bug is in the condition that gates plan mode enforcement: it treats "bypass is available" as equivalent to "bypass is active," defeating plan mode for anyone who has ever enabled the bypass capability. This compounds with [#40324](https://github.com/anthropics/claude-code/issues/40324) (plan mode prompt-only enforcement) and [#41545](https://github.com/anthropics/claude-code/issues/41545) (bypass overrides plan mode). Workaround: use `tool-block` rules for Write/Edit/MultiEdit and `bash-guard` for git push/commit during plan mode, or avoid configuring bypass permissions entirely. See [#41758](https://github.com/anthropics/claude-code/issues/41758).

**Large system prompts trigger premature context management, causing duplicate tool execution.** When CLAUDE.md and system prompts exceed approximately 35K tokens, context management fires on every turn with empty `applied_edits`, causing [all tool calls to execute twice](https://github.com/anthropics/claude-code/issues/41750). The model issues a tool call, context management triggers before the result is processed, and the model reissues the same tool call. This affects automated workflows with substantial CLAUDE.md configurations, hook injection text, or large rule sets. Not hookable at the context management layer. Workaround: keep total system prompt size below the context management threshold by splitting CLAUDE.md across multiple files (only the active file is loaded) or reducing hook output verbosity. See [#41750](https://github.com/anthropics/claude-code/issues/41750).

**Model ignores explicit user corrections during failing tool retry loops.** When Claude Code enters a loop of failing tool calls (e.g., a Bash command that returns an error), the model [acknowledges user corrections verbally but immediately repeats the same failing tool call](https://github.com/anthropics/claude-code/issues/41659) without incorporating the correction. This can persist for 4+ iterations. Not hookable — the model's retry decision happens in the inference layer, not at the tool call level. A PreToolUse hook could detect repeated identical tool calls and block after N retries, but cannot force the model to follow the user's alternative instruction. See [#41659](https://github.com/anthropics/claude-code/issues/41659).

**Suspicious path prompt silently downgrades `bypassPermissions` to `acceptEdits`.** When running with `--dangerously-skip-permissions`, a write or create operation targeting a path that triggers Claude Code's "suspicious path pattern" check (e.g., directories with underscores or uncommon names) produces a safety prompt. If the user selects "Yes, and always allow access to [path] from this project," the internal suggestion handler [unconditionally sets the permission mode to `acceptEdits`](https://github.com/anthropics/claude-code/issues/41763) without checking whether the current mode is already `bypassPermissions`. The mode silently downgrades, and all subsequent tool calls require per-tool approval for the rest of the session. Root cause: `pathValidation.ts` pushes `{type: 'setMode', mode: 'acceptEdits'}` for write operations with no guard against overwriting a higher-privilege mode. This compounds with [#37745](https://github.com/anthropics/claude-code/issues/37745) (hooks can reset bypass mode), [#37420](https://github.com/anthropics/claude-code/issues/37420) ("ask" permanently breaks bypass), and [#40328](https://github.com/anthropics/claude-code/issues/40328) (bypass partially broken). The pattern: multiple independent codepaths in Claude Code can downgrade `bypassPermissions` to a lower mode, and none of them check the current mode first. PreToolUse hooks fire regardless of permission mode and are unaffected by these downgrades. See [#41763](https://github.com/anthropics/claude-code/issues/41763).

**Hooks can only inject context, never remove or replace it.** Hooks (`PreCompact`, `PostToolUse`, etc.) can add `additionalContext` or `systemMessage` to the conversation, but [cannot remove, summarize, or replace](https://github.com/anthropics/claude-code/issues/41810) existing tool results or prior conversation turns. Duplicate information (re-reading the same file, re-running similar analysis) stays in context permanently until auto-compaction. Large Bash outputs remain in full even when only success/failure matters. Repeated `system-reminder` injections from multiple hooks compound. Not hookable — hooks are append-only by design. Workaround: keep hook output minimal, use `hookSpecificOutput` instead of `additionalContext` where possible, and design hooks to emit concise summaries rather than raw data. See [#41810](https://github.com/anthropics/claude-code/issues/41810).

**Disabled MCP servers still expose tools in deferred tools list.** When MCP servers are disabled via `disabledMcpServers` in `settings.local.json`, their tool names [still appear in the system-reminder deferred tools list](https://github.com/anthropics/claude-code/issues/41809) injected at session start. The model sees tool names for servers that cannot actually execute, wasting context tokens and potentially causing the model to attempt calls that will fail. Not hookable — the deferred tools list is assembled during startup before any tool call. See [#41809](https://github.com/anthropics/claude-code/issues/41809).

**MCP connector tools fail to load in scheduled unattended runs.** MCP tools attached to Claude.ai scheduled triggers (CCR) [load successfully during manual/test runs but fail with "No MCP tools are loaded"](https://github.com/anthropics/claude-code/issues/41805) when the same trigger fires on its cron schedule unattended. The connector initialization path differs between interactive and scheduled execution. Any autonomous workflow relying on MCP tools via scheduled triggers will silently lose access to those tools. Not hookable — MCP loading happens before any hook fires. See [#41805](https://github.com/anthropics/claude-code/issues/41805).

**Plan mode tools disabled globally when channel plugins exist.** When an MCP channel plugin (e.g., Telegram) is configured, `EnterPlanMode` and `ExitPlanMode` tools are [completely disabled](https://github.com/anthropics/claude-code/issues/41787) even for local terminal interactions where the plan approval dialog works fine. The check disables plan mode tools whenever channels exist in configuration, rather than checking whether the current prompt originated from a channel. Users who have a channel plugin configured but work at the terminal lose plan mode entirely. Not hookable — tool availability is resolved before hooks fire. See [#41787](https://github.com/anthropics/claude-code/issues/41787).

**Symlink-target matching for Read/Edit permission rules (partially fixed v2.1.89).** When `Read` or `Edit` permission rules use absolute paths (`//path`), v2.1.89 [now checks the resolved symlink target](https://github.com/anthropics/claude-code/issues/41793), not just the requested path. Before v2.1.89, a deny rule on `/etc/passwd` would not match if the model read via a symlink like `/tmp/link-to-passwd`. Hook-based enforcement using `file-guard` independently resolves symlinks on macOS (since v0.10.0) and matches on both the requested path and the resolved target. For pre-v2.1.89 users, hooks remain the only reliable symlink-aware enforcement. See [#41793](https://github.com/anthropics/claude-code/issues/41793).

**PreToolUse hooks support a fourth decision: `defer` (v2.1.89+).** In addition to `allow`, `deny`, and `ask`, hooks can now return `permissionDecision: "defer"` to [pause a headless session at the tool call](https://github.com/anthropics/claude-code/issues/41791). The session can later be resumed with `claude -p --resume <session-id>`, at which point the same PreToolUse hook re-evaluates. This enables async approval workflows where an external system (CI, Slack bot, human reviewer) decides whether to proceed. The current docs still describe PreToolUse as a three-outcome API. enforce-hooks does not generate `defer` hooks but the plugin mode passes through any `permissionDecision` value your rules emit. See [#41791](https://github.com/anthropics/claude-code/issues/41791).

**Formatter/linter hooks can cause stale-read warnings (v2.1.89+).** PostToolUse hooks that run formatters (`prettier --write`, `eslint --fix`) or linters that auto-fix rewrite files that Claude has already read. Claude Code now [warns when a Bash command modifies previously-read files](https://github.com/anthropics/claude-code/issues/41797), prompting a re-read before further edits. This is expected behavior for recommended formatter workflows, not a bug, but hook authors should be aware that formatter hooks trigger this warning cycle. Keep formatter hooks targeted (only process the specific edited file, not the entire project) to minimize stale-read churn. See [#41797](https://github.com/anthropics/claude-code/issues/41797).

**Hook output over 50K characters spills to disk (v2.1.89+).** Hook stdout, `additionalContext`, and async `systemMessage` payloads that exceed approximately 50,000 characters are [saved to disk with a file path and preview](https://github.com/anthropics/claude-code/issues/41799) instead of being injected directly into Claude's context. This means hooks that produce large output (verbose test results, full lint reports, large file listings) may not be fully visible to Claude. The docs still say hook output enters context "without truncation." Design hooks to emit concise summaries rather than raw data. session-log and safety-check hooks in this framework already follow this practice. See [#41799](https://github.com/anthropics/claude-code/issues/41799).

**PreToolUse hook with exit 0 and valid `hookSpecificOutput` displayed as "hook error."** A PreToolUse hook that exits 0 with valid JSON `hookSpecificOutput.additionalContext` is [displayed as "hook error" in the UI](https://github.com/anthropics/claude-code/issues/41868) even though the hook succeeded and the tool was not blocked. The model reads "hook error" and may abandon the task prematurely or retry unnecessarily. The hook output is delivered correctly (tool proceeds, context is injected), but the UI label is wrong. This affects any hook that uses `additionalContext` to inject advisory information. No workaround at the hook level — the mislabeling is in the UI renderer. See [#41868](https://github.com/anthropics/claude-code/issues/41868).

**`--dangerously-skip-permissions` flag no longer bypasses permission dialogs (v2.1.89 regression).** In v2.1.89, the `--dangerously-skip-permissions` flag [stops suppressing runtime permission prompts](https://github.com/anthropics/claude-code/issues/41848). File edits and bash commands still trigger per-tool confirmation despite the flag. This compounds with [#40328](https://github.com/anthropics/claude-code/issues/40328) (startup suppressed but runtime prompts fire), [#40552](https://github.com/anthropics/claude-code/issues/40552) (bypass unreliable), and [#41763](https://github.com/anthropics/claude-code/issues/41763) (suspicious paths downgrade bypass). Autonomous pipelines depending on this flag will stall. PreToolUse hooks returning `{"allow": true}` remain the only reliable prompt suppression mechanism. See [#41848](https://github.com/anthropics/claude-code/issues/41848).

**CLAUDE.md rules ignored when model suggests posting confidential info publicly.** Despite explicit CLAUDE.md rules prohibiting disclosure of confidential project information to public repositories, Claude [suggested filing a public issue containing client names, internal system details, and ticket references](https://github.com/anthropics/claude-code/issues/41852). The user caught it manually. This is another instance of text-based rules failing under task pressure ([#40537](https://github.com/anthropics/claude-code/issues/40537), [#40425](https://github.com/anthropics/claude-code/issues/40425)). A PreToolUse hook on Bash that blocks `gh issue create` or `git push` to public remotes would catch this. Not hookable at the suggestion level — the model generates the suggestion before any tool call. See [#41852](https://github.com/anthropics/claude-code/issues/41852).

**CLAUDE.md working directory instructions ignored across sessions.** CLAUDE.md specified a working directory (D: drive), but Claude [repeatedly operated on C: drive](https://github.com/anthropics/claude-code/issues/41850) across multiple sessions over 10 days. Verbal corrections during sessions were also ignored. This is a persistent compliance failure, not a one-off. A PreToolUse hook on Bash could enforce directory constraints by blocking commands that reference unauthorized paths. See [#41850](https://github.com/anthropics/claude-code/issues/41850).

**Auto-implementation triggered despite canceling planning phase.** With auto mode enabled, hitting Esc to cancel plan mode and add more context caused Claude to [start implementing automatically](https://github.com/anthropics/claude-code/issues/41861) instead of waiting for the revised input. The Esc action was interpreted as "proceed" rather than "cancel." Not hookable — the auto-mode trigger happens at the UI event layer before any tool call. Compounds with [#41545](https://github.com/anthropics/claude-code/issues/41545) (bypass overrides plan mode) and [#40324](https://github.com/anthropics/claude-code/issues/40324) (plan mode prompt-only enforcement). See [#41861](https://github.com/anthropics/claude-code/issues/41861).

**Custom commands and skills broken in v2.1.88-89.** Custom slash commands from `.claude/commands/` [do not appear in autocomplete and return "Unknown skill"](https://github.com/anthropics/claude-code/issues/41864) when invoked via the Skill tool in v2.1.89. A related regression in v2.1.88 causes [skills to invoke the wrong one or fail entirely](https://github.com/anthropics/claude-code/issues/41882), possibly due to an `EACCES` error on the bundled ripgrep binary. Additionally, standalone `.md` files in `.claude/skills/` are [not discoverable via slash command search](https://github.com/anthropics/claude-code/issues/41855) — only the `folder/SKILL.md` pattern works. These regressions affect any workflow that delivers enforcement rules or operational procedures via custom skills. Downgrade to v2.1.87 as a workaround. See [#41864](https://github.com/anthropics/claude-code/issues/41864), [#41882](https://github.com/anthropics/claude-code/issues/41882), [#41855](https://github.com/anthropics/claude-code/issues/41855). Related to [#41530](https://github.com/anthropics/claude-code/issues/41530) (v2.1.88 skills regression).

**Plugin `skills/` directory does not register slash commands.** Plugin skills defined in `skills/*/SKILL.md` work when the model invokes them via the Skill tool, but are [not registered as user-invocable `/` slash commands](https://github.com/anthropics/claude-code/issues/41842). Only the `commands/` directory registers slash commands. This contradicts official documentation. Plugin authors who provide enforcement workflows as skills cannot make them directly user-accessible. See [#41842](https://github.com/anthropics/claude-code/issues/41842).

**`attribution` setting does not control session URL in commit messages.** Setting `attribution.commit` to `""` removes the co-authored-by text but [does not remove the session deep link URL](https://github.com/anthropics/claude-code/issues/41873) (`https://claude.ai/code/session_...`). No setting controls this. The URL leaks tooling information in commit history. Not hookable at the attribution layer. A PostToolUse hook on Bash could intercept `git commit` commands and strip the URL, but this is fragile. See [#41873](https://github.com/anthropics/claude-code/issues/41873).

**MCP server instructions from `initialize` response dropped for HTTP/remote servers.** The `instructions` field in MCP `initialize` responses [works for stdio servers but is silently dropped for HTTP-transport servers](https://github.com/anthropics/claude-code/issues/41834). Server-side confirms instructions are returned. MCP servers that deliver enforcement context or operational guidelines via instructions cannot reach the model when using HTTP transport. Not hookable. See [#41834](https://github.com/anthropics/claude-code/issues/41834).

**No session or conversation identifier sent to MCP servers.** Claude Code does not echo back `Mcp-Session-Id` headers and provides [no conversation identifier to MCP servers](https://github.com/anthropics/claude-code/issues/41836), violating the MCP spec. MCP servers cannot maintain per-conversation state, track enforcement decisions across tool calls, or correlate requests within a session. Not hookable. See [#41836](https://github.com/anthropics/claude-code/issues/41836).

**Sandbox fails with "bwrap: execvp /bin/bash: No such file or directory" on Ubuntu 24.04.** Sandbox mode with custom filesystem allowlist causes [all Bash tool calls to fail](https://github.com/anthropics/claude-code/issues/41863) because bubblewrap cannot find `/bin/bash` inside the sandbox. Manual `bwrap` with the same binds works. Not hookable — sandbox filesystem assembly happens before tool execution. See [#41863](https://github.com/anthropics/claude-code/issues/41863).

**Unexpected SSH connection to GitHub on startup.** Claude Code initiates an [SSH connection to GitHub on startup](https://github.com/anthropics/claude-code/issues/41846) even when all remotes use HTTPS. This triggers Touch ID prompts for FIDO2 SSH keys and may fail in environments with restricted outbound SSH. The connection appears non-essential. Not hookable — the connection occurs during startup before any tool call or hook fires. See [#41846](https://github.com/anthropics/claude-code/issues/41846).

**Plugin hooks fire even when plugin is disabled in settings.** Plugins with `SessionStart` hooks [continue to fire](https://github.com/anthropics/claude-code/issues/41919) even when explicitly disabled via `enabledPlugins: false` in settings.json. The disable setting prevents the plugin's tools and skills from loading but does not suppress its hooks. This means a disabled enforcement plugin still injects context and runs checks, potentially confusing users who expect disabled to mean fully off. Not hookable — plugin lifecycle management happens before hooks fire. See [#41919](https://github.com/anthropics/claude-code/issues/41919).

**No option to suppress async hook completion notifications.** When multiple plugins with async hooks are enabled, `Async hook PreToolUse completed` and `PostToolUse completed` messages [create visual noise](https://github.com/anthropics/claude-code/issues/41901) in the UI. Each hook fires a separate notification. No setting controls this. Not hookable — the notification is generated by the hook runner itself. See [#41901](https://github.com/anthropics/claude-code/issues/41901).

**`--worktree` flag silently fails to create git worktree.** The `--worktree` (`-w`) flag [starts the session normally but creates no worktree](https://github.com/anthropics/claude-code/issues/41883) and produces no error. The session runs in the original working directory. Compounds with [#41614](https://github.com/anthropics/claude-code/issues/41614) (WorktreeCreate hook causes indefinite hang). Not hookable — worktree creation happens at the CLI startup layer. See [#41883](https://github.com/anthropics/claude-code/issues/41883).

**Opus ignores CLAUDE.md rules and memory across sessions.** A user with 10 hard-block rules in CLAUDE.md reports Opus 4.6 [consistently ignores them](https://github.com/anthropics/claude-code/issues/41830), repeating documented failures session after session. Memory files and CLAUDE.md rules are read but not reliably followed. Another instance of the enforcement gap described in [#32163](https://github.com/anthropics/claude-code/issues/32163), [#40425](https://github.com/anthropics/claude-code/issues/40425), [#40537](https://github.com/anthropics/claude-code/issues/40537). PreToolUse hooks remain the only mechanism that reliably blocks specific operations. See [#41830](https://github.com/anthropics/claude-code/issues/41830).

**`/insights` misclassifies intentional hook guardrails as friction.** The `/insights` command analyzes session data without considering user hook configuration and [systematically flags intentional guardrail blocks as friction](https://github.com/anthropics/claude-code/issues/41782), suggesting users remove them. This undermines enforcement by recommending removal of working safeguards. Not hookable — `/insights` runs its own analysis pipeline with no hook integration. See [#41782](https://github.com/anthropics/claude-code/issues/41782).

**Task tools (TaskPush, TaskDone) bypass PreToolUse hooks entirely.** The Task* family of internal tools [does not trigger PreToolUse hook events](https://github.com/anthropics/claude-code/issues/20243). Unlike the Agent tool (which fires hooks but may ignore exit codes per [#40580](https://github.com/anthropics/claude-code/issues/40580)), Task tools skip the hook lifecycle completely. Any enforcement logic in PreToolUse hooks is invisible to Task tool operations. This is part of a broader pattern where internal/system tools operate outside the hook system. Not hookable by definition. See [#20243](https://github.com/anthropics/claude-code/issues/20243).

**SDK ignores PostToolUse `continue: false` response.** When using the Claude Agent SDK, PostToolUse hooks that return `continue: false` (requesting session termination after a tool call) are [silently ignored](https://github.com/anthropics/claude-code/issues/29991). The session continues executing instead of stopping. This means PostToolUse hooks cannot reliably halt execution in SDK mode, even when they detect a dangerous operation that has already completed. Distinct from the Stop hook issue ([#40022](https://github.com/anthropics/claude-code/issues/40022)) which affects resumed sessions specifically. No workaround in SDK mode. See [#29991](https://github.com/anthropics/claude-code/issues/29991).

**`/reload-plugins` crashes when hooks declared as string path.** Marketplace plugins that declare hooks using the documented string-path form (`"hooks": "./hooks/hooks.json"`) cause a [TypeError on `/reload-plugins`](https://github.com/anthropics/claude-code/issues/41943): `J?.reduce is not a function`. The plugin loader expects hooks to be an array, not a string reference. This crashes the entire reload operation, not just the affected plugin. Affects any plugin (including enforce-hooks) that uses the string-path hooks format. Workaround: declare hooks inline as an array in the plugin manifest instead of referencing an external file. See [#41943](https://github.com/anthropics/claude-code/issues/41943).

**Windows: `bypassPermissions` fails on UNC paths.** On Windows, `bypassPermissions` mode [does not auto-approve Edit/Write](https://github.com/anthropics/claude-code/issues/41914) when the working directory uses UNC paths (`\\server\share\...`). Every file operation prompts for confirmation despite bypass mode being active. The path normalization logic does not recognize UNC paths as "within the project directory." This compounds with [#40328](https://github.com/anthropics/claude-code/issues/40328) (bypass partially broken) and [#41763](https://github.com/anthropics/claude-code/issues/41763) (suspicious path downgrades bypass). PreToolUse hooks returning `{"allow": true}` work regardless of path format. See [#41914](https://github.com/anthropics/claude-code/issues/41914).

**Hook output cannot control terminal rendering (no `suppressDiff`).** PreToolUse hooks can approve, deny, or modify tool inputs, but [cannot suppress Claude Code's built-in terminal rendering](https://github.com/anthropics/claude-code/issues/42014) of tool results. A user building an external diff viewer over Unix domain sockets reviews Edit/Write diffs in a purpose-built TUI, but Claude Code still renders the full inline diff redundantly in the terminal. IDE integrations (VS Code, JetBrains) already suppress terminal diffs and redirect to their native diff viewers, but hooks have no equivalent `suppressDiff` or `skipTerminalDiff` output field. External review tooling built on hooks always produces duplicated display. No workaround. See [#42014](https://github.com/anthropics/claude-code/issues/42014).

**Hook `file_path` now always absolute for Write/Edit/Read (v2.1.89+).** Before v2.1.89, PreToolUse and PostToolUse hooks sometimes received relative `file_path` values for Write, Edit, and Read tools, despite documentation stating paths would be absolute. This is [now fixed](https://github.com/anthropics/claude-code/releases/tag/v2.1.89). file-guard already handled both relative and absolute paths, but hooks that assumed absolute paths (e.g., checking prefixes like `/etc/` or `/home/`) could silently miss relative path inputs on older versions. If you are on v2.1.88 or earlier, always resolve paths in your hooks before matching.

**`PermissionDenied` hook event available (v2.1.89+).** A new hook event fires after the auto mode classifier denies a tool call. Return `{"hookSpecificOutput": {"retry": true}}` to tell the model it can retry the denied operation. Without this hook, auto mode denials are final and not retried. This enables custom recovery logic: for example, a hook could log the denial, adjust parameters, or escalate to a human reviewer. enforce-hooks does not yet generate PermissionDenied hooks. safety-check detects when this event is configured. See [#41261](https://github.com/anthropics/claude-code/issues/41261).

**Autocompact thrash loop now self-terminates (v2.1.89+).** Before v2.1.89, when context refilled to the limit immediately after compaction, Claude Code would [loop indefinitely](https://github.com/anthropics/claude-code/releases/tag/v2.1.89) burning API calls on repeated compaction cycles. v2.1.89 detects three consecutive refill-after-compact cycles and stops with an actionable error. This previously caused runaway costs in long sessions with large CLAUDE.md configs or verbose hook output. Stateful hooks that inject `additionalContext` on every tool call are a common trigger for context pressure that leads to thrash loops.

**PreToolUse hook "allow" bypassing deny rules re-fixed (v2.1.89).** The [original fix in v2.1.77](#pretooluse-hook-allow-no-longer-bypasses-deny-rules) for hooks overriding deny rules (including enterprise managed settings) was [incomplete or regressed](https://github.com/anthropics/claude-code/releases/tag/v2.1.89). v2.1.89 re-fixes this. If you updated past v2.1.77 and still saw hooks overriding deny rules, update to v2.1.89.

**Windows: hook command paths with `..` intermittently resolve wrong.** On Windows, hook commands that reference sibling directories via `..` (e.g., `node "../other-repo/.claude/scripts/hooks.mjs"`) [intermittently drop the `..` component](https://github.com/anthropics/claude-code/issues/42065), treating the target as a subdirectory instead of a sibling. Running the same command from bash in the same working directory resolves correctly. Affects all hook events (Stop, PreToolUse, PostToolUse). Quoting the path does not fix it. Workaround: use absolute paths in hook commands on Windows, or resolve paths in a wrapper script before invoking the hook. Related to [#39478](https://github.com/anthropics/claude-code/issues/39478) (spaces in working directory) and [#40084](https://github.com/anthropics/claude-code/issues/40084) (spaces in user profile path). See [#42065](https://github.com/anthropics/claude-code/issues/42065).

**PermissionRequest hook deny decision is ignored.** Returning `{"decision": "deny"}` from a PermissionRequest hook [does not suppress the permission prompt](https://github.com/anthropics/claude-code/issues/19298). The interactive dialog still appears regardless of the hook's output. PermissionRequest hooks cannot auto-deny dangerous commands; they can only auto-allow (which works). PreToolUse hooks are the reliable deny path. See [#19298](https://github.com/anthropics/claude-code/issues/19298).

**PermissionRequest hook races with the permission dialog.** PermissionRequest hooks run asynchronously. If the hook takes more than ~1-2 seconds to return, the [permission dialog appears anyway](https://github.com/anthropics/claude-code/issues/12176), even when the hook returns `{"behavior": "allow"}`. The dialog is added to UI state before awaiting hook results. Fast hooks (< 1s) work reliably; slow hooks (network calls, complex checks) race with the dialog. Breaks CI/CD workflows and security automation that depend on hooks intercepting prompts. See [#12176](https://github.com/anthropics/claude-code/issues/12176).

**PermissionRequest hooks do not fire for subagent permission requests.** When subagents spawned via Agent Teams need permission, the request is [delegated to the parent session's terminal prompt](https://github.com/anthropics/claude-code/issues/23983) without triggering PermissionRequest hooks. Main-session requests fire correctly. Notification hooks (Telegram, Slack) and auto-approval hooks are bypassed for all subagent permission requests. Compounds with [#37730](https://github.com/anthropics/claude-code/issues/37730) (subagents don't inherit permission settings) and [#40241](https://github.com/anthropics/claude-code/issues/40241) (bypass doesn't propagate). See [#23983](https://github.com/anthropics/claude-code/issues/23983).

**VS Code ignores hook `permissionDecision: "ask"`.** In the VS Code extension, PreToolUse hooks returning `{"permissionDecision": "ask"}` are [silently ignored](https://github.com/anthropics/claude-code/issues/13339). The same hooks work correctly in CLI. Other decisions (`allow`, `deny`, `block`) work in both environments. Hooks cannot enforce "ask before executing" policies in VS Code; only hard-allow or hard-deny. Workaround: use `"decision": "block"` instead of `"ask"`, at the cost of losing case-by-case approval. Compounds with [#40029](https://github.com/anthropics/claude-code/issues/40029) (Stop hooks don't fire in VS Code). See [#13339](https://github.com/anthropics/claude-code/issues/13339).

**Model can obfuscate terms to evade pattern-matching hooks.** Claude Code may [rewrite commands to avoid triggering hook patterns](https://github.com/anthropics/claude-code/issues/29691). If a PostToolUse hook flags a forbidden term, the model can vary its output to circumvent the check. This is not a platform bug but a fundamental limitation: any hook that relies on string matching against model output can be evaded by a sufficiently capable model rephrasing its response. Hooks that match on tool names or structural properties (file paths, exit codes) are more robust than those matching on content. See [#29691](https://github.com/anthropics/claude-code/issues/29691).

**Hooks cannot protect themselves from modification.** Claude can use Edit/Write tools to [modify hook scripts](https://github.com/anthropics/claude-code/issues/11226) that are meant to constrain it. `permissions.deny` rules do not reliably prevent this (see [#22055](https://github.com/anthropics/claude-code/issues/22055) for a regression). This is a circular security gap: the enforcement mechanism is editable by the entity being enforced. Workaround: set hook files to read-only via OS permissions (`chmod 444`), use managed settings for enterprise deployments, or place hooks outside the project directory where the model is less likely to discover them. See [#11226](https://github.com/anthropics/claude-code/issues/11226), [#22055](https://github.com/anthropics/claude-code/issues/22055).

**Built-in permission matching is structurally inadequate.** The permissions system's pattern matching has [30+ open issues](https://github.com/anthropics/claude-code/issues/30519) documenting failures: wildcards don't match compound commands, deny rules are bypassed via pipes, `&&` chains, and reordered flags. This is not a collection of bugs but a structural limitation: the matching model operates on full command strings rather than parsed ASTs. Hooks solve this by running arbitrary code that can parse commands properly (e.g., bash-guard splits compound commands into segments). See [#30519](https://github.com/anthropics/claude-code/issues/30519).

**Semantic rules are not enforceable.** Rules like "write clean code," "use descriptive variable names," or "keep functions under 20 lines" have no tool-call signal to match against. The tool skips these and explains why during `--scan`.

## Tests

```sh
python3 enforce-hooks.py --test
```

Covers directive classification, hook generation, suggestion discovery, runtime evaluation, content-guard, scoped-content-guard, flag patterns, and cache invalidation.

## License

MIT
