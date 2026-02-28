#!/bin/bash
# Tests for Broca — the memory system

set -euo pipefail
source "$(dirname "$0")/test_helper.sh"

echo "=== Broca Tests ==="

# --- Test: broca_remember creates a file ---
test_remember_creates_file() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    local result
    result=$(broca_remember "$tmpdir/memory" "fact" "Test Fact" "This is a test fact." "test" "broca")

    assert_file_exists "$result" "broca_remember should create a memory file"

    teardown_test_agent "$tmpdir"
}

# --- Test: broca_remember file has correct frontmatter ---
test_remember_frontmatter() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    local filepath
    filepath=$(broca_remember "$tmpdir/memory" "decision" "Use Bash" "We decided to use bash for the framework." "bash" "framework")

    local content
    content=$(cat "$filepath")

    assert_contains "$content" "type: decision" "Should contain correct type" &&
    assert_contains "$content" "confidence: 0.8" "Should have default confidence" &&
    assert_contains "$content" '"bash"' "Should contain tag 'bash'" &&
    assert_contains "$content" '"framework"' "Should contain tag 'framework'" &&
    assert_contains "$content" "# Use Bash" "Should contain title"

    teardown_test_agent "$tmpdir"
}

# --- Test: broca_remember with no tags ---
test_remember_no_tags() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    local filepath
    filepath=$(broca_remember "$tmpdir/memory" "observation" "Empty Tags" "No tags here.")

    local content
    content=$(cat "$filepath")

    assert_contains "$content" "tags: []" "Should have empty tags array"

    teardown_test_agent "$tmpdir"
}

# --- Test: broca_journal creates journal entry ---
test_journal_creates_entry() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    local filepath
    filepath=$(broca_journal "$tmpdir/memory" "Completed iteration 42. Built the tests.")

    assert_file_exists "$filepath" "Journal entry should exist" &&

    local content
    content=$(cat "$filepath")
    assert_contains "$content" "type: journal" "Should be journal type" &&
    assert_contains "$content" "Completed iteration 42" "Should contain summary"

    teardown_test_agent "$tmpdir"
}

# --- Test: broca_search finds entries by keyword ---
test_search_finds_keyword() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    broca_remember "$tmpdir/memory" "fact" "Python is great" "Python is a great programming language." "python" >/dev/null
    broca_remember "$tmpdir/memory" "fact" "Bash is useful" "Bash is useful for scripting." "bash" >/dev/null
    broca_remember "$tmpdir/memory" "fact" "Ruby is elegant" "Ruby is elegant and expressive." "ruby" >/dev/null

    local results
    results=$(broca_search "$tmpdir/memory" "Python")

    assert_contains "$results" "python-is-great" "Should find the Python entry" &&
    assert_not_contains "$results" "bash-is-useful" "Should not find the Bash entry"

    teardown_test_agent "$tmpdir"
}

# --- Test: broca_search_tag finds entries by tag ---
test_search_tag() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    broca_remember "$tmpdir/memory" "fact" "Tagged Entry" "Content here." "alpha" "beta" >/dev/null
    broca_remember "$tmpdir/memory" "fact" "Other Entry" "Other content." "gamma" >/dev/null

    local results
    results=$(broca_search_tag "$tmpdir/memory" "alpha")

    assert_contains "$results" "tagged-entry" "Should find entry with tag 'alpha'" &&
    assert_not_contains "$results" "other-entry" "Should not find entry with different tag"

    teardown_test_agent "$tmpdir"
}

# --- Test: broca_recent returns entries sorted by time ---
test_recent_returns_entries() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    broca_remember "$tmpdir/memory" "fact" "First" "First entry." >/dev/null
    sleep 1
    broca_remember "$tmpdir/memory" "fact" "Second" "Second entry." >/dev/null

    local results
    results=$(broca_recent "$tmpdir/memory" 2)

    # Most recent should be first
    local first_result
    first_result=$(echo "$results" | head -1)
    assert_contains "$first_result" "second" "Most recent entry should be first"

    teardown_test_agent "$tmpdir"
}

# --- Test: broca_state reads state file ---
test_state_reads_file() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    echo "# My State" > "$tmpdir/memory/state.md"
    echo "I am alive." >> "$tmpdir/memory/state.md"

    local result
    result=$(broca_state "$tmpdir/memory")

    assert_contains "$result" "My State" "Should read state file" &&
    assert_contains "$result" "I am alive" "Should contain state content"

    teardown_test_agent "$tmpdir"
}

# --- Test: broca_state handles missing file ---
test_state_missing_file() {
    local tmpdir
    tmpdir=$(setup_test_agent)
    rm -f "$tmpdir/memory/state.md"

    local result
    result=$(broca_state "$tmpdir/memory")

    assert_contains "$result" "No state file found" "Should indicate missing state"

    teardown_test_agent "$tmpdir"
}

# --- Run all tests ---
run_test "broca_remember creates file" test_remember_creates_file
run_test "broca_remember has correct frontmatter" test_remember_frontmatter
run_test "broca_remember with no tags" test_remember_no_tags
run_test "broca_journal creates entry" test_journal_creates_entry
run_test "broca_search finds by keyword" test_search_finds_keyword
run_test "broca_search_tag finds by tag" test_search_tag
run_test "broca_recent returns entries" test_recent_returns_entries
run_test "broca_state reads file" test_state_reads_file
run_test "broca_state handles missing file" test_state_missing_file

print_summary
