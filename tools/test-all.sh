#!/bin/bash
# Run all hook test suites
# Usage: bash tools/test-all.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_SUITES=""

echo "=== Environment ==="
echo "OS: $(uname -s) $(uname -r)"
echo "Bash: ${BASH_VERSION:-unknown}"
echo "jq: $(jq --version 2>/dev/null || echo 'not found')"
echo "python3: $(python3 --version 2>/dev/null || echo 'not found')"
echo "shasum: $(which shasum 2>/dev/null || echo 'not found')"
echo "sha256sum: $(which sha256sum 2>/dev/null || echo 'not found')"
echo "grep: $(grep --version 2>/dev/null | head -1 || echo 'unknown')"

run_suite() {
  local name="$1"
  local script="$2"
  echo ""
  echo "========================================"
  echo "  $name"
  echo "========================================"

  if bash "$script"; then
    echo "  -> $name: OK"
  else
    echo "  -> $name: FAILED"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    FAILED_SUITES="$FAILED_SUITES $name"
    return 1
  fi
  TOTAL_PASS=$((TOTAL_PASS + 1))
}

# Core hook test suites
run_suite "read-once"    "$SCRIPT_DIR/read-once/test.sh"    || true
run_suite "file-guard"   "$SCRIPT_DIR/file-guard/test.sh"   || true
run_suite "git-safe"     "$SCRIPT_DIR/git-safe/test.sh"     || true
run_suite "bash-guard"   "$SCRIPT_DIR/bash-guard/test.sh"   || true
run_suite "branch-guard"   "$SCRIPT_DIR/branch-guard/test.sh"   || true
run_suite "worktree-guard" "$SCRIPT_DIR/worktree-guard/test.sh" || true
run_suite "session-log"    "$SCRIPT_DIR/session-log/test.sh"    || true
run_suite "safety-check" "$SCRIPT_DIR/safety-check/test.sh" || true
run_suite "enforce"      "$SCRIPT_DIR/enforce/test.sh"      || true

# Additional test suites
run_suite "file-guard-init"   "$SCRIPT_DIR/file-guard/test-init.sh"       || true
run_suite "session-report"    "$SCRIPT_DIR/session-log/test-report.sh"    || true
run_suite "unified-installer" "$SCRIPT_DIR/test-install.sh"               || true
run_suite "format-regression" "$SCRIPT_DIR/test-format.sh"                || true

echo ""
echo "========================================"
echo "  SUMMARY"
echo "========================================"
echo "  Suites passed: $TOTAL_PASS"
echo "  Suites failed: $TOTAL_FAIL"
if [ -n "$FAILED_SUITES" ]; then
  echo "  Failed:$FAILED_SUITES"
fi
echo "========================================"

[ "$TOTAL_FAIL" -eq 0 ] || exit 1
