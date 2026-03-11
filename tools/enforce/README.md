# enforce-hooks

Turn CLAUDE.md rules into PreToolUse hooks that actually block violations.

Claude Code's CLAUDE.md lets you write project rules, but Claude follows them on a best-effort basis. enforce-hooks reads your rules and generates hooks that deterministically block violations before they happen.

## Quick Start

**One command (recommended):**

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/enforce/install.sh | bash
```

**Or manually (inspect before installing):**

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/enforce/enforce-hooks.py -o /tmp/enforce-hooks.py
python3 /tmp/enforce-hooks.py --scan             # preview what's enforceable
python3 /tmp/enforce-hooks.py --install-plugin   # install
```

## Why Hooks Instead of Rules

CLAUDE.md rules rely on the model choosing to comply. That breaks down in three specific ways:

1. **Compliance decay**: As conversations grow and context compacts, CLAUDE.md directives lose influence. A "never modify .env" rule works at the start and stops working later.
2. **Subagent blindness**: Path-specific rules and some CLAUDE.md sections [don't load in subagents or teammates](https://github.com/anthropics/claude-code/issues/32906). A spawned agent can violate rules it never received.
3. **No enforcement boundary**: Rules are suggestions. There is no mechanism to make the model fail when it violates one. It can read "never force push" and still run `git push --force`.

PreToolUse hooks solve all three. They run as code before every tool call, they fire in every context (including subagents), and they return a hard block that the model cannot override.

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

**Semantic rules are not enforceable.** Rules like "write clean code," "use descriptive variable names," or "keep functions under 20 lines" have no tool-call signal to match against. The tool skips these and explains why during `--scan`.

## Tests

```sh
python3 enforce-hooks.py --test
```

Covers directive classification, hook generation, suggestion discovery, runtime evaluation, content-guard, scoped-content-guard, flag patterns, and cache invalidation.

## License

MIT
