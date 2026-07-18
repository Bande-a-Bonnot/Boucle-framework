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

echo "test-hook contract OK"
