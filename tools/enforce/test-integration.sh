#!/usr/bin/env bash
# Integration test for enforce-hooks.
# Tests the hook in the same way Claude Code invokes it:
#   echo '{"tool_name":"X","tool_input":{...}}' | hook --evaluate
#
# Creates a temp directory, installs enforce-hooks, and runs tests.
# Usage: bash tools/enforce/test-integration.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap "rm -rf '$TMPDIR_TEST'" EXIT

# Set up test project
cat > "$TMPDIR_TEST/CLAUDE.md" << 'EOF'
# Test Project Rules

## Protected Files @enforced
Never modify .env, secrets/, or *.pem files.

## No Force Push @enforced
Never use git push --force or git push -f.

## No console.log @enforced
Do not use console.log in production code.

## Code Style
Use 4-space indentation.
EOF

# Install enforce-hooks
cd "$TMPDIR_TEST"
python3 "$SCRIPT_DIR/enforce-hooks.py" --install-plugin > /dev/null 2>&1

HOOK=".claude/hooks/enforce-hooks.py"
PASS=0
FAIL=0

check() {
    local desc="$1"
    local input="$2"
    local expect="$3"  # "block" or "allow"

    result=$(echo "$input" | python3 "$HOOK" --evaluate 2>/dev/null)
    decision=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('decision','error'))" 2>/dev/null || echo "error")

    if [ "$decision" = "$expect" ]; then
        echo "  PASS: $desc ($decision)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected=$expect got=$decision)"
        echo "        $result"
        FAIL=$((FAIL + 1))
    fi
}

echo "enforce-hooks integration test"
echo "=============================="

# --- File guard tests ---
echo "File guard (protected files):"
check "Block write to .env" \
    '{"tool_name":"Write","tool_input":{"file_path":"/project/.env","content":"x"}}' \
    "block"

check "Block edit of secrets/key.pem" \
    '{"tool_name":"Edit","tool_input":{"file_path":"/project/secrets/key.pem","old_string":"a","new_string":"b"}}' \
    "block"

check "Allow write to app.js" \
    '{"tool_name":"Write","tool_input":{"file_path":"/project/app.js","content":"x"}}' \
    "allow"

# --- Bash guard tests ---
echo ""
echo "Bash guard (dangerous commands):"
check "Block git push --force" \
    '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}' \
    "block"

check "Block git push -f" \
    '{"tool_name":"Bash","tool_input":{"command":"git push -f origin main"}}' \
    "block"

check "Allow git commit" \
    '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"update\""}}' \
    "allow"

check "Allow git push (without force)" \
    '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}' \
    "allow"

# --- Content guard tests ---
echo ""
echo "Content guard (banned patterns in content):"
check "Block console.log in Write" \
    '{"tool_name":"Write","tool_input":{"file_path":"/project/app.js","content":"console.log(\"debug\")"}}' \
    "block"

check "Block console.log in Edit" \
    '{"tool_name":"Edit","tool_input":{"file_path":"/project/app.js","old_string":"x","new_string":"console.log(y)"}}' \
    "block"

check "Allow clean code in Write" \
    '{"tool_name":"Write","tool_input":{"file_path":"/project/app.js","content":"return 42;"}}' \
    "allow"

# --- Non-tool calls (should always allow) ---
echo ""
echo "Non-matching tools:"
check "Allow Read tool" \
    '{"tool_name":"Read","tool_input":{"file_path":"/project/.env"}}' \
    "allow"

check "Allow Grep tool" \
    '{"tool_name":"Grep","tool_input":{"pattern":"password","path":"."}}' \
    "allow"

# --- Summary ---
echo ""
echo "=============================="
TOTAL=$((PASS + FAIL))
echo "Results: $PASS/$TOTAL passed ($FAIL failed)"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
