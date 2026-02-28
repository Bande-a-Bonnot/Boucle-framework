#!/bin/bash
# Tests for the core loop runner

set -euo pipefail
source "$(dirname "$0")/test_helper.sh"

echo "=== Loop Runner Tests ==="

# --- Test: find_agent_root finds boucle.toml ---
test_find_agent_root() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    local result
    result=$(find_agent_root "$tmpdir")

    assert_equals "$tmpdir" "$result" "Should find agent root at tmpdir"

    teardown_test_agent "$tmpdir"
}

# --- Test: find_agent_root searches upward ---
test_find_agent_root_nested() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    # Create a nested directory
    mkdir -p "$tmpdir/deep/nested/dir"

    local result
    result=$(find_agent_root "$tmpdir/deep/nested/dir")

    assert_equals "$tmpdir" "$result" "Should find agent root from nested dir"

    teardown_test_agent "$tmpdir"
}

# --- Test: find_agent_root fails without config ---
test_find_agent_root_missing() {
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/boucle-test-XXXXXX")

    local exit_code=0
    find_agent_root "$tmpdir" >/dev/null 2>&1 || exit_code=$?

    assert_exit_code 1 "$exit_code" "Should fail when no boucle.toml exists"

    rm -rf "$tmpdir"
}

# --- Test: toml_get reads simple values ---
test_toml_get_string() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    local result
    result=$(toml_get "$tmpdir/boucle.toml" "name")

    assert_equals "test-agent" "$result" "Should read name from TOML"

    teardown_test_agent "$tmpdir"
}

# --- Test: toml_get returns default for missing key ---
test_toml_get_default() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    local result
    result=$(toml_get "$tmpdir/boucle.toml" "nonexistent" "fallback")

    assert_equals "fallback" "$result" "Should return default for missing key"

    teardown_test_agent "$tmpdir"
}

# --- Test: toml_get handles missing file ---
test_toml_get_missing_file() {
    local result
    result=$(toml_get "/nonexistent/file.toml" "key" "default-val")

    assert_equals "default-val" "$result" "Should return default for missing file"
}

# --- Test: acquire_lock and release_lock ---
test_lock_lifecycle() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    acquire_lock "$tmpdir"
    assert_file_exists "$tmpdir/.boucle.lock" "Lock file should exist after acquire"

    release_lock "$tmpdir"
    if [ -f "$tmpdir/.boucle.lock" ]; then
        echo "Lock file should be removed after release"
        teardown_test_agent "$tmpdir"
        return 1
    fi

    teardown_test_agent "$tmpdir"
}

# --- Test: acquire_lock rejects double acquire ---
test_lock_rejects_double() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    acquire_lock "$tmpdir"

    # Second acquire should fail
    local exit_code=0
    acquire_lock "$tmpdir" 2>/dev/null || exit_code=$?

    assert_exit_code 1 "$exit_code" "Double acquire should fail"

    release_lock "$tmpdir"
    teardown_test_agent "$tmpdir"
}

# --- Test: assemble_context includes goals ---
test_context_includes_goals() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    echo "# Goal 1: Build something" > "$tmpdir/goals/001.md"

    local context
    context=$(assemble_context "$tmpdir")

    assert_contains "$context" "Current Goals" "Should have goals section" &&
    assert_contains "$context" "Build something" "Should include goal content"

    teardown_test_agent "$tmpdir"
}

# --- Test: assemble_context includes memory ---
test_context_includes_memory() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    echo "# State" > "$tmpdir/memory/state.md"
    echo "I know things." >> "$tmpdir/memory/state.md"

    local context
    context=$(assemble_context "$tmpdir")

    assert_contains "$context" "Memory" "Should have memory section" &&
    assert_contains "$context" "I know things" "Should include state content"

    teardown_test_agent "$tmpdir"
}

# --- Test: assemble_context includes gates ---
test_context_includes_gates() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    echo "# Approval needed" > "$tmpdir/gates/001.md"
    echo "Please approve posting to HN" >> "$tmpdir/gates/001.md"

    local context
    context=$(assemble_context "$tmpdir")

    assert_contains "$context" "Pending Approvals" "Should have approvals section" &&
    assert_contains "$context" "approve posting to HN" "Should include gate content"

    teardown_test_agent "$tmpdir"
}

# --- Test: assemble_context handles empty agent ---
test_context_empty_agent() {
    local tmpdir
    tmpdir=$(setup_test_agent)
    rm -f "$tmpdir/memory/state.md"

    local context
    context=$(assemble_context "$tmpdir")

    assert_contains "$context" "No active goals" "Should indicate no goals" &&
    assert_contains "$context" "first loop" "Should indicate no memory" &&
    assert_contains "$context" "No pending approvals" "Should indicate no approvals" &&
    assert_contains "$context" "System Status" "Should have system status"

    teardown_test_agent "$tmpdir"
}

# --- Test: assemble_context includes system status ---
test_context_system_status() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    local context
    context=$(assemble_context "$tmpdir")

    assert_contains "$context" "System Status" "Should have system status" &&
    assert_contains "$context" "Timestamp:" "Should include timestamp" &&
    assert_contains "$context" "Git status:" "Should include git info"

    teardown_test_agent "$tmpdir"
}

# --- Test: read_system_prompt from file ---
test_read_system_prompt_file() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    echo "You are a test agent with special powers." > "$tmpdir/system-prompt.md"

    local result
    result=$(read_system_prompt "$tmpdir")

    assert_contains "$result" "special powers" "Should read custom system prompt"

    teardown_test_agent "$tmpdir"
}

# --- Test: read_system_prompt default ---
test_read_system_prompt_default() {
    local tmpdir
    tmpdir=$(setup_test_agent)
    rm -f "$tmpdir/system-prompt.md"

    local result
    result=$(read_system_prompt "$tmpdir")

    assert_contains "$result" "autonomous AI agent" "Should return default prompt"

    teardown_test_agent "$tmpdir"
}

# --- Test: read_allowed_tools from file ---
test_read_allowed_tools() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    printf "Read\nWrite\nEdit\n" > "$tmpdir/allowed-tools.txt"

    local result
    result=$(read_allowed_tools "$tmpdir")

    assert_equals "Read,Write,Edit" "$result" "Should return comma-separated tools"

    teardown_test_agent "$tmpdir"
}

# --- Test: read_allowed_tools empty when no file ---
test_read_allowed_tools_default() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    local result
    result=$(read_allowed_tools "$tmpdir")

    assert_equals "" "$result" "Should return empty when no allowed-tools.txt"

    teardown_test_agent "$tmpdir"
}

# --- Test: run_script with shebang ---
test_run_script_shebang() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    cat > "$tmpdir/test-script.sh" <<'SCRIPT'
#!/bin/bash
echo "hello from bash"
SCRIPT

    local result
    result=$(run_script "$tmpdir/test-script.sh")

    assert_equals "hello from bash" "$result" "Should run bash script via shebang"

    teardown_test_agent "$tmpdir"
}

# --- Test: run_script with env shebang ---
test_run_script_env_shebang() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    cat > "$tmpdir/test-script.py" <<'SCRIPT'
#!/usr/bin/env python3
print("hello from python")
SCRIPT

    local result
    result=$(run_script "$tmpdir/test-script.py")

    assert_equals "hello from python" "$result" "Should run python script via env shebang"

    teardown_test_agent "$tmpdir"
}

# --- Test: run_script by extension ---
test_run_script_extension() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    echo 'echo "hello from extension"' > "$tmpdir/test-script.sh"

    local result
    result=$(run_script "$tmpdir/test-script.sh")

    assert_equals "hello from extension" "$result" "Should detect interpreter from .sh extension"

    teardown_test_agent "$tmpdir"
}

# --- Test: run_script missing file ---
test_run_script_missing() {
    local exit_code=0
    run_script "/nonexistent/script.sh" 2>/dev/null || exit_code=$?

    assert_exit_code 1 "$exit_code" "Should fail for missing script"
}

# --- Test: context plugins run ---
test_context_plugins() {
    local tmpdir
    tmpdir=$(setup_test_agent)

    cat > "$tmpdir/context.d/01-test-plugin" <<'PLUGIN'
#!/bin/bash
echo "## Plugin Output"
echo ""
echo "Data from plugin."
PLUGIN

    local context
    context=$(assemble_context "$tmpdir")

    assert_contains "$context" "Plugin Output" "Should include plugin output" &&
    assert_contains "$context" "Data from plugin" "Should include plugin content"

    teardown_test_agent "$tmpdir"
}

# --- Run all tests ---
run_test "find_agent_root" test_find_agent_root
run_test "find_agent_root nested" test_find_agent_root_nested
run_test "find_agent_root missing config" test_find_agent_root_missing
run_test "toml_get reads string values" test_toml_get_string
run_test "toml_get returns default for missing key" test_toml_get_default
run_test "toml_get handles missing file" test_toml_get_missing_file
run_test "lock acquire and release" test_lock_lifecycle
run_test "lock rejects double acquire" test_lock_rejects_double
run_test "context includes goals" test_context_includes_goals
run_test "context includes memory" test_context_includes_memory
run_test "context includes gates" test_context_includes_gates
run_test "context handles empty agent" test_context_empty_agent
run_test "context includes system status" test_context_system_status
run_test "read_system_prompt from file" test_read_system_prompt_file
run_test "read_system_prompt default" test_read_system_prompt_default
run_test "read_allowed_tools from file" test_read_allowed_tools
run_test "read_allowed_tools default" test_read_allowed_tools_default
run_test "run_script with shebang" test_run_script_shebang
run_test "run_script with env shebang" test_run_script_env_shebang
run_test "run_script by extension" test_run_script_extension
run_test "run_script missing file" test_run_script_missing
run_test "context plugins run" test_context_plugins

print_summary
