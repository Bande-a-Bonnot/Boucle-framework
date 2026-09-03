#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== test-hook contract =="

help_output=$(bash "$REPO_ROOT/tools/test-hook.sh" --help)
case "$help_output" in
    *"test-hook.sh <hook-command> [options]"* ) ;;
    *)
        printf 'test-hook help output is missing usage text.\nOutput:\n%s\n' "$help_output" >&2
        exit 1
        ;;
esac
case "$help_output" in
    *"bash tools/bash-guard/hook.sh"* ) ;;
    *)
        printf 'test-hook help output should use copy-pasteable repository hook paths.\nOutput:\n%s\n' "$help_output" >&2
        exit 1
        ;;
esac
case "$help_output" in
    *"tools/test-hook-bash-guard-examples.jsonl"* ) ;;
    *)
        printf 'test-hook help output should name the copy-pasteable bash-guard batch fixture.\nOutput:\n%s\n' "$help_output" >&2
        exit 1
        ;;
esac

tools_readme=$(cat "$REPO_ROOT/tools/README.md")
llms_summary=$(cat "$REPO_ROOT/docs/llms.txt")
file_guard_example='bash tools/test-hook.sh "bash tools/file-guard/hook.sh" --tool Write --file ".env" --content "SECRET=x" --expect-deny'
case "$tools_readme" in
    *"| [test-hook](test-hook.sh) | Dry-runs a hook with synthetic \`PreToolUse\` payloads | CLI tool |"* ) ;;
    *)
        printf 'tools README should list test-hook in the available tools table.\n' >&2
        exit 1
        ;;
esac
case "$tools_readme" in
    *"bash tools/test-hook.sh \"bash tools/bash-guard/hook.sh\" --command \"rm -rf /\""* ) ;;
    *)
        printf 'tools README should use copy-pasteable repository hook paths for bash-guard.\n' >&2
        exit 1
        ;;
esac
case "$tools_readme" in
    *"$file_guard_example"* ) ;;
    *)
        printf 'tools README should show a write-protect file-guard example with an expected deny.\n' >&2
        exit 1
        ;;
esac
case "$tools_readme" in
    *"tools/test-hook-bash-guard-examples.jsonl"* ) ;;
    *)
        printf 'tools README should name the copy-pasteable bash-guard batch fixture.\n' >&2
        exit 1
        ;;
esac
case "$tools_readme" in
    *"python3 tools/test-hook-verify.py"* ) ;;
    *)
        printf 'tools README should expose the built-in test-hook verifier command.\n' >&2
        exit 1
        ;;
esac
case "$llms_summary" in
    *"bash tools/test-hook.sh \"bash tools/bash-guard/hook.sh\" --command \"rm -rf /\" --expect-deny"* ) ;;
    *)
        printf 'llms.txt should expose the copy-pasteable bash-guard test-hook command.\n' >&2
        exit 1
        ;;
esac
case "$llms_summary" in
    *"test-hook.sh"*PreToolUse*"does not prove Claude Code loaded those hooks from settings"* ) ;;
    *)
        printf 'llms.txt should document the test-hook dry-run boundary.\n' >&2
        exit 1
        ;;
esac
case "$llms_summary" in
    *"python3 tools/test-hook-verify.py"* ) ;;
    *)
        printf 'llms.txt should expose the built-in test-hook verifier command.\n' >&2
        exit 1
        ;;
esac

verify_header=$(sed -n '1,8p' "$REPO_ROOT/tools/test-hook-verify.py")
case "$verify_header" in
    *"python3 tools/test-hook-verify.py"* ) ;;
    *)
        printf 'test-hook verifier header should name its real command.\nHeader:\n%s\n' "$verify_header" >&2
        exit 1
        ;;
esac

deny_output=$(
    cd "$REPO_ROOT"
    bash tools/test-hook.sh "bash tools/bash-guard/hook.sh" --command "rm -rf /" --expect-deny
)
case "$deny_output" in
    *"[DENY] Bash \"rm -rf /\""* ) ;;
    *)
        printf 'test-hook should classify bash-guard stderr+exit-2 blocks as DENY.\nOutput:\n%s\n' "$deny_output" >&2
        exit 1
        ;;
esac

batch_output=$(
    cd "$REPO_ROOT"
    bash tools/test-hook.sh "bash tools/bash-guard/hook.sh" --batch tools/test-hook-bash-guard-examples.jsonl
)
case "$batch_output" in
    *"Results: 4/4 passed"* ) ;;
    *)
        printf 'test-hook bash-guard batch examples should all pass.\nOutput:\n%s\n' "$batch_output" >&2
        exit 1
        ;;
esac

newline_output=$(
    cd "$REPO_ROOT"
    bash tools/test-hook.sh "python3 -c 'import json,sys; json.load(sys.stdin)'" --command $'echo first\necho second' --expect-allow
)
case "$newline_output" in
    *"[ALLOW] Bash"* ) ;;
    *)
        printf 'test-hook should JSON-escape multi-line Bash commands.\nOutput:\n%s\n' "$newline_output" >&2
        exit 1
        ;;
esac

quote_path_output=$(
    cd "$REPO_ROOT"
    bash tools/test-hook.sh "python3 -c 'import json,sys; json.load(sys.stdin)'" --tool Write --file 'path with "quote".txt' --content $'line1\nline2' --expect-allow
)
case "$quote_path_output" in
    *"[ALLOW] Write path with \"quote\".txt"* ) ;;
    *)
        printf 'test-hook should JSON-escape quoted paths and multi-line content.\nOutput:\n%s\n' "$quote_path_output" >&2
        exit 1
        ;;
esac

echo "test-hook contract OK"
