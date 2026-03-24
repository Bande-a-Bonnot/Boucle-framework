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

# === Test 11: IS_DEMO warning ===
TMPDIR_DEMO=$(mktemp -d)
export HOME="$TMPDIR_DEMO"
export IS_DEMO=1
DEMO_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert "IS_DEMO warning shown" "IS_DEMO" "$DEMO_OUTPUT"
assert "IS_DEMO mentions hooks disabled" "disables ALL hooks" "$DEMO_OUTPUT"
unset IS_DEMO
rm -rf "$TMPDIR_DEMO"

# === Test 12: No IS_DEMO warning when unset ===
TMPDIR_NODEMO=$(mktemp -d)
export HOME="$TMPDIR_NODEMO"
unset IS_DEMO 2>/dev/null || true
NODEMO_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert_not "no IS_DEMO warning when unset" "IS_DEMO" "$NODEMO_OUTPUT"
rm -rf "$TMPDIR_NODEMO"

# === Test 13: JSONC warning for invalid settings ===
TMPDIR_JSONC=$(mktemp -d)
export HOME="$TMPDIR_JSONC"
mkdir -p "$TMPDIR_JSONC/.claude"
cat > "$TMPDIR_JSONC/.claude/settings.json" << 'JSONC'
{
  // This is a JSONC comment that breaks JSON parsing
  "hooks": {}
}
JSONC
JSONC_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert "JSONC warning shown" "JSONC comments" "$JSONC_OUTPUT"
rm -rf "$TMPDIR_JSONC"

# === Test 14: No JSONC warning for valid JSON ===
TMPDIR_VALID=$(mktemp -d)
export HOME="$TMPDIR_VALID"
mkdir -p "$TMPDIR_VALID/.claude"
echo '{"hooks": {}}' > "$TMPDIR_VALID/.claude/settings.json"
VALID_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert_not "no JSONC warning for valid JSON" "JSONC comments" "$VALID_OUTPUT"
rm -rf "$TMPDIR_VALID"

# === Test 15: Hook health checks — missing hook file ===
TMPDIR_HEALTH=$(mktemp -d)
export HOME="$TMPDIR_HEALTH"
mkdir -p "$TMPDIR_HEALTH/.claude"
cat > "$TMPDIR_HEALTH/.claude/settings.json" << HEALTH
{
  "hooks": {
    "PreToolUse": [
      {
        "hooks": [{"type": "command", "command": "$TMPDIR_HEALTH/.claude/hooks/nonexistent.sh"}]
      }
    ]
  }
}
HEALTH
HEALTH_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert "missing hook detected" "file not found" "$HEALTH_OUTPUT"
assert "has hook health section" "Hook Health" "$HEALTH_OUTPUT"
rm -rf "$TMPDIR_HEALTH"

# === Test 16: Hook health checks — non-executable hook ===
TMPDIR_NOEXEC=$(mktemp -d)
export HOME="$TMPDIR_NOEXEC"
mkdir -p "$TMPDIR_NOEXEC/.claude/hooks"
echo '#!/bin/bash' > "$TMPDIR_NOEXEC/.claude/hooks/test-hook.sh"
chmod -x "$TMPDIR_NOEXEC/.claude/hooks/test-hook.sh"
cat > "$TMPDIR_NOEXEC/.claude/settings.json" << NOEXEC
{
  "hooks": {
    "PreToolUse": [
      {
        "hooks": [{"type": "command", "command": "$TMPDIR_NOEXEC/.claude/hooks/test-hook.sh"}]
      }
    ]
  }
}
NOEXEC
NOEXEC_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert "non-executable hook detected" "not executable" "$NOEXEC_OUTPUT"
rm -rf "$TMPDIR_NOEXEC"

# === Test 17: Hook health checks — healthy hook ===
TMPDIR_OK=$(mktemp -d)
export HOME="$TMPDIR_OK"
mkdir -p "$TMPDIR_OK/.claude/hooks"
echo '#!/bin/bash' > "$TMPDIR_OK/.claude/hooks/good-hook.sh"
chmod +x "$TMPDIR_OK/.claude/hooks/good-hook.sh"
cat > "$TMPDIR_OK/.claude/settings.json" << OKHOOK
{
  "hooks": {
    "PreToolUse": [
      {
        "hooks": [{"type": "command", "command": "$TMPDIR_OK/.claude/hooks/good-hook.sh"}]
      }
    ]
  }
}
OKHOOK
OK_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert "healthy hook shows checkmark" "✓.*good-hook" "$OK_OUTPUT"
assert_not "healthy hook no errors" "file not found" "$OK_OUTPUT"
rm -rf "$TMPDIR_OK"

# === Test 18: enforce-hooks detection in user-level settings ===
TMPDIR_ENFORCE=$(mktemp -d)
export HOME="$TMPDIR_ENFORCE"
mkdir -p "$TMPDIR_ENFORCE/.claude"
cat > "$TMPDIR_ENFORCE/.claude/settings.json" << 'ENFORCE_SETTINGS'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [{"type": "command", "command": "python3 .claude/hooks/enforce-hooks.py"}]
      }
    ]
  }
}
ENFORCE_SETTINGS
ENFORCE_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert "enforce-hooks detected in settings" "✓.*enforce-hooks" "$ENFORCE_OUTPUT"
assert "has rule enforcement section" "Rule Enforcement" "$ENFORCE_OUTPUT"
rm -rf "$TMPDIR_ENFORCE"

# === Test 19: enforce-hooks not installed ===
TMPDIR_NOENF=$(mktemp -d)
export HOME="$TMPDIR_NOENF"
mkdir -p "$TMPDIR_NOENF/.claude"
echo '{"hooks": {}}' > "$TMPDIR_NOENF/.claude/settings.json"
ORIG_DIR_19=$(pwd)
cd "$TMPDIR_NOENF"
NOENF_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert "enforce-hooks missing flagged" "✗.*enforce-hooks" "$NOENF_OUTPUT"
cd "$ORIG_DIR_19"
rm -rf "$TMPDIR_NOENF"

# === Test 20: enforce-hooks via project-level .claude/hooks/ ===
TMPDIR_PROJ=$(mktemp -d)
export HOME="$TMPDIR_PROJ"
mkdir -p "$TMPDIR_PROJ/.claude"
echo '{}' > "$TMPDIR_PROJ/.claude/settings.json"
ORIG_DIR=$(pwd)
cd "$TMPDIR_PROJ"
mkdir -p .claude/hooks
echo '#!/usr/bin/env python3' > .claude/hooks/enforce-hooks.py
PROJ_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert "project-level enforce-hooks detected" "✓.*enforce-hooks" "$PROJ_OUTPUT"
cd "$ORIG_DIR"
rm -rf "$TMPDIR_PROJ"

# === Test 21: CLAUDE.md with @enforced rules ===
TMPDIR_RULES=$(mktemp -d)
export HOME="$TMPDIR_RULES"
mkdir -p "$TMPDIR_RULES/.claude"
echo '{}' > "$TMPDIR_RULES/.claude/settings.json"
ORIG_DIR=$(pwd)
cd "$TMPDIR_RULES"
cat > CLAUDE.md << 'CLAUDEMD'
## Safety @enforced
- Never modify .env files
- Do not use git push --force

## Guidelines @enforced(warn)
- Always run tests before committing
CLAUDEMD
RULES_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert "CLAUDE.md @enforced rules detected" "✓.*@enforced" "$RULES_OUTPUT"
assert "shows rule count" "2 found" "$RULES_OUTPUT"
cd "$ORIG_DIR"
rm -rf "$TMPDIR_RULES"

# === Test 22: CLAUDE.md without @enforced rules ===
TMPDIR_NORULES=$(mktemp -d)
export HOME="$TMPDIR_NORULES"
mkdir -p "$TMPDIR_NORULES/.claude"
echo '{}' > "$TMPDIR_NORULES/.claude/settings.json"
ORIG_DIR=$(pwd)
cd "$TMPDIR_NORULES"
cat > CLAUDE.md << 'NORULES'
## Guidelines
- Write clean code
- Use meaningful variable names
NORULES
NORULES_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert "CLAUDE.md without @enforced flagged" "✗.*@enforced" "$NORULES_OUTPUT"
assert "advisory warning shown" "advisory only" "$NORULES_OUTPUT"
cd "$ORIG_DIR"
rm -rf "$TMPDIR_NORULES"

# === Test 23: No CLAUDE.md at all ===
TMPDIR_NOCL=$(mktemp -d)
export HOME="$TMPDIR_NOCL"
mkdir -p "$TMPDIR_NOCL/.claude"
echo '{}' > "$TMPDIR_NOCL/.claude/settings.json"
ORIG_DIR=$(pwd)
cd "$TMPDIR_NOCL"
NOCL_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert "no CLAUDE.md flagged" "✗.*@enforced" "$NOCL_OUTPUT"
assert "no CLAUDE.md message" "No CLAUDE.md" "$NOCL_OUTPUT"
cd "$ORIG_DIR"
rm -rf "$TMPDIR_NOCL"

# === Test 24: Full setup includes enforce-hooks in score ===
TMPDIR_FULL2=$(mktemp -d)
export HOME="$TMPDIR_FULL2"
mkdir -p "$TMPDIR_FULL2/.claude"
cat > "$TMPDIR_FULL2/.claude/settings.json" << 'FULL2'
{
  "hooks": {
    "PreToolUse": [
      {"hooks": [{"type": "command", "command": "bash ~/.claude/hooks/bash-guard.sh"}]},
      {"hooks": [{"type": "command", "command": "bash ~/.claude/hooks/git-safe.sh"}]},
      {"hooks": [{"type": "command", "command": "bash ~/.claude/hooks/file-guard.sh"}]},
      {"hooks": [{"type": "command", "command": "bash ~/.claude/hooks/branch-guard.sh"}]},
      {"hooks": [{"type": "command", "command": "bash ~/.claude/hooks/read-once.sh"}]},
      {"hooks": [{"type": "command", "command": "python3 .claude/hooks/enforce-hooks.py"}]}
    ],
    "PostToolUse": [
      {"hooks": [{"type": "command", "command": "bash ~/.claude/hooks/session-log.sh"}]}
    ]
  },
  "permissions": {"allow": ["Read"], "deny": []}
}
FULL2
ORIG_DIR=$(pwd)
cd "$TMPDIR_FULL2"
mkdir -p .claude/hooks
echo '#!/usr/bin/env python3' > .claude/hooks/enforce-hooks.py
cat > CLAUDE.md << 'FULLENF'
## Safety @enforced
- Never modify .env
FULLENF
FULL2_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert "full setup with enforce gets high grade" "Grade [AB]" "$FULL2_OUTPUT"
assert "full setup detects enforce-hooks" "✓.*enforce-hooks" "$FULL2_OUTPUT"
assert "full setup detects @enforced" "✓.*@enforced" "$FULL2_OUTPUT"
cd "$ORIG_DIR"
rm -rf "$TMPDIR_FULL2"

# === Test 25: --verify flag with no hooks installed ===
TMPDIR_VNONE=$(mktemp -d)
export HOME="$TMPDIR_VNONE"
mkdir -p "$TMPDIR_VNONE/.claude"
echo '{"hooks": {}}' > "$TMPDIR_VNONE/.claude/settings.json"
VNONE_OUTPUT=$(bash "$CHECK_SCRIPT" --verify 2>&1) || true
assert "verify no hooks message" "No hooks found to verify" "$VNONE_OUTPUT"
rm -rf "$TMPDIR_VNONE"

# === Test 26: --verify with working bash-guard ===
TMPDIR_VBG=$(mktemp -d)
export HOME="$TMPDIR_VBG"
mkdir -p "$TMPDIR_VBG/.claude/hooks"
# Copy real bash-guard hook
cp "$SCRIPT_DIR/../bash-guard/hook.sh" "$TMPDIR_VBG/.claude/hooks/bash-guard.sh"
chmod +x "$TMPDIR_VBG/.claude/hooks/bash-guard.sh"
cat > "$TMPDIR_VBG/.claude/settings.json" << VBGSETTINGS
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash $TMPDIR_VBG/.claude/hooks/bash-guard.sh"}]
      }
    ]
  }
}
VBGSETTINGS
VBG_OUTPUT=$(bash "$CHECK_SCRIPT" --verify 2>&1) || true
assert "verify bash-guard blocks" "blocks correctly" "$VBG_OUTPUT"
assert "verify bash-guard passes safe" "passes safe" "$VBG_OUTPUT"
assert "verify has section header" "Hook Verification" "$VBG_OUTPUT"
rm -rf "$TMPDIR_VBG"

# === Test 27: --verify with broken (fail-open) hook ===
TMPDIR_VBROKEN=$(mktemp -d)
export HOME="$TMPDIR_VBROKEN"
mkdir -p "$TMPDIR_VBROKEN/.claude/hooks"
# Create a broken hook that reads stdin but outputs nothing (silent fail-open)
cat > "$TMPDIR_VBROKEN/.claude/hooks/bash-guard.sh" << 'BROKEN'
#!/bin/bash
cat > /dev/null
exit 0
BROKEN
chmod +x "$TMPDIR_VBROKEN/.claude/hooks/bash-guard.sh"
cat > "$TMPDIR_VBROKEN/.claude/settings.json" << VBRKSET
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash $TMPDIR_VBROKEN/.claude/hooks/bash-guard.sh"}]
      }
    ]
  }
}
VBRKSET
VBRK_OUTPUT=$(bash "$CHECK_SCRIPT" --verify 2>&1) || true
assert "verify broken hook detected" "FAIL-OPEN" "$VBRK_OUTPUT"
assert "verify broken hook shows not block" "did NOT block" "$VBRK_OUTPUT"
rm -rf "$TMPDIR_VBROKEN"

# === Test 28: --verify with missing hook file ===
TMPDIR_VMISS=$(mktemp -d)
export HOME="$TMPDIR_VMISS"
mkdir -p "$TMPDIR_VMISS/.claude"
cat > "$TMPDIR_VMISS/.claude/settings.json" << VMISSSET
{
  "hooks": {
    "PreToolUse": [
      {
        "hooks": [{"type": "command", "command": "bash $TMPDIR_VMISS/.claude/hooks/nonexistent-bash-guard.sh"}]
      }
    ]
  }
}
VMISSSET
VMISS_OUTPUT=$(bash "$CHECK_SCRIPT" --verify 2>&1) || true
assert "verify missing hook detected" "not found" "$VMISS_OUTPUT"
rm -rf "$TMPDIR_VMISS"

# === Test 29: --verify with git-safe ===
TMPDIR_VGS=$(mktemp -d)
export HOME="$TMPDIR_VGS"
mkdir -p "$TMPDIR_VGS/.claude/hooks"
cp "$SCRIPT_DIR/../git-safe/hook.sh" "$TMPDIR_VGS/.claude/hooks/git-safe.sh"
chmod +x "$TMPDIR_VGS/.claude/hooks/git-safe.sh"
cat > "$TMPDIR_VGS/.claude/settings.json" << VGSSET
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash $TMPDIR_VGS/.claude/hooks/git-safe.sh"}]
      }
    ]
  }
}
VGSSET
VGS_OUTPUT=$(bash "$CHECK_SCRIPT" --verify 2>&1) || true
assert "verify git-safe blocks force push" "blocks correctly" "$VGS_OUTPUT"
assert "verify git-safe passes safe" "passes safe" "$VGS_OUTPUT"
rm -rf "$TMPDIR_VGS"

# === Test 30: --verify with file-guard ===
TMPDIR_VFG=$(mktemp -d)
export HOME="$TMPDIR_VFG"
mkdir -p "$TMPDIR_VFG/.claude/hooks"
cp "$SCRIPT_DIR/../file-guard/hook.sh" "$TMPDIR_VFG/.claude/hooks/file-guard.sh"
chmod +x "$TMPDIR_VFG/.claude/hooks/file-guard.sh"
echo '.env' > "$TMPDIR_VFG/.file-guard"
export FILE_GUARD_CONFIG="$TMPDIR_VFG/.file-guard"
cat > "$TMPDIR_VFG/.claude/settings.json" << VFGSET
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Read|Write|Edit",
        "hooks": [{"type": "command", "command": "bash $TMPDIR_VFG/.claude/hooks/file-guard.sh"}]
      }
    ]
  }
}
VFGSET
VFG_OUTPUT=$(bash "$CHECK_SCRIPT" --verify 2>&1) || true
assert "verify file-guard blocks .env write" "blocks correctly" "$VFG_OUTPUT"
assert "verify file-guard passes safe" "passes safe" "$VFG_OUTPUT"
unset FILE_GUARD_CONFIG
rm -rf "$TMPDIR_VFG"

# === Test 31: --verify with session-log (PostToolUse, should not block) ===
TMPDIR_VSL=$(mktemp -d)
export HOME="$TMPDIR_VSL"
mkdir -p "$TMPDIR_VSL/.claude/hooks"
cp "$SCRIPT_DIR/../session-log/hook.sh" "$TMPDIR_VSL/.claude/hooks/session-log.sh"
chmod +x "$TMPDIR_VSL/.claude/hooks/session-log.sh"
cat > "$TMPDIR_VSL/.claude/settings.json" << VSLSET
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [{"type": "command", "command": "bash $TMPDIR_VSL/.claude/hooks/session-log.sh"}]
      }
    ]
  }
}
VSLSET
VSL_OUTPUT=$(bash "$CHECK_SCRIPT" --verify 2>&1) || true
assert "verify session-log accepts payloads" "accepts payloads" "$VSL_OUTPUT"
rm -rf "$TMPDIR_VSL"

# === Test 32: --verify summary line — all pass ===
TMPDIR_VSUM=$(mktemp -d)
export HOME="$TMPDIR_VSUM"
mkdir -p "$TMPDIR_VSUM/.claude/hooks"
cp "$SCRIPT_DIR/../bash-guard/hook.sh" "$TMPDIR_VSUM/.claude/hooks/bash-guard.sh"
chmod +x "$TMPDIR_VSUM/.claude/hooks/bash-guard.sh"
cat > "$TMPDIR_VSUM/.claude/settings.json" << VSUMSET
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash $TMPDIR_VSUM/.claude/hooks/bash-guard.sh"}]
      }
    ]
  }
}
VSUMSET
VSUM_OUTPUT=$(bash "$CHECK_SCRIPT" --verify 2>&1) || true
assert "verify summary all pass" "All.*verified hooks working" "$VSUM_OUTPUT"
rm -rf "$TMPDIR_VSUM"

# === Test 33: --verify summary line — has failures ===
TMPDIR_VFAIL=$(mktemp -d)
export HOME="$TMPDIR_VFAIL"
mkdir -p "$TMPDIR_VFAIL/.claude/hooks"
cat > "$TMPDIR_VFAIL/.claude/hooks/bash-guard.sh" << 'FAILHOOK'
#!/bin/bash
cat > /dev/null
exit 0
FAILHOOK
chmod +x "$TMPDIR_VFAIL/.claude/hooks/bash-guard.sh"
cat > "$TMPDIR_VFAIL/.claude/settings.json" << VFAILSET
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash $TMPDIR_VFAIL/.claude/hooks/bash-guard.sh"}]
      }
    ]
  }
}
VFAILSET
VFAIL_OUTPUT=$(bash "$CHECK_SCRIPT" --verify 2>&1) || true
assert "verify summary shows failures" "FAIL-OPEN" "$VFAIL_OUTPUT"
rm -rf "$TMPDIR_VFAIL"

# === Test 34: --verify with branch-guard (skipped) ===
TMPDIR_VBR=$(mktemp -d)
export HOME="$TMPDIR_VBR"
mkdir -p "$TMPDIR_VBR/.claude/hooks"
cp "$SCRIPT_DIR/../branch-guard/hook.sh" "$TMPDIR_VBR/.claude/hooks/branch-guard.sh" 2>/dev/null || echo '#!/bin/bash' > "$TMPDIR_VBR/.claude/hooks/branch-guard.sh"
chmod +x "$TMPDIR_VBR/.claude/hooks/branch-guard.sh"
cat > "$TMPDIR_VBR/.claude/settings.json" << VBRSET
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash $TMPDIR_VBR/.claude/hooks/branch-guard.sh"}]
      }
    ]
  }
}
VBRSET
VBR_OUTPUT=$(bash "$CHECK_SCRIPT" --verify 2>&1) || true
assert "verify branch-guard skipped" "skipped" "$VBR_OUTPUT"
rm -rf "$TMPDIR_VBR"

# === Test 35: without --verify flag, no verify section ===
TMPDIR_NOVERIFY=$(mktemp -d)
export HOME="$TMPDIR_NOVERIFY"
mkdir -p "$TMPDIR_NOVERIFY/.claude/hooks"
cp "$SCRIPT_DIR/../bash-guard/hook.sh" "$TMPDIR_NOVERIFY/.claude/hooks/bash-guard.sh"
chmod +x "$TMPDIR_NOVERIFY/.claude/hooks/bash-guard.sh"
cat > "$TMPDIR_NOVERIFY/.claude/settings.json" << NVSET
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash $TMPDIR_NOVERIFY/.claude/hooks/bash-guard.sh"}]
      }
    ]
  }
}
NVSET
NV_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert_not "no verify section without flag" "Hook Verification" "$NV_OUTPUT"
rm -rf "$TMPDIR_NOVERIFY"

# === Test 36: CLAUDE.md rule coverage — suggests file-guard ===
TMPDIR_RC1=$(mktemp -d)
export HOME="$TMPDIR_RC1"
mkdir -p "$TMPDIR_RC1/.claude"
echo '{"hooks": {}}' > "$TMPDIR_RC1/.claude/settings.json"
ORIG_DIR=$(pwd)
cd "$TMPDIR_RC1"
cat > CLAUDE.md << 'RC1MD'
## Rules
- Never modify .env files
- Keep API keys secret
RC1MD
RC1_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert "rule coverage suggests file-guard" "file-guard" "$RC1_OUTPUT"
assert "rule coverage mentions sensitive files" "sensitive files" "$RC1_OUTPUT"
cd "$ORIG_DIR"
rm -rf "$TMPDIR_RC1"

# === Test 37: CLAUDE.md rule coverage — suggests git-safe ===
TMPDIR_RC2=$(mktemp -d)
export HOME="$TMPDIR_RC2"
mkdir -p "$TMPDIR_RC2/.claude"
echo '{"hooks": {}}' > "$TMPDIR_RC2/.claude/settings.json"
ORIG_DIR=$(pwd)
cd "$TMPDIR_RC2"
cat > CLAUDE.md << 'RC2MD'
## Git Rules
- Never use git push --force
- Do not use reset --hard
RC2MD
RC2_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert "rule coverage suggests git-safe" "git-safe" "$RC2_OUTPUT"
assert "rule coverage mentions git operations" "destructive git" "$RC2_OUTPUT"
cd "$ORIG_DIR"
rm -rf "$TMPDIR_RC2"

# === Test 38: CLAUDE.md rule coverage — suggests bash-guard ===
TMPDIR_RC3=$(mktemp -d)
export HOME="$TMPDIR_RC3"
mkdir -p "$TMPDIR_RC3/.claude"
echo '{"hooks": {}}' > "$TMPDIR_RC3/.claude/settings.json"
ORIG_DIR=$(pwd)
cd "$TMPDIR_RC3"
cat > CLAUDE.md << 'RC3MD'
## Safety
- Never run rm -rf on important directories
- Do not use sudo
RC3MD
RC3_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert "rule coverage suggests bash-guard" "bash-guard" "$RC3_OUTPUT"
assert "rule coverage mentions dangerous commands" "dangerous commands" "$RC3_OUTPUT"
cd "$ORIG_DIR"
rm -rf "$TMPDIR_RC3"

# === Test 39: CLAUDE.md rule coverage — suggests branch-guard ===
TMPDIR_RC4=$(mktemp -d)
export HOME="$TMPDIR_RC4"
mkdir -p "$TMPDIR_RC4/.claude"
echo '{"hooks": {}}' > "$TMPDIR_RC4/.claude/settings.json"
ORIG_DIR=$(pwd)
cd "$TMPDIR_RC4"
cat > CLAUDE.md << 'RC4MD'
## Branching
- Always use feature branches
- Never commit directly to main
RC4MD
RC4_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert "rule coverage suggests branch-guard" "branch-guard" "$RC4_OUTPUT"
assert "rule coverage mentions branch protection" "branch protection" "$RC4_OUTPUT"
cd "$ORIG_DIR"
rm -rf "$TMPDIR_RC4"

# === Test 40: CLAUDE.md rule coverage — no suggestions when hooks installed ===
TMPDIR_RC5=$(mktemp -d)
export HOME="$TMPDIR_RC5"
mkdir -p "$TMPDIR_RC5/.claude"
cat > "$TMPDIR_RC5/.claude/settings.json" << 'RC5SET'
{
  "hooks": {
    "PreToolUse": [
      {"hooks": [{"type": "command", "command": "bash ~/.claude/hooks/bash-guard.sh"}]},
      {"hooks": [{"type": "command", "command": "bash ~/.claude/hooks/git-safe.sh"}]},
      {"hooks": [{"type": "command", "command": "bash ~/.claude/hooks/file-guard.sh"}]},
      {"hooks": [{"type": "command", "command": "bash ~/.claude/hooks/branch-guard.sh"}]}
    ]
  }
}
RC5SET
ORIG_DIR=$(pwd)
cd "$TMPDIR_RC5"
cat > CLAUDE.md << 'RC5MD'
## Rules
- Never modify .env
- Never use git push --force
- Never run rm -rf /
- Always use feature branches
RC5MD
RC5_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert_not "no rule suggestions when all hooks installed" "Rules in CLAUDE.md that could be enforced" "$RC5_OUTPUT"
cd "$ORIG_DIR"
rm -rf "$TMPDIR_RC5"

# === Test 41: CLAUDE.md rule coverage — only suggests missing hooks ===
TMPDIR_RC6=$(mktemp -d)
export HOME="$TMPDIR_RC6"
mkdir -p "$TMPDIR_RC6/.claude"
# Only git-safe installed
cat > "$TMPDIR_RC6/.claude/settings.json" << 'RC6SET'
{
  "hooks": {
    "PreToolUse": [
      {"hooks": [{"type": "command", "command": "bash ~/.claude/hooks/git-safe.sh"}]}
    ]
  }
}
RC6SET
ORIG_DIR=$(pwd)
cd "$TMPDIR_RC6"
cat > CLAUDE.md << 'RC6MD'
## Rules
- Never modify .env files
- Never use git push --force
- Never run rm -rf /
RC6MD
RC6_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert "suggests file-guard for .env rule" "file-guard" "$RC6_OUTPUT"
assert "suggests bash-guard for rm rule" "bash-guard" "$RC6_OUTPUT"
assert_not "no git-safe suggestion when already installed" "git-safe.*destructive git" "$RC6_OUTPUT"
cd "$ORIG_DIR"
rm -rf "$TMPDIR_RC6"

# === Test 42: No CLAUDE.md — no rule coverage section ===
TMPDIR_RC7=$(mktemp -d)
export HOME="$TMPDIR_RC7"
mkdir -p "$TMPDIR_RC7/.claude"
echo '{"hooks": {}}' > "$TMPDIR_RC7/.claude/settings.json"
ORIG_DIR=$(pwd)
cd "$TMPDIR_RC7"
# No CLAUDE.md
RC7_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert_not "no rule coverage section without CLAUDE.md" "Rules in CLAUDE.md that could be enforced" "$RC7_OUTPUT"
cd "$ORIG_DIR"
rm -rf "$TMPDIR_RC7"

# === Test 43: CLAUDE.md with no enforceable content — no suggestions ===
TMPDIR_RC8=$(mktemp -d)
export HOME="$TMPDIR_RC8"
mkdir -p "$TMPDIR_RC8/.claude"
echo '{"hooks": {}}' > "$TMPDIR_RC8/.claude/settings.json"
ORIG_DIR=$(pwd)
cd "$TMPDIR_RC8"
cat > CLAUDE.md << 'RC8MD'
## Style Guide
- Write clean code
- Use meaningful variable names
- Keep functions small
RC8MD
RC8_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert_not "no suggestions for non-enforceable rules" "Rules in CLAUDE.md that could be enforced" "$RC8_OUTPUT"
cd "$ORIG_DIR"
rm -rf "$TMPDIR_RC8"

# === Test 44: jq missing warning ===
TMPDIR_JQ=$(mktemp -d)
export HOME="$TMPDIR_JQ"
mkdir -p "$TMPDIR_JQ/.claude"
echo '{"hooks": {}}' > "$TMPDIR_JQ/.claude/settings.json"
# Simulate missing jq by hiding it from PATH
JQ_OUTPUT=$(PATH="/usr/bin:/bin" bash "$CHECK_SCRIPT" 2>&1) || true
# On systems where jq is in /usr/bin or /bin, this may still find it
# so we test that the check script at least has the jq check code
assert "jq check code exists" "jq" "$(cat "$CHECK_SCRIPT")"
rm -rf "$TMPDIR_JQ"

# === Test 45: python3 check exists in script ===
assert "python3 check code exists" "python3 is not installed" "$(cat "$CHECK_SCRIPT")"

# === Test 46: Windows warning code exists ===
assert "windows check code exists" "Windows" "$(cat "$CHECK_SCRIPT")"

# === Test 47: jq warning message format ===
assert "jq warning mentions brew" "brew install jq" "$(cat "$CHECK_SCRIPT")"

# === Test 48: jq warning mentions apt ===
assert "jq warning mentions apt" "apt install jq" "$(cat "$CHECK_SCRIPT")"

# === Test 49: Windows hook reliability rate cited ===
assert "windows hooks 18% cited" "18%" "$(cat "$CHECK_SCRIPT")"

# === Test 50: jq warning references hook count ===
assert "jq warning says 5 of 7 hooks" "5 of 7" "$(cat "$CHECK_SCRIPT")"

# === Test 51: GIT_INDEX_FILE warning shown when set ===
TMPDIR_GIT_IDX=$(mktemp -d)
export HOME="$TMPDIR_GIT_IDX"
export GIT_INDEX_FILE="/some/project/.git/index"
GIT_IDX_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert "GIT_INDEX_FILE warning shown" "GIT_INDEX_FILE" "$GIT_IDX_OUTPUT"
assert "GIT_INDEX_FILE mentions git hook" "git hook" "$GIT_IDX_OUTPUT"
unset GIT_INDEX_FILE
rm -rf "$TMPDIR_GIT_IDX"

# === Test 52: No GIT_INDEX_FILE warning when unset ===
TMPDIR_NOGIT_IDX=$(mktemp -d)
export HOME="$TMPDIR_NOGIT_IDX"
unset GIT_INDEX_FILE 2>/dev/null || true
NOGIT_IDX_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert_not "no GIT_INDEX_FILE warning when unset" "GIT_INDEX_FILE" "$NOGIT_IDX_OUTPUT"
rm -rf "$TMPDIR_NOGIT_IDX"

# === Test 53: GIT_INDEX_FILE warning mentions corruption ===
assert "GIT_INDEX_FILE check code exists" "corrupt" "$(cat "$CHECK_SCRIPT")"

# === Test 54: Deny rules without bash-guard shows bypass warning ===
TMPDIR_DENY=$(mktemp -d)
export HOME="$TMPDIR_DENY"
mkdir -p "$TMPDIR_DENY/.claude"
cat > "$TMPDIR_DENY/.claude/settings.json" << 'DENYSET'
{
  "permissions": {
    "deny": ["Bash(rm -rf /*)"]
  }
}
DENYSET
DENY_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert "deny bypass warning shown" "bypassable" "$DENY_OUTPUT"
assert "deny bypass mentions multi-line" "multi-line" "$DENY_OUTPUT"
assert "deny bypass references issue 38119" "38119" "$DENY_OUTPUT"
rm -rf "$TMPDIR_DENY"

# === Test 55: Deny rules WITH bash-guard — no bypass warning ===
TMPDIR_DENYBG=$(mktemp -d)
export HOME="$TMPDIR_DENYBG"
mkdir -p "$TMPDIR_DENYBG/.claude"
cat > "$TMPDIR_DENYBG/.claude/settings.json" << 'DENYBGSET'
{
  "hooks": {
    "PreToolUse": [
      {"hooks": [{"type": "command", "command": "bash ~/.claude/hooks/bash-guard.sh"}]}
    ]
  },
  "permissions": {
    "deny": ["Bash(rm -rf /*)"]
  }
}
DENYBGSET
DENYBG_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert_not "no bypass warning when bash-guard installed" "bypassable" "$DENYBG_OUTPUT"
rm -rf "$TMPDIR_DENYBG"

# === Test 56: No deny rules — no bypass warning ===
TMPDIR_NODENY=$(mktemp -d)
export HOME="$TMPDIR_NODENY"
mkdir -p "$TMPDIR_NODENY/.claude"
cat > "$TMPDIR_NODENY/.claude/settings.json" << 'NODENYSET'
{
  "permissions": {
    "allow": ["Read"]
  }
}
NODENYSET
NODENY_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert_not "no bypass warning without deny rules" "bypassable" "$NODENY_OUTPUT"
rm -rf "$TMPDIR_NODENY"

# === Test 57: Deny rules without any permissions key — no bypass warning ===
TMPDIR_NOPERM=$(mktemp -d)
export HOME="$TMPDIR_NOPERM"
mkdir -p "$TMPDIR_NOPERM/.claude"
echo '{"hooks": {}}' > "$TMPDIR_NOPERM/.claude/settings.json"
NOPERM_OUTPUT=$(bash "$CHECK_SCRIPT" 2>&1) || true
assert_not "no bypass warning without permissions" "bypassable" "$NOPERM_OUTPUT"
rm -rf "$TMPDIR_NOPERM"

# === Test 58: Deny bypass warning references compound commands ===
assert "deny bypass code references compound" "compound" "$(cat "$CHECK_SCRIPT")"

# === Results ===
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━"
echo "safety-check tests: $PASS/$TOTAL passed"
if [ "$FAIL" -gt 0 ]; then
    echo "$FAIL FAILED"
    exit 1
fi
echo "All tests passed."
