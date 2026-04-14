#!/bin/bash
# git-safe: PreToolUse hook for Claude Code
# Prevents destructive git operations that can lose work.
#
# Blocked operations:
#   - git push --force / -f (can rewrite remote history)
#   - git reset --hard (discards uncommitted changes)
#   - git checkout . / git checkout -- <file> (discards changes)
#   - git checkout <ref> -- <path> (overwrites files from ref)
#   - git restore without --staged (discards working tree changes)
#   - git restore --source / -s (overwrites from arbitrary ref)
#   - git clean -f (deletes untracked files permanently)
#   - git branch -D (force-deletes unmerged branches)
#   - git stash drop / clear (permanently deletes stashed work)
#   - git commit --no-verify / -n (skips pre-commit hooks)
#   - git push --delete / origin :branch (removes remote refs)
#   - git rebase without safeguards
#   - git reflog expire (destroys recovery data)
#   - git filter-branch / filter-repo (rewrites entire history)
#   - git push --mirror (overwrites all remote refs)
#   - git update-ref -d (low-level ref deletion)
#   - git gc --prune=now (premature garbage collection)
#   - git remote remove (removes remote configuration)
#   - git submodule deinit --force (force-removes submodule data)
#   - git worktree remove --force (force-removes dirty worktrees)
#   - git tag -d (deletes local tags)
#   - git config --system/--global (modifies global git config)
#   - git merge --no-verify (skips pre-merge hooks)
#   - git push via refspec to protected branches
#
# Install:
#   curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/git-safe/install.sh | bash
#
# Config (.git-safe):
#   allow: push --force    # whitelist specific operations
#   allow: reset --hard
#
# Env vars:
#   GIT_SAFE_DISABLED=1    Disable the hook entirely
#   GIT_SAFE_LOG=1         Log all checks to stderr

set -euo pipefail

if [ "${GIT_SAFE_DISABLED:-0}" = "1" ]; then
  exit 0
fi

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only check Bash commands
if [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
if [ -z "$COMMAND" ]; then
  exit 0
fi

log() {
  if [ "${GIT_SAFE_LOG:-0}" = "1" ]; then
    echo "[git-safe] $*" >&2
  fi
}

# Check if command contains git
if ! echo "$COMMAND" | grep -q 'git\b' 2>/dev/null; then
  log "SKIP: no git command"
  exit 0
fi

# Load allowlist from .git-safe config
ALLOWED=()
CONFIG="${GIT_SAFE_CONFIG:-.git-safe}"
if [ -f "$CONFIG" ]; then
  while IFS= read -r line; do
    line=$(echo "$line" | sed 's/#.*//' | xargs)
    [ -z "$line" ] && continue
    if [[ "$line" == allow:* ]]; then
      pattern=$(echo "$line" | sed 's/^allow:\s*//' | xargs)
      ALLOWED+=("$pattern")
    fi
  done < "$CONFIG"
fi

# Check if an operation is allowed via config
is_allowed() {
  local op="$1"
  for a in "${ALLOWED[@]+"${ALLOWED[@]}"}"; do
    if [ "$a" = "$op" ]; then
      log "ALLOWED by config: $op"
      return 0
    fi
  done
  return 1
}

block() {
  local reason="$1"
  local suggestion="${2:-}"
  local msg="git-safe: $reason"
  if [ -n "$suggestion" ]; then
    msg="$msg Suggestion: $suggestion"
  fi
  printf '%s\n' "$msg" >&2
  exit 2
}

# --- Destructive operation checks ---

# git commit/merge/push --no-verify / -n (skips safety hooks like pre-commit, pre-push)
# See: https://github.com/anthropics/claude-code/issues/40117
if echo "$COMMAND" | grep -qE 'git\s+(commit|merge|push|cherry-pick|revert|am)\s.*--no-verify' 2>/dev/null; then
  is_allowed "no-verify" || block "git --no-verify skips pre-commit/pre-push hooks, bypassing safety checks like linting, tests, and secret scanning." "Remove --no-verify and let hooks run. Fix any issues they report. Add 'allow: no-verify' to .git-safe only if you understand the risk."
fi
# Also catch -n shorthand for commit (git commit -n is --no-verify)
if echo "$COMMAND" | grep -qE 'git\s+commit\s+(-[a-zA-Z]*n[a-zA-Z]*\b|.*\s-[a-zA-Z]*n[a-zA-Z]*\b)' 2>/dev/null; then
  # Don't false-positive on --dry-run (-n for some commands) — commit's -n IS --no-verify
  if ! echo "$COMMAND" | grep -q '\-\-no-verify' 2>/dev/null; then
    is_allowed "no-verify" || block "git commit -n skips pre-commit hooks (same as --no-verify)." "Remove -n and let pre-commit hooks run. Add 'allow: no-verify' to .git-safe only if you understand the risk."
  fi
fi

# git push --force / -f (but not --force-with-lease which is safer)
if echo "$COMMAND" | grep -qE 'git\s+push\s.*--force(\s|$)' 2>/dev/null; then
  if echo "$COMMAND" | grep -q '\-\-force-with-lease' 2>/dev/null; then
    log "ALLOW: --force-with-lease is safe"
  else
    is_allowed "push --force" || block "Force push can rewrite remote history and lose commits for other collaborators." "Use --force-with-lease instead, or add 'allow: push --force' to .git-safe."
  fi
fi
if echo "$COMMAND" | grep -qE 'git\s+push\s+(-[a-zA-Z]*f\b|.*\s-[a-zA-Z]*f\b)' 2>/dev/null; then
  if ! echo "$COMMAND" | grep -q '\-\-force' 2>/dev/null; then
    is_allowed "push --force" || block "Force push (-f) can rewrite remote history and lose commits." "Use --force-with-lease instead, or add 'allow: push --force' to .git-safe."
  fi
fi

# git reset --hard
if echo "$COMMAND" | grep -qE 'git\s+reset\s.*--hard' 2>/dev/null; then
  is_allowed "reset --hard" || block "git reset --hard discards all uncommitted changes permanently." "Commit or stash changes first, or add 'allow: reset --hard' to .git-safe."
fi

# git checkout . / git checkout -- (discards working tree changes)
if echo "$COMMAND" | grep -qE 'git\s+checkout\s+\.\s*$' 2>/dev/null; then
  is_allowed "checkout ." || block "git checkout . discards all uncommitted changes in the working tree." "Commit or stash changes first, or add 'allow: checkout .' to .git-safe."
fi
if echo "$COMMAND" | grep -qE 'git\s+checkout\s+--\s' 2>/dev/null; then
  is_allowed "checkout --" || block "git checkout -- discards uncommitted changes to specified files." "Commit or stash first, or add 'allow: checkout --' to .git-safe."
fi

# git checkout <ref> -- <path> (overwrites working tree from a specific ref)
# Catches: git checkout HEAD -- src/, git checkout main -- file.js, git checkout abc123 -- .
# Does NOT catch: git checkout -- file (no ref; already caught above)
# Does NOT catch: git checkout -b branch (flag, not ref)
if echo "$COMMAND" | grep -qE 'git\s+checkout\s+[^-][^ ]*\s+--\s' 2>/dev/null; then
  is_allowed "checkout ref --" || block "git checkout <ref> -- <path> overwrites working tree files with the version from that ref, discarding local changes." "Commit or stash changes first, or add 'allow: checkout ref --' to .git-safe."
fi

# git restore (various destructive forms)
if echo "$COMMAND" | grep -qE 'git\s+restore\s' 2>/dev/null; then
  # Always block --source/-s (restoring from arbitrary ref)
  if echo "$COMMAND" | grep -qE '(--source|-s\s)' 2>/dev/null; then
    is_allowed "restore --source" || block "git restore --source overwrites files from a specific ref, discarding local changes." "Commit or stash first, or add 'allow: restore --source' to .git-safe."
  # Block --worktree/-W (explicitly discards working tree)
  elif echo "$COMMAND" | grep -qE '(--worktree|-W\b)' 2>/dev/null; then
    is_allowed "restore" || block "git restore --worktree discards uncommitted working tree changes." "Commit or stash first, or add 'allow: restore' to .git-safe."
  # Block if no --staged flag (default = working tree restore = destructive)
  elif ! echo "$COMMAND" | grep -qE '\-\-staged' 2>/dev/null; then
    is_allowed "restore" || block "git restore without --staged discards uncommitted working tree changes." "Use git restore --staged to unstage only, or commit/stash first. Add 'allow: restore' to .git-safe."
  fi
fi

# git clean -f (deletes untracked files)
if echo "$COMMAND" | grep -qE 'git\s+clean\s.*-[a-zA-Z]*f' 2>/dev/null; then
  is_allowed "clean -f" || block "git clean -f permanently deletes untracked files." "Use git clean -n (dry run) first, or add 'allow: clean -f' to .git-safe."
fi

# git branch -D (force-delete unmerged branch)
if echo "$COMMAND" | grep -qE 'git\s+branch\s.*-[a-zA-Z]*D' 2>/dev/null; then
  is_allowed "branch -D" || block "git branch -D force-deletes a branch even if not fully merged." "Use -d (lowercase) which only deletes merged branches, or add 'allow: branch -D' to .git-safe."
fi

# git stash drop / clear
if echo "$COMMAND" | grep -qE 'git\s+stash\s+drop' 2>/dev/null; then
  is_allowed "stash drop" || block "git stash drop permanently deletes stashed changes." "Add 'allow: stash drop' to .git-safe to permit this."
fi
if echo "$COMMAND" | grep -qE 'git\s+stash\s+clear' 2>/dev/null; then
  is_allowed "stash clear" || block "git stash clear permanently deletes all stashed changes." "Add 'allow: stash clear' to .git-safe to permit this."
fi

# git reflog expire / delete
if echo "$COMMAND" | grep -qE 'git\s+reflog\s+(expire|delete)' 2>/dev/null; then
  is_allowed "reflog expire" || block "git reflog expire/delete destroys recovery data." "This is almost never needed. Add 'allow: reflog expire' to .git-safe if you really need it."
fi

# git push --delete (removes remote branches/tags)
if echo "$COMMAND" | grep -qE 'git\s+push\s.*--delete\s' 2>/dev/null; then
  is_allowed "push --delete" || block "git push --delete permanently removes remote branches or tags." "Use 'git branch -d' for local cleanup instead, or add 'allow: push --delete' to .git-safe."
fi
# git push origin :branch (alternate delete syntax)
if echo "$COMMAND" | grep -qE 'git\s+push\s+\S+\s+:[^/\s]' 2>/dev/null; then
  is_allowed "push --delete" || block "git push origin :branch permanently removes a remote branch." "Use 'git branch -d' for local cleanup instead, or add 'allow: push --delete' to .git-safe."
fi

# git rebase (can rewrite history and lose commits)
# Allow: --abort, --continue, --skip, --quit (recovery operations)
# Uses ([[:space:]]|$) to catch bare "git rebase" with no args
# Checks -i/--interactive anywhere in command to catch "git rebase --autosquash -i"
if echo "$COMMAND" | grep -qE 'git[[:space:]]+rebase([[:space:]]|$)' 2>/dev/null; then
  if echo "$COMMAND" | grep -qE 'git[[:space:]]+rebase[[:space:]]+.*--(abort|continue|skip|quit)([[:space:]]|$)' 2>/dev/null; then
    log "ALLOW: rebase recovery operation"
  elif echo "$COMMAND" | grep -qE '(^|[[:space:]])(-i|--interactive)([[:space:]]|$)' 2>/dev/null; then
    is_allowed "rebase -i" || block "Interactive rebase can rewrite, squash, drop, or reorder commits, permanently altering history." "Use non-interactive rebase if you just need to replay commits, or add 'allow: rebase -i' to .git-safe."
  else
    is_allowed "rebase" || block "git rebase replays commits onto a new base, which can lose work during conflict resolution and rewrites history." "Prefer git merge to preserve history, or add 'allow: rebase' to .git-safe."
  fi
fi

# git merge to protected branches (main/master/production/release)
# Can't detect current branch from command alone, so check for explicit patterns
if echo "$COMMAND" | grep -qE 'git\s+merge\s' 2>/dev/null; then
  # Allow recovery: --abort, --continue, --quit
  if echo "$COMMAND" | grep -qE 'git\s+merge\s+.*--(abort|continue|quit)' 2>/dev/null; then
    log "ALLOW: merge recovery operation"
  # Block --no-verify on merge (skips hooks)
  elif echo "$COMMAND" | grep -qE 'git\s+merge\s.*--no-verify' 2>/dev/null; then
    is_allowed "no-verify" || block "git merge --no-verify skips pre-merge hooks." "Remove --no-verify and let hooks run, or add 'allow: no-verify' to .git-safe."
  fi
fi

# git push to protected branches via refspec (e.g. git push origin feature:main)
# Parses the command token-by-token, skipping flags and the repository argument,
# then scans EVERY remaining refspec for a protected destination. Handles:
#   - Flag placement anywhere: git push -u origin feature:main
#   - SSH remote URLs (contain ':'): git push git@github.com:org/repo.git feature:main
#   - Multiple refspecs: git push origin feature:dev hotfix:main
#   - Full ref format: git push origin feature:refs/heads/main
#   - Avoids false positives on hyphenated names: release-candidate is allowed
if echo "$COMMAND" | grep -qE 'git[[:space:]]+push[[:space:]]' 2>/dev/null; then
  _gs_seen_git=0
  _gs_seen_push=0
  _gs_seen_repo=0
  for _gs_tok in $COMMAND; do
    # Skip until we see 'git' then 'push'
    if [ "$_gs_seen_git" = "0" ]; then
      [ "$_gs_tok" = "git" ] && _gs_seen_git=1
      continue
    fi
    if [ "$_gs_seen_push" = "0" ]; then
      [ "$_gs_tok" = "push" ] && _gs_seen_push=1
      continue
    fi
    # Skip flags (anything starting with -)
    case "$_gs_tok" in
      -*) continue ;;
    esac
    # First non-flag argument is the repository — skip it (may be URL with ':')
    if [ "$_gs_seen_repo" = "0" ]; then
      _gs_seen_repo=1
      continue
    fi
    # All remaining non-flag tokens are refspecs — check each for protected dst
    case "$_gs_tok" in
      *:*)
        _gs_dst="${_gs_tok#*:}"
        _gs_dst="${_gs_dst#refs/heads/}"
        case "$_gs_dst" in
          main|master|production|release)
            block "Pushing to a protected branch ($_gs_dst) via refspec can bypass branch protections." "Push to a feature branch and open a PR instead."
            ;;
        esac
        ;;
    esac
  done
fi

# git filter-branch / git filter-repo (rewrites entire repository history)
if echo "$COMMAND" | grep -qE 'git\s+filter-(branch|repo)\s' 2>/dev/null; then
  is_allowed "filter-branch" || block "git filter-branch/filter-repo rewrites entire repository history at scale." "This is rarely needed. Add 'allow: filter-branch' to .git-safe only if you understand the impact."
fi

# git push --mirror (overwrites ALL remote refs to match local)
if echo "$COMMAND" | grep -qE 'git\s+push\s+.*--mirror' 2>/dev/null; then
  is_allowed "push --mirror" || block "git push --mirror overwrites all remote refs to match local, destroying remote branches and tags." "Push specific branches instead, or add 'allow: push --mirror' to .git-safe."
fi

# git update-ref -d (low-level ref deletion, bypasses branch safeguards)
if echo "$COMMAND" | grep -qE 'git\s+update-ref\s+.*-d\b' 2>/dev/null; then
  is_allowed "update-ref -d" || block "git update-ref -d deletes refs directly, bypassing normal branch/tag deletion safeguards." "Use git branch -d or git tag -d instead, or add 'allow: update-ref -d' to .git-safe."
fi

# git gc --prune=now (immediately garbage-collects unreachable objects)
if echo "$COMMAND" | grep -qE 'git\s+gc\s+.*--prune=(now|all)' 2>/dev/null; then
  is_allowed "gc --prune" || block "git gc --prune=now immediately garbage-collects unreachable objects before reflog can save them." "Use git gc without --prune=now to respect reflog expiry, or add 'allow: gc --prune' to .git-safe."
fi

# git remote remove/rm (removes remote configuration)
if echo "$COMMAND" | grep -qE 'git\s+remote\s+(remove|rm)\s' 2>/dev/null; then
  is_allowed "remote remove" || block "git remote remove deletes remote configuration, losing track of upstream." "Add 'allow: remote remove' to .git-safe to permit this."
fi

# git submodule deinit --force (force-removes submodule working tree)
if echo "$COMMAND" | grep -qE 'git\s+submodule\s+deinit\s+.*--force' 2>/dev/null; then
  is_allowed "submodule deinit" || block "git submodule deinit --force removes submodule working tree data." "Use without --force, or add 'allow: submodule deinit' to .git-safe."
fi

# git worktree remove --force (force-removes worktree with uncommitted changes)
if echo "$COMMAND" | grep -qE 'git\s+worktree\s+remove\s+.*--force' 2>/dev/null; then
  is_allowed "worktree remove --force" || block "git worktree remove --force removes a worktree even with uncommitted changes." "Commit or stash changes first, or add 'allow: worktree remove --force' to .git-safe."
fi

# git tag -d (deletes local tags, including release tags)
if echo "$COMMAND" | grep -qE 'git\s+tag\s+.*-[a-zA-Z]*d' 2>/dev/null; then
  is_allowed "tag -d" || block "git tag -d deletes local tags which may include release infrastructure." "Add 'allow: tag -d' to .git-safe to permit this."
fi

# git config --system / --global (modifies git config beyond this repo)
if echo "$COMMAND" | grep -qE 'git\s+config\s+.*--(system|global)\s' 2>/dev/null; then
  is_allowed "config --global" || block "git config --system/--global modifies git configuration beyond this repository." "Use --local for repo-specific config, or add 'allow: config --global' to .git-safe."
fi

# Force push to main/master (extra protection)
if echo "$COMMAND" | grep -qE 'git\s+push\s.*--force.*\s(main|master)(\s|$)' 2>/dev/null; then
  block "Force push to main/master is extremely dangerous." "This is blocked even with 'allow: push --force'. Never force push to main."
fi
if echo "$COMMAND" | grep -qE 'git\s+push\s.*\s(main|master)\s.*--force' 2>/dev/null; then
  block "Force push to main/master is extremely dangerous." "This is blocked even with 'allow: push --force'. Never force push to main."
fi

log "ALLOW: $COMMAND"
exit 0
