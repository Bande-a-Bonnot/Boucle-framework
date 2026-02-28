#!/bin/bash
# Tests for the scheduling utilities

set -euo pipefail
source "$(dirname "$0")/test_helper.sh"

echo "=== Schedule Tests ==="

# --- Test: interval parsing seconds ---
test_interval_seconds() {
    local result
    result=$(interval_to_seconds "30s")
    assert_equals "30" "$result" "30s should be 30 seconds"
}

# --- Test: interval parsing minutes ---
test_interval_minutes() {
    local result
    result=$(interval_to_seconds "5m")
    assert_equals "300" "$result" "5m should be 300 seconds"
}

# --- Test: interval parsing hours ---
test_interval_hours() {
    local result
    result=$(interval_to_seconds "1h")
    assert_equals "3600" "$result" "1h should be 3600 seconds"
}

# --- Test: interval parsing days ---
test_interval_days() {
    local result
    result=$(interval_to_seconds "2d")
    assert_equals "172800" "$result" "2d should be 172800 seconds"
}

# --- Test: interval parsing invalid ---
test_interval_invalid() {
    local exit_code=0
    interval_to_seconds "5x" 2>/dev/null || exit_code=$?
    assert_exit_code 1 "$exit_code" "Invalid unit should fail"
}

# --- Run all tests ---
run_test "interval_to_seconds: seconds" test_interval_seconds
run_test "interval_to_seconds: minutes" test_interval_minutes
run_test "interval_to_seconds: hours" test_interval_hours
run_test "interval_to_seconds: days" test_interval_days
run_test "interval_to_seconds: invalid" test_interval_invalid

print_summary
