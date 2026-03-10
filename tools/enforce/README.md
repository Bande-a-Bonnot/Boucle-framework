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

## The Problem

CLAUDE.md directives rely on prompt compliance. Compliance drops as instruction count grows. "Never modify .env" works until context gets large enough that it doesn't.

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
| "Never run rm -rf @enforced" | bash-guard | dangerous command patterns |
| "Use pnpm instead of npm @enforced" | bash-guard | npm commands |
| "Don't commit directly to main @enforced" | branch-guard | git commit/push on main |
| "Don't use WebSearch @enforced" | tool-block | Block tool by name |
| "Always run tests before committing @enforced" | require-prior-tool | Commit without prior test run |
| "Read test file before editing source @enforced" | require-prior-tool | Edit without prior Read |
| "Never write `console.log` @enforced" | content-guard | Edit/Write containing banned pattern |
| "Don't use the `any` type @enforced" | content-guard | Edit/Write containing banned code |

Rules like "write clean code" or "be concise" are skipped (subjective, no tool-call signal). The tool explains what it skips and why.

## Example

Given this CLAUDE.md:

```markdown
## Safety Rules
- Never modify .env files @enforced
- Don't run `rm -rf` or `sudo` @enforced
- Never commit to main @enforced

## Code Style
- Use 4-space indentation and snake_case
```

```
$ python3 enforce-hooks.py --scan

Found 3 enforceable directive(s):

  #  Type                  What it blocks                            Source line
---  ----                  ---                                       ---
  1  file-guard            Block Write/Edit to: .env                 L3
  2  bash-guard            Block commands: rm -rf, sudo              L4
  3  branch-guard          Block commits to: main                    L5
```

The `@enforced` tag tells enforce-hooks which rules to activate.

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
  --evaluate          PreToolUse mode: read tool call from stdin, output decision
  --json              Output as JSON (with --scan)
  --hooks-dir         Directory for hooks (default: .claude/hooks)
  --settings          Path to settings.json (default: .claude/settings.json)
  --test              Run self-tests (171 assertions)
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

## Tests

```sh
python3 enforce-hooks.py --test
```

171 assertions covering directive classification, hook generation, suggestion discovery, runtime evaluation, content-guard, and cache invalidation.

## License

MIT
