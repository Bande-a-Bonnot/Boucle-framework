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

## Known Limitations

**Mid-session worktree operations may bypass hooks.** When Claude uses the Agent tool with `isolation: "worktree"`, the worktree lifecycle is managed internally. [EnterWorktree ignores configured hooks](https://github.com/anthropics/claude-code/issues/36205) for these operations. worktree-guard fires on explicit ExitWorktree tool calls, but may not fire for internally-managed worktree cleanup.

**CWD drift after background agents.** After a background Agent with worktree isolation completes, the parent session's working directory can [silently drift to the worktree path](https://github.com/anthropics/claude-code/issues/38448). This is outside the hook lifecycle and cannot be detected by any PreToolUse hook.

**`--worktree --tmux` skips hooks entirely.** When Claude Code is launched with both `--worktree` and `--tmux`, it uses a separate codepath that [creates git worktrees directly](https://github.com/anthropics/claude-code/issues/39281), bypassing WorktreeCreate and WorktreeRemove hooks. worktree-guard cannot fire in this mode. Workaround: use `--worktree` without `--tmux`.

**Stop hooks fail after worktree cleanup.** After a worktree is removed (post-merge), stop hooks [fail with ENOENT](https://github.com/anthropics/claude-code/issues/39432) because the session's CWD no longer exists. Node.js reports the error on `/bin/sh` rather than the missing CWD. This can prevent any cleanup hooks from running.

**Worktree memory resolves to wrong project directory.** When Claude Code launches from a linked worktree, it uses `git rev-parse --git-common-dir` to derive the project path, which resolves to the main worktree's `.git` directory. This means [both worktrees share the same memory file](https://github.com/anthropics/claude-code/issues/39920), causing cross-contamination of project-specific memory. This is a Claude Code internal behavior that hooks cannot change.

**Worktree isolation can silently fail.** The Agent tool's `isolation: "worktree"` option can [silently run the agent in the main repository](https://github.com/anthropics/claude-code/issues/39886) instead of creating an isolated worktree. The result metadata shows `worktreePath: done` (not an actual path) and `worktreeBranch: undefined`. The agent commits directly to the main checkout's branch with zero isolation. This cannot be detected or prevented by hooks. If you run parallel agents that modify git state, verify `worktreePath` in agent results before trusting branch isolation.

## Tests

```sh
bash tools/worktree-guard/test.sh
```

## License

MIT
