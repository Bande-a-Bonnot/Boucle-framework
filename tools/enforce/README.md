# enforce-hooks

Turn CLAUDE.md rules into PreToolUse hooks that actually block violations.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/enforce/install.sh | bash
```

Then tell Claude: **"enforce my CLAUDE.md rules"**

## The problem

CLAUDE.md directives rely on prompt compliance. Research shows compliance drops linearly as instruction count grows. "Never modify .env" works until context gets large enough that it doesn't.

## How it works

1. You install the skill (one command, copies a single file)
2. You ask Claude to enforce your rules
3. Claude reads your CLAUDE.md, identifies enforceable directives, generates hook scripts
4. You review the hooks and confirm
5. Hooks run before every tool call, blocking violations at the code level

No runtime dependencies. No external services. Generated hooks are standalone bash scripts in `.claude/hooks/`, scoped to your project.

## What's enforceable

Rules that constrain tool usage at call time:

| Directive | Hook type | What it blocks |
|-----------|-----------|----------------|
| "Never modify .env" | file-guard | Write/Edit to .env |
| "Don't force push" | bash-guard | `push --force` in Bash |
| "Search docs/ before web search" | require-prior-tool | WebSearch without prior Grep |
| "Don't commit to main" | branch-guard | git commit on main |
| "Never run rm -rf /" | bash-guard | dangerous command patterns |
| "Don't edit vendor/" | file-guard | Write/Edit to vendor/* |

Rules like "write clean code" or "be concise" are not enforceable (subjective, no tool-call signal). The skill explains why it skips them.

## Example

Given this CLAUDE.md:

```markdown
## Knowledge Retrieval @enforced
Before any WebSearch, grep docs/ first.

## Protected Files @enforced
Never modify .env, secrets/, or *.pem files.

## Code Style
Use 4-space indentation and snake_case.
```

Claude generates 2 hooks (skips Code Style), shows you a table of what each blocks, and asks for confirmation before writing files.

## Alternative: declarative rules

Instead of generated scripts, you can write JSON rule objects in `.claude/enforcements/`:

```json
{
  "name": "No Force Push",
  "directive": "Never use git push --force.",
  "trigger": { "tool": "Bash" },
  "condition": { "type": "block_args", "pattern": "push\\s+(-f|--force)" },
  "action": "block",
  "message": "Force push is blocked by CLAUDE.md"
}
```

Then register `engine.sh` as a PreToolUse hook. The engine reads all `.json` rules and enforces them. Condition types: `require_prior_tool`, `block_tool`, `block_args`, `require_args`, `block_file_pattern`.

## Project-scoped

Everything lives in `.claude/` at your project root:
- `.claude/skills/enforce-hooks/SKILL.md` (the skill)
- `.claude/hooks/enforce-*.sh` (generated hooks)
- `.claude/enforcements/*.json` (declarative rules, if using engine mode)

Nothing touches `~/.claude/` or other projects.

## Tests

```sh
bash tools/enforce/test.sh    # 16 tests
```

## License

MIT
