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

PAYLOAD_CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -n "$PAYLOAD_CWD" ] || PAYLOAD_CWD="$PWD"
log() {
  if [ "${GIT_SAFE_LOG:-0}" = "1" ]; then
    echo "[git-safe] $*" >&2
  fi
}

# Print command segments split on unquoted shell separators. Most quoted
# arguments become opaque markers; simple literal words, options, and Git
# environment assignments remain visible after quote removal. Here-docs become
# spaces, and substitutions in unquoted bodies still emit an execution marker.
# A quoted -C directory still occupies one argument when options are normalized.
command_segments() {
  awk '
    function quoted_token(word, name) {
      if (word == "") return ""
      if (word ~ /^GIT_(DIR|WORK_TREE|OBJECT_DIRECTORY)=/) {
        name = word
        sub(/=.*/, "", name)
        return name "=__GIT_SAFE_QUOTED__"
      }
      # Shell also removes quotes around simple options and word fragments.
      # Keep shell syntax and whitespace opaque.
      if (word ~ /^[-A-Za-z0-9_.\/=:+@]+$/) {
        return word
      }
      return "__GIT_SAFE_OPAQUE_Q__"
    }

    function reset_heredoc(delim, quoted) {
      heredoc = delim
      heredoc_quoted = quoted
    }

    function comment_starts(line, pos,    i, c, sq, dq, esc, boundary) {
      boundary = 1
      for (i = 1; i < pos; i++) {
        c = substr(line, i, 1)
        if (sq) {
          if (c == "'\''") sq = 0
          boundary = 0
          continue
        }
        if (esc) {
          esc = 0
          boundary = 0
          continue
        }
        if (c == "\\") {
          esc = 1
          boundary = 0
          continue
        }
        if (c == "'\''" && !dq) {
          sq = 1
          boundary = 0
          continue
        }
        if (c == "\"") {
          dq = !dq
          boundary = 0
          continue
        }
        if (dq) {
          boundary = 0
          continue
        }
        boundary = c ~ /[ \t;&|<>]/
      }
      return !sq && !dq && !esc && boundary
    }

    function line_continues(line,    i, c, sq, dq, esc) {
      sq = 0
      dq = 0
      esc = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (sq) {
          if (c == "'\''") sq = 0
          continue
        }
        if (esc) {
          esc = 0
          continue
        }
        if (c == "\\") {
          esc = 1
          continue
        }
        if (c == "\"" && !sq) {
          dq = !dq
          continue
        }
        if (c == "'\''" && !dq) {
          sq = 1
          continue
        }
        if (c == "#" && !dq && comment_starts(line, i)) {
          return 0
        }
      }
      return esc && !sq
    }

    function maybe_heredoc(line,    i, c, n, q, delim, quoted, sq, dq, esc) {
      sq = 0
      dq = 0
      esc = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        n = substr(line, i + 1, 1)
        if (esc) {
          esc = 0
          continue
        }
        if (c == "\\" && !sq) {
          esc = 1
          continue
        }
        if (c == "'\''" && !dq) {
          sq = !sq
          continue
        }
        if (c == "\"" && !sq) {
          dq = !dq
          continue
        }
        if (sq || dq) {
          continue
        }
        if (c == "#" && comment_starts(line, i)) {
          return
        }
        if (c == "<" && n == "<") {
          if (substr(line, i + 2, 1) == "<") {
            i += 2
            continue
          }
          i += 2
          if (substr(line, i, 1) == "-") {
            i++
          }
          while (substr(line, i, 1) ~ /[ \t]/) {
            i++
          }
          q = ""
          delim = ""
          quoted = 0
          esc = 0
          while (i <= length(line)) {
            c = substr(line, i, 1)
            if (esc) {
              delim = delim c
              esc = 0
            } else if (c == "\\" && q != "'\''") {
              n = substr(line, i + 1, 1)
              if (q == "\"" && n != "$" && n != "`" &&
                  n != "\"" && n != "\\") {
                delim = delim c
              } else {
                quoted = 1
                esc = 1
              }
            } else if (q != "") {
              if (c == q) q = ""; else delim = delim c
            } else if (c == "\"" || c == "'\''") {
              quoted = 1
              q = c
            } else if (c ~ /[ \t;&|<>]/) {
              break
            } else {
              delim = delim c
            }
            i++
          }
          if (delim != "" && q == "" && !esc) {
            reset_heredoc(delim, quoted)
            return
          }
        }
      }
    }

    {
      if (heredoc != "") {
        if ($0 == heredoc) {
          heredoc = ""
          heredoc_quoted = 0
          print ""
          next
        }
        if (!heredoc_quoted) {
          esc = 0
          for (i = 1; i <= length($0); i++) {
            c = substr($0, i, 1)
            n = substr($0, i + 1, 1)
            if (esc) {
              esc = 0
              continue
            }
            if (c == "\\") {
              esc = 1
              continue
            }
            if (c == "`" || (c == "$" && n == "(")) {
              print "__GIT_SAFE_EMBEDDED__"
              break
            }
          }
        }
        print ""
        next
      }

      # Only Bash continuations in executable text join physical lines.
      # A backslash in a comment, a single quote, or a here-doc body is data.
      logical = $0
      while (line_continues(logical)) {
        logical = substr(logical, 1, length(logical) - 1)
        if ((getline continuation) <= 0) break
        logical = logical continuation
      }
      $0 = logical

      out = ""
      embedded = 0
      sq = 0
      dq = 0
      esc = 0
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        n = substr($0, i + 1, 1)

        if (esc) {
          if (sq || dq) {
            quote_text = quote_text "\\" c
            out = out " "
          } else {
            # Backslash-escaped dollars and backticks are literal shell data.
            out = out ((c == "$" || c == "`") ? "__GIT_SAFE_ESCAPED__" : c)
          }
          esc = 0
          continue
        }

        if (c == "\\" && !sq) {
          out = out (dq ? " " : c)
          esc = 1
          continue
        }

        if (c == "'\''" && !dq) {
          if (sq) {
            sq = 0
            out = substr(out, 1, quote_start) quoted_token(quote_text)
          } else {
            sq = 1
            quote_start = length(out)
            quote_text = ""
            out = out "__GIT_SAFE_OPAQUE_Q__"
          }
          continue
        }

        if (c == "\"" && !sq) {
          if (dq) {
            dq = 0
            out = substr(out, 1, quote_start) quoted_token(quote_text)
          } else {
            dq = 1
            quote_start = length(out)
            quote_text = ""
            out = out "__GIT_SAFE_OPAQUE_Q__"
          }
          continue
        }

        # Substitutions execute in unquoted and double-quoted text, but not
        # inside single quotes.  Here-doc bodies are skipped above.
        if (!sq && (c == "`" || (c == "$" && n == "("))) {
          embedded = 1
        }

        if (sq || dq) {
          quote_text = quote_text c
          out = out " "
          continue
        }

        # A shell comment starts at a word boundary; its text is not executed.
        if (c == "#" && comment_starts($0, i)) {
          break
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
      if (embedded) {
        print "__GIT_SAFE_EMBEDDED__"
      }
      maybe_heredoc($0)
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

# A prior shell assignment or export can redirect a later Git command in the
# same Bash tool call. Text printed by a command such as echo is not an export.
segment_sets_git_env() {
  local words=() token i=0
  read -r -a words <<< "$1"
  [ ${#words[@]} -gt 0 ] || return 1
  while [ $i -lt ${#words[@]} ]; do
    case "${words[$i]}" in
      builtin) i=$((i + 1)) ;;
      command)
        i=$((i + 1))
        while [ $i -lt ${#words[@]} ]; do
          case "${words[$i]}" in
            -p|--) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      *) break ;;
    esac
  done
  [ $i -lt ${#words[@]} ] || return 1
  case "${words[$i]}" in
    export|declare|typeset|readonly|local) ;;
    *) is_assignment_token "${words[$i]}" || return 1 ;;
  esac
  for token in "${words[@]}"; do
    case "$token" in
      GIT_DIR=*|GIT_WORK_TREE=*|GIT_OBJECT_DIRECTORY=*) return 0 ;;
    esac
  done
  return 1
}

segment_sets_git_config() {
  local words=() token i=0
  read -r -a words <<< "$1"
  [ ${#words[@]} -gt 0 ] || return 1
  while [ $i -lt ${#words[@]} ]; do
    case "${words[$i]}" in
      builtin|command) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  [ $i -lt ${#words[@]} ] || return 1
  case "${words[$i]}" in
    export|declare|typeset|readonly|local) ;;
    *) is_assignment_token "${words[$i]}" || return 1 ;;
  esac
  for token in "${words[@]}"; do
    case "$token" in GIT_CONFIG_*=*) return 0 ;; esac
  done
  return 1
}

# Keep a marker when a shell word concatenates an expansion with verb or flag
# fragments, so the complete runtime argv cannot be mistaken for a literal.
is_opaque_word() {
  case "$1" in
    *__GIT_SAFE_OPAQUE_Q__*|*__GIT_SAFE_OPAQUE_U__*) return 0 ;;
    *) return 1 ;;
  esac
}

is_git_command_segment() {
  local segment="$1"
  local words=()
  local i=0
  local token=""
  local base=""

  CURRENT_OPAQUE_EXEC=0
  read -r -a words <<< "$segment"
  [ ${#words[@]} -gt 0 ] || return 1

  while [ $i -lt ${#words[@]} ]; do
    token="${words[$i]}"
    if is_assignment_token "$token"; then
      i=$((i + 1))
      continue
    fi
    base="${token##*/}"
    case "$base" in
      env)
        i=$((i + 1))
        while [ $i -lt ${#words[@]} ]; do
          token="${words[$i]}"
          case "$token" in
            -S|--split-string|-S?*|--split-string=*)
              # env -S splits a string into an executable and its arguments.
              # The quoted string is opaque to the outer segment scanner.
              EMBEDDED_SHELL=1
              i=$((i + 2)) ;;
            -C|--chdir) WRAPPER_CWD=1; i=$((i + 2)) ;;
            -C?*|--chdir=*) WRAPPER_CWD=1; i=$((i + 1)) ;;
            -u|--unset) i=$((i + 2)) ;;
            -i|--ignore-environment|-0|--null|--|-u?*|--unset=*)
              i=$((i + 1)) ;;
            -*) i=$((i + 1)) ;;
            *) if is_assignment_token "$token"; then i=$((i + 1)); else break; fi ;;
          esac
        done
        ;;
      command)
        i=$((i + 1))
        while [ $i -lt ${#words[@]} ]; do
          case "${words[$i]}" in
            -p|--) i=$((i + 1)) ;;
            -v|-V) return 1 ;;
            *) break ;;
          esac
        done
        ;;
      sudo)
        i=$((i + 1))
        while [ $i -lt ${#words[@]} ]; do
          token="${words[$i]}"
          case "$token" in
            -D|--chdir|-R|--chroot)
              WRAPPER_CWD=1; i=$((i + 2)) ;;
            -D?*|--chdir=*|-R?*|--chroot=*)
              WRAPPER_CWD=1; i=$((i + 1)) ;;
            -u|--user|-g|--group|-h|--host|-p|--prompt|-C|--close-from|-r|--role|-t|--type|-T|--command-timeout|-U|--other-user)
              i=$((i + 2)) ;;
            -u?*|--user=*|-g?*|--group=*|-n|-E|-H|-S|-b|-P|-A|--)
              i=$((i + 1)) ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      time)
        i=$((i + 1))
        while [ $i -lt ${#words[@]} ]; do
          case "${words[$i]}" in
            -o|--output|-f|--format) i=$((i + 2)) ;;
            -p|--portability|--|-l|-v|-a) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      nice)
        i=$((i + 1))
        while [ $i -lt ${#words[@]} ]; do
          case "${words[$i]}" in
            -n|--adjustment) i=$((i + 2)) ;;
            -n?*|--adjustment=*|-[0-9]*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      timeout)
        i=$((i + 1))
        while [ $i -lt ${#words[@]} ]; do
          case "${words[$i]}" in
            -s|--signal|-k|--kill-after) i=$((i + 2)) ;;
            -s?*|--signal=*|-k?*|--kill-after=*|--foreground|--preserve-status|--)
              i=$((i + 1)) ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        i=$((i + 1)) # duration
        ;;
      caffeinate)
        i=$((i + 1))
        while [ $i -lt ${#words[@]} ]; do
          case "${words[$i]}" in
            -t|-w) i=$((i + 2)) ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      stdbuf)
        i=$((i + 1))
        while [ $i -lt ${#words[@]} ]; do
          case "${words[$i]}" in
            -i|-o|-e) i=$((i + 2)) ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      exec)
        i=$((i + 1))
        while [ $i -lt ${#words[@]} ]; do
          case "${words[$i]}" in
            -a) i=$((i + 2)) ;;
            -c|-l|--) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      nohup) i=$((i + 1)) ;;
      *) break ;;
    esac
  done

  [ $i -lt ${#words[@]} ] || return 1
  if is_opaque_word "${words[$i]}"; then
    # An expansion can select git at runtime. Match destructive Git arguments
    # under an unresolved target instead of treating the call as non-Git.
    OPAQUE_EXEC=1
    CURRENT_OPAQUE_EXEC=1
    GIT_CANDIDATE_INDEX=$i
    return 0
  fi
  is_git_binary_token "${words[$i]}"
}

is_embedded_shell_segment() {
  local segment="$1" words=() i=0 j=0 token option
  read -r -a words <<< "$segment"
  [ ${#words[@]} -gt 0 ] || return 1

  while [ $i -lt ${#words[@]} ]; do
    token="${words[$i]}"
    if [ "$token" = "env" ] || [ "$token" = "command" ] || [ "$token" = "exec" ] ||
       [ "$token" = "sudo" ] || [ "$token" = "time" ] || [ "$token" = "nohup" ] ||
       is_assignment_token "$token"; then
      i=$((i + 1))
    else
      break
    fi
  done
  [ $i -lt ${#words[@]} ] || return 1
  token="${words[$i]##*/}"
  [ "$token" = "eval" ] && return 0

  # Wrappers such as `env -i`, `sudo -u root`, and `time -p` can put the
  # shell beyond the first executable token.  The segment has already had
  # quoted arguments scrubbed, so scan its remaining executable words.
  for ((i = 0; i < ${#words[@]}; i++)); do
    token="${words[$i]##*/}"
    case "$token" in bash|sh|zsh|dash|ksh) ;; *) continue ;; esac
    for ((j = i + 1; j < ${#words[@]}; j++)); do
      option="${words[$j]}"
      case "$option" in
        -O|-o) j=$((j + 1)); continue ;;
      esac
      if [[ "$option" =~ ^-[a-zA-Z]*c[a-zA-Z]*$ ]]; then
        return 0
      fi
      case "$option" in
        --) break ;;
        -*) ;;
        *) break ;;
      esac
    done
  done
  return 1
}

# Git accepts global options between `git` and the subcommand.  Match against
# each quote-scrubbed executable segment after removing those options, or
# `git -C dir reset --hard` escapes every `git reset` rule below.  Never rewrite
# the raw shell command before quote parsing: that can consume a closing quote
# in harmless prose and hide a later real Git command.
strip_git_globals() {
  local command="$1" words=() output=() i=0 token
  read -r -a words <<< "$command"
  while [ $i -lt ${#words[@]} ]; do
    token="${words[$i]}"
    # env -S accepts the executable attached to its option. Expose a literal
    # Git head here so its global options are normalized like a direct call.
    case "$token" in
      -S?*) candidate="${token#-S}" ;;
      --split-string=*) candidate="${token#--split-string=}" ;;
      *) candidate="" ;;
    esac
    if [ -n "$candidate" ] && is_git_binary_token "$candidate"; then
      token="git"
    fi
    output+=("$token")
    i=$((i + 1))
    if ! is_git_binary_token "$token"; then
      continue
    fi
    while [ $i -lt ${#words[@]} ]; do
      token="${words[$i]}"
      case "$token" in
        -C|-c|--git-dir|--work-tree|--namespace|--config-env|--super-prefix)
          i=$((i + 2)) ;;
        -C?*|-c?*|--git-dir=*|--work-tree=*|--namespace=*|--exec-path=*|--config-env=*|--super-prefix=*|-*)
          i=$((i + 1)) ;;
        *) break ;;
      esac
    done
  done
  [ ${#output[@]} -gt 0 ] || return 0
  printf '%s ' "${output[@]}" | sed 's/ $//'
}

# The shell expands unquoted variables and substitutions before Git receives
# argv. Keep assignment names for target/config checks, but mark any unknown
# value as an opaque marker. Unlike quoted words, unquoted values may split.
mark_opaque_expansions() {
  local words=() output=() token
  if [ -z "${1//[[:space:]]/}" ]; then
    printf '\n'
    return 0
  fi
  read -r -a words <<< "$1"
  for token in "${words[@]}"; do
    case "$token" in
      *'$'*|*'`'*)
        if is_assignment_token "$token"; then
          output+=("${token%%=*}=__GIT_SAFE_OPAQUE_U__")
        else
          output+=("__GIT_SAFE_OPAQUE_U__")
        fi ;;
      *) output+=("$token") ;;
    esac
  done
  printf '%s\n' "${output[*]}"
}

mark_opaque_segments() {
  local segment
  while IFS= read -r segment; do
    mark_opaque_expansions "$segment"
  done <<< "$1"
}

append_literal_script_contents() {
  local segments="$1" depth="${2:-0}" segment words=() token path script_path script_body nested_segments seen i interpreter
  [ "$depth" -lt 16 ] || return 1
  while IFS= read -r segment; do
    read -r -a words <<< "$segment"
    i=0
    while [ $i -lt ${#words[@]} ]; do
      token="${words[$i]}"
      if is_assignment_token "$token"; then i=$((i + 1)); continue; fi
      case "$token" in
        env)
          i=$((i + 1))
          while [ $i -lt ${#words[@]} ]; do
            case "${words[$i]}" in
              -u|--unset|-C|--chdir) i=$((i + 2)) ;;
              -i|--ignore-environment|-0|--null|--unset=*|--chdir=*) i=$((i + 1)) ;;
              --) i=$((i + 1)); break ;;
              -*) return 1 ;;
              *=*) i=$((i + 1)) ;;
              *) break ;;
            esac
          done
          continue ;;
        command|builtin)
          i=$((i + 1))
          while [ $i -lt ${#words[@]} ]; do
            case "${words[$i]}" in
              -p|--) i=$((i + 1)) ;;
              -*) return 1 ;;
              *) break ;;
            esac
          done
          continue ;;
        exec)
          i=$((i + 1))
          while [ $i -lt ${#words[@]} ]; do
            case "${words[$i]}" in
              -a) i=$((i + 2)) ;;
              -c|-l|--) i=$((i + 1)) ;;
              -*) return 1 ;;
              *) break ;;
            esac
          done
          continue ;;
        nohup) i=$((i + 1)); continue ;;
        sudo|time|nice|timeout|stdbuf|caffeinate)
          i=$((i + 1))
          while [ $i -lt ${#words[@]} ]; do
            case "${words[$i]}" in
              --) i=$((i + 1)); break ;;
              -u|-g|-h|-C|-r|-t|-D)
                [ "$token" = sudo ] || return 1
                i=$((i + 2)) ;;
              --user|--group|--host|--chdir|--role|--type)
                [ "$token" = sudo ] || return 1
                i=$((i + 2)) ;;
              --user=*|--group=*|--host=*|--chdir=*|--role=*|--type=*)
                [ "$token" = sudo ] || return 1
                i=$((i + 1)) ;;
              -p)
                if [ "$token" = sudo ]; then i=$((i + 2)); else i=$((i + 1)); fi ;;
              -f|-o)
                [ "$token" = time ] || [ "$token" = stdbuf ] || return 1
                i=$((i + 2)) ;;
              -n)
                if [ "$token" = nice ]; then i=$((i + 2));
                elif [ "$token" = sudo ]; then i=$((i + 1));
                else return 1; fi ;;
              -s|-k)
                if [ "$token" = timeout ]; then i=$((i + 2));
                elif [ "$token" = sudo ]; then i=$((i + 1));
                else return 1; fi ;;
              -i|-e)
                [ "$token" = stdbuf ] || return 1
                i=$((i + 2)) ;;
              --adjustment)
                [ "$token" = nice ] || return 1
                i=$((i + 2)) ;;
              --signal|--kill-after)
                [ "$token" = timeout ] || return 1
                i=$((i + 2)) ;;
              --adjustment=*)
                [ "$token" = nice ] || return 1
                i=$((i + 1)) ;;
              --signal=*|--kill-after=*)
                [ "$token" = timeout ] || return 1
                i=$((i + 1)) ;;
              -o?*|-i?*|-e?*)
                [ "$token" = stdbuf ] || return 1
                i=$((i + 1)) ;;
              -[0-9]*)
                [ "$token" = nice ] || return 1
                i=$((i + 1)) ;;
              -n|-E|-H|-k|-K|-S|-b|-v|-P|-l|-s|-p)
                i=$((i + 1)) ;;
              -*) return 1 ;;
              *) break ;;
            esac
          done
          case "$token" in timeout) i=$((i + 1)) ;; esac
          continue ;;
      esac
      break
    done
    [ $i -lt ${#words[@]} ] || continue
    path=""
    interpreter=0
    token="${words[$i]}"
    case "$token" in
      source|.) interpreter=1; path="${words[$((i + 1))]:-}" ;;
      bash|sh|zsh|dash|ksh)
        interpreter=1
        i=$((i + 1))
        while [ $i -lt ${#words[@]} ] && [[ "${words[$i]}" == [-+]* ]]; do
          case "${words[$i]}" in
            -c|--command|-[A-Za-z]*c[A-Za-z]*) break ;;
            -O|-o|+O|+o) i=$((i + 1)) ;;
          esac
          i=$((i + 1))
        done
        if [ $i -lt ${#words[@]} ]; then
          case "${words[$i]}" in
            -c|--command|-[A-Za-z]*c[A-Za-z]*) ;;
            *) path="${words[$i]}" ;;
          esac
        fi ;;
      ./*|../*|/*|*.sh) path="$token" ;;
    esac
      [ -n "$path" ] || continue
      case "$path" in *'$'*|*'`'*|*'__GIT_SAFE_'*) return 1 ;; esac
      path="${path#\"}"; path="${path%\"}"
      path="${path#\'}"; path="${path%\'}"
      if [ "$interpreter" = "0" ]; then
        case "$path" in ./*|../*|/*|*.sh) ;; *) continue ;; esac
      fi
      if [[ "$path" = /* ]]; then
        script_path="$path"
      else
        script_path="$PAYLOAD_CWD/$path"
      fi
      [ -f "$script_path" ] || return 1
      seen=""
      for seen in "${SCRIPT_SEEN[@]}"; do
        [ "$seen" != "$script_path" ] || break
      done
      [ "$seen" != "$script_path" ] || continue
      SCRIPT_SEEN+=("$script_path")
      script_body=$(<"$script_path") || return 1
      COMMAND="${COMMAND}"$'\n'"${script_body}"
      nested_segments=$(COMMAND="$script_body" command_segments) || return 1
      append_literal_script_contents "$nested_segments" "$((depth + 1))" || return 1
  done <<< "$segments"
}

GIT_COMMANDS=""
IMPLICIT_GIT=0
EMBEDDED_SHELL=0
REPEATED_C=0
INLINE_GIT_ENV=0
WRAPPER_CWD=0
OPAQUE_EXEC=0
CURRENT_OPAQUE_EXEC=0
GIT_CANDIDATE_INDEX=0
OPAQUE_EXEC_LINES=""
DYNAMIC_SHELL=0
SCRIPT_SEEN=("")
SAFE_CD_CHAIN=0
# Only this single, guarded cd form can omit the starting cwd from policy
# checks. Other control flow may run Git in the starting directory.
if [[ "$COMMAND" =~ ^[[:space:]]*cd[[:space:]]+[^\;\&\|]+[[:space:]]*\&\&[[:space:]]*git[[:space:]]+[^\;\&\|]*$ ]]; then
  SAFE_CD_CHAIN=1
fi
if ! original_segments=$(command_segments); then
  printf '%s\n' 'git-safe: command inspection failed.' >&2
  exit 2
fi
if ! append_literal_script_contents "$original_segments"; then
  printf '%s\n' 'git-safe: Script contents cannot be inspected safely.' >&2
  exit 2
fi
if ! segments=$(command_segments); then
  printf '%s\n' 'git-safe: command inspection failed.' >&2
  exit 2
fi
if ! segments=$(mark_opaque_segments "$segments"); then
  printf '%s\n' 'git-safe: command inspection failed.' >&2
  exit 2
fi
while IFS= read -r segment; do
  if [ "$segment" = "__GIT_SAFE_EMBEDDED__" ]; then
    EMBEDDED_SHELL=1
    continue
  fi
  normalized=$(strip_git_globals "$segment")
  if segment_sets_git_env "$normalized"; then
    INLINE_GIT_ENV=1
  fi
  if is_embedded_shell_segment "$segment"; then
    EMBEDDED_SHELL=1
    if is_opaque_word "$segment"; then
      DYNAMIC_SHELL=1
    fi
  fi
  if is_git_command_segment "$normalized"; then
    if [ "$CURRENT_OPAQUE_EXEC" = "1" ]; then
      read -r -a candidate_words <<< "$normalized"
      candidate_words[$GIT_CANDIDATE_INDEX]="git"
      normalized="${candidate_words[*]}"
      OPAQUE_EXEC_LINES="${OPAQUE_EXEC_LINES}
$normalized"
    fi
    # Attached env split-string heads have already been normalized to Git;
    # retain their opaque target context instead of borrowing the cwd policy.
    if [[ "$segment" =~ (^|[[:space:]])env[[:space:]]+(-S|--split-string) ]]; then
      EMBEDDED_SHELL=1
    fi
    # Inline assignments affect the child Git process, even though they do
    # not appear in this hook's own environment. No local allowlist is safe.
    if [[ "$normalized" =~ (^|[[:space:]])GIT_(DIR|WORK_TREE|OBJECT_DIRECTORY)= ]]; then
      INLINE_GIT_ENV=1
    fi
    c_in_segment=$(printf '%s\n' "$segment" | grep -oE '(^|[[:space:]])-C([[:space:]]|[^[:space:]])' | wc -l | tr -d '[:space:]' || true)
    if [ "$c_in_segment" -gt 1 ]; then
      REPEATED_C=1
    fi
    # A Git invocation without its own -C may still run in the payload cwd.
    # The only supported exception is one leading `cd target && git ...`, whose
    # Git call cannot run when cd fails.  All other shell control flow is
    # conservatively checked against the payload cwd as well.
    if ! [[ "$segment" =~ (^|[[:space:]])-C([[:space:]]|[^[:space:]]) ]] &&
       [ "$SAFE_CD_CHAIN" = "0" ]; then
      IMPLICIT_GIT=1
    fi
    if [ -z "$GIT_COMMANDS" ]; then
      GIT_COMMANDS="$normalized"
    else
      GIT_COMMANDS="$GIT_COMMANDS
$normalized"
    fi
  fi
done <<< "$segments"

# A quoted shell script or command substitution is executable, even though the
# outer quote parser treats ordinary prose as data.  Its target cannot be
# inferred safely from the outer shell.
if [ "$EMBEDDED_SHELL" = "1" ]; then
  embedded_text=$(printf '%s' "$COMMAND" | tr '\047\042\140\044\050\051' '      ')
  while IFS= read -r embedded_line; do
    GIT_COMMANDS="$GIT_COMMANDS
$(strip_git_globals "$embedded_line")"
  done <<< "$embedded_text"
  GIT_COMMANDS="$GIT_COMMANDS
$COMMAND"
fi

matches_git_command() {
  printf '%s\n' "$GIT_COMMANDS" | grep -qE "$1" 2>/dev/null
}

contains_git_text() {
  printf '%s\n' "$GIT_COMMANDS" | grep -q "$1" 2>/dev/null
}

if [ -z "$GIT_COMMANDS" ]; then
  if [ "$DYNAMIC_SHELL" != "0" ]; then
    printf '%s\n' 'git-safe: Shell command is selected at runtime and cannot be inspected.' >&2
    exit 2
  fi
  log "SKIP: no executable git command"
  exit 0
fi

# Resolve policy from the repository the command targets, not the hook's own
# process cwd.  A session in repo A can run `git -C repo-B ...` or `cd repo-B &&
# git ...`; A's allowlist must never authorize destructive work in B.  Multiple
# targets must all allow the operation.  Unresolvable explicit targets deny it.
target_path() {
  local raw="$1"
  raw="${raw#\"}"; raw="${raw%\"}"
  raw="${raw#\'}"; raw="${raw%\'}"
  (cd "$PAYLOAD_CWD" 2>/dev/null && cd "$raw" 2>/dev/null && pwd) || true
}

TARGET_DIRS=()
UNRESOLVED_TARGET=0
[ "$EMBEDDED_SHELL" = "0" ] || UNRESOLVED_TARGET=1
[ "$REPEATED_C" = "0" ] || UNRESOLVED_TARGET=1
[ "$INLINE_GIT_ENV" = "0" ] || UNRESOLVED_TARGET=1
[ "$WRAPPER_CWD" = "0" ] || UNRESOLVED_TARGET=1
[ "$OPAQUE_EXEC" = "0" ] || UNRESOLVED_TARGET=1
# Git repository environment can redirect the actual operation independently
# of -C. Without modelling that environment, no local allowlist is trusted.
if [ -n "${GIT_DIR:-}" ] || [ -n "${GIT_WORK_TREE:-}" ] ||
   [ -n "${GIT_OBJECT_DIRECTORY:-}" ]; then
  UNRESOLVED_TARGET=1
fi
C_OPTIONS=0
CD_OPTIONS=0
while IFS= read -r raw; do
  [ -n "$raw" ] || continue
  C_OPTIONS=$((C_OPTIONS + 1))
  raw=$(printf '%s' "$raw" | sed -E 's/.*-C[[:space:]]+//')
  target=$(target_path "$raw")
  if [ -n "$target" ]; then TARGET_DIRS+=("$target"); else UNRESOLVED_TARGET=1; fi
done < <(printf '%s\n' "$COMMAND" | grep -oE "(^|[[:space:]])-C[[:space:]]+('[^']*'|\"[^\"]*\"|[^[:space:];&|]+)" || true)
# Attached -C and alternate git-dir/work-tree forms are not resolved here.
if printf '%s\n' "$COMMAND" | grep -qE '(^|[[:space:]])-C[^[:space:]]|(^|[[:space:]])--(git-dir|work-tree)(=|[[:space:]])'; then
  UNRESOLVED_TARGET=1
fi
while IFS= read -r raw; do
  [ -n "$raw" ] || continue
  CD_OPTIONS=$((CD_OPTIONS + 1))
  raw=$(printf '%s' "$raw" | sed -E 's/.*cd[[:space:]]+//')
  target=$(target_path "$raw")
  if [ -n "$target" ]; then TARGET_DIRS+=("$target"); else UNRESOLVED_TARGET=1; fi
done < <(printf '%s\n' "$COMMAND" | grep -oE "(^|[;&|][[:space:]]*)cd[[:space:]]+('[^']*'|\"[^\"]*\"|[^[:space:];&|]+)" || true)
# Relative -C after cd, and repeated cd, need full shell state tracking to
# resolve precisely. Do not borrow any one of their policies.
if [ "$CD_OPTIONS" -gt 1 ] || { [ "$CD_OPTIONS" -gt 0 ] && [ "$C_OPTIONS" -gt 0 ]; }; then
  UNRESOLVED_TARGET=1
fi
[ ${#TARGET_DIRS[@]} -gt 0 ] || TARGET_DIRS=("$PAYLOAD_CWD")
[ "$IMPLICIT_GIT" = "0" ] || TARGET_DIRS+=("$PAYLOAD_CWD")

CONFIG_FILES=()
if [ -n "${GIT_SAFE_CONFIG:-}" ]; then
  CONFIG_FILES=("$GIT_SAFE_CONFIG")
elif [ "$UNRESOLVED_TARGET" = "0" ]; then
  for target in "${TARGET_DIRS[@]}"; do
    root=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_OBJECT_DIRECTORY \
      git -C "$target" rev-parse --show-toplevel 2>/dev/null || true)
    [ -n "$root" ] || root="$target"
    CONFIG_FILES+=("$root/.git-safe")
  done
fi

config_allows() {
  local op="$1" config="$2" line pattern
  [ -f "$config" ] || return 1
  while IFS= read -r line; do
    line=$(echo "$line" | sed 's/#.*//' | xargs)
    [ -z "$line" ] && continue
    if [[ "$line" == allow:* ]]; then
      pattern=$(echo "$line" | sed 's/^allow:\s*//' | xargs)
      [ "$pattern" = "$op" ] && return 0
    fi
  done < "$config"
  return 1
}

is_allowed() {
  local op="$1" config
  [ ${#CONFIG_FILES[@]} -gt 0 ] || return 1
  for config in "${CONFIG_FILES[@]}"; do
    config_allows "$op" "$config" || return 1
  done
  log "ALLOWED by config: $op"
  return 0
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

# Opaque markers represent words whose values are unknown until execution.
# Unquoted values can split into multiple argv entries or join literal text.
# Either may become a guarded flag or refspec. A quoted commit message is
# data after -m/--message.
check_opaque_git_operands() {
  local line words=() i j verb previous
  while IFS= read -r line; do
    line=$(strip_git_globals "$line")
    read -r -a words <<< "$line"
    for ((i = 0; i + 1 < ${#words[@]}; i++)); do
      is_git_binary_token "${words[$i]}" || continue
      verb="${words[$((i + 1))]}"
      if is_opaque_word "$verb"; then
        block "Git subcommand is selected at runtime and cannot be inspected."
      fi
      case "$verb" in
        status|log|show|diff|rev-parse|ls-files|ls-tree|cat-file|check-attr|check-ignore|for-each-ref|add)
          break ;;
      esac
      for ((j = i + 2; j < ${#words[@]}; j++)); do
        if ! is_opaque_word "${words[$j]}"; then
          continue
        fi
        previous="${words[$((j - 1))]}"
        if [ "$verb" = "commit" ] && [ "${words[$j]}" = "__GIT_SAFE_OPAQUE_Q__" ] &&
           { [ "$previous" = "-m" ] || [ "$previous" = "--message" ]; }; then
          continue
        fi
        block "Git argument is selected at runtime and may change a guarded operation."
      done
      break
    done
  done <<< "$GIT_COMMANDS"
}

# The scanner retains literal -c values but represents a quoted value with
# spaces as an opaque marker. Either may define an alias that rewrites it.
check_inline_alias_config() {
  local segment normalized words=() i git_index token value prior_config=0
  while IFS= read -r segment; do
    if segment_sets_git_config "$segment"; then
      prior_config=1
    fi
    normalized=$(strip_git_globals "$segment")
    is_git_command_segment "$normalized" || continue
    [ "$prior_config" = "0" ] ||
      block "Git configuration is selected at runtime and may define an alias."
    read -r -a words <<< "$segment"
    git_index=-1
    for ((i = 0; i < ${#words[@]}; i++)); do
      if is_git_binary_token "${words[$i]}" || is_opaque_word "${words[$i]}"; then
        git_index=$i
        break
      fi
    done
    [ "$git_index" -ge 0 ] || continue
    for ((i = 0; i < git_index; i++)); do
      case "${words[$i]}" in
        GIT_CONFIG_*=*|HOME=*|XDG_CONFIG_HOME=*)
          block "Git configuration source is selected at runtime." ;;
      esac
    done
    for ((i = git_index + 1; i < ${#words[@]}; i++)); do
      token="${words[$i]}"
      case "$token" in
        -c|--config-env)
          value="${words[$((i + 1))]:-}"
          i=$((i + 1)) ;;
        -c?*) value="${token#-c}" ;;
        --config-env=*) value="${token#--config-env=}" ;;
        -C|--git-dir|--work-tree|--namespace|--super-prefix)
          i=$((i + 1)); continue ;;
        -*) continue ;;
        *) break ;;
      esac
      value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
      case "$value" in
        *__git_safe_opaque_q__*|*__git_safe_opaque_u__*|alias.*|include.*|includeif.*|help.autocorrect=*)
          block "Git alias configuration cannot be inspected safely." ;;
      esac
    done
  done <<< "$segments"
}

# Git itself resolves global, conditional-include, and repository aliases.
# An alias may expand to destructive Git options or arbitrary shell code.
# Built-in commands take precedence over aliases.
check_configured_aliases() {
  local builtins line words=() i verb target key rc prior_git_config=0
  if ! builtins=$(git --list-cmds=builtins 2>/dev/null); then
    block "Git built-in command inventory is unavailable."
  fi
  if [[ "$segments" == *$'\n'* ]]; then
    prior_git_config=1
  fi
  while IFS= read -r line; do
    line=$(strip_git_globals "$line")
    if printf '%s\n' "$OPAQUE_EXEC_LINES" | grep -Fqx "$line"; then
      continue
    fi
    read -r -a words <<< "$line"
    for ((i = 0; i + 1 < ${#words[@]}; i++)); do
      is_git_binary_token "${words[$i]}" || continue
      verb="${words[$((i + 1))]}"
      [[ "$verb" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] ||
        block "Git subcommand cannot be inspected safely."
      if [ "$verb" = "config" ]; then
        # A previous segment may define an alias before this payload invokes
        # it; inspecting only the pre-tool repository snapshot is insufficient.
        prior_git_config=1
      fi
      if printf '%s\n' "$builtins" | grep -Fqx "$verb"; then
        break
      fi
      [ "$prior_git_config" = "0" ] ||
        block "Git configuration may have changed before alias inspection."
      [ "$UNRESOLVED_TARGET" = "0" ] ||
        block "Git alias target cannot be resolved safely."
      for target in "${TARGET_DIRS[@]}"; do
        for key in "alias.$verb" "alias.$verb.command"; do
          if env -u GIT_DIR -u GIT_WORK_TREE -u GIT_OBJECT_DIRECTORY \
            git -C "$target" config --get "$key" >/dev/null 2>&1; then
            block "Git alias '$verb' may execute a guarded operation."
          else
            rc=$?
            [ "$rc" -eq 1 ] || block "Git alias inspection failed."
          fi
        done
      done
      break
    done
  done <<< "$GIT_COMMANDS"
}

[ "$DYNAMIC_SHELL" = "0" ] ||
  block "Shell command is selected at runtime and cannot be inspected."
check_opaque_git_operands
check_inline_alias_config
check_configured_aliases

# --- Destructive operation checks ---

# git commit/merge/push --no-verify / -n (skips safety hooks like pre-commit, pre-push)
# See: https://github.com/anthropics/claude-code/issues/40117
if matches_git_command 'git\s+(commit|merge|push|cherry-pick|revert|am)\s.*--no-verify'; then
  is_allowed "no-verify" || block "git --no-verify skips pre-commit/pre-push hooks, bypassing safety checks like linting, tests, and secret scanning." "Remove --no-verify and let hooks run. Fix any issues they report. Add 'allow: no-verify' to .git-safe only if you understand the risk."
fi
# Also catch -n shorthand for commit (git commit -n is --no-verify)
if matches_git_command 'git\s+commit\s+(-[a-zA-Z]*n[a-zA-Z]*\b|.*\s-[a-zA-Z]*n[a-zA-Z]*\b)'; then
  # Don't false-positive on --dry-run (-n for some commands) — commit's -n IS --no-verify
  if ! contains_git_text '\-\-no-verify'; then
    is_allowed "no-verify" || block "git commit -n skips pre-commit hooks (same as --no-verify)." "Remove -n and let pre-commit hooks run. Add 'allow: no-verify' to .git-safe only if you understand the risk."
  fi
fi

# git push --force / -f (but not --force-with-lease which is safer)
if matches_git_command 'git\s+push\s.*--force(\s|$)'; then
  if contains_git_text '\-\-force-with-lease'; then
    log "ALLOW: --force-with-lease is safe"
  else
    is_allowed "push --force" || block "Force push can rewrite remote history and lose commits for other collaborators." "Use --force-with-lease instead, or add 'allow: push --force' to .git-safe."
  fi
fi
if matches_git_command 'git\s+push\s+(-[a-zA-Z]*f\b|.*\s-[a-zA-Z]*f\b)'; then
  if ! contains_git_text '\-\-force'; then
    is_allowed "push --force" || block "Force push (-f) can rewrite remote history and lose commits." "Use --force-with-lease instead, or add 'allow: push --force' to .git-safe."
  fi
fi

# git reset --hard
if matches_git_command 'git\s+reset\s.*--hard'; then
  is_allowed "reset --hard" || block "git reset --hard discards all uncommitted changes permanently." "Commit or stash changes first, or add 'allow: reset --hard' to .git-safe."
fi

# git checkout . / git checkout -- (discards working tree changes)
if matches_git_command 'git\s+checkout\s+\.\s*$'; then
  is_allowed "checkout ." || block "git checkout . discards all uncommitted changes in the working tree." "Commit or stash changes first, or add 'allow: checkout .' to .git-safe."
fi
if matches_git_command 'git\s+checkout\s+--\s'; then
  is_allowed "checkout --" || block "git checkout -- discards uncommitted changes to specified files." "Commit or stash first, or add 'allow: checkout --' to .git-safe."
fi

# git checkout <ref> -- <path> (overwrites working tree from a specific ref)
# Catches: git checkout HEAD -- src/, git checkout main -- file.js, git checkout abc123 -- .
# Does NOT catch: git checkout -- file (no ref; already caught above)
# Does NOT catch: git checkout -b branch (flag, not ref)
if matches_git_command 'git\s+checkout\s+[^-][^ ]*\s+--\s'; then
  is_allowed "checkout ref --" || block "git checkout <ref> -- <path> overwrites working tree files with the version from that ref, discarding local changes." "Commit or stash changes first, or add 'allow: checkout ref --' to .git-safe."
fi

# git restore (various destructive forms)
if matches_git_command 'git\s+restore\s'; then
  # Always block --source/-s (restoring from arbitrary ref)
  if matches_git_command '(--source|-s\s)'; then
    is_allowed "restore --source" || block "git restore --source overwrites files from a specific ref, discarding local changes." "Commit or stash first, or add 'allow: restore --source' to .git-safe."
  # Block --worktree/-W (explicitly discards working tree)
  elif matches_git_command '(--worktree|-W\b)'; then
    is_allowed "restore" || block "git restore --worktree discards uncommitted working tree changes." "Commit or stash first, or add 'allow: restore' to .git-safe."
  # Block if no --staged flag (default = working tree restore = destructive)
  elif ! matches_git_command '\-\-staged'; then
    is_allowed "restore" || block "git restore without --staged discards uncommitted working tree changes." "Use git restore --staged to unstage only, or commit/stash first. Add 'allow: restore' to .git-safe."
  fi
fi

# git clean -f (deletes untracked files)
if matches_git_command 'git\s+clean\s.*-[a-zA-Z]*f'; then
  is_allowed "clean -f" || block "git clean -f permanently deletes untracked files." "Use git clean -n (dry run) first, or add 'allow: clean -f' to .git-safe."
fi

# git branch -D (force-delete unmerged branch)
if matches_git_command 'git\s+branch\s.*-[a-zA-Z]*D'; then
  is_allowed "branch -D" || block "git branch -D force-deletes a branch even if not fully merged." "Use -d (lowercase) which only deletes merged branches, or add 'allow: branch -D' to .git-safe."
fi

# git stash drop / clear
if matches_git_command 'git\s+stash\s+drop'; then
  is_allowed "stash drop" || block "git stash drop permanently deletes stashed changes." "Add 'allow: stash drop' to .git-safe to permit this."
fi
if matches_git_command 'git\s+stash\s+clear'; then
  is_allowed "stash clear" || block "git stash clear permanently deletes all stashed changes." "Add 'allow: stash clear' to .git-safe to permit this."
fi

# git reflog expire / delete
if matches_git_command 'git\s+reflog\s+(expire|delete)'; then
  is_allowed "reflog expire" || block "git reflog expire/delete destroys recovery data." "This is almost never needed. Add 'allow: reflog expire' to .git-safe if you really need it."
fi

# git push --delete (removes remote branches/tags)
if matches_git_command 'git\s+push\s.*--delete\s'; then
  is_allowed "push --delete" || block "git push --delete permanently removes remote branches or tags." "Use 'git branch -d' for local cleanup instead, or add 'allow: push --delete' to .git-safe."
fi
# git push origin :branch (alternate delete syntax)
if matches_git_command 'git\s+push\s+\S+\s+:[^/\s]'; then
  is_allowed "push --delete" || block "git push origin :branch permanently removes a remote branch." "Use 'git branch -d' for local cleanup instead, or add 'allow: push --delete' to .git-safe."
fi

# git rebase (can rewrite history and lose commits)
# Allow: --abort, --continue, --skip, --quit (recovery operations)
# Uses ([[:space:]]|$) to catch bare "git rebase" with no args
# Checks -i/--interactive anywhere in command to catch "git rebase --autosquash -i"
if matches_git_command 'git[[:space:]]+rebase([[:space:]]|$)'; then
  if matches_git_command 'git[[:space:]]+rebase[[:space:]]+.*--(abort|continue|skip|quit)([[:space:]]|$)'; then
    log "ALLOW: rebase recovery operation"
  elif matches_git_command '(^|[[:space:]])(-i|--interactive)([[:space:]]|$)'; then
    is_allowed "rebase -i" || block "Interactive rebase can rewrite, squash, drop, or reorder commits, permanently altering history." "Use non-interactive rebase if you just need to replay commits, or add 'allow: rebase -i' to .git-safe."
  else
    is_allowed "rebase" || block "git rebase replays commits onto a new base, which can lose work during conflict resolution and rewrites history." "Prefer git merge to preserve history, or add 'allow: rebase' to .git-safe."
  fi
fi

# git merge to protected branches (main/master/production/release)
# Can't detect current branch from command alone, so check for explicit patterns
if matches_git_command 'git\s+merge\s'; then
  # Allow recovery: --abort, --continue, --quit
  if matches_git_command 'git\s+merge\s+.*--(abort|continue|quit)'; then
    log "ALLOW: merge recovery operation"
  # Block --no-verify on merge (skips hooks)
  elif matches_git_command 'git\s+merge\s.*--no-verify'; then
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
if matches_git_command 'git[[:space:]]+push[[:space:]]'; then
  _gs_seen_git=0
  _gs_seen_push=0
  _gs_seen_repo=0
  for _gs_tok in $GIT_COMMANDS; do
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
    # First non-flag argument is the repository/remote — skip it entirely.
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
if matches_git_command 'git\s+filter-(branch|repo)([[:space:]]|$)'; then
  is_allowed "filter-branch" || block "git filter-branch/filter-repo rewrites entire repository history at scale." "This is rarely needed. Add 'allow: filter-branch' to .git-safe only if you understand the impact."
fi

# git push --mirror (overwrites ALL remote refs to match local)
if matches_git_command 'git\s+push\s+.*--mirror'; then
  is_allowed "push --mirror" || block "git push --mirror overwrites all remote refs to match local, destroying remote branches and tags." "Push specific branches instead, or add 'allow: push --mirror' to .git-safe."
fi

# git update-ref -d (low-level ref deletion, bypasses branch safeguards)
if matches_git_command 'git\s+update-ref\s+.*-d\b'; then
  is_allowed "update-ref -d" || block "git update-ref -d deletes refs directly, bypassing normal branch/tag deletion safeguards." "Use git branch -d or git tag -d instead, or add 'allow: update-ref -d' to .git-safe."
fi

# git gc --prune=now (immediately garbage-collects unreachable objects)
if matches_git_command 'git\s+gc\s+.*--prune=(now|all)'; then
  is_allowed "gc --prune" || block "git gc --prune=now immediately garbage-collects unreachable objects before reflog can save them." "Use git gc without --prune=now to respect reflog expiry, or add 'allow: gc --prune' to .git-safe."
fi

# git remote remove/rm (removes remote configuration)
if matches_git_command 'git\s+remote\s+(remove|rm)\s'; then
  is_allowed "remote remove" || block "git remote remove deletes remote configuration, losing track of upstream." "Add 'allow: remote remove' to .git-safe to permit this."
fi

# git submodule deinit --force (force-removes submodule working tree)
if matches_git_command 'git\s+submodule\s+deinit\s+.*--force'; then
  is_allowed "submodule deinit" || block "git submodule deinit --force removes submodule working tree data." "Use without --force, or add 'allow: submodule deinit' to .git-safe."
fi

# git worktree remove --force (force-removes worktree with uncommitted changes)
if matches_git_command 'git\s+worktree\s+remove\s+.*--force'; then
  is_allowed "worktree remove --force" || block "git worktree remove --force removes a worktree even with uncommitted changes." "Commit or stash changes first, or add 'allow: worktree remove --force' to .git-safe."
fi

# git tag -d / --delete (deletes local tags, including release tags)
if matches_git_command 'git\s+tag([[:space:]]+.*)?([[:space:]]|^)(-d|--delete)([[:space:]]|$)'; then
  is_allowed "tag -d" || block "git tag -d deletes local tags which may include release infrastructure." "Add 'allow: tag -d' to .git-safe to permit this."
fi

# git config --system / --global (modifies git config beyond this repo)
if matches_git_command 'git\s+config\s+.*--system([[:space:]]|$)'; then
  is_allowed "config --system" || block "git config --system modifies machine-wide git configuration." "Use --local for repo-specific config, or add 'allow: config --system' to .git-safe."
elif matches_git_command 'git\s+config\s+.*--global([[:space:]]|$)'; then
  is_allowed "config --global" || block "git config --system/--global modifies git configuration beyond this repository." "Use --local for repo-specific config, or add 'allow: config --global' to .git-safe."
fi

# Force push to main/master (extra protection)
if matches_git_command 'git\s+push\s.*--force.*\s(main|master)(\s|$)'; then
  block "Force push to main/master is extremely dangerous." "This is blocked even with 'allow: push --force'. Never force push to main."
fi
if matches_git_command 'git\s+push\s.*\s(main|master)\s.*--force'; then
  block "Force push to main/master is extremely dangerous." "This is blocked even with 'allow: push --force'. Never force push to main."
fi

log "ALLOW: $COMMAND"
exit 0
