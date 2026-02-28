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

# --- Test: broca_recall returns ranked results ---
test_recall_ranked() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    broca_remember "$tmpdir/memory" "fact" "Python packaging" "Python uses pyproject.toml for packaging." "python" "packaging" >/dev/null
    broca_remember "$tmpdir/memory" "fact" "Bash scripting" "Bash is good for scripting." "bash" >/dev/null
    broca_remember "$tmpdir/memory" "fact" "Python testing" "Python uses pytest for testing." "python" "testing" >/dev/null

    local results
    results=$(broca_recall "$tmpdir/memory" "python")

    # Should find python entries but not bash
    assert_contains "$results" "python" "Should find python entries" &&
    assert_not_contains "$results" "bash-scripting" "Should not include bash entry"

    teardown_test_agent "$tmpdir"
}

# --- Test: broca_recall returns nothing for no match ---
test_recall_no_match() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    broca_remember "$tmpdir/memory" "fact" "Bash scripting" "Bash is useful." "bash" >/dev/null

    local results
    results=$(broca_recall "$tmpdir/memory" "nonexistent")

    assert_equals "" "$results" "Should return empty for no matches"

    teardown_test_agent "$tmpdir"
}

# --- Test: broca_recall handles empty knowledge dir ---
test_recall_empty() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    local results
    results=$(broca_recall "$tmpdir/memory" "anything")

    assert_equals "" "$results" "Should return empty for empty knowledge"

    teardown_test_agent "$tmpdir"
}

# --- Test: broca_show displays content without frontmatter ---
test_show_strips_frontmatter() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    local filepath
    filepath=$(broca_remember "$tmpdir/memory" "fact" "Visible Content" "This should be visible.")

    local result
    result=$(broca_show "$filepath")

    assert_contains "$result" "Visible Content" "Should show title" &&
    assert_contains "$result" "This should be visible" "Should show content" &&
    assert_not_contains "$result" "type: fact" "Should not show frontmatter"

    teardown_test_agent "$tmpdir"
}

# --- Test: broca_update_confidence changes confidence ---
test_update_confidence() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    local filepath
    filepath=$(broca_remember "$tmpdir/memory" "fact" "Changeable" "Content." "test")

    broca_update_confidence "$filepath" "0.95" >/dev/null

    local content
    content=$(cat "$filepath")

    assert_contains "$content" "confidence: 0.95" "Should have updated confidence" &&
    assert_not_contains "$content" "confidence: 0.8" "Should not have old confidence"

    teardown_test_agent "$tmpdir"
}

# --- Test: broca_index generates index file ---
test_index_generation() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    broca_remember "$tmpdir/memory" "fact" "Index Test" "Testing the index." "test" >/dev/null
    broca_remember "$tmpdir/memory" "decision" "Another Entry" "More content." "test" >/dev/null

    local index_path
    index_path=$(broca_index "$tmpdir/memory")

    assert_file_exists "$index_path" "Index file should exist" &&

    local content
    content=$(cat "$index_path")
    assert_contains "$content" "Index Test" "Should contain first entry title" &&
    assert_contains "$content" "Another Entry" "Should contain second entry title" &&
    assert_contains "$content" "entries:" "Should have entries key"

    teardown_test_agent "$tmpdir"
}

# --- Test: broca_stats shows distribution ---
test_stats_output() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    broca_remember "$tmpdir/memory" "fact" "Stat Test 1" "Content." "tag1" >/dev/null
    broca_remember "$tmpdir/memory" "decision" "Stat Test 2" "Content." "tag2" >/dev/null
    broca_journal "$tmpdir/memory" "Test journal entry" >/dev/null

    local result
    result=$(broca_stats "$tmpdir/memory")

    assert_contains "$result" "Knowledge entries: 2" "Should show 2 knowledge entries" &&
    assert_contains "$result" "Journal entries: 1" "Should show 1 journal entry" &&
    assert_contains "$result" "By type:" "Should show type breakdown"

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
run_test "broca_recall returns ranked results" test_recall_ranked
run_test "broca_recall returns nothing for no match" test_recall_no_match
run_test "broca_recall handles empty knowledge dir" test_recall_empty
run_test "broca_show strips frontmatter" test_show_strips_frontmatter
run_test "broca_update_confidence changes value" test_update_confidence
run_test "broca_index generates index file" test_index_generation
run_test "broca_stats shows distribution" test_stats_output

print_summary
