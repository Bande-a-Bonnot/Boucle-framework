# branch-guard

A Claude Code hook that prevents direct commits to protected branches (main, master, production, release). Forces feature-branch workflow.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/branch-guard/install.sh | bash
```

## What it does

Blocks `git commit` on protected branches. Allows commits on any other branch.

```
✗ git commit -m "fix" (on main)     → blocked
✓ git commit -m "fix" (on feature/) → allowed
✓ git commit --amend (on main)      → allowed (amending, not new commit)
```

## Configure

Create `.branch-guard` in your project root:

```
protect: main
protect: staging
protect: deploy
```

Or set via environment variable:

```sh
BRANCH_GUARD_PROTECTED=main,master,staging
```

Default protected branches (when no config): `main`, `master`, `production`, `release`.

## Disable

```sh
BRANCH_GUARD_DISABLED=1
```

## Works with

- **git-safe**: Prevents destructive git operations (force push, reset --hard)
- **bash-guard**: Blocks dangerous shell commands (rm -rf, eval)
- **file-guard**: Protects sensitive files from modification

Together they form a complete safety net for AI-assisted development.

## License

MIT
