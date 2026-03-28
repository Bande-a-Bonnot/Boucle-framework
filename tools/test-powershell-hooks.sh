#!/bin/bash
# Test PowerShell hook scripts by verifying their JSON contract
# These tests validate the PowerShell hooks produce correct output
# by checking the script structure and testing with pwsh if available.
#
# Can run on any platform. Uses pwsh if installed, otherwise structural checks only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0
SKIP=0

pass() { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
skip() { echo "  [SKIP] $1"; SKIP=$((SKIP+1)); }

echo "=== PowerShell Hook Tests ==="
echo ""

# Check if pwsh is available
PWSH=""
if command -v pwsh &>/dev/null; then
    PWSH="pwsh"
    echo "pwsh found: $(pwsh --version)"
elif command -v powershell &>/dev/null; then
    PWSH="powershell"
    echo "powershell found"
else
    echo "No PowerShell available - running structural tests only"
fi

# --- Structural tests (always run) ---

echo ""
echo "--- Structural Tests ---"

# file-guard.ps1
if [ -f "$SCRIPT_DIR/file-guard/hook.ps1" ]; then
    pass "file-guard/hook.ps1 exists"

    # Check required elements
    if grep -q 'ConvertFrom-Json' "$SCRIPT_DIR/file-guard/hook.ps1"; then
        pass "file-guard: uses ConvertFrom-Json (no jq dependency)"
    else
        fail "file-guard: missing ConvertFrom-Json"
    fi

    if grep -q 'ConvertTo-Json' "$SCRIPT_DIR/file-guard/hook.ps1"; then
        pass "file-guard: uses ConvertTo-Json for output"
    else
        fail "file-guard: missing ConvertTo-Json"
    fi

    if grep -q 'FILE_GUARD_DISABLED' "$SCRIPT_DIR/file-guard/hook.ps1"; then
        pass "file-guard: supports FILE_GUARD_DISABLED env var"
    else
        fail "file-guard: missing FILE_GUARD_DISABLED support"
    fi

    if grep -q 'FILE_GUARD_CONFIG' "$SCRIPT_DIR/file-guard/hook.ps1"; then
        pass "file-guard: supports FILE_GUARD_CONFIG env var"
    else
        fail "file-guard: missing FILE_GUARD_CONFIG support"
    fi

    if grep -q 'FILE_GUARD_LOG' "$SCRIPT_DIR/file-guard/hook.ps1"; then
        pass "file-guard: supports FILE_GUARD_LOG env var"
    else
        fail "file-guard: missing FILE_GUARD_LOG support"
    fi

    if grep -q '\[deny\]' "$SCRIPT_DIR/file-guard/hook.ps1"; then
        pass "file-guard: handles [deny] section"
    else
        fail "file-guard: missing [deny] section handling"
    fi

    for tool in Write Edit Read Grep Glob Bash; do
        if grep -q "'$tool'" "$SCRIPT_DIR/file-guard/hook.ps1"; then
            pass "file-guard: handles $tool tool"
        else
            fail "file-guard: missing $tool tool handling"
        fi
    done

    if grep -q 'relative path' "$SCRIPT_DIR/file-guard/hook.ps1"; then
        pass "file-guard: rejects relative paths"
    else
        fail "file-guard: missing relative path rejection"
    fi

    if grep -q 'Normalize-TargetPath' "$SCRIPT_DIR/file-guard/hook.ps1"; then
        pass "file-guard: has path normalization"
    else
        fail "file-guard: missing path normalization"
    fi
else
    fail "file-guard/hook.ps1 does not exist"
fi

echo ""

# git-safe.ps1
if [ -f "$SCRIPT_DIR/git-safe/hook.ps1" ]; then
    pass "git-safe/hook.ps1 exists"

    if grep -q 'ConvertFrom-Json' "$SCRIPT_DIR/git-safe/hook.ps1"; then
        pass "git-safe: uses ConvertFrom-Json"
    else
        fail "git-safe: missing ConvertFrom-Json"
    fi

    if grep -q 'GIT_SAFE_DISABLED' "$SCRIPT_DIR/git-safe/hook.ps1"; then
        pass "git-safe: supports GIT_SAFE_DISABLED env var"
    else
        fail "git-safe: missing GIT_SAFE_DISABLED support"
    fi

    # Check all destructive operations are covered
    for pattern in "push.*--force" "reset.*--hard" "checkout.*\\\." "checkout.*--" "restore" "clean.*-f" "branch.*-D" "stash.*drop" "stash.*clear" "reflog.*(expire|delete)" "push.*--delete" "force-with-lease"; do
        if grep -qE "$pattern" "$SCRIPT_DIR/git-safe/hook.ps1"; then
            pass "git-safe: checks $pattern"
        else
            fail "git-safe: missing check for $pattern"
        fi
    done

    if grep -q '.git-safe' "$SCRIPT_DIR/git-safe/hook.ps1"; then
        pass "git-safe: supports .git-safe config"
    else
        fail "git-safe: missing .git-safe config support"
    fi

    if grep -q 'main.*master' "$SCRIPT_DIR/git-safe/hook.ps1"; then
        pass "git-safe: extra protection for main/master"
    else
        fail "git-safe: missing main/master extra protection"
    fi
else
    fail "git-safe/hook.ps1 does not exist"
fi

echo ""

# branch-guard.ps1
if [ -f "$SCRIPT_DIR/branch-guard/hook.ps1" ]; then
    pass "branch-guard/hook.ps1 exists"

    if grep -q 'ConvertFrom-Json' "$SCRIPT_DIR/branch-guard/hook.ps1"; then
        pass "branch-guard: uses ConvertFrom-Json"
    else
        fail "branch-guard: missing ConvertFrom-Json"
    fi

    if grep -q 'BRANCH_GUARD_DISABLED' "$SCRIPT_DIR/branch-guard/hook.ps1"; then
        pass "branch-guard: supports BRANCH_GUARD_DISABLED env var"
    else
        fail "branch-guard: missing BRANCH_GUARD_DISABLED support"
    fi

    if grep -q 'BRANCH_GUARD_PROTECTED' "$SCRIPT_DIR/branch-guard/hook.ps1"; then
        pass "branch-guard: supports BRANCH_GUARD_PROTECTED env var"
    else
        fail "branch-guard: missing BRANCH_GUARD_PROTECTED support"
    fi

    if grep -q 'git rev-parse' "$SCRIPT_DIR/branch-guard/hook.ps1"; then
        pass "branch-guard: gets current branch"
    else
        fail "branch-guard: missing branch detection"
    fi

    if grep -q 'amend' "$SCRIPT_DIR/branch-guard/hook.ps1"; then
        pass "branch-guard: skips --amend"
    else
        fail "branch-guard: missing --amend skip"
    fi

    for branch in main master production release; do
        if grep -q "$branch" "$SCRIPT_DIR/branch-guard/hook.ps1"; then
            pass "branch-guard: default protects $branch"
        else
            fail "branch-guard: missing default protection for $branch"
        fi
    done
else
    fail "branch-guard/hook.ps1 does not exist"
fi

# --- Functional tests (only with pwsh) ---

if [ -n "$PWSH" ]; then
    echo ""
    echo "--- Functional Tests (pwsh) ---"

    TMPDIR=$(mktemp -d)
    trap "rm -rf $TMPDIR" EXIT

    # Helper to run a PS1 hook with JSON input
    run_hook() {
        local hook="$1"
        local json="$2"
        echo "$json" | $PWSH -File "$hook" 2>/dev/null || true
    }

    # --- file-guard functional tests ---
    echo ""
    echo "  file-guard:"

    # Create a temp .file-guard config
    cat > "$TMPDIR/.file-guard" << 'CONF'
# Write protected
.env
secrets/*.key

# Deny all access
[deny]
codegen/
generated/
CONF

    # Test: Write to .env should be blocked
    RESULT=$(cd "$TMPDIR" && run_hook "$SCRIPT_DIR/file-guard/hook.ps1" '{"tool_name":"Write","tool_input":{"file_path":"/tmp/test/.env","content":"x"}}')
    if echo "$RESULT" | grep -q '"block"'; then
        pass "file-guard: blocks Write to .env"
    else
        fail "file-guard: did not block Write to .env (got: $RESULT)"
    fi

    # Test: Read .env should be allowed (write-protect only)
    RESULT=$(cd "$TMPDIR" && run_hook "$SCRIPT_DIR/file-guard/hook.ps1" '{"tool_name":"Read","tool_input":{"file_path":"/tmp/test/.env"}}')
    if [ -z "$RESULT" ] || echo "$RESULT" | grep -qv '"block"'; then
        pass "file-guard: allows Read of write-protected .env"
    else
        fail "file-guard: incorrectly blocked Read of .env (got: $RESULT)"
    fi

    # Test: Read denied path should be blocked
    RESULT=$(cd "$TMPDIR" && run_hook "$SCRIPT_DIR/file-guard/hook.ps1" '{"tool_name":"Read","tool_input":{"file_path":"codegen/output.js"}}')
    if echo "$RESULT" | grep -q '"block"'; then
        pass "file-guard: blocks Read of [deny] path"
    else
        fail "file-guard: did not block Read of denied path (got: $RESULT)"
    fi

    # Test: Grep on denied path should be blocked
    RESULT=$(cd "$TMPDIR" && run_hook "$SCRIPT_DIR/file-guard/hook.ps1" '{"tool_name":"Grep","tool_input":{"pattern":"foo","path":"codegen/"}}')
    if echo "$RESULT" | grep -q '"block"'; then
        pass "file-guard: blocks Grep on [deny] path"
    else
        fail "file-guard: did not block Grep on denied path (got: $RESULT)"
    fi

    # Test: Non-protected file should be allowed
    RESULT=$(cd "$TMPDIR" && run_hook "$SCRIPT_DIR/file-guard/hook.ps1" '{"tool_name":"Write","tool_input":{"file_path":"/tmp/test/README.md","content":"x"}}')
    if [ -z "$RESULT" ] || echo "$RESULT" | grep -qv '"block"'; then
        pass "file-guard: allows Write to non-protected file"
    else
        fail "file-guard: incorrectly blocked Write to README.md (got: $RESULT)"
    fi

    # Test: Relative path rejection
    RESULT=$(cd "$TMPDIR" && run_hook "$SCRIPT_DIR/file-guard/hook.ps1" '{"tool_name":"Write","tool_input":{"file_path":"relative/path.txt","content":"x"}}')
    if echo "$RESULT" | grep -q '"block"'; then
        pass "file-guard: blocks relative paths in Write"
    else
        fail "file-guard: did not block relative path (got: $RESULT)"
    fi

    # Test: Bash command referencing denied path
    RESULT=$(cd "$TMPDIR" && run_hook "$SCRIPT_DIR/file-guard/hook.ps1" '{"tool_name":"Bash","tool_input":{"command":"cat codegen/output.js"}}')
    if echo "$RESULT" | grep -q '"block"'; then
        pass "file-guard: blocks Bash referencing [deny] path"
    else
        fail "file-guard: did not block Bash with denied path (got: $RESULT)"
    fi

    # Test: Disabled via env var
    RESULT=$(cd "$TMPDIR" && FILE_GUARD_DISABLED=1 run_hook "$SCRIPT_DIR/file-guard/hook.ps1" '{"tool_name":"Write","tool_input":{"file_path":"/tmp/.env","content":"x"}}')
    if [ -z "$RESULT" ] || echo "$RESULT" | grep -qv '"block"'; then
        pass "file-guard: respects FILE_GUARD_DISABLED=1"
    else
        fail "file-guard: did not respect FILE_GUARD_DISABLED (got: $RESULT)"
    fi

    # --- git-safe functional tests ---
    echo ""
    echo "  git-safe:"

    # Test: git push --force should be blocked
    RESULT=$(run_hook "$SCRIPT_DIR/git-safe/hook.ps1" '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}')
    if echo "$RESULT" | grep -q '"block"'; then
        pass "git-safe: blocks git push --force"
    else
        fail "git-safe: did not block force push (got: $RESULT)"
    fi

    # Test: git push --force-with-lease should be allowed
    RESULT=$(run_hook "$SCRIPT_DIR/git-safe/hook.ps1" '{"tool_name":"Bash","tool_input":{"command":"git push --force-with-lease origin feature"}}')
    if [ -z "$RESULT" ] || echo "$RESULT" | grep -qv '"block"'; then
        pass "git-safe: allows --force-with-lease"
    else
        fail "git-safe: blocked --force-with-lease (got: $RESULT)"
    fi

    # Test: git reset --hard should be blocked
    RESULT=$(run_hook "$SCRIPT_DIR/git-safe/hook.ps1" '{"tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD~1"}}')
    if echo "$RESULT" | grep -q '"block"'; then
        pass "git-safe: blocks git reset --hard"
    else
        fail "git-safe: did not block reset --hard (got: $RESULT)"
    fi

    # Test: git clean -f should be blocked
    RESULT=$(run_hook "$SCRIPT_DIR/git-safe/hook.ps1" '{"tool_name":"Bash","tool_input":{"command":"git clean -fd"}}')
    if echo "$RESULT" | grep -q '"block"'; then
        pass "git-safe: blocks git clean -f"
    else
        fail "git-safe: did not block clean -f (got: $RESULT)"
    fi

    # Test: git branch -D should be blocked
    RESULT=$(run_hook "$SCRIPT_DIR/git-safe/hook.ps1" '{"tool_name":"Bash","tool_input":{"command":"git branch -D old-feature"}}')
    if echo "$RESULT" | grep -q '"block"'; then
        pass "git-safe: blocks git branch -D"
    else
        fail "git-safe: did not block branch -D (got: $RESULT)"
    fi

    # Test: git stash drop should be blocked
    RESULT=$(run_hook "$SCRIPT_DIR/git-safe/hook.ps1" '{"tool_name":"Bash","tool_input":{"command":"git stash drop"}}')
    if echo "$RESULT" | grep -q '"block"'; then
        pass "git-safe: blocks git stash drop"
    else
        fail "git-safe: did not block stash drop (got: $RESULT)"
    fi

    # Test: Non-git command should pass
    RESULT=$(run_hook "$SCRIPT_DIR/git-safe/hook.ps1" '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}')
    if [ -z "$RESULT" ] || echo "$RESULT" | grep -qv '"block"'; then
        pass "git-safe: allows non-git commands"
    else
        fail "git-safe: blocked non-git command (got: $RESULT)"
    fi

    # Test: git restore --staged should be allowed
    RESULT=$(run_hook "$SCRIPT_DIR/git-safe/hook.ps1" '{"tool_name":"Bash","tool_input":{"command":"git restore --staged file.txt"}}')
    if [ -z "$RESULT" ] || echo "$RESULT" | grep -qv '"block"'; then
        pass "git-safe: allows git restore --staged"
    else
        fail "git-safe: blocked restore --staged (got: $RESULT)"
    fi

    # Test: git restore without --staged should be blocked
    RESULT=$(run_hook "$SCRIPT_DIR/git-safe/hook.ps1" '{"tool_name":"Bash","tool_input":{"command":"git restore file.txt"}}')
    if echo "$RESULT" | grep -q '"block"'; then
        pass "git-safe: blocks git restore without --staged"
    else
        fail "git-safe: did not block restore without --staged (got: $RESULT)"
    fi

    # Test: Non-Bash tool should pass
    RESULT=$(run_hook "$SCRIPT_DIR/git-safe/hook.ps1" '{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.txt","content":"x"}}')
    if [ -z "$RESULT" ] || echo "$RESULT" | grep -qv '"block"'; then
        pass "git-safe: ignores non-Bash tools"
    else
        fail "git-safe: blocked non-Bash tool (got: $RESULT)"
    fi

    # --- branch-guard functional tests ---
    echo ""
    echo "  branch-guard:"

    # Test: Non-Bash tool should pass
    RESULT=$(run_hook "$SCRIPT_DIR/branch-guard/hook.ps1" '{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.txt","content":"x"}}')
    if [ -z "$RESULT" ] || echo "$RESULT" | grep -qv '"block"'; then
        pass "branch-guard: ignores non-Bash tools"
    else
        fail "branch-guard: blocked non-Bash tool (got: $RESULT)"
    fi

    # Test: Non-commit command should pass
    RESULT=$(run_hook "$SCRIPT_DIR/branch-guard/hook.ps1" '{"tool_name":"Bash","tool_input":{"command":"git status"}}')
    if [ -z "$RESULT" ] || echo "$RESULT" | grep -qv '"block"'; then
        pass "branch-guard: allows non-commit commands"
    else
        fail "branch-guard: blocked non-commit (got: $RESULT)"
    fi

    # Test: --amend should pass
    RESULT=$(run_hook "$SCRIPT_DIR/branch-guard/hook.ps1" '{"tool_name":"Bash","tool_input":{"command":"git commit --amend"}}')
    if [ -z "$RESULT" ] || echo "$RESULT" | grep -qv '"block"'; then
        pass "branch-guard: allows --amend"
    else
        fail "branch-guard: blocked --amend (got: $RESULT)"
    fi

else
    echo ""
    echo "--- Functional Tests ---"
    skip "pwsh not available - skipping functional tests"
fi

echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "  Skipped: $SKIP"
echo ""

if [ $FAIL -gt 0 ]; then
    echo "SOME TESTS FAILED"
    exit 1
fi

echo "ALL TESTS PASSED"
exit 0
