#!/bin/bash
# branch-guard: PreToolUse hook for Claude Code
# Prevents commits directly to protected branches (main, master, etc.).
# Forces feature-branch workflow.
#
# Protected branches (default): main, master, production, release
#
# Install:
#   curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/branch-guard/install.sh | bash
#
# Config (.branch-guard):
#   protect: main
#   protect: master
#   protect: staging
#   allow-merge: true     # allow merge commits on protected branches
#
# Env vars:
#   BRANCH_GUARD_DISABLED=1       Disable the hook entirely
#   BRANCH_GUARD_PROTECTED=main,master   Override protected branch list
#   BRANCH_GUARD_LOG=1            Log all checks to stderr

set -euo pipefail

if [ "${BRANCH_GUARD_DISABLED:-0}" = "1" ]; then
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
  if [ "${BRANCH_GUARD_LOG:-0}" = "1" ]; then
    echo "[branch-guard] $*" >&2
  fi
}

# Print command segments split on unquoted shell separators. Characters inside
# single or double quotes are replaced with spaces so examples like
# echo "git commit -m test" do not look executable to the matcher.
command_segments() {
  awk '
    {
      out = ""
      sq = 0
      dq = 0
      esc = 0
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        n = substr($0, i + 1, 1)

        if (esc) {
          out = out ((sq || dq) ? " " : c)
          esc = 0
          continue
        }

        if (c == "\\" && !sq) {
          out = out (dq ? " " : c)
          esc = 1
          continue
        }

        if (c == "'"'"'" && !dq) {
          sq = !sq
          out = out " "
          continue
        }

        if (c == "\"" && !sq) {
          dq = !dq
          out = out " "
          continue
        }

        if (sq || dq) {
          out = out " "
          continue
        }

        if (c == ";" || c == "|") {
          print out
          out = ""
          if (c == "|" && n == "|") {
            i++
          }
          continue
        }

        if (c == "&" && n == "&") {
          print out
          out = ""
          i++
          continue
        }

        out = out c
      }
      print out
    }
  ' <<< "$COMMAND"
}

is_git_binary_token() {
  local token="$1"
  token="${token##*/}"
  token="${token%.exe}"
  [ "$token" = "git" ]
}

is_assignment_token() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]
}

normalize_target_dir() {
  local dir="$1"
  dir=$(printf '%s' "$dir" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  local first="${dir:0:1}"
  local last="${dir: -1}"
  if { [ "$first" = '"' ] && [ "$last" = '"' ]; } || { [ "$first" = "'" ] && [ "$last" = "'" ]; }; then
    dir="${dir:1:${#dir}-2}"
  fi
  printf '%s' "$dir"
}

leading_cd_target_dir() {
  local cmd="$1"
  local cd_pattern="^[[:space:]]*cd[[:space:]]+([^&;|]+)[[:space:]]*&&"
  if [[ "$cmd" =~ $cd_pattern ]]; then
    normalize_target_dir "${BASH_REMATCH[1]}"
    return
  fi
  printf '.'
}

is_git_commit_segment() {
  local segment="$1"
  local words=()
  local i=0
  local token=""
  local subcommand=""
  local target_dir="$GIT_COMMIT_TARGET_DIR"

  read -r -a words <<< "$segment"
  [ ${#words[@]} -gt 0 ] || return 1

  while [ $i -lt ${#words[@]} ]; do
    token="${words[$i]}"
    if [ "$token" = "env" ] || [ "$token" = "command" ] || [ "$token" = "exec" ]; then
      i=$((i + 1))
      continue
    fi
    if is_assignment_token "$token"; then
      i=$((i + 1))
      continue
    fi
    break
  done

  [ $i -lt ${#words[@]} ] || return 1
  is_git_binary_token "${words[$i]}" || return 1
  i=$((i + 1))

  while [ $i -lt ${#words[@]} ]; do
    token="${words[$i]}"
    case "$token" in
      -C)
        if [ $((i + 1)) -lt ${#words[@]} ]; then
          target_dir=$(normalize_target_dir "${words[$((i + 1))]}")
        fi
        i=$((i + 2))
        continue
        ;;
      -c|--git-dir|--work-tree|--namespace|--exec-path|--config-env)
        i=$((i + 2))
        continue
        ;;
      --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*|--config-env=*)
        i=$((i + 1))
        continue
        ;;
      --)
        i=$((i + 1))
        break
        ;;
      -*)
        i=$((i + 1))
        continue
        ;;
      *)
        break
        ;;
    esac
  done

  [ $i -lt ${#words[@]} ] || return 1
  subcommand="${words[$i]}"
  [ "$subcommand" = "commit" ] || return 1

  for token in "${words[@]:$((i + 1))}"; do
    if [ "$token" = "--amend" ]; then
      return 2
    fi
  done

  GIT_COMMIT_TARGET_DIR="$target_dir"
  return 0
}

HAS_NEW_COMMIT=0
GIT_COMMIT_TARGET_DIR=$(leading_cd_target_dir "$COMMAND")
while IFS= read -r segment; do
  set +e
  is_git_commit_segment "$segment"
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    HAS_NEW_COMMIT=1
    break
  fi
done < <(command_segments)

# Only check actual git commit command segments.
if [ "$HAS_NEW_COMMIT" -eq 0 ]; then
  log "SKIP: not a git commit"
  exit 0
fi

block() {
  local reason="$1"
  local suggestion="${2:-}"
  local msg="branch-guard: $reason"
  if [ -n "$suggestion" ]; then
    msg="$msg Suggestion: $suggestion"
  fi
  jq -cn --arg r "$msg" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
  exit 0
}

# Build protected branches list
PROTECTED=()

# 1. Check env var override
if [ -n "${BRANCH_GUARD_PROTECTED:-}" ]; then
  IFS=',' read -ra PROTECTED <<< "$BRANCH_GUARD_PROTECTED"
  log "Protected branches from env: ${PROTECTED[*]}"
else
  # 2. Check config file
  CONFIG="${BRANCH_GUARD_CONFIG:-.branch-guard}"
  if [ -f "$CONFIG" ]; then
    while IFS= read -r line; do
      line=$(echo "$line" | sed 's/#.*//' | xargs)
      [ -z "$line" ] && continue
      if [[ "$line" == protect:* ]]; then
        branch=$(echo "$line" | sed 's/^protect:\s*//' | xargs)
        PROTECTED+=("$branch")
      fi
    done < "$CONFIG"
    log "Protected branches from config: ${PROTECTED[*]+"${PROTECTED[*]}"}"
  fi

  # 3. Defaults if nothing configured
  if [ ${#PROTECTED[@]} -eq 0 ]; then
    PROTECTED=("main" "master" "production" "release")
    log "Protected branches (defaults): ${PROTECTED[*]}"
  fi
fi

log "Target directory: $GIT_COMMIT_TARGET_DIR"

# Get current branch from the repository that the intercepted command targets.
CURRENT_BRANCH=$(git -C "$GIT_COMMIT_TARGET_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [ -z "$CURRENT_BRANCH" ]; then
  log "SKIP: target is not in a git repo or detached HEAD"
  exit 0
fi

log "Current branch: $CURRENT_BRANCH"

# Check if current branch is protected
for protected in "${PROTECTED[@]}"; do
  if [ "$CURRENT_BRANCH" = "$protected" ]; then
    block \
      "Direct commit to '$CURRENT_BRANCH' is not allowed. Protected branches require feature-branch workflow." \
      "Create a feature branch first: git checkout -b feature/your-change"
  fi
done

log "ALLOW: branch '$CURRENT_BRANCH' is not protected"
exit 0
