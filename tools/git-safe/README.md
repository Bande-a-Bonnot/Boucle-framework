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

The hook reads this file from the repository targeted by the command. For
example, `git -C other-repo reset --hard` uses `other-repo/.git-safe`, not the
session's starting repository. A command touching multiple repositories needs
permission from each. If an explicit target cannot be resolved, the destructive
operation is blocked. `GIT_SAFE_CONFIG` remains an explicit override.

## Environment variables

```bash
GIT_SAFE_DISABLED=1   # Disable entirely
GIT_SAFE_LOG=1        # Debug logging to stderr
GIT_SAFE_CONFIG=path  # Custom config file location
```

## How it works

git-safe is a [PreToolUse hook](https://docs.anthropic.com/en/docs/claude-code/hooks) that inspects Bash commands before execution. It normalizes Git global options such as `-C` before matching destructive subcommands, then blocks with a human-readable reason on `stderr` plus exit code `2`.

Executable shell strings (`eval`, shell `-c`, `env -S`, and command substitutions) are
checked too, including substitutions in unquoted here-doc bodies. Literal
examples in single-quoted arguments and quoted here-doc bodies remain inert.
Shell quotes around literal executable names, Git options, and Git environment
assignments are removed for inspection. If an executable is selected by an
expansion, destructive Git-shaped arguments are checked with an unresolved
target; a shell-scanner failure denies the tool call.
Repeated `-C` targets are treated as ambiguous and require an
explicit `GIT_SAFE_CONFIG` override for a guarded operation.
Inherited, inline, or earlier exported `GIT_DIR`, `GIT_WORK_TREE`, or
`GIT_OBJECT_DIRECTORY` make the target ambiguous, so repository-local
allowlists are not applied. The same applies to wrapper options that change
the working directory, such as `sudo -D` and `env -C`. Options to `nice`,
`timeout`, `caffeinate`, and `stdbuf` are skipped before identifying the Git
command they run. Split strings passed to `env -S` are treated conservatively:
a literal mention of a destructive Git command inside such a string may be
blocked even when its intended executable only prints that text.

Safe operations (`git status`, `git commit`, `git push`, `git branch -d`, etc.) pass through without interference.

## Part of Boucle

git-safe is a standalone tool from the [Boucle framework](https://github.com/Bande-a-Bonnot/Boucle-framework). No framework installation required.
