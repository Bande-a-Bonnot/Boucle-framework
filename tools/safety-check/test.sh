#!/usr/bin/env bash
# Tests for Claude Code Safety Check
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/check.sh"
PASS=0
FAIL=0
TOTAL=0

assert() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$actual" | grep -q "$expected"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $name"
        echo "  Expected to find: $expected"
        echo "  In output: $(echo "$actual" | head -3)"
    fi
}

assert_not() {
    local name="$1"
    local not_expected="$2"
    local actual="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$actual" | grep -q "$not_expected"; then
        FAIL=$((FAIL + 1))
        echo "FAIL: $name"
        echo "  Should NOT contain: $not_expected"
    else
        PASS=$((PASS + 1))
    fi
}

# === Test 1: Script runs without errors ===
OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert "script runs" "Safety Score:" "$OUTPUT"

# === Test 2: Shows all sections ===
assert "has setup section" "Setup" "$OUTPUT"
assert "has destructive section" "Destructive Command Protection" "$OUTPUT"
assert "has file section" "File Protection" "$OUTPUT"
assert "has observability section" "Observability" "$OUTPUT"
assert "has efficiency section" "Efficiency" "$OUTPUT"
assert "has settings section" "Built-in Settings" "$OUTPUT"

# === Test 3: Shows check results ===
assert "has claude installed check" "Claude Code installed" "$OUTPUT"
assert "has bash-guard check" "bash-guard" "$OUTPUT"
assert "has git-safe check" "git-safe" "$OUTPUT"
assert "has file-guard check" "file-guard" "$OUTPUT"
assert "has branch-guard check" "branch-guard" "$OUTPUT"
assert "has session-log check" "session-log" "$OUTPUT"
assert "has read-once check" "read-once" "$OUTPUT"
assert "has permissions check" "Permission rules" "$OUTPUT"

# === Test 4: Score is a valid number ===
SCORE_LINE=$(echo "$OUTPUT" | grep "Safety Score:")
assert "has percentage" "%" "$SCORE_LINE"
assert "has grade" "Grade" "$SCORE_LINE"

# === Test 5: Grade is one of A/B/C/D/F ===
assert "has valid grade" "Grade [ABCDF]" "$SCORE_LINE"

# === Test 6: Checks passed line ===
assert "has checks count" "checks passed" "$OUTPUT"

# === Test 7: Has repo link ===
assert "has repo link" "github.com/Bande-a-Bonnot/Boucle-framework" "$OUTPUT"

# === Test 8: Non-interactive output has no ANSI codes ===
PIPED_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1 | cat)
assert_not "no ANSI in piped output" $'\033' "$PIPED_OUTPUT"

# === Test 9: Exit code is 0 ===
bash "$CHECK_SCRIPT" >/dev/null 2>&1
EXIT_CODE=$?
TOTAL=$((TOTAL + 1))
if [ "$EXIT_CODE" -eq 0 ]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "FAIL: exit code should be 0, got $EXIT_CODE"
fi

# === Test 10: With fake settings file (mock full setup) ===
TMPDIR_TEST=$(mktemp -d)
export HOME="$TMPDIR_TEST"
mkdir -p "$TMPDIR_TEST/.claude"
cat > "$TMPDIR_TEST/.claude/settings.json" << 'SETTINGS'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/bash-guard.sh"}]
      },
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/git-safe.sh"}]
      },
      {
        "matcher": "Write|Edit",
        "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/file-guard.sh"}]
      },
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/branch-guard.sh"}]
      },
      {
        "matcher": "Read",
        "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/read-once.sh"}]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/session-log.sh"}]
      }
    ]
  },
  "permissions": {
    "allow": ["Read"],
    "deny": ["Bash(rm -rf /*)"]
  }
}
SETTINGS

FULL_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert "full setup detects bash-guard" "✓.*bash-guard" "$FULL_OUTPUT"
assert "full setup detects git-safe" "✓.*git-safe" "$FULL_OUTPUT"
assert "full setup detects file-guard" "✓.*file-guard" "$FULL_OUTPUT"
assert "full setup detects branch-guard" "✓.*branch-guard" "$FULL_OUTPUT"
assert "full setup detects session-log" "✓.*session-log" "$FULL_OUTPUT"
assert "full setup detects read-once" "✓.*read-once" "$FULL_OUTPUT"
assert "full setup detects permissions" "✓.*Permission" "$FULL_OUTPUT"
assert "full setup high score" "Grade [AB]" "$FULL_OUTPUT"

# Cleanup
rm -rf "$TMPDIR_TEST"

# === Results ===
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━"
echo "safety-check tests: $PASS/$TOTAL passed"
if [ "$FAIL" -gt 0 ]; then
    echo "$FAIL FAILED"
    exit 1
fi
echo "All tests passed."
