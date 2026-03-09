# enforce-hooks

Turn CLAUDE.md rules into PreToolUse hooks that actually block violations.

## Quick Start

```sh
# Try it without cloning (scans your project's CLAUDE.md)
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/enforce/enforce-hooks.py -o /tmp/enforce-hooks.py && python3 /tmp/enforce-hooks.py --scan

# Or clone and run locally
python3 enforce-hooks.py --scan       # show enforceable directives
python3 enforce-hooks.py --generate   # print hook scripts to stdout
python3 enforce-hooks.py --install    # write hooks and update settings.json
```

## The Problem

CLAUDE.md directives rely on prompt compliance. Compliance drops as instruction count grows. "Never modify .env" works until context gets large enough that it doesn't.

## How It Works

1. Point the tool at your CLAUDE.md
2. It identifies enforceable directives (rules that constrain tool usage)
3. It generates standalone bash hook scripts
4. Hooks run before every tool call, blocking violations at the code level

No runtime dependencies beyond Python 3.6+ and `jq`. Generated hooks are standalone bash scripts.

## What's Enforceable

| Directive | Hook type | What it blocks |
|-----------|-----------|----------------|
| "Never modify .env" | file-guard | Write/Edit to .env |
| "Don't edit the Makefile" | file-guard | Write/Edit to Makefile |
| "Don't force push" | bash-guard | `push --force`, `push -f` in Bash |
| "Never reset --hard" | bash-guard | `reset --hard` in Bash |
| "Always run tests before committing" | require-prior-tool | Commit without prior test run |
| "Don't commit directly to main" | branch-guard | git commit/push on main |
| "Don't use WebSearch" | tool-block | Block tool by name |
| "Never run rm -rf" | bash-guard | dangerous command patterns |
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

  --scan          Show enforceable directives (default)
  --generate      Print hook scripts to stdout
  --install       Write hooks and update settings.json
  --json          Output as JSON (with --scan)
  --hooks-dir     Directory for hooks (default: .claude/hooks)
  --settings      Path to settings.json (default: .claude/settings.json)
  --test          Run self-tests (77 assertions)
```

Auto-detects CLAUDE.md in the current or parent directories if no file is specified.

## As a Claude Code Skill

Copy `SKILL.md` to `.claude/skills/enforce-hooks/SKILL.md` in your project. Then tell Claude: **"enforce my CLAUDE.md rules"**. Claude reads your CLAUDE.md, shows you what it found, and generates hooks on confirmation.

## Tests

```sh
python3 enforce-hooks.py --test
```

## License

MIT
