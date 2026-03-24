#!/usr/bin/env bash
# Claude Code Safety Check
# Run: curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash
# Verify: curl -fsSL ... | bash -s -- --verify
#
# Audits your Claude Code setup and scores it for safety.
# --verify sends test payloads to each hook and checks they actually block.
# No installation, no dependencies — just information.

set -euo pipefail

# Parse flags
VERIFY_MODE=0
for arg in "$@"; do
    if [ "$arg" = "--verify" ]; then
        VERIFY_MODE=1
    fi
done

CLAUDE_DIR="${HOME}/.claude"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"
SCORE=0
MAX_SCORE=0
CHECKS_PASSED=0
CHECKS_TOTAL=0
ISSUES=()
FIXES=()

# Colors (disabled if not a terminal)
if [ -t 1 ]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    GREEN='' RED='' YELLOW='' BLUE='' BOLD='' DIM='' NC=''
fi

check() {
    local name="$1"
    local weight="$2"
    local pass="$3"
    local issue="$4"
    local fix="${5:-}"

    MAX_SCORE=$((MAX_SCORE + weight))
    CHECKS_TOTAL=$((CHECKS_TOTAL + 1))

    if [ "$pass" = "true" ]; then
        SCORE=$((SCORE + weight))
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
        printf "  ${GREEN}✓${NC} %s ${DIM}(+%d)${NC}\n" "$name" "$weight"
    else
        printf "  ${RED}✗${NC} %s ${DIM}(0/%d)${NC}\n" "$name" "$weight"
        ISSUES+=("$issue")
        if [ -n "$fix" ]; then
            FIXES+=("$fix")
        fi
    fi
}

# Detect all hooks in one python3 call (outputs space-separated list of found hooks)
DETECTED_HOOKS=""
if [ -f "$SETTINGS_FILE" ]; then
    DETECTED_HOOKS=$(python3 - "$SETTINGS_FILE" << 'PYEOF'
import json, sys
found = set()
try:
    with open(sys.argv[1]) as f:
        s = json.load(f)
    needles = ["bash-guard", "bash_guard", "git-safe", "git_safe",
               "file-guard", "file_guard", "branch-guard", "branch_guard",
               "session-log", "session_log", "read-once", "read_once",
               "enforce-hooks", "enforce_hooks"]
    for hook_type in ["PreToolUse", "PostToolUse"]:
        for entry in s.get("hooks", {}).get(hook_type, []):
            cmds = []
            # Nested format: {"hooks": [{"type": "command", "command": "..."}]}
            for hook in entry.get("hooks", []):
                cmds.append(hook.get("command", ""))
            # Flat format: {"type": "command", "command": "..."}
            cmds.append(entry.get("command", ""))
            for cmd in cmds:
                for needle in needles:
                    if needle in cmd:
                        found.add(needle.replace("_", "-"))
    perms = s.get("permissions", {})
    if perms.get("allow", []) or perms.get("deny", []):
        found.add("permissions")
except Exception:
    pass
print(" ".join(found))
PYEOF
    )
fi

has_hook() { echo " $DETECTED_HOOKS " | grep -q " $1 "; }

echo ""
printf "${BOLD}Claude Code Safety Check${NC}\n"
echo "━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# === Section 0: Environment Warnings ===
# These are platform bugs that silently disable hooks — check before anything else
WARNINGS=()

# IS_DEMO check (claude-code#37780: silently disables all hooks)
if [ "${IS_DEMO:-}" = "1" ]; then
    WARNINGS+=("IS_DEMO=1 is set in your environment. This silently disables ALL hooks by suppressing workspace trust. Unset it: unset IS_DEMO (see claude-code#37780)")
fi

# GIT_INDEX_FILE check (claude-code#38181: corrupts git index when Claude launched from git hooks)
if [ -n "${GIT_INDEX_FILE:-}" ]; then
    WARNINGS+=("GIT_INDEX_FILE is set ($GIT_INDEX_FILE). If Claude was launched from a git hook (post-commit, pre-push, etc.), plugin initialization can corrupt your git index by writing plugin entries into it. Unset this variable before invoking Claude, or run in a separate shell. (see claude-code#38181)")
fi

# JSONC check: settings.json with comments silently breaks hook loading
if [ -f "$SETTINGS_FILE" ]; then
    if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$SETTINGS_FILE" 2>/dev/null; then
        WARNINGS+=("settings.json contains JSONC comments or invalid JSON. Hooks may not load. Run any hook installer to auto-fix, or remove // and /* */ comments manually (see claude-code#37540)")
    fi
fi

# Dependency checks: jq is required by 5 of 7 hooks (bash-guard, git-safe, file-guard, branch-guard, read-once)
if ! command -v jq >/dev/null 2>&1; then
    WARNINGS+=("jq is not installed. 5 of 7 hooks require jq for JSON parsing and will silently fail without it. Install: brew install jq (macOS), apt install jq (Debian/Ubuntu), or see https://jqlang.github.io/jq/download/")
fi

# python3 check: needed by enforce-hooks, session-log, and safety-check itself
if ! command -v python3 >/dev/null 2>&1; then
    WARNINGS+=("python3 is not installed. enforce-hooks and session-log require python3. Some safety-check features may not work.")
fi

# Platform check: Windows hooks have known reliability issues
if [[ "${OS:-}" == "Windows_NT" ]] || [[ "$(uname -s 2>/dev/null)" == MINGW* ]] || [[ "$(uname -s 2>/dev/null)" == MSYS* ]]; then
    WARNINGS+=("Running on Windows. Claude Code hooks fire only ~18% of the time on Windows (see claude-code#37988). Hooks are unreliable on this platform.")
fi

# CLI version check: warn about known dangerous versions
if command -v claude >/dev/null 2>&1; then
    CLI_VERSION=$(claude --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "")
    if [ -n "$CLI_VERSION" ]; then
        CLI_MINOR=$(echo "$CLI_VERSION" | cut -d. -f3)
        # v2.1.78+: permissionDecision from PreToolUse hooks silently ignored (claude-code#37597)
        if [ "$CLI_MINOR" -ge 78 ] 2>/dev/null; then
            WARNINGS+=("Claude CLI v$CLI_VERSION: permissionDecision responses from PreToolUse hooks may be silently ignored (regression since v2.1.78, see claude-code#37597). Hooks using decision:block format still work.")
        fi
        # v2.1.81+: crashes when invoked by launchd (claude-code#37878)
        if [ "$CLI_MINOR" -ge 81 ] 2>/dev/null; then
            WARNINGS+=("Claude CLI v$CLI_VERSION: crashes when invoked by launchd/cron (regression since v2.1.81, see claude-code#37878). If running automated loops, pin to v2.1.77 or earlier.")
        fi
    fi
fi

if [ ${#WARNINGS[@]} -gt 0 ]; then
    printf "${RED}${BOLD}⚠ Environment Warnings${NC}\n"
    for warn in "${WARNINGS[@]}"; do
        printf "  ${RED}!${NC} %s\n" "$warn"
    done
    echo ""
fi

# === Section 1: Basic Setup ===
printf "${BLUE}Setup${NC}\n"

check "Claude Code installed" 5 \
    "$(command -v claude >/dev/null 2>&1 && echo true || echo false)" \
    "Claude Code CLI not found" \
    "Install: https://docs.anthropic.com/en/docs/claude-code"

check "Settings file exists" 5 \
    "$([ -f "$SETTINGS_FILE" ] && echo true || echo false)" \
    "No settings.json — Claude Code may be using defaults" \
    ""

# === Section 2: Destructive Command Protection ===
echo ""
printf "${BLUE}Destructive Command Protection${NC}\n"

check "bash-guard (blocks rm -rf /, sudo, curl|bash)" 20 \
    "$(has_hook bash-guard && echo true || echo false)" \
    "No bash-guard: Claude can run rm -rf /, sudo, curl|bash, and other dangerous commands" \
    "curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/bash-guard/install.sh | bash"

check "git-safe (blocks force push, hard reset)" 15 \
    "$(has_hook git-safe && echo true || echo false)" \
    "No git-safe: Claude can force-push, hard-reset, and destroy git history" \
    "curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/git-safe/install.sh | bash"

# === Section 3: File Protection ===
echo ""
printf "${BLUE}File Protection${NC}\n"

check "file-guard (protects .env, secrets, keys)" 15 \
    "$(has_hook file-guard && echo true || echo false)" \
    "No file-guard: Claude can read/modify .env, private keys, and credential files" \
    "curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/file-guard/install.sh | bash"

check "branch-guard (prevents commits to main)" 10 \
    "$(has_hook branch-guard && echo true || echo false)" \
    "No branch-guard: Claude can commit directly to main/master/production" \
    "curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/branch-guard/install.sh | bash"

# === Section 4: Observability ===
echo ""
printf "${BLUE}Observability${NC}\n"

check "session-log (audit trail of all actions)" 15 \
    "$(has_hook session-log && echo true || echo false)" \
    "No session-log: no record of what Claude did in each session" \
    "curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/session-log/install.sh | bash"

# === Section 5: Efficiency ===
echo ""
printf "${BLUE}Efficiency${NC}\n"

check "read-once (prevents redundant file reads)" 10 \
    "$(has_hook read-once && echo true || echo false)" \
    "No read-once: Claude re-reads files it already has, wasting tokens" \
    "curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/read-once/install.sh | bash"

# === Section 6: Built-in protections ===
echo ""
printf "${BLUE}Built-in Settings${NC}\n"

check "Permission rules configured" 5 \
    "$(has_hook permissions && echo true || echo false)" \
    "No permission allow/deny rules in settings.json" \
    "See: https://docs.anthropic.com/en/docs/claude-code/settings"

# === Section 7: Rule Enforcement ===
echo ""
printf "${BLUE}Rule Enforcement${NC}\n"

# Check for enforce-hooks in user-level settings
ENFORCE_IN_USER=$(has_hook enforce-hooks && echo true || echo false)

# Also check project-level: .claude/hooks/enforce-hooks.py or referenced in .claude/settings.json
ENFORCE_IN_PROJECT=false
if [ -f ".claude/hooks/enforce-hooks.py" ]; then
    ENFORCE_IN_PROJECT=true
elif [ -f ".claude/settings.json" ]; then
    ENFORCE_IN_PROJECT=$(python3 - ".claude/settings.json" << 'PYEOF2'
import json, sys
try:
    with open(sys.argv[1]) as f:
        s = json.load(f)
    for ht in ["PreToolUse", "PostToolUse"]:
        for e in s.get("hooks", {}).get(ht, []):
            for h in e.get("hooks", []):
                if "enforce" in h.get("command", ""):
                    print("true"); sys.exit(0)
            if "enforce" in e.get("command", ""):
                print("true"); sys.exit(0)
except Exception:
    pass
print("false")
PYEOF2
    )
fi

ENFORCE_FOUND=false
if [ "$ENFORCE_IN_USER" = "true" ] || [ "$ENFORCE_IN_PROJECT" = "true" ]; then
    ENFORCE_FOUND=true
fi

check "enforce-hooks (turns CLAUDE.md rules into hooks)" 10 \
    "$ENFORCE_FOUND" \
    "No enforce-hooks: CLAUDE.md rules are suggestions that degrade as context grows" \
    "curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/enforce/install.sh | bash"

# Check for @enforced rules in CLAUDE.md
if [ -f "CLAUDE.md" ]; then
    ENFORCED_COUNT=$(grep -c '@enforced' CLAUDE.md 2>/dev/null || echo "0")
    if [ "$ENFORCED_COUNT" -gt 0 ]; then
        check "CLAUDE.md has @enforced rules ($ENFORCED_COUNT found)" 5 \
            "true" \
            "" \
            ""
    else
        check "CLAUDE.md has @enforced rules" 5 \
            "false" \
            "CLAUDE.md exists but has no @enforced rules. Rules without @enforced are advisory only." \
            "Add @enforced to section headings in CLAUDE.md, e.g.: ## Safety @enforced"
    fi
else
    check "CLAUDE.md has @enforced rules" 5 \
        "false" \
        "No CLAUDE.md found in current directory. Create one with @enforced rules for deterministic enforcement." \
        ""
fi

# === Section 7b: CLAUDE.md Rule Coverage ===
# Scan CLAUDE.md for enforceable rules and show which hooks cover them
if [ -f "CLAUDE.md" ]; then
    RULE_SUGGESTIONS=()

    # Check for file protection rules not covered by file-guard
    if ! has_hook file-guard; then
        if grep -qiE '\.env|secret|credential|private.?key|api.?key|\.pem|\.key|token' CLAUDE.md 2>/dev/null; then
            RULE_SUGGESTIONS+=("file-guard — your CLAUDE.md mentions sensitive files (.env, keys, credentials)")
        fi
    fi

    # Check for git safety rules not covered by git-safe
    if ! has_hook git-safe; then
        if grep -qiE 'force.?push|reset.?--hard|checkout\s*\.|clean\s+-f|branch\s+-[dD]|push.?--delete' CLAUDE.md 2>/dev/null; then
            RULE_SUGGESTIONS+=("git-safe — your CLAUDE.md mentions destructive git operations")
        fi
    fi

    # Check for command safety rules not covered by bash-guard
    if ! has_hook bash-guard; then
        if grep -qiE 'rm\s+-rf|sudo|curl.*bash|drop\s+(table|database)|dangerous|destructive' CLAUDE.md 2>/dev/null; then
            RULE_SUGGESTIONS+=("bash-guard — your CLAUDE.md mentions dangerous commands")
        fi
    fi

    # Check for branch protection rules not covered by branch-guard
    if ! has_hook branch-guard; then
        if grep -qiE 'feature.?branch|never.*commit.*main|no.*direct.*commit|protected.?branch' CLAUDE.md 2>/dev/null; then
            RULE_SUGGESTIONS+=("branch-guard — your CLAUDE.md mentions branch protection")
        fi
    fi

    if [ ${#RULE_SUGGESTIONS[@]} -gt 0 ]; then
        echo ""
        printf "${YELLOW}${BOLD}Rules in CLAUDE.md that could be enforced:${NC}\n"
        for suggestion in "${RULE_SUGGESTIONS[@]}"; do
            printf "  ${YELLOW}→${NC} %s\n" "$suggestion"
        done
        printf "${DIM}  These are advisory until backed by hooks. Install the hooks above or use enforce-hooks.${NC}\n"
    fi
fi

# === Section 8: Hook Health ===
# Verify that registered hooks actually exist and are executable
HOOK_HEALTH_ISSUES=0
HOOK_PATHS=""
if [ -f "$SETTINGS_FILE" ]; then
    HOOK_PATHS=$(python3 - "$SETTINGS_FILE" << 'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        s = json.load(f)
    paths = []
    for hook_type in ["PreToolUse", "PostToolUse", "SessionStart", "SessionEnd"]:
        for entry in s.get("hooks", {}).get(hook_type, []):
            for hook in entry.get("hooks", []):
                cmd = hook.get("command", "")
                if cmd: paths.append(cmd)
            cmd = entry.get("command", "")
            if cmd: paths.append(cmd)
    for p in paths:
        print(p)
except Exception:
    pass
PYEOF
    )

    if [ -n "$HOOK_PATHS" ]; then
        echo ""
        printf "${BLUE}Hook Health${NC}\n"
        while IFS= read -r hook_path; do
            # Expand ~ to HOME
            expanded_path="${hook_path/#\~/$HOME}"
            hook_basename=$(basename "$expanded_path")
            if [ ! -f "$expanded_path" ]; then
                printf "  ${RED}✗${NC} %s — file not found\n" "$hook_basename"
                HOOK_HEALTH_ISSUES=$((HOOK_HEALTH_ISSUES + 1))
            elif [ ! -x "$expanded_path" ]; then
                printf "  ${RED}✗${NC} %s — not executable (run: chmod +x %s)\n" "$hook_basename" "$hook_path"
                HOOK_HEALTH_ISSUES=$((HOOK_HEALTH_ISSUES + 1))
            else
                printf "  ${GREEN}✓${NC} %s\n" "$hook_basename"
            fi
        done <<< "$HOOK_PATHS"
        if [ "$HOOK_HEALTH_ISSUES" -gt 0 ]; then
            ISSUES+=("$HOOK_HEALTH_ISSUES hook(s) are broken (missing or not executable). Hooks that don't exist fail silently.")
        fi
    fi
fi

# === Section 9: Verify Mode — test hooks with real payloads ===
if [ "$VERIFY_MODE" = "1" ] && [ -n "$HOOK_PATHS" ]; then
    echo ""
    printf "${BOLD}Hook Verification${NC} ${DIM}(sending test payloads)${NC}\n"

    VERIFY_PASS=0
    VERIFY_FAIL=0
    VERIFY_SKIP=0
    VERIFY_TOTAL=0

    # Test payloads for known hooks
    BASH_GUARD_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}'
    GIT_SAFE_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}'
    FILE_GUARD_PAYLOAD='{"tool_name":"Write","tool_input":{"file_path":".env","content":"SECRET=exposed"}}'
    BRANCH_GUARD_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"git commit -m test"}}'
    NONMATCH_PAYLOAD='{"tool_name":"Read","tool_input":{"file_path":"README.md"}}'

    verify_hook() {
        local name="$1"
        local hook_cmd="$2"
        local payload="$3"
        local expect_block="$4"  # true = should block, false = should pass, skip = skip

        if [ "$expect_block" = "skip" ]; then
            VERIFY_SKIP=$((VERIFY_SKIP + 1))
            printf "  ${DIM}— %s (skipped, needs runtime state)${NC}\n" "$name"
            return
        fi

        VERIFY_TOTAL=$((VERIFY_TOTAL + 1))

        # Extract the script path from commands like "bash ~/.claude/hooks/foo.sh"
        local script_path=""
        if [[ "$hook_cmd" == bash\ * ]]; then
            script_path="${hook_cmd#bash }"
        elif [[ "$hook_cmd" == python3\ * ]]; then
            script_path="${hook_cmd#python3 }"
        else
            script_path="$hook_cmd"
        fi
        # Expand ~
        script_path="${script_path/#\~/$HOME}"

        if [ ! -f "$script_path" ]; then
            VERIFY_FAIL=$((VERIFY_FAIL + 1))
            printf "  ${RED}✗${NC} %s — script not found: %s\n" "$name" "$script_path"
            return
        fi

        if [ ! -x "$script_path" ] && [[ "$hook_cmd" != bash\ * ]] && [[ "$hook_cmd" != python3\ * ]]; then
            VERIFY_FAIL=$((VERIFY_FAIL + 1))
            printf "  ${RED}✗${NC} %s — not executable\n" "$name"
            return
        fi

        local output=""
        local exit_code=0
        # Run the hook (timeout via background+wait if coreutils timeout unavailable)
        if [[ "$hook_cmd" == bash\ * ]]; then
            output=$(echo "$payload" | bash "$script_path" 2>/dev/null) || exit_code=$?
        elif [[ "$hook_cmd" == python3\ * ]]; then
            output=$(echo "$payload" | python3 "$script_path" 2>/dev/null) || exit_code=$?
        else
            output=$(echo "$payload" | "$script_path" 2>/dev/null) || exit_code=$?
        fi

        if [ "$expect_block" = "true" ]; then
            # Should have blocked — look for "decision":"block" in JSON output
            if [ -n "$output" ] && echo "$output" | grep -qE '"decision"[[:space:]]*:[[:space:]]*"block"'; then
                VERIFY_PASS=$((VERIFY_PASS + 1))
                printf "  ${GREEN}✓${NC} %s — blocks correctly\n" "$name"
            else
                VERIFY_FAIL=$((VERIFY_FAIL + 1))
                printf "  ${RED}✗${NC} %s — did NOT block ${RED}(FAIL-OPEN)${NC}\n" "$name"
                if [ -n "$output" ]; then
                    printf "    ${DIM}Output: %s${NC}\n" "$(echo "$output" | head -1 | cut -c1-80)"
                else
                    printf "    ${DIM}No output (silent fail-open)${NC}\n"
                fi
            fi
        else
            # Should pass through — just verify it doesn't crash
            if [ "$exit_code" -le 1 ]; then
                VERIFY_PASS=$((VERIFY_PASS + 1))
                printf "  ${GREEN}✓${NC} %s — passes safe payload\n" "$name"
            else
                VERIFY_FAIL=$((VERIFY_FAIL + 1))
                printf "  ${RED}✗${NC} %s — crashed on safe payload (exit %d)\n" "$name" "$exit_code"
            fi
        fi
    }

    # For each hook command, identify what it is and test it
    while IFS= read -r hook_cmd; do
        [ -z "$hook_cmd" ] && continue

        if echo "$hook_cmd" | grep -q "bash-guard"; then
            verify_hook "bash-guard blocks rm -rf /" "$hook_cmd" "$BASH_GUARD_PAYLOAD" "true"
            verify_hook "bash-guard passes safe commands" "$hook_cmd" "$NONMATCH_PAYLOAD" "false"
        elif echo "$hook_cmd" | grep -q "git-safe"; then
            verify_hook "git-safe blocks force push" "$hook_cmd" "$GIT_SAFE_PAYLOAD" "true"
            verify_hook "git-safe passes safe commands" "$hook_cmd" "$NONMATCH_PAYLOAD" "false"
        elif echo "$hook_cmd" | grep -q "file-guard"; then
            # file-guard requires a .file-guard config to know what to protect
            if [ -f ".file-guard" ] || [ -n "${FILE_GUARD_CONFIG:-}" ]; then
                verify_hook "file-guard blocks .env write" "$hook_cmd" "$FILE_GUARD_PAYLOAD" "true"
                verify_hook "file-guard passes safe reads" "$hook_cmd" "$NONMATCH_PAYLOAD" "false"
            else
                VERIFY_SKIP=$((VERIFY_SKIP + 1))
                printf "  ${DIM}— file-guard (skipped, no .file-guard config found)${NC}\n"
                printf "    ${DIM}Create .file-guard with paths to protect, e.g.: echo '.env' > .file-guard${NC}\n"
            fi
        elif echo "$hook_cmd" | grep -q "branch-guard"; then
            verify_hook "branch-guard (git state dependent)" "$hook_cmd" "$BRANCH_GUARD_PAYLOAD" "skip"
        elif echo "$hook_cmd" | grep -q "session-log"; then
            verify_hook "session-log accepts payloads" "$hook_cmd" "$NONMATCH_PAYLOAD" "false"
        elif echo "$hook_cmd" | grep -q "read-once"; then
            verify_hook "read-once (session state dependent)" "$hook_cmd" "$NONMATCH_PAYLOAD" "skip"
        elif echo "$hook_cmd" | grep -q "enforce"; then
            verify_hook "enforce-hooks accepts payloads" "$hook_cmd" "$NONMATCH_PAYLOAD" "false"
        else
            # Unknown hook — just test it doesn't crash
            hook_basename=$(basename "$hook_cmd" | head -1)
            verify_hook "$hook_basename accepts payloads" "$hook_cmd" "$NONMATCH_PAYLOAD" "false"
        fi
    done <<< "$HOOK_PATHS"

    # Summary
    echo ""
    if [ "$VERIFY_FAIL" -gt 0 ]; then
        printf "  ${RED}%d/%d hooks FAIL-OPEN${NC}" "$VERIFY_FAIL" "$VERIFY_TOTAL"
        if [ "$VERIFY_SKIP" -gt 0 ]; then
            printf " ${DIM}(%d skipped)${NC}" "$VERIFY_SKIP"
        fi
        echo ""
        ISSUES+=("$VERIFY_FAIL hook(s) did not block when they should have. This means dangerous commands can execute unchecked.")
    else
        printf "  ${GREEN}All %d verified hooks working correctly${NC}" "$VERIFY_PASS"
        if [ "$VERIFY_SKIP" -gt 0 ]; then
            printf " ${DIM}(%d skipped)${NC}" "$VERIFY_SKIP"
        fi
        echo ""
    fi
elif [ "$VERIFY_MODE" = "1" ]; then
    echo ""
    printf "${DIM}No hooks found to verify. Install hooks first.${NC}\n"
fi

# === Results ===
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━"

# Calculate percentage
if [ "$MAX_SCORE" -gt 0 ]; then
    PCT=$((SCORE * 100 / MAX_SCORE))
else
    PCT=0
fi

# Grade
if [ "$PCT" -ge 90 ]; then
    GRADE="A"
    GRADE_COLOR="$GREEN"
    VERDICT="Excellent. Your Claude Code setup is well-protected."
elif [ "$PCT" -ge 70 ]; then
    GRADE="B"
    GRADE_COLOR="$GREEN"
    VERDICT="Good. A few gaps worth addressing."
elif [ "$PCT" -ge 50 ]; then
    GRADE="C"
    GRADE_COLOR="$YELLOW"
    VERDICT="Fair. Several important protections are missing."
elif [ "$PCT" -ge 30 ]; then
    GRADE="D"
    GRADE_COLOR="$RED"
    VERDICT="Poor. Claude has too much unguarded access."
else
    GRADE="F"
    GRADE_COLOR="$RED"
    VERDICT="Unsafe. Claude can do almost anything unchecked."
fi

printf "\n${BOLD}Safety Score: ${GRADE_COLOR}%d/%d (%d%%) — Grade %s${NC}\n" "$SCORE" "$MAX_SCORE" "$PCT" "$GRADE"
printf "%s\n" "$VERDICT"
printf "${DIM}%d/%d checks passed${NC}\n" "$CHECKS_PASSED" "$CHECKS_TOTAL"

# Show issues and fixes
if [ ${#ISSUES[@]} -gt 0 ]; then
    echo ""
    printf "${BOLD}Issues:${NC}\n"
    for issue in "${ISSUES[@]}"; do
        printf "  ${YELLOW}⚠${NC}  %s\n" "$issue"
    done
fi

if [ ${#FIXES[@]} -gt 0 ]; then
    echo ""
    printf "${BOLD}Quick fixes:${NC}\n"
    for fix in "${FIXES[@]}"; do
        if [ -n "$fix" ]; then
            printf "  ${DIM}\$${NC} %s\n" "$fix"
        fi
    done
fi

# Install all suggestion
MISSING=$((CHECKS_TOTAL - CHECKS_PASSED))
if [ "$MISSING" -gt 2 ]; then
    echo ""
    printf "${BOLD}Or install all hooks at once:${NC}\n"
    printf "  ${DIM}\$${NC} curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- all\n"
fi

echo ""
printf "${DIM}https://github.com/Bande-a-Bonnot/Boucle-framework/tree/main/tools${NC}\n"
echo ""
