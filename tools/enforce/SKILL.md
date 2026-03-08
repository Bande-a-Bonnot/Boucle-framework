---
name: enforce-hooks
description: "Analyze a CLAUDE.md file and generate PreToolUse hook scripts that enforce its rules at the tool-call level. Use when users want their CLAUDE.md directives enforced as code rather than relying on prompt compliance. Reads the CLAUDE.md, identifies enforceable rules, generates standalone bash hook scripts, and wires them into .claude/settings.json."
---

# Enforce Hooks

Generate PreToolUse hook scripts from CLAUDE.md directives.

## When to use

- User says "enforce my CLAUDE.md rules" or "generate hooks from my CLAUDE.md"
- User complains about Claude ignoring CLAUDE.md instructions
- User wants code-level enforcement of their rules
- User mentions `@enforced` directives

## How it works

1. Read the user's CLAUDE.md (or the file they specify)
2. Classify each directive as enforceable or not
3. For each enforceable directive, generate a standalone bash hook script
4. Show the user what you found and what hooks you would create
5. On confirmation, write the hooks and update .claude/settings.json

## What is enforceable

A directive is enforceable if it can be checked at tool-call time. The hook receives the tool name and input JSON before execution and can block it.

**Enforceable (yes):**
- "Never modify .env files" -> file-guard hook (block Write/Edit to .env)
- "Don't force push" -> bash-guard hook (block `push --force` in Bash)
- "Always search locally before using web search" -> require-prior-tool hook
- "Don't commit to main" -> branch-guard hook (block git commit on main)
- "Never run rm -rf" -> bash-guard hook (block pattern in Bash commands)
- "Don't edit files in vendor/" -> file-guard hook (block by path pattern)
- "Always run tests before committing" -> require-prior-tool hook
- "Never use sudo" -> bash-guard hook
- "Don't read files in secrets/" -> file-guard hook (block Read too)
- "Use TypeScript, not JavaScript" -> file-guard hook (block Write to *.js)

**Not enforceable (skip with explanation):**
- "Write clean code" (subjective, no tool-call signal)
- "Use descriptive variable names" (code quality, not a tool constraint)
- "Follow REST conventions" (architectural, not checkable at tool-call time)
- "Be concise in responses" (output style, not tool usage)

## Hook templates

Use these templates as the basis for generated hooks. Each hook is a standalone bash script that reads JSON from stdin and outputs a JSON decision.

### Template: file-guard

Blocks Write, Edit, or Read operations on protected files.

```bash
#!/usr/bin/env bash
# enforce: {DIRECTIVE_TEXT}
# Generated from CLAUDE.md by enforce-hooks skill
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name')
case "$TOOL" in Write|Edit|MultiEdit|Read) ;; *) exit 0 ;; esac
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$FILE" ] && exit 0
BLOCKED_PATTERNS=({PATTERNS})
for pat in "${BLOCKED_PATTERNS[@]}"; do
  [[ "$FILE" == *"$pat"* ]] && echo "{\"decision\": \"block\", \"reason\": \"Protected: $FILE matches $pat. CLAUDE.md: {SHORT_DIRECTIVE}\"}" && exit 0
done
exit 0
```

Replace {PATTERNS} with quoted glob patterns like `".env" "secrets/" "*.pem"`.
Replace {DIRECTIVE_TEXT} with the original CLAUDE.md text.
Replace {SHORT_DIRECTIVE} with a truncated version for the block message.
Adjust the case statement: remove `Read` if the directive only blocks writes.

### Template: bash-guard

Blocks dangerous patterns in Bash commands.

```bash
#!/usr/bin/env bash
# enforce: {DIRECTIVE_TEXT}
INPUT=$(cat)
[ "$(echo "$INPUT" | jq -r '.tool_name')" != "Bash" ] && exit 0
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
BLOCKED=({PATTERNS})
for pat in "${BLOCKED[@]}"; do
  [[ "$CMD" == *"$pat"* ]] && echo "{\"decision\": \"block\", \"reason\": \"Blocked command pattern: $pat. CLAUDE.md: {SHORT_DIRECTIVE}\"}" && exit 0
done
exit 0
```

Replace {PATTERNS} with quoted command fragments like `"push --force" "rm -rf /" "sudo "`.

### Template: branch-guard

Blocks git operations on protected branches.

```bash
#!/usr/bin/env bash
# enforce: {DIRECTIVE_TEXT}
INPUT=$(cat)
[ "$(echo "$INPUT" | jq -r '.tool_name')" != "Bash" ] && exit 0
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
PROTECTED=({BRANCHES})
for b in "${PROTECTED[@]}"; do
  if [ "$BRANCH" = "$b" ]; then
    case "$CMD" in
      *"git commit"*|*"git merge"*|*"git push"*)
        echo "{\"decision\": \"block\", \"reason\": \"Branch $b is protected. CLAUDE.md: {SHORT_DIRECTIVE}\"}"
        exit 0 ;;
    esac
  fi
done
exit 0
```

Replace {BRANCHES} with quoted branch names like `"main" "master" "production"`.

### Template: require-prior-tool

Blocks a tool unless another tool was used first in the session.

```bash
#!/usr/bin/env bash
# enforce: {DIRECTIVE_TEXT}
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name')
# Only check for the target tools
case "$TOOL" in {TARGET_TOOLS}) ;; *) exit 0 ;; esac
# Check session log for required prior tool
TODAY=$(date -u +%Y-%m-%d)
LOG="$HOME/.claude/session-logs/$TODAY.jsonl"
if [ -f "$LOG" ]; then
  if grep -q '"tool":"{REQUIRED_TOOL}"' "$LOG" 2>/dev/null; then
    exit 0
  fi
fi
echo "{\"decision\": \"block\", \"reason\": \"Run {REQUIRED_TOOL} first. CLAUDE.md: {SHORT_DIRECTIVE}\"}"
exit 0
```

Replace {TARGET_TOOLS} with pipe-separated tool names like `WebSearch|WebFetch`.
Replace {REQUIRED_TOOL} with the tool that must be used first like `Grep`.

**Note:** require-prior-tool needs session-log hook installed to work. If it's not installed, mention this to the user and offer to set it up.

### Template: tool-blocker

Unconditionally blocks a specific tool.

```bash
#!/usr/bin/env bash
# enforce: {DIRECTIVE_TEXT}
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name')
case "$TOOL" in {BLOCKED_TOOLS}) ;; *) exit 0 ;; esac
echo "{\"decision\": \"block\", \"reason\": \"{BLOCK_REASON}. CLAUDE.md: {SHORT_DIRECTIVE}\"}"
exit 0
```

## Installation procedure

After generating hooks, install them:

1. Create directory: `mkdir -p .claude/hooks`
2. Write each hook script to `.claude/hooks/{hook-name}.sh`
3. Make executable: `chmod +x .claude/hooks/{hook-name}.sh`
4. Update `.claude/settings.json` to register the hooks

The settings.json hooks section should look like:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {"type": "command", "command": ".claude/hooks/enforce-file-guard.sh"},
          {"type": "command", "command": ".claude/hooks/enforce-bash-guard.sh"}
        ]
      }
    ]
  }
}
```

Use `matcher: ""` to run the hook on every tool call (the hook scripts do their own filtering).

If `.claude/settings.json` already exists with hooks, MERGE the new hooks into the existing array. Do not overwrite existing hooks.

## Interaction pattern

Present findings as a table:

```
Found N enforceable directives in your CLAUDE.md:

| # | Directive | Hook type | What it blocks |
|---|-----------|-----------|----------------|
| 1 | "Never modify .env" | file-guard | Write/Edit to .env* |
| 2 | "Don't force push" | bash-guard | push --force, push -f |
| 3 | ... | ... | ... |

Skipped M directives (not enforceable at tool-call level):
- "Write clean code" (subjective, no tool-call signal)
- ...

Generate these hooks? I'll create them in .claude/hooks/ and update settings.json.
```

Wait for user confirmation before writing any files.

## Testing

After installation, suggest the user test each hook:

```
To verify your hooks work:
1. Try editing .env -> should be blocked with a clear message
2. Try running `git push --force` -> should be blocked
3. Normal operations should work unchanged
```
