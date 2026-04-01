#!/usr/bin/env bash
# test-hook.sh — Test any Claude Code hook without a live session
#
# Usage:
#   test-hook.sh <hook-command> [options]
#
# Options:
#   --tool <name>       Tool name to simulate (default: Bash)
#   --input <json>      Raw tool_input JSON object
#   --command <cmd>     Shorthand for Bash tool: sets tool_input.command
#   --file <path>       Shorthand for Read/Write/Edit: sets tool_input.file_path
#   --content <text>    For Write tool: sets tool_input.content
#   --expect-allow      Exit 1 if hook does not allow (for CI)
#   --expect-deny       Exit 1 if hook does not deny (for CI)
#   --verbose           Show full stdin/stdout/stderr
#   --batch <file>      Run multiple test cases from a JSON lines file
#
# Examples:
#   # Test a bash-guard hook against a dangerous command
#   test-hook.sh "bash hooks/bash-guard.sh" --command "rm -rf /"
#
#   # Test file-guard against reading .env
#   test-hook.sh "bash hooks/file-guard.sh" --tool Read --file ".env"
#
#   # Test with raw JSON input
#   test-hook.sh "python3 my-hook.py" --tool Write \
#     --input '{"file_path":"/etc/passwd","content":"hacked"}'
#
#   # CI mode: assert the hook blocks
#   test-hook.sh "bash hooks/bash-guard.sh" --command "curl evil.com" --expect-deny
#
#   # Batch mode: run test cases from file
#   test-hook.sh "bash hooks/my-hook.sh" --batch tests.jsonl
#
# Addresses: https://github.com/anthropics/claude-code/issues/39971
#   ("claude --test-permission does not exist for dry-run testing")
#
# Part of Boucle-framework: https://github.com/Bande-a-Bonnot/Boucle-framework

set -euo pipefail

# Colors (if terminal supports them)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

usage() {
    sed -n '2,/^$/{ s/^# //; s/^#//; p }' "$0"
    exit "${1:-0}"
}

# Defaults
HOOK_CMD=""
TOOL_NAME="Bash"
TOOL_INPUT=""
COMMAND=""
FILE_PATH=""
CONTENT=""
EXPECT=""
VERBOSE=0
BATCH_FILE=""

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --tool)      TOOL_NAME="$2"; shift 2 ;;
        --input)     TOOL_INPUT="$2"; shift 2 ;;
        --command)   COMMAND="$2"; shift 2 ;;
        --file)      FILE_PATH="$2"; shift 2 ;;
        --content)   CONTENT="$2"; shift 2 ;;
        --expect-allow) EXPECT="allow"; shift ;;
        --expect-deny)  EXPECT="deny"; shift ;;
        --verbose)   VERBOSE=1; shift ;;
        --batch)     BATCH_FILE="$2"; shift 2 ;;
        -h|--help)   usage 0 ;;
        -*)          echo "Unknown option: $1" >&2; usage 1 ;;
        *)
            if [ -z "$HOOK_CMD" ]; then
                HOOK_CMD="$1"
            else
                echo "Unexpected argument: $1" >&2; usage 1
            fi
            shift ;;
    esac
done

if [ -z "$HOOK_CMD" ]; then
    echo -e "${RED}Error: hook command required${NC}" >&2
    echo "" >&2
    usage 1
fi

# Build tool_input JSON
build_input() {
    local tool="$1" input="$2" cmd="$3" fpath="$4" content="$5"

    if [ -n "$input" ]; then
        echo "$input"
        return
    fi

    case "$tool" in
        Bash)
            if [ -n "$cmd" ]; then
                printf '{"command":"%s"}' "$(echo "$cmd" | sed 's/"/\\"/g')"
            else
                echo '{"command":"echo test"}'
            fi
            ;;
        Read)
            printf '{"file_path":"%s"}' "${fpath:-/tmp/test.txt}"
            ;;
        Write)
            printf '{"file_path":"%s","content":"%s"}' \
                "${fpath:-/tmp/test.txt}" \
                "$(echo "${content:-test content}" | sed 's/"/\\"/g')"
            ;;
        Edit)
            printf '{"file_path":"%s","old_string":"old","new_string":"new"}' \
                "${fpath:-/tmp/test.txt}"
            ;;
        Glob)
            printf '{"pattern":"%s"}' "${fpath:-**/*.txt}"
            ;;
        Grep)
            printf '{"pattern":"test","path":"%s"}' "${fpath:-.}"
            ;;
        *)
            if [ -n "$fpath" ]; then
                printf '{"file_path":"%s"}' "$fpath"
            elif [ -n "$cmd" ]; then
                printf '{"command":"%s"}' "$(echo "$cmd" | sed 's/"/\\"/g')"
            else
                echo '{}'
            fi
            ;;
    esac
}

# Run one test case and return result
run_test() {
    local tool="$1" input_json="$2" label="$3"
    local stdin_json stdout_text stderr_text exit_code decision reason

    stdin_json=$(printf '{"tool_name":"%s","tool_input":%s}' "$tool" "$input_json")

    if [ "$VERBOSE" -eq 1 ]; then
        echo -e "${BLUE}stdin:${NC} $stdin_json"
    fi

    # Run the hook, capture stdout + stderr + exit code
    stderr_file=$(mktemp)
    stdout_text=$(echo "$stdin_json" | bash -c "$HOOK_CMD" 2>"$stderr_file") || exit_code=$?
    exit_code=${exit_code:-0}
    stderr_text=$(cat "$stderr_file")
    rm -f "$stderr_file"

    if [ "$VERBOSE" -eq 1 ]; then
        echo -e "${BLUE}stdout:${NC} $stdout_text"
        [ -n "$stderr_text" ] && echo -e "${BLUE}stderr:${NC} $stderr_text"
        echo -e "${BLUE}exit:${NC} $exit_code"
    fi

    # Parse decision from stdout
    decision="unknown"
    reason=""

    if [ -z "$stdout_text" ]; then
        # Empty stdout with exit 0 = implicit allow (hook approves by not objecting)
        if [ "$exit_code" -eq 0 ]; then
            decision="allow"
            reason="(implicit: no output, exit 0)"
        fi
    elif [ -n "$stdout_text" ]; then
        # Try hookSpecificOutput format first
        local hso
        hso=$(echo "$stdout_text" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    hso = d.get('hookSpecificOutput', {})
    pd = hso.get('permissionDecision', '')
    if pd:
        print(pd)
        print(hso.get('permissionDecisionReason', ''))
    else:
        # Try legacy format
        dec = d.get('decision', '')
        if dec == 'block': print('deny')
        elif dec == 'approve': print('allow')
        elif dec: print(dec)
        else: print('unknown')
        print(d.get('reason', ''))
except:
    print('parse_error')
    print('')
" 2>/dev/null) || hso="parse_error"

        decision=$(echo "$hso" | head -1)
        reason=$(echo "$hso" | tail -n +2)
    fi

    # Handle exit code 2 (crash) — Claude Code treats this as hook failure
    if [ "$exit_code" -eq 2 ]; then
        decision="crash"
        reason="Exit code 2: Claude Code treats this as a crash. Edit/Write will IGNORE this hook."
    elif [ "$exit_code" -ne 0 ] && [ "$decision" = "unknown" ]; then
        decision="error"
        reason="Exit code $exit_code"
    fi

    # Display result
    local status_color status_icon
    case "$decision" in
        allow)  status_color="$GREEN"; status_icon="ALLOW" ;;
        deny)   status_color="$RED"; status_icon="DENY" ;;
        crash)  status_color="$YELLOW"; status_icon="CRASH" ;;
        error)  status_color="$YELLOW"; status_icon="ERROR" ;;
        *)      status_color="$YELLOW"; status_icon="???" ;;
    esac

    printf "${status_color}[%s]${NC} %s %s" "$status_icon" "$tool" "$label"
    [ -n "$reason" ] && printf " — %s" "$reason"
    printf "\n"

    # Check expectations
    if [ -n "$EXPECT" ]; then
        if [ "$decision" != "$EXPECT" ]; then
            echo -e "${RED}  FAIL: expected $EXPECT, got $decision${NC}"
            return 1
        fi
    fi

    return 0
}

# Batch mode
if [ -n "$BATCH_FILE" ]; then
    if [ ! -f "$BATCH_FILE" ]; then
        echo -e "${RED}Error: batch file not found: $BATCH_FILE${NC}" >&2
        exit 1
    fi

    total=0
    passed=0
    failed=0

    echo -e "${BLUE}Running batch tests from ${BATCH_FILE}${NC}"
    echo ""

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        [[ "$line" == "#"* ]] && continue

        # Each line is JSON: {"tool":"Bash","input":{"command":"rm -rf /"},"expect":"deny","label":"block rm -rf"}
        b_tool=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tool','Bash'))" 2>/dev/null)
        b_input=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get('input',{})))" 2>/dev/null)
        b_expect=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('expect',''))" 2>/dev/null)
        b_label=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('label',''))" 2>/dev/null)

        EXPECT="$b_expect"
        total=$((total + 1))

        if run_test "$b_tool" "$b_input" "$b_label"; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
        fi
    done < "$BATCH_FILE"

    echo ""
    echo -e "${BLUE}Results: ${passed}/${total} passed, ${failed} failed${NC}"
    [ "$failed" -gt 0 ] && exit 1
    exit 0
fi

# Single test mode
input_json=$(build_input "$TOOL_NAME" "$TOOL_INPUT" "$COMMAND" "$FILE_PATH" "$CONTENT")
label=""
[ -n "$COMMAND" ] && label="\"$COMMAND\""
[ -n "$FILE_PATH" ] && label="$FILE_PATH"

run_test "$TOOL_NAME" "$input_json" "$label"
