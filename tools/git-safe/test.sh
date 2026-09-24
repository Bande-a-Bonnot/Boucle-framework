#!/bin/bash
# Tests for git-safe hook
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/hook.sh"
PASS=0
FAIL=0
TOTAL=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

hook_input() {
  jq -cn --arg command "$1" '{"tool_name":"Bash","tool_input":{"command":$command}}'
}

hook_input_at() {
  jq -cn --arg command "$1" --arg cwd "$2" \
    '{"tool_name":"Bash","cwd":$cwd,"tool_input":{"command":$command}}'
}

assert_blocked() {
  local desc="$1"
  local input="$2"
  local stdout_file stderr_file rc result stderr
  TOTAL=$((TOTAL + 1))

  stdout_file=$(mktemp)
  stderr_file=$(mktemp)
  if echo "$input" | bash "$HOOK" >"$stdout_file" 2>"$stderr_file"; then
    rc=0
  else
    rc=$?
  fi
  result=$(cat "$stdout_file")
  stderr=$(cat "$stderr_file")
  rm -f "$stdout_file" "$stderr_file"

  if [ "$rc" -eq 2 ] && [ -z "$result" ] && echo "$stderr" | grep -q 'git-safe:'; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}PASS${NC}: $desc"
  else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}FAIL${NC}: $desc (expected rc=2 with stderr reason, got rc=$rc stdout='$result' stderr='$stderr')"
  fi
}

assert_allowed() {
  local desc="$1"
  local input="$2"
  local stdout_file stderr_file rc result stderr
  TOTAL=$((TOTAL + 1))

  stdout_file=$(mktemp)
  stderr_file=$(mktemp)
  if echo "$input" | bash "$HOOK" >"$stdout_file" 2>"$stderr_file"; then
    rc=0
  else
    rc=$?
  fi
  result=$(cat "$stdout_file")
  stderr=$(cat "$stderr_file")
  rm -f "$stdout_file" "$stderr_file"

  if [ "$rc" -eq 0 ] && [ -z "$result" ] && [ -z "$stderr" ]; then
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}PASS${NC}: $desc"
  else
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}FAIL${NC}: $desc (expected clean allow, got rc=$rc stdout='$result' stderr='$stderr')"
  fi
}

echo "=== git-safe tests ==="
echo ""

# --- Non-git tools should pass through ---
echo "Tool filtering:"
assert_allowed "Write tool passes through" \
  '{"tool_name":"Write","tool_input":{"file_path":"test.txt","content":"hi"}}'
assert_allowed "Edit tool passes through" \
  '{"tool_name":"Edit","tool_input":{"file_path":"test.txt"}}'
assert_allowed "Read tool passes through" \
  '{"tool_name":"Read","tool_input":{"file_path":"test.txt"}}'

# --- Safe git commands ---
echo ""
echo "Safe git commands:"
assert_allowed "git status" \
  '{"tool_name":"Bash","tool_input":{"command":"git status"}}'
assert_allowed "git log" \
  '{"tool_name":"Bash","tool_input":{"command":"git log --oneline -10"}}'
assert_allowed "git diff" \
  '{"tool_name":"Bash","tool_input":{"command":"git diff HEAD~1"}}'
assert_allowed "git add" \
  '{"tool_name":"Bash","tool_input":{"command":"git add src/main.rs"}}'
assert_allowed "git commit" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"fix: update readme\""}}'
assert_allowed "git push (normal)" \
  '{"tool_name":"Bash","tool_input":{"command":"git push origin feature-branch"}}'
assert_allowed "git push to SSH remote URL (not a refspec)" \
  '{"tool_name":"Bash","tool_input":{"command":"git push git@github.com:org/repo.git feature-branch"}}'
assert_allowed "git pull" \
  '{"tool_name":"Bash","tool_input":{"command":"git pull origin main"}}'
assert_allowed "git fetch" \
  '{"tool_name":"Bash","tool_input":{"command":"git fetch --all"}}'
assert_allowed "git branch -d (lowercase, safe)" \
  '{"tool_name":"Bash","tool_input":{"command":"git branch -d merged-branch"}}'
assert_allowed "git stash (save)" \
  '{"tool_name":"Bash","tool_input":{"command":"git stash"}}'
assert_allowed "git stash pop" \
  '{"tool_name":"Bash","tool_input":{"command":"git stash pop"}}'
assert_allowed "git reset (soft)" \
  '{"tool_name":"Bash","tool_input":{"command":"git reset --soft HEAD~1"}}'
assert_allowed "git reset (mixed, default)" \
  '{"tool_name":"Bash","tool_input":{"command":"git reset HEAD~1"}}'
assert_allowed "git checkout branch" \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout feature-branch"}}'
assert_allowed "git checkout -b new branch" \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout -b new-feature"}}'
assert_allowed "git clean -n (dry run)" \
  '{"tool_name":"Bash","tool_input":{"command":"git clean -n"}}'
assert_allowed "non-git command" \
  '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
assert_allowed "push --force-with-lease (safer)" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --force-with-lease origin feature"}}'

# --- Destructive operations (should be blocked) ---
echo ""
echo "Destructive operations (should block):"
assert_blocked "git push --force" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --force origin feature"}}'
assert_blocked "git push -f" \
  '{"tool_name":"Bash","tool_input":{"command":"git push -f origin feature"}}'
assert_blocked "git reset --hard" \
  '{"tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD~3"}}'
assert_blocked "git reset --hard HEAD" \
  '{"tool_name":"Bash","tool_input":{"command":"git reset --hard"}}'
assert_blocked "git checkout ." \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout ."}}'
assert_blocked "git checkout -- file" \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout -- src/main.rs"}}'
assert_blocked "git restore ." \
  '{"tool_name":"Bash","tool_input":{"command":"git restore ."}}'

# --- git checkout <ref> -- <path> (issue #37888 pattern) ---
echo ""
echo "Checkout from ref (issue #37888):"
assert_blocked "git checkout HEAD -- src/" \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout HEAD -- src/"}}'
assert_blocked "git checkout HEAD -- ." \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout HEAD -- ."}}'
assert_blocked "git checkout main -- file.js" \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout main -- file.js"}}'
assert_blocked "git checkout origin/main -- path/to/file" \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout origin/main -- path/to/file"}}'
assert_blocked "git checkout abc123 -- ." \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout abc123 -- ."}}'
assert_blocked "git checkout HEAD~3 -- src/main.rs" \
  '{"tool_name":"Bash","tool_input":{"command":"git checkout HEAD~3 -- src/main.rs"}}'

# --- git restore expanded coverage ---
echo ""
echo "Restore expanded coverage:"
assert_blocked "git restore src/main.rs (no --staged)" \
  '{"tool_name":"Bash","tool_input":{"command":"git restore src/main.rs"}}'
assert_blocked "git restore --source=HEAD ." \
  '{"tool_name":"Bash","tool_input":{"command":"git restore --source=HEAD ."}}'
assert_blocked "git restore --source=main file.js" \
  '{"tool_name":"Bash","tool_input":{"command":"git restore --source=main file.js"}}'
assert_blocked "git restore -s HEAD file.js" \
  '{"tool_name":"Bash","tool_input":{"command":"git restore -s HEAD file.js"}}'
assert_blocked "git restore --worktree ." \
  '{"tool_name":"Bash","tool_input":{"command":"git restore --worktree ."}}'
assert_blocked "git restore --staged --worktree ." \
  '{"tool_name":"Bash","tool_input":{"command":"git restore --staged --worktree ."}}'
assert_allowed "git restore --staged file.js (safe: just unstages)" \
  '{"tool_name":"Bash","tool_input":{"command":"git restore --staged file.js"}}'
assert_allowed "git restore --staged . (safe: just unstages)" \
  '{"tool_name":"Bash","tool_input":{"command":"git restore --staged ."}}'
assert_blocked "git clean -f" \
  '{"tool_name":"Bash","tool_input":{"command":"git clean -f"}}'
assert_blocked "git clean -fd" \
  '{"tool_name":"Bash","tool_input":{"command":"git clean -fd"}}'
assert_blocked "git clean -fdx" \
  '{"tool_name":"Bash","tool_input":{"command":"git clean -fdx"}}'
assert_blocked "git branch -D" \
  '{"tool_name":"Bash","tool_input":{"command":"git branch -D unmerged-feature"}}'
assert_blocked "git stash drop" \
  '{"tool_name":"Bash","tool_input":{"command":"git stash drop stash@{0}"}}'
assert_blocked "git stash clear" \
  '{"tool_name":"Bash","tool_input":{"command":"git stash clear"}}'
assert_blocked "git reflog expire" \
  '{"tool_name":"Bash","tool_input":{"command":"git reflog expire --expire=now --all"}}'
assert_blocked "git reflog delete" \
  '{"tool_name":"Bash","tool_input":{"command":"git reflog delete HEAD@{2}"}}'
assert_blocked "git push --delete branch" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --delete origin feature-branch"}}'
assert_blocked "git push --delete tag" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --delete origin v1.0.0"}}'
assert_blocked "git push origin :branch (alternate delete syntax)" \
  '{"tool_name":"Bash","tool_input":{"command":"git push origin :feature-branch"}}'
assert_allowed "git push origin branch (normal, not delete)" \
  '{"tool_name":"Bash","tool_input":{"command":"git push origin feature-branch"}}'

# --- --no-verify (skips pre-commit hooks) ---
echo ""
echo "No-verify detection:"
assert_blocked "git commit --no-verify" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit --no-verify -m \"skip hooks\""}}'
assert_blocked "git commit -n (shorthand)" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -n -m \"skip hooks\""}}'
assert_blocked "git commit -an (combined flags)" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -an -m \"skip hooks\""}}'
assert_blocked "git commit -anm (combined with message)" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -anm \"skip hooks\""}}'
assert_blocked "git merge --no-verify" \
  '{"tool_name":"Bash","tool_input":{"command":"git merge --no-verify feature-branch"}}'
assert_blocked "git push --no-verify" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --no-verify origin main"}}'
assert_blocked "git cherry-pick --no-verify" \
  '{"tool_name":"Bash","tool_input":{"command":"git cherry-pick --no-verify abc123"}}'
assert_blocked "git revert --no-verify" \
  '{"tool_name":"Bash","tool_input":{"command":"git revert --no-verify HEAD"}}'
assert_blocked "git am --no-verify" \
  '{"tool_name":"Bash","tool_input":{"command":"git am --no-verify patch.mbox"}}'
assert_allowed "git commit (normal, no skip)" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"normal commit\""}}'
assert_allowed "git commit -a (all, not -n)" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -a -m \"stage and commit\""}}'
assert_allowed "git commit --amend (no skip)" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit --amend -m \"amend\""}}'

# --- Force push to main/master (always blocked) ---
echo ""
echo "Force push to main/master (always blocked):"
assert_blocked "force push to main" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}'
assert_blocked "force push to master" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --force origin master"}}'
assert_blocked "push later refspec to protected branch" \
  '{"tool_name":"Bash","tool_input":{"command":"git push origin feature:dev hotfix:main"}}'

# --- Additional destructive operations ---
echo ""
echo "Additional destructive operations:"
assert_blocked "git filter-repo (bare command)" \
  '{"tool_name":"Bash","tool_input":{"command":"git filter-repo"}}'
assert_blocked "git filter-branch (bare command)" \
  '{"tool_name":"Bash","tool_input":{"command":"git filter-branch"}}'
assert_blocked "git tag -d v1.0.0" \
  '{"tool_name":"Bash","tool_input":{"command":"git tag -d v1.0.0"}}'
assert_blocked "git tag --delete v1.0.0" \
  '{"tool_name":"Bash","tool_input":{"command":"git tag --delete v1.0.0"}}'
assert_allowed "git tag --merged main" \
  '{"tool_name":"Bash","tool_input":{"command":"git tag --merged main"}}'
assert_blocked "git config --global user.name test" \
  '{"tool_name":"Bash","tool_input":{"command":"git config --global user.name test"}}'
assert_blocked "git config --system user.name test" \
  '{"tool_name":"Bash","tool_input":{"command":"git config --system user.name test"}}'

# --- Allowlist config ---
echo ""
echo "Allowlist config:"

# Create temp config
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

echo "allow: reset --hard" > "$TMPDIR/.git-safe"
echo "allow: push --force" >> "$TMPDIR/.git-safe"

GIT_SAFE_CONFIG="$TMPDIR/.git-safe" assert_allowed "reset --hard allowed by config" \
  '{"tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD~1"}}'

GIT_SAFE_CONFIG="$TMPDIR/.git-safe" assert_allowed "push --force allowed by config" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --force origin feature"}}'

echo "allow: no-verify" >> "$TMPDIR/.git-safe"
echo "allow: push --delete" >> "$TMPDIR/.git-safe"
echo "allow: config --system" >> "$TMPDIR/.git-safe"

GIT_SAFE_CONFIG="$TMPDIR/.git-safe" assert_allowed "no-verify allowed by config" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit --no-verify -m \"allowed\""}}'

GIT_SAFE_CONFIG="$TMPDIR/.git-safe" assert_allowed "push --delete allowed by config" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --delete origin old-branch"}}'
GIT_SAFE_CONFIG="$TMPDIR/.git-safe" assert_allowed "config --system allowed by config" \
  '{"tool_name":"Bash","tool_input":{"command":"git config --system user.name test"}}'
GIT_SAFE_CONFIG="$TMPDIR/.git-safe" assert_blocked "config --global still blocked without explicit allow" \
  '{"tool_name":"Bash","tool_input":{"command":"git config --global user.name test"}}'

# Force push to main still blocked even with config
GIT_SAFE_CONFIG="$TMPDIR/.git-safe" assert_blocked "force push to main still blocked with allowlist" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}'

# Disabled via env var
echo ""
echo "Disable via env var:"
TOTAL=$((TOTAL + 1))
stdout_file=$(mktemp)
stderr_file=$(mktemp)
if echo '{"tool_name":"Bash","tool_input":{"command":"git push --force origin feature"}}' | GIT_SAFE_DISABLED=1 bash "$HOOK" >"$stdout_file" 2>"$stderr_file"; then
  rc=0
else
  rc=$?
fi
result=$(cat "$stdout_file")
stderr=$(cat "$stderr_file")
rm -f "$stdout_file" "$stderr_file"
if [ "$rc" -eq 0 ] && [ -z "$result" ] && [ -z "$stderr" ]; then
  PASS=$((PASS + 1))
  echo -e "  ${GREEN}PASS${NC}: disabled hook allows everything"
else
  FAIL=$((FAIL + 1))
  echo -e "  ${RED}FAIL${NC}: disabled hook should allow everything (rc=$rc stdout='$result' stderr='$stderr')"
fi

# --- Edge cases ---
echo ""
echo "Edge cases:"
assert_allowed "empty command" \
  '{"tool_name":"Bash","tool_input":{"command":""}}'
assert_allowed "git in non-git context" \
  '{"tool_name":"Bash","tool_input":{"command":"echo git is great"}}'
assert_allowed "piped git command (safe)" \
  '{"tool_name":"Bash","tool_input":{"command":"git log --oneline | head -5"}}'

echo ""
echo "False-positive avoidance (issue #449):"
assert_allowed "git commit message can mention git reset --hard" \
  "$(hook_input 'git commit -m "avoid git reset --hard"')"
assert_allowed "git log --grep can search for reset --hard" \
  "$(hook_input 'git log --grep="reset --hard"')"
assert_allowed "non-git command can pass JSON payload mentioning git push -f" \
  "$(hook_input 'node probe.js "{\"command\":\"git push -f\"}"')"
assert_allowed "echo can mention git reset --hard without executing git" \
  "$(hook_input 'echo git reset --hard')"

HEREDOC_COMMIT_MESSAGE=$(cat <<'CMD'
git commit -F - <<'EOF'
document git reset --hard in the commit message
EOF
CMD
)
assert_allowed "git commit -F heredoc body can mention git reset --hard" \
  "$(hook_input "$HEREDOC_COMMIT_MESSAGE")"
assert_blocked "real destructive git command after harmless mention still blocks" \
  "$(hook_input 'echo "git reset --hard"; git reset --hard')"
assert_blocked "bash -c executes a quoted destructive command" \
  "$(hook_input 'bash -c "git reset --hard"')"
assert_blocked "sh -c executes a single-quoted destructive command" \
  "$(hook_input "sh -c 'git reset --hard'")"
assert_blocked "command substitution executes inside a double quote" \
  "$(hook_input 'echo "$(git reset --hard)"')"
assert_blocked "backtick substitution executes a destructive command" \
  "$(hook_input 'echo `git reset --hard`')"
assert_blocked "commit message substitution executes before commit" \
  "$(hook_input 'git commit -m "$(git reset --hard)"')"
assert_blocked "eval executes a quoted destructive command" \
  "$(hook_input "eval 'git reset --hard'")"
assert_blocked "bash options before -c execute a destructive command" \
  "$(hook_input "bash -e -c 'git reset --hard'")"
assert_blocked "bash -O option before -c executes a destructive command" \
  "$(hook_input "bash -O extglob -c 'git reset --hard'")"
assert_blocked "bash -o option before -c executes a destructive command" \
  "$(hook_input "bash -o errexit -c 'git reset --hard'")"
assert_blocked "dash -c executes a destructive command" \
  "$(hook_input "dash -c 'git reset --hard'")"
assert_blocked "ksh options before -c execute a destructive command" \
  "$(hook_input "ksh -e -c 'git reset --hard'")"
assert_blocked "eval cannot combine shell wrapping and a Git global option" \
  "$(hook_input "eval 'git --no-advice reset --hard'")"
assert_blocked "bash -c cannot combine shell wrapping and a Git global option" \
  "$(hook_input "bash -c 'git --no-advice reset --hard'")"
assert_blocked "command substitution cannot combine with a Git global option" \
  "$(hook_input 'echo "$(git --no-advice reset --hard)"')"
assert_blocked "sudo shell command remains guarded" \
  "$(hook_input "sudo bash -c 'git reset --hard'")"
assert_blocked "env flags before bash -c remain guarded" \
  "$(hook_input "env -i bash -c 'git reset --hard'")"
assert_blocked "sudo flags and arguments before bash -c remain guarded" \
  "$(hook_input "sudo -u root bash -c 'git reset --hard'")"
assert_blocked "time flags before bash -c remain guarded" \
  "$(hook_input "time -p bash -c 'git reset --hard'")"
assert_blocked "nested command and env wrappers remain guarded" \
  "$(hook_input "command env -i bash -c 'git reset --hard'")"
assert_blocked "env flags before direct Git remain guarded" \
  "$(hook_input 'env -i git reset --hard')"
assert_blocked "command -p before direct Git remains guarded" \
  "$(hook_input 'command -p git reset --hard')"
assert_blocked "time -p before direct Git remains guarded" \
  "$(hook_input 'time -p git reset --hard')"
assert_blocked "sudo user flag before direct Git remains guarded" \
  "$(hook_input 'sudo -u root git reset --hard')"
assert_blocked "nested command and env wrappers before direct Git remain guarded" \
  "$(hook_input 'command env -i git reset --hard')"
assert_blocked "timeout argument before bash -c remains guarded" \
  "$(hook_input "timeout 5 bash -c 'git reset --hard'")"
assert_blocked "nice arguments before bash -c remain guarded" \
  "$(hook_input "nice -n 10 bash -c 'git reset --hard'")"
assert_allowed "single-quoted backticks in commit prose are literal" \
  "$(hook_input "git commit -m 'docs mention \`git reset --hard\`'")"
assert_allowed "single-quoted command substitution in commit prose is literal" \
  "$(hook_input "git commit -m 'docs mention \$(git reset --hard)'")"
assert_allowed "single-quoted wrapper prose remains literal" \
  "$(hook_input "git commit -m 'docs mention env -i bash -c git reset --hard'")"
CONTINUED_GIT=$(printf '%s\n' 'git \' 'reset --hard')
assert_blocked "backslash-newline joins direct Git command" \
  "$(hook_input "$CONTINUED_GIT")"
COMMENTED_BACKSLASH_THEN_GIT=$(printf '%s\n' '# prose \' 'git reset --hard')
assert_blocked "comment backslash cannot swallow next Git command" \
  "$(hook_input "$COMMENTED_BACKSLASH_THEN_GIT")"
PAIRED_BACKSLASH_THEN_GIT=$(printf '%s\n' 'printf CANARY_FIRST\\' 'git reset --hard')
assert_blocked "paired backslashes leave next Git command executable" \
  "$(hook_input "$PAIRED_BACKSLASH_THEN_GIT")"
QUOTED_BODY_BACKSLASH_THEN_GIT=$(printf '%s\n' "cat <<'EOF'" 'foo\' 'EOF' 'git reset --hard')
assert_blocked "quoted here-doc body backslash cannot swallow next Git command" \
  "$(hook_input "$QUOTED_BODY_BACKSLASH_THEN_GIT")"
QUOTED_MARKER_THEN_GIT=$(cat <<'CMD'
printf '%s\n' '<<EOF'
git reset --hard
EOF
CMD
)
assert_blocked "quoted here-doc marker cannot hide next command" \
  "$(hook_input "$QUOTED_MARKER_THEN_GIT")"
COMMENTED_MARKER_THEN_GIT=$(cat <<'CMD'
# <<EOF
git reset --hard
EOF
CMD
)
assert_blocked "commented here-doc marker cannot hide next command" \
  "$(hook_input "$COMMENTED_MARKER_THEN_GIT")"
HERE_STRING_THEN_GIT=$(printf '%s\n' 'cat <<<EOF' 'git reset --hard')
assert_blocked "here-string marker cannot hide next Git command" \
  "$(hook_input "$HERE_STRING_THEN_GIT")"
assert_blocked "escaped space before hash keeps following semicolon executable" \
  "$(hook_input 'echo foo\ #; git reset --hard')"
assert_blocked "escaped semicolon before hash keeps following semicolon executable" \
  "$(hook_input 'echo foo\;#; git reset --hard')"
PART_QUOTED_HEREDOC_THEN_GIT=$(cat <<'CMD'
cat <<E"OF"
body
EOF
git reset --hard
CMD
)
assert_blocked "partly quoted here-doc delimiter cannot hide a later command" \
  "$(hook_input "$PART_QUOTED_HEREDOC_THEN_GIT")"
PART_QUOTED_HEREDOC_BODY=$(cat <<'CMD'
cat <<E"OF"
git reset --hard
EOF
CMD
)
assert_allowed "partly quoted here-doc body is literal data" \
  "$(hook_input "$PART_QUOTED_HEREDOC_BODY")"
DOUBLE_QUOTED_BACKSLASH_THEN_GIT=$(cat <<'CMD'
cat <<"E\OF"
body
E\OF
git reset --hard
CMD
)
assert_blocked "double-quoted delimiter retains literal backslash before O" \
  "$(hook_input "$DOUBLE_QUOTED_BACKSLASH_THEN_GIT")"
DOUBLE_QUOTED_BACKSLASH_BODY=$(cat <<'CMD'
cat <<"E\OF"
git reset --hard
E\OF
CMD
)
assert_allowed "double-quoted backslash delimiter keeps body literal" \
  "$(hook_input "$DOUBLE_QUOTED_BACKSLASH_BODY")"
QUOTED_MARKER_SAFE=$(cat <<'CMD'
printf '%s\n' '<<EOF'
echo safe
EOF
CMD
)
assert_allowed "quoted here-doc marker with benign next line remains allowed" \
  "$(hook_input "$QUOTED_MARKER_SAFE")"
assert_allowed "commented destructive Git command is not executed" \
  "$(hook_input '# git reset --hard')"
HEREDOC_LITERAL_SUBSTITUTION=$(cat <<'CMD'
git commit -F - <<'EOF'
document `git reset --hard` and $(git reset --hard)
EOF
CMD
)
assert_allowed "literal here-doc substitution examples remain prose" \
  "$(hook_input "$HEREDOC_LITERAL_SUBSTITUTION")"
UNQUOTED_HEREDOC_SUBSTITUTION=$(cat <<'CMD'
cat <<EOF
$(git reset --hard)
EOF
CMD
)
assert_blocked "unquoted here-doc command substitution executes" \
  "$(hook_input "$UNQUOTED_HEREDOC_SUBSTITUTION")"
UNQUOTED_HEREDOC_BACKTICKS=$(cat <<'CMD'
cat <<EOF
`git reset --hard`
EOF
CMD
)
assert_blocked "unquoted here-doc backticks execute" \
  "$(hook_input "$UNQUOTED_HEREDOC_BACKTICKS")"
UNQUOTED_HEREDOC_GLOBAL=$(cat <<'CMD'
cat <<EOF
$(git --no-advice reset --hard)
EOF
CMD
)
assert_blocked "unquoted here-doc substitution with Git global option executes" \
  "$(hook_input "$UNQUOTED_HEREDOC_GLOBAL")"
MULTILINE_GLOBAL_SUBSTITUTION=$(cat <<'CMD'
echo ok
$(git --no-advice reset --hard)
CMD
)
assert_blocked "multiline command substitution with Git global option executes" \
  "$(hook_input "$MULTILINE_GLOBAL_SUBSTITUTION")"
MULTILINE_GLOBAL_SHELL=$(cat <<'CMD'
echo ok
bash -c 'git --no-advice reset --hard'
CMD
)
assert_blocked "multiline shell -c with Git global option executes" \
  "$(hook_input "$MULTILINE_GLOBAL_SHELL")"
QUOTED_HEREDOC_LITERAL=$(cat <<'CMD'
cat <<'EOF'
$(git reset --hard)
`git reset --hard`
EOF
CMD
)
assert_allowed "quoted here-doc body does not execute substitutions" \
  "$(hook_input "$QUOTED_HEREDOC_LITERAL")"
QUOTED_HEREDOC_GLOBAL=$(cat <<'CMD'
cat <<'EOF'
$(git --no-advice reset --hard)
EOF
CMD
)
assert_allowed "quoted here-doc global-option example remains literal" \
  "$(hook_input "$QUOTED_HEREDOC_GLOBAL")"
ESCAPED_HEREDOC_LITERAL=$(cat <<'CMD'
cat <<EOF
\$(git reset --hard)
\`git reset --hard\`
EOF
CMD
)
assert_allowed "escaped substitutions in unquoted here-doc remain literal" \
  "$(hook_input "$ESCAPED_HEREDOC_LITERAL")"

# Global Git options must not hide the subcommand.  Resolve .git-safe from the
# target repo, not from the hook's process cwd or the session's initial repo.
echo ""
echo "Global options and target repository policy:"
mkdir -p "$TMPDIR/session" "$TMPDIR/target" "$TMPDIR/target with spaces" "$TMPDIR/denied"
git init -q "$TMPDIR/session"
git init -q "$TMPDIR/target"
git init -q "$TMPDIR/target with spaces"
git init -q "$TMPDIR/denied"
echo "allow: reset --hard" > "$TMPDIR/session/.git-safe"

assert_blocked "git -C cannot bypass reset guard or borrow session allowlist" \
  "$(hook_input_at "git -C $TMPDIR/target reset --hard" "$TMPDIR/session")"
GIT_WORK_TREE="$TMPDIR/session" assert_blocked "inherited worktree cannot borrow session allowlist" \
  "$(hook_input_at "git -C $TMPDIR/target reset --hard" "$TMPDIR/session")"
GIT_DIR="$TMPDIR/session/.git" GIT_WORK_TREE="$TMPDIR/session" \
  assert_blocked "inherited git-dir and worktree cannot borrow session allowlist" \
  "$(hook_input_at "git -C $TMPDIR/target reset --hard" "$TMPDIR/session")"
assert_blocked "global -c before -C still uses target policy" \
  "$(hook_input_at "git -c color.ui=false -C $TMPDIR/target reset --hard" "$TMPDIR/session")"
assert_blocked "attached -C path cannot borrow session allowlist" \
  "$(hook_input_at "git -C$TMPDIR/target reset --hard" "$TMPDIR/session")"
assert_blocked "alternate --git-dir path cannot borrow session allowlist" \
  "$(hook_input_at "git --git-dir=$TMPDIR/target/.git reset --hard" "$TMPDIR/session")"
assert_blocked "repeated -C cannot borrow an intermediate allowlist" \
  "$(hook_input_at "git -C $TMPDIR/session -C ../target reset --hard" "$TMPDIR/session")"
assert_blocked "git global -c cannot bypass reset guard" \
  "$(hook_input_at 'git -c color.ui=false reset --hard' "$TMPDIR/target")"
assert_blocked "git --no-pager cannot bypass reset guard" \
  "$(hook_input_at 'git --no-pager reset --hard' "$TMPDIR/target")"
assert_blocked "git --no-advice cannot bypass reset guard" \
  "$(hook_input_at 'git --no-advice reset --hard' "$TMPDIR/target")"
assert_blocked "cd target cannot borrow session allowlist" \
  "$(hook_input_at "cd $TMPDIR/target && git reset --hard" "$TMPDIR/session")"
assert_blocked "quoted -C target with spaces is enforced" \
  "$(hook_input_at "git -C '$TMPDIR/target with spaces' reset --hard" "$TMPDIR/session")"
assert_blocked "global option text in a quote cannot hide a later reset" \
  "$(hook_input_at 'echo "git -c x"; git reset --hard' "$TMPDIR/denied")"
assert_blocked "attached -C text in a quote cannot hide a later reset" \
  "$(hook_input_at 'echo "git -Cfoo"; git reset --hard' "$TMPDIR/denied")"
assert_blocked "attached -C after another global option cannot borrow session policy" \
  "$(hook_input_at "git --no-pager -C$TMPDIR/target reset --hard" "$TMPDIR/session")"
assert_blocked "attached -c cannot hide reset" \
  "$(hook_input_at 'git -ccolor.ui=false reset --hard' "$TMPDIR/denied")"

echo "allow: reset --hard" > "$TMPDIR/target/.git-safe"
mkdir -p "$TMPDIR/session/target"
git init -q "$TMPDIR/session/target"
assert_blocked "repeated -C cannot borrow independent allowlists" \
  "$(hook_input_at "git -C session -C target reset --hard" "$TMPDIR")"
assert_allowed "target's own allowlist permits git -C reset" \
  "$(hook_input_at "git -C $TMPDIR/target reset --hard" "$TMPDIR/session")"
assert_allowed "target's own allowlist permits cd then reset" \
  "$(hook_input_at "cd $TMPDIR/target && git reset --hard" "$TMPDIR/session")"
assert_blocked "later cd cannot authorize an earlier reset" \
  "$(hook_input_at "git reset --hard; cd $TMPDIR/target" "$TMPDIR/denied")"
assert_blocked "echo -C cannot authorize a reset" \
  "$(hook_input_at "echo -C $TMPDIR/target; git reset --hard" "$TMPDIR/denied")"
assert_blocked "safe targeted Git command cannot authorize later implicit reset" \
  "$(hook_input_at "git -C $TMPDIR/target status; git reset --hard" "$TMPDIR/denied")"
assert_blocked "failed cd fallback cannot borrow target policy" \
  "$(hook_input_at "cd $TMPDIR/target || git reset --hard" "$TMPDIR/denied")"
assert_allowed "separate authorized -C commands are not a repeated -C chain" \
  "$(hook_input_at "git -C $TMPDIR/target reset --hard; git -C $TMPDIR/target reset --hard" "$TMPDIR/denied")"
mkdir -p "$TMPDIR/session/child" "$TMPDIR/target/child"
git init -q "$TMPDIR/session/child"
git init -q "$TMPDIR/target/child"
echo "allow: reset --hard" > "$TMPDIR/session/child/.git-safe"
assert_blocked "relative -C after cd cannot borrow the wrong child policy" \
  "$(hook_input_at "cd $TMPDIR/target && git -C child reset --hard" "$TMPDIR/session")"
assert_blocked "second relative cd cannot borrow the wrong child policy" \
  "$(hook_input_at "cd $TMPDIR/target && cd child && git reset --hard" "$TMPDIR/session")"
assert_allowed "safe git -C status remains allowed" \
  "$(hook_input_at "git -C $TMPDIR/target status" "$TMPDIR/session")"

# --- Results ---
echo ""
echo "========================================="
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} out of $TOTAL"
echo "========================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
