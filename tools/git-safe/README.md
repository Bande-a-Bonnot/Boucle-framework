# git-safe

A Claude Code hook that prevents destructive git operations.

When Claude runs `git push --force`, `git reset --hard`, `git checkout HEAD -- path`, `git restore`, or other destructive commands, git-safe blocks the operation and suggests a safer alternative.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/git-safe/install.sh | bash
```

## What it blocks

| Operation | Why it's dangerous | Safer alternative |
|-----------|-------------------|-------------------|
| `git commit --no-verify` / `-n` | Skips pre-commit hooks (linting, tests, secrets) | Remove the flag; fix what hooks report |
| `git push --force` | Rewrites remote history | `git push --force-with-lease` |
| `git reset --hard` | Discards uncommitted changes | `git stash` first, or `git reset --soft` |
| `git checkout .` | Discards all working tree changes | `git stash` |
| `git checkout -- <file>` | Discards changes to file | `git stash` |
| `git checkout <ref> -- <path>` | Overwrites files from a ref | Commit or stash first |
| `git restore <path>` | Discards working tree changes | `git restore --staged` to unstage only |
| `git restore --source=<ref>` | Overwrites files from a ref | Commit or stash first |
| `git restore --worktree` | Explicitly discards changes | `git restore --staged` to unstage only |
| `git clean -f` | Deletes untracked files permanently | `git clean -n` (dry run first) |
| `git branch -D` | Force-deletes unmerged branch | `git branch -d` (only merged) |
| `git push --delete` | Permanently removes remote branches/tags | `git branch -d` for local cleanup |
| `git push origin :branch` | Alternate remote branch delete syntax | `git branch -d` for local cleanup |
| `git stash drop/clear` | Permanently deletes stashed work | |
| `git reflog expire` | Destroys recovery data | |

Force push to `main` or `master` is always blocked, even with an allowlist.

## Configuration

Create a `.git-safe` file to allow specific operations:

```
# Allow force push (but never to main/master)
allow: push --force

# Allow hard reset
allow: reset --hard
```

## Environment variables

```bash
GIT_SAFE_DISABLED=1   # Disable entirely
GIT_SAFE_LOG=1        # Debug logging to stderr
GIT_SAFE_CONFIG=path  # Custom config file location
```

## How it works

git-safe is a [PreToolUse hook](https://docs.anthropic.com/en/docs/claude-code/hooks) that inspects Bash commands before execution. It uses pattern matching to detect destructive git operations and returns a `block` decision with an explanation.

Safe operations (`git status`, `git commit`, `git push`, `git branch -d`, etc.) pass through without interference.

## Part of Boucle

git-safe is a standalone tool from the [Boucle framework](https://github.com/Bande-a-Bonnot/Boucle-framework). No framework installation required.
