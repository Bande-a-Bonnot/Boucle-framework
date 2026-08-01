---
name: enforce-hooks
description: "Analyze a CLAUDE.md file and install enforce-hooks so tagged rules become verified PreToolUse checks for covered tool calls. Use when users want CLAUDE.md directives enforced as code rather than relying on prompt compliance. Prefer the dynamic plugin mode (`--install-plugin`), which re-reads CLAUDE.md on every tool call. Per-rule generated bash hooks (`--install`) are an advanced fallback."
---

# Enforce Hooks

Turn CLAUDE.md rules into runtime checks for covered Claude Code tool calls.

## When to use

- User says "enforce my CLAUDE.md rules" or "generate hooks from my CLAUDE.md"
- User complains about Claude ignoring CLAUDE.md instructions
- User wants code-level checks for project rules
- User mentions `@enforced` directives

## Default workflow

Use dynamic plugin mode unless the user explicitly asks for individual generated
hook scripts.

1. Read the user's CLAUDE.md, or the file they specify.
2. Run `python3 tools/enforce/enforce-hooks.py --scan` from a local checkout, or
   download `enforce-hooks.py` and run `python3 enforce-hooks.py --scan`.
3. Explain which rules are enforceable, which are skipped, and why.
4. With the user's confirmation, run `python3 enforce-hooks.py --install-plugin`.
5. Verify with `python3 .claude/hooks/enforce-hooks.py --verify` and
   `python3 .claude/hooks/enforce-hooks.py --smoke-test`.
6. Tell the user to start a fresh Claude Code session from the same project root.

Plugin mode installs one PreToolUse wrapper plus the Python engine in
`.claude/hooks/`. It reads CLAUDE.md on every tool call, so rule changes do not
require regenerating scripts.

## What is enforceable

A directive is enforceable when the tool call itself contains enough signal to
decide before execution.

**Enforceable examples:**
- "Never modify .env files" -> file-guard rule for Write/Edit/MultiEdit paths
- "Don't force push" -> bash-guard rule for `push --force` and `push -f`
- "Always search locally before using web search" -> require-prior-tool rule
- "Don't commit to main" -> branch-guard rule for protected branches
- "Never run rm -rf" -> bash-guard rule for dangerous command patterns
- "Don't edit files in vendor/" -> file-guard path rule
- "Always run tests before committing" -> require-prior-tool or command rule
- "Never use sudo" -> bash-guard rule
- "Don't read files in secrets/" -> file-guard rule including Read
- "Use TypeScript, not JavaScript" -> content or path rule for generated files

**Not enforceable examples:**
- "Write clean code" (subjective, no tool-call signal)
- "Use descriptive variable names" (code quality, not a tool constraint)
- "Follow REST conventions" (architectural, not checkable at tool-call time)
- "Be concise in responses" (output style, not tool usage)

## User-facing summary format

Present findings briefly before installing:

```text
Found N enforceable directive(s):

| # | Directive | Rule type | What it checks |
|---|-----------|-----------|----------------|
| 1 | Never modify .env | file-guard | Write/Edit/MultiEdit to .env* |
| 2 | Don't force push | bash-guard | push --force, push -f |

Skipped M directive(s):
- Write clean code: subjective; no tool-call signal.
```

If no rules are tagged, suggest adding `@enforced` to the specific sections or
bullets that should become runtime checks.

## Install commands

Recommended project-local install:

```bash
python3 enforce-hooks.py --scan
python3 enforce-hooks.py --install-plugin
python3 .claude/hooks/enforce-hooks.py --verify
python3 .claude/hooks/enforce-hooks.py --smoke-test
```

From a fresh project without a local checkout:

```bash
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/enforce/install.sh | bash
python3 .claude/hooks/enforce-hooks.py --verify
python3 .claude/hooks/enforce-hooks.py --smoke-test
```

## Advanced per-rule mode

`python3 enforce-hooks.py --install` writes one generated bash hook per rule.
Use this only when the user specifically wants static scripts they can inspect
or modify independently. In that mode, re-run installation after CLAUDE.md
changes.

## Boundaries

enforce-hooks is not a sandbox. It checks covered Claude Code tool calls. It
does not see prompt assembly, external processes, OS-level side effects outside
Claude Code, or every platform-specific hook bypass. For critical boundaries,
pair hooks with OS permissions, containers, network controls, or separate
out-of-process validation.
