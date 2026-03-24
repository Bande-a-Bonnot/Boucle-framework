# worktree-guard

PreToolUse hook for Claude Code that prevents data loss from worktree exit.

## The Problem

When you use `claude -w` to work in a worktree, exiting the session deletes the worktree branch and all its commits. If those commits were never pushed or merged, they're silently lost. The only recovery path is `git fsck --unreachable`, and only until `git gc` runs.

See [anthropics/claude-code#38287](https://github.com/anthropics/claude-code/issues/38287).

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/worktree-guard/install.sh | bash
```

## What It Checks

When Claude tries to exit a worktree, the hook checks four things:

1. **Uncommitted changes** (staged or unstaged modifications)
2. **Untracked files** (new files not yet added to git)
3. **Unmerged commits** (commits on the current branch not in main/master)
4. **Unpushed commits** (commits not pushed to the remote tracking branch)

If any check fails, exit is blocked with a message explaining what needs to happen first.

## Config

Create `.worktree-guard` in your project root or home directory:

```
# Skip specific checks
allow: uncommitted     # permit uncommitted changes
allow: untracked       # permit untracked files
allow: unmerged        # permit unmerged commits
allow: unpushed        # permit unpushed commits

# Override base branch detection (default: auto-detect main/master)
base: develop
```

## Environment Variables

| Variable | Effect |
|---|---|
| `WORKTREE_GUARD_DISABLED=1` | Disable the hook entirely |
| `WORKTREE_GUARD_LOG=1` | Log all checks to stderr |

## How It Works

The hook registers as a `PreToolUse` hook with `ExitWorktree` matcher. When Claude Code attempts to exit a worktree session, the hook runs git commands to check the working tree state. If it finds uncommitted changes, untracked files, or unmerged/unpushed commits, it returns a block decision with a description of what needs to be resolved.

The hook auto-detects the base branch by checking `origin/main`, `origin/master`, `main`, then `master`. Override with the `base:` config directive if your repo uses a different default branch.

## Tests

```sh
bash tools/worktree-guard/test.sh
```

## License

MIT
