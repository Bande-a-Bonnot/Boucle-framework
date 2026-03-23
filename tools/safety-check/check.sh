#!/usr/bin/env bash
# Claude Code Safety Check
# Run: curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash
#
# Audits your Claude Code setup and scores it for safety.
# No installation, no dependencies — just information.

set -euo pipefail

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
               "session-log", "session_log", "read-once", "read_once"]
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

# JSONC check: settings.json with comments silently breaks hook loading
if [ -f "$SETTINGS_FILE" ]; then
    if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$SETTINGS_FILE" 2>/dev/null; then
        WARNINGS+=("settings.json contains JSONC comments or invalid JSON. Hooks may not load. Run any hook installer to auto-fix, or remove // and /* */ comments manually (see claude-code#37540)")
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

# === Section 7: Hook Health ===
# Verify that registered hooks actually exist and are executable
HOOK_HEALTH_ISSUES=0
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
