# enforce-hooks

Turn CLAUDE.md rules into PreToolUse hooks that actually block violations.

## Quick Start

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/enforce/install.sh | bash
```

Or download and run manually:

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

| Directive | Hook type | What it blocks |
|-----------|-----------|----------------|
| "Never modify .env" | file-guard | Write/Edit to .env |
| "Don't read files in secrets/" | file-guard | Read/Write/Edit in secrets/ |
| "Don't force push" | bash-guard | `push --force`, `push -f` in Bash |
| "Never reset --hard" | bash-guard | `reset --hard` in Bash |
| "Always run tests before committing" | require-prior-tool | Commit without prior test run |
| "Don't commit directly to main" | branch-guard | git commit/push on main |
| "Don't use WebSearch" | tool-block | Block tool by name |
| "Never run rm -rf" | bash-guard | dangerous command patterns |
| "Use pnpm instead of npm" | bash-guard | npm commands |
| "Protected files: X, Y" | file-guard | Listed file patterns |
| "Blocked commands: X, Y" | bash-guard | Listed command patterns |

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

The `@enforced` tag is optional but recommended for clarity.

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
  --test              Run self-tests (134 assertions)
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

134 assertions covering directive classification, hook generation, runtime evaluation, and cache invalidation.

## License

MIT
