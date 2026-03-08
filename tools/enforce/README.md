# enforce-hooks

Turn CLAUDE.md rules into PreToolUse hooks that actually block violations.

## The problem

CLAUDE.md directives rely on prompt compliance. Compliance rates drop as context grows. "Never modify .env" works until it doesn't.

## The solution

Generate standalone bash hook scripts from your CLAUDE.md. Each hook runs before every tool call and blocks violations at the code level.

## As a Claude Code skill

Copy `SKILL.md` to your project:

```
mkdir -p .claude/skills/enforce-hooks
cp SKILL.md .claude/skills/enforce-hooks/
```

Then ask Claude: "Enforce my CLAUDE.md rules" or "Generate hooks from my CLAUDE.md."

Claude reads your CLAUDE.md, identifies enforceable directives, and generates hook scripts.

## What's enforceable

Rules that constrain tool usage at call time:

| Directive | Hook type | What it blocks |
|-----------|-----------|----------------|
| "Never modify .env" | file-guard | Write/Edit to .env |
| "Don't force push" | bash-guard | push --force in Bash |
| "Search docs before web" | require-prior-tool | WebSearch without prior Grep |
| "Don't commit to main" | branch-guard | git commit on main |
| "Run tests before committing" | require-prior-tool | git commit without cargo test |

Rules like "write clean code" are not enforceable (subjective, no tool-call signal). The skill skips these with an explanation.

## Example

Given this CLAUDE.md:

```markdown
## Knowledge Retrieval @enforced
Before any WebSearch, grep docs/ first.

## Protected Files @enforced
Never modify .env, secrets/, or *.pem files.

## No Force Push @enforced
Never use git push --force or git push -f.

## Code Style
Use 4-space indentation and snake_case.
```

The skill generates 3 hooks (skips Code Style as non-enforceable). See `examples/` for the generated scripts.

## Manual usage

Without the skill, use the standalone scripts:

- `generate.sh` -- extract @enforced directives from CLAUDE.md
- `engine.sh` -- PreToolUse hook that evaluates JSON rule objects

## File structure

```
enforce/
  SKILL.md          # Claude Code skill instructions
  engine.sh         # Runtime enforcement engine (JSON rules)
  generate.sh       # Directive extractor
  test-claude.md    # Test CLAUDE.md with sample directives
  examples/         # Example generated hooks
```
