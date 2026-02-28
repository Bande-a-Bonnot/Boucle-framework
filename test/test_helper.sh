#!/bin/bash
# Boucle test helper — minimal bash test framework
# No external dependencies required.

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
CURRENT_TEST=""

# Source the framework libraries
BOUCLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BOUCLE_DIR/lib/loop.sh"
source "$BOUCLE_DIR/lib/broca.sh"
source "$BOUCLE_DIR/lib/schedule.sh"

# Create a temporary agent directory for testing
setup_test_agent() {
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/boucle-test-XXXXXX")

    # Create minimal agent structure
    mkdir -p "$tmpdir/memory/journal" "$tmpdir/memory/knowledge"
    mkdir -p "$tmpdir/goals" "$tmpdir/gates" "$tmpdir/logs"
    mkdir -p "$tmpdir/context.d" "$tmpdir/hooks"

    cat > "$tmpdir/boucle.toml" <<'EOF'
[agent]
name = "test-agent"
description = "Test agent for CI"
version = "0.1.0"

[schedule]
interval = "1h"
method = "cron"
EOF

    cat > "$tmpdir/system-prompt.md" <<'EOF'
You are a test agent.
EOF

    # Initialize git repo for git-dependent operations
    git init "$tmpdir" >/dev/null 2>&1
    git -C "$tmpdir" -c user.name="Test" -c user.email="test@test.com" add -A >/dev/null 2>&1
    git -C "$tmpdir" -c user.name="Test" -c user.email="test@test.com" commit -m "init" >/dev/null 2>&1

    echo "$tmpdir"
}

# Clean up a test agent directory
teardown_test_agent() {
    local tmpdir="$1"
    if [ -d "$tmpdir" ] && [[ "$tmpdir" == *boucle-test-* ]]; then
        rm -rf "$tmpdir"
    fi
}

# --- Assertions ---

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Expected '$expected', got '$actual'}"

    if [ "$expected" = "$actual" ]; then
        return 0
    else
        echo -e "  ${RED}FAIL: $message${NC}" >&2
        echo -e "    expected: '$expected'" >&2
        echo -e "    actual:   '$actual'" >&2
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-Expected output to contain '$needle'}"

    if echo "$haystack" | grep -qF "$needle"; then
        return 0
    else
        echo -e "  ${RED}FAIL: $message${NC}" >&2
        echo -e "    output: '$haystack'" >&2
        echo -e "    missing: '$needle'" >&2
        return 1
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-Expected output NOT to contain '$needle'}"

    if echo "$haystack" | grep -qF "$needle"; then
        echo -e "  ${RED}FAIL: $message${NC}" >&2
        return 1
    else
        return 0
    fi
}

assert_file_exists() {
    local filepath="$1"
    local message="${2:-Expected file to exist: $filepath}"

    if [ -f "$filepath" ]; then
        return 0
    else
        echo -e "  ${RED}FAIL: $message${NC}" >&2
        return 1
    fi
}

assert_dir_exists() {
    local dirpath="$1"
    local message="${2:-Expected directory to exist: $dirpath}"

    if [ -d "$dirpath" ]; then
        return 0
    else
        echo -e "  ${RED}FAIL: $message${NC}" >&2
        return 1
    fi
}

assert_exit_code() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Expected exit code $expected, got $actual}"

    if [ "$expected" -eq "$actual" ]; then
        return 0
    else
        echo -e "  ${RED}FAIL: $message${NC}" >&2
        return 1
    fi
}

# --- Test Runner ---

run_test() {
    local test_name="$1"
    local test_fn="$2"

    CURRENT_TEST="$test_name"
    TESTS_RUN=$((TESTS_RUN + 1))

    # Run the test function
    if $test_fn; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC} $test_name"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC} $test_name"
    fi
}

print_summary() {
    echo ""
    echo "================================"
    echo -e "Tests: $TESTS_RUN | ${GREEN}Pass: $TESTS_PASSED${NC} | ${RED}Fail: $TESTS_FAILED${NC}"
    echo "================================"

    if [ "$TESTS_FAILED" -gt 0 ]; then
        return 1
    fi
    return 0
}
