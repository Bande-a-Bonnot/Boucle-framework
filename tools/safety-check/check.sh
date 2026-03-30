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

# Detect all hooks from both user-level and project-level settings
# User-level: ~/.claude/settings.json
# Project-level: .claude/settings.json (in current directory)
DETECTED_HOOKS=""
PROJECT_SETTINGS=".claude/settings.json"
ALL_HOOK_CMDS=""  # Track all hook commands for inventory
HOOK_SOURCES=""   # Track where hooks come from

detect_hooks_from() {
    local file="$1"
    local source_label="$2"
    [ -f "$file" ] || return 0
    python3 - "$file" "$source_label" << 'PYEOF'
import json, sys
found = set()
all_cmds = []
try:
    with open(sys.argv[1]) as f:
        s = json.load(f)
    source = sys.argv[2]
    needles = ["bash-guard", "bash_guard", "git-safe", "git_safe",
               "file-guard", "file_guard", "branch-guard", "branch_guard",
               "worktree-guard", "worktree_guard",
               "session-log", "session_log", "read-once", "read_once",
               "enforce-hooks", "enforce_hooks"]
    all_hook_types = ["PreToolUse", "PostToolUse", "SessionStart", "SessionEnd",
                      "Stop", "SubagentStop", "TaskCreated", "WorktreeCreate",
                      "WorktreeRemove", "UserPromptSubmit", "Notification"]
    for hook_type in all_hook_types:
        for entry in s.get("hooks", {}).get(hook_type, []):
            cmds = []
            for hook in entry.get("hooks", []):
                cmd = hook.get("command", "")
                if cmd:
                    cmds.append(cmd)
                    all_cmds.append(f"{hook_type}:{source}:{cmd}")
            cmd = entry.get("command", "")
            if cmd:
                cmds.append(cmd)
                all_cmds.append(f"{hook_type}:{source}:{cmd}")
            for cmd in cmds:
                for needle in needles:
                    if needle in cmd:
                        found.add(needle.replace("_", "-"))
    perms = s.get("permissions", {})
    if perms.get("allow", []) or perms.get("deny", []):
        found.add("permissions")
except Exception:
    pass
# Output format: HOOKS:space-separated-hooks\nCMDS:newline-separated-cmds
print("HOOKS:" + " ".join(found))
for c in all_cmds:
    print("CMD:" + c)
PYEOF
}

# Merge hooks from both user and project settings
_merge_hooks() {
    local output=""
    output+=$(detect_hooks_from "$SETTINGS_FILE" "user" 2>/dev/null)
    output+=$'\n'
    output+=$(detect_hooks_from "$PROJECT_SETTINGS" "project" 2>/dev/null)

    local hooks=""
    local cmds=""
    while IFS= read -r line; do
        if [[ "$line" == HOOKS:* ]]; then
            hooks="$hooks ${line#HOOKS:}"
        elif [[ "$line" == CMD:* ]]; then
            cmds="$cmds"$'\n'"${line#CMD:}"
        fi
    done <<< "$output"
    DETECTED_HOOKS="$hooks"
    ALL_HOOK_CMDS="$cmds"
}
_merge_hooks

has_hook() { echo " $DETECTED_HOOKS " | grep -q " $1 "; }

# Check if a specific hook event type (e.g., "Stop") is configured in any settings file
has_hook_type() {
    local event_type="$1"
    for sf in "$SETTINGS_FILE" "$PROJECT_SETTINGS"; do
        [ -f "$sf" ] || continue
        local _hht_result=""
        _hht_result=$(python3 - "$sf" "$event_type" << 'PYEOF_HHT'
import json,sys
try:
    s=json.load(open(sys.argv[1]))
    hooks=s.get('hooks',{}).get(sys.argv[2],[])
    print('yes' if hooks else 'no')
except:
    print('no')
PYEOF_HHT
        ) 2>/dev/null || _hht_result="no"
        if [ "$_hht_result" = "yes" ]; then
            return 0
        fi
    done
    return 1
}

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

# Dependency checks: jq is required by 6 of 8 hooks (bash-guard, git-safe, file-guard, branch-guard, worktree-guard, read-once)
if ! command -v jq >/dev/null 2>&1; then
    WARNINGS+=("jq is not installed. 6 of 8 hooks require jq for JSON parsing and will silently fail without it. Install: brew install jq (macOS), apt install jq (Debian/Ubuntu), or see https://jqlang.github.io/jq/download/")
fi

# python3 check: needed by enforce-hooks, session-log, and safety-check itself
if ! command -v python3 >/dev/null 2>&1; then
    WARNINGS+=("python3 is not installed. enforce-hooks and session-log require python3. Some safety-check features may not work.")
fi

# Platform check: Windows hooks have known reliability issues
if [[ "${OS:-}" == "Windows_NT" ]] || [[ "$(uname -s 2>/dev/null)" == MINGW* ]] || [[ "$(uname -s 2>/dev/null)" == MSYS* ]]; then
    WARNINGS+=("Running on Windows. Claude Code hooks fire only ~18% of the time on Windows (see claude-code#37988). Hooks are unreliable on this platform.")
    WARNINGS+=("Windows: permission path matching in settings.json is case-sensitive, but NTFS is case-insensitive. Deny rules may silently fail if path casing differs from what the model uses. Double-check deny/allow paths match exact casing (see claude-code#40170).")
fi

# CLI version check: warn about known dangerous versions
if command -v claude >/dev/null 2>&1; then
    CLI_VERSION=$(claude --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "")
    if [ -n "$CLI_VERSION" ]; then
        CLI_MINOR=$(echo "$CLI_VERSION" | cut -d. -f3)
        # v2.1.78-2.1.84: permissionDecision from PreToolUse hooks silently ignored (claude-code#37597, fixed upstream)
        if [ "$CLI_MINOR" -ge 78 ] 2>/dev/null && [ "$CLI_MINOR" -le 84 ] 2>/dev/null; then
            WARNINGS+=("Claude CLI v$CLI_VERSION: permissionDecision responses from PreToolUse hooks may be silently ignored (regression v2.1.78-v2.1.84, see claude-code#37597, now fixed upstream). Hooks using decision:block format still work. Update CLI to resolve.")
        fi
        # v2.1.81-2.1.84: crashes when invoked by launchd (claude-code#37878, fixed upstream)
        if [ "$CLI_MINOR" -ge 81 ] 2>/dev/null && [ "$CLI_MINOR" -le 84 ] 2>/dev/null; then
            WARNINGS+=("Claude CLI v$CLI_VERSION: crashes when invoked by launchd/cron (regression v2.1.81-v2.1.84, see claude-code#37878, now fixed upstream). Update CLI to resolve.")
        fi
    fi
fi

# deny rules + denyWrite sandbox conflict (claude-code#38375: bwrap failures on Linux)
if [ -f "$SETTINGS_FILE" ]; then
    DENY_DENYWRITE_CONFLICT=$(python3 - "$SETTINGS_FILE" << 'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        s = json.load(f)
    deny_rules = s.get("permissions", {}).get("deny", [])
    sandbox_deny = s.get("sandbox", {}).get("filesystem", {}).get("denyWrite", [])
    # Check for explicit filepath deny rules (Write/Edit with paths, not Bash commands)
    has_filepath_deny = False
    for rule in deny_rules:
        r = rule if isinstance(rule, str) else ""
        # Only Write/Edit deny rules cause bwrap issues (not Bash command patterns)
        if "(" in r:
            tool_part = r.split("(")[0].strip()
            if tool_part in ("Write", "Edit", "MultiEdit"):
                inner = r.split("(", 1)[1].rstrip(")")
                if inner.startswith("/") or inner.startswith("~"):
                    has_filepath_deny = True
                    break
    if has_filepath_deny and sandbox_deny:
        print("true")
    else:
        print("false")
except Exception:
    print("false")
PYEOF
    )
    if [ "$DENY_DENYWRITE_CONFLICT" = "true" ]; then
        WARNINGS+=("Filepath deny rules combined with sandbox denyWrite can cause ALL Bash calls to fail with bwrap errors. bwrap tries to create dummy files for denied filepaths, which conflicts with denyWrite. Use glob patterns in deny rules instead of exact paths. (see claude-code#38375)")
    fi

    # Path deny rules don't apply to Bash tool (claude-code#39987)
    HAS_PATH_DENY=$(python3 - "$SETTINGS_FILE" << 'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        s = json.load(f)
    deny_rules = s.get("permissions", {}).get("deny", [])
    for rule in deny_rules:
        r = rule if isinstance(rule, str) else ""
        if "(" in r:
            tool_part = r.split("(")[0].strip()
            if tool_part in ("Read", "Write", "Edit", "Glob", "Grep", "MultiEdit"):
                print("true")
                sys.exit(0)
    print("false")
except Exception:
    print("false")
PYEOF
    )
    if [ "$HAS_PATH_DENY" = "true" ] && ! has_hook bash-guard; then
        WARNINGS+=("Path deny rules only apply to file tools (Read/Write/Edit/Glob/Grep), not to Bash. Claude can still cat, grep, or head denied files via shell commands. Install bash-guard to cover Bash tool access, or use OS-level permissions for true isolation. (see claude-code#39987)")
    fi
fi

# bypassPermissions mode instability (claude-code#38372: resets to 'default' in long sessions)
if [ -f "$SETTINGS_FILE" ]; then
    BYPASS_MODE=$(python3 -c "
import json,sys
try:
    s=json.load(open(sys.argv[1]))
    print(s.get('permissions',{}).get('permissionMode',''))
except: print('')
" "$SETTINGS_FILE" 2>/dev/null)
    if [ "$BYPASS_MODE" = "bypassPermissions" ]; then
        WARNINGS+=("permissionMode is set to bypassPermissions. This mode can silently reset to 'default' during long sessions (3+ hours), causing unexpected permission prompts. Consider using PreToolUse hooks for reliable auto-approval instead. (see claude-code#38372)")
    fi
fi

# Write permissions don't work outside project directory (claude-code#38391)
if [ -f "$SETTINGS_FILE" ]; then
    HAS_EXTERNAL_WRITE_ALLOW=$(python3 - "$SETTINGS_FILE" << 'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        s = json.load(f)
    allow_rules = s.get("permissions", {}).get("allow", [])
    for rule in allow_rules:
        r = rule if isinstance(rule, str) else ""
        # Write/Edit with absolute path or home-relative path
        if ("Write(" in r or "Edit(" in r):
            inner = r.split("(", 1)[1].rstrip(")")
            if inner.startswith("/") or inner.startswith("~"):
                print("true")
                sys.exit(0)
    print("false")
except Exception:
    print("false")
PYEOF
    )
    if [ "$HAS_EXTERNAL_WRITE_ALLOW" = "true" ]; then
        WARNINGS+=("Write/Edit allow rules with absolute paths outside the project may not auto-approve as expected. Read permissions work with absolute paths, but Write/Edit do not. Use a PreToolUse hook to auto-approve writes to specific external paths. (see claude-code#38391)")
    fi
fi

# Colon in filenames breaks permission matching (claude-code#38409: Edit/Write prompt despite allow-list)
COLON_FILE=$(find . -maxdepth 5 -name '*:*' -not -path './.git/*' -not -path './node_modules/*' -not -path './.claude/*' -print -quit 2>/dev/null)
if [ -n "$COLON_FILE" ]; then
    WARNINGS+=("Project contains files with colons in filenames (e.g. $(basename "$COLON_FILE")). Claude Code permission matching breaks on paths containing ':' — Edit/Write will prompt for permission even when allowed or in bypassPermissions mode. Workaround: rename to bracket notation (e.g. [id].vue instead of :id.vue) or use a PreToolUse hook to auto-approve. (see claude-code#38409)")
fi

# Hooks using permissionDecision "ask" permanently break bypass mode (claude-code#37420)
HOOK_DIR="${HOME}/.claude/hooks"
if [ -d "$HOOK_DIR" ]; then
    ASK_HOOKS=""
    for hookfile in "$HOOK_DIR"/*; do
        [ -f "$hookfile" ] || continue
        if grep -qlE 'permissionDecision.*ask|"ask".*permissionDecision' "$hookfile" 2>/dev/null; then
            ASK_HOOKS="${ASK_HOOKS} $(basename "$hookfile")"
        fi
    done
    if [ -n "$ASK_HOOKS" ]; then
        WARNINGS+=("Hook(s) use permissionDecision 'ask':${ASK_HOOKS}. This permanently breaks bypass mode for the entire session after the user responds. Use decision:block with a reason instead. (see claude-code#37420)")
    fi
fi
if [ -d ".claude/hooks" ]; then
    ASK_HOOKS=""
    for hookfile in ".claude/hooks"/*; do
        [ -f "$hookfile" ] || continue
        if grep -qlE 'permissionDecision.*ask|"ask".*permissionDecision' "$hookfile" 2>/dev/null; then
            ASK_HOOKS="${ASK_HOOKS} $(basename "$hookfile")"
        fi
    done
    if [ -n "$ASK_HOOKS" ]; then
        WARNINGS+=("Project hook(s) use permissionDecision 'ask':${ASK_HOOKS}. This permanently breaks bypass mode for the entire session. Use decision:block with a reason instead. (see claude-code#37420)")
    fi
fi

# Hooks using exit code 2 for deny may be silently ignored (claude-code#37210)
# Exit 2 can be treated as a hook crash, causing Claude to proceed despite the deny.
# Correct pattern: exit 0 with {"decision":"block","reason":"..."} JSON on stdout.
for hookdir in "${HOME}/.claude/hooks" ".claude/hooks"; do
    [ -d "$hookdir" ] || continue
    EXIT2_HOOKS=""
    for hookfile in "$hookdir"/*; do
        [ -f "$hookfile" ] || continue
        if grep -qlE 'exit\s+2' "$hookfile" 2>/dev/null; then
            EXIT2_HOOKS="${EXIT2_HOOKS} $(basename "$hookfile")"
        fi
    done
    if [ -n "$EXIT2_HOOKS" ]; then
        scope="Hook(s)"
        [ "$hookdir" = ".claude/hooks" ] && scope="Project hook(s)"
        WARNINGS+=("${scope} use exit code 2 for deny:${EXIT2_HOOKS}. Exit 2 is treated as a hook crash and may be silently ignored, especially for Edit/Write tools. Use exit 0 with {\"decision\":\"block\",\"reason\":\"...\"} JSON on stdout instead. (see claude-code#37210)")
    fi
done

# Spaces in working directory path break hooks (claude-code#39478)
case "$PWD" in
    *" "*)
        WARNINGS+=("Working directory contains spaces: $PWD. Claude Code may pass unquoted paths to hooks, causing parse errors. Move your project to a path without spaces if hooks misbehave. (see claude-code#39478)")
        ;;
esac

# Spaces in HOME path break hook command invocation (claude-code#40084)
# When the user profile path contains spaces (e.g. /Users/Lea Chan/), hook commands
# that reference $HOME or CLAUDE_PLUGIN_ROOT get word-split by bash, causing:
#   bash: /c/Users/Lea: No such file or directory
# This affects ALL hooks — both plugin hooks and settings.json hooks.
case "$HOME" in
    *" "*)
        WARNINGS+=("Home directory contains spaces: $HOME. Hook commands that include your home path will fail because Claude Code's hook runner word-splits the path at spaces. Affected: all hooks in ~/.claude/. Workaround: create a symlink from a space-free path (e.g. ln -s \"$HOME\" /opt/claude-home) and update hook command paths, or use PowerShell hooks on Windows. (see claude-code#40084)")
        ;;
esac

# Stop hooks blocking parallel sessions (claude-code#39530)
for _stop_cfg in "$SETTINGS_FILE" "$PROJECT_SETTINGS"; do
    [ -f "$_stop_cfg" ] || continue
    _HAS_STOP=$(python3 -c "
import json,sys
try:
    s=json.load(open(sys.argv[1]))
    stops = s.get('hooks',{}).get('PostToolUse',[]) + s.get('hooks',{}).get('SessionEnd',[])
    print('true' if stops else 'false')
except: print('false')
" "$_stop_cfg" 2>/dev/null)
    if [ "$_HAS_STOP" = "true" ]; then
        WARNINGS+=("Stop/PostToolUse hooks detected. Stop hooks fire across ALL parallel Claude sessions sharing this settings file, not just the session that triggered them. If you run multiple Claude instances, a stop hook from one session can affect others. Use separate project directories or check \$CLAUDE_SESSION_ID in your hook. (see claude-code#39530)")
        break
    fi
done

# Hooks using updatedInput with Agent tool (claude-code#39814)
for hookdir in "${HOME}/.claude/hooks" ".claude/hooks"; do
    [ -d "$hookdir" ] || continue
    UPDATEDINPUT_HOOKS=""
    for hookfile in "$hookdir"/*; do
        [ -f "$hookfile" ] || continue
        if grep -qlE 'updatedInput' "$hookfile" 2>/dev/null; then
            UPDATEDINPUT_HOOKS="${UPDATEDINPUT_HOOKS} $(basename "$hookfile")"
        fi
    done
    if [ -n "$UPDATEDINPUT_HOOKS" ]; then
        scope="Hook(s)"
        [ "$hookdir" = ".claude/hooks" ] && scope="Project hook(s)"
        WARNINGS+=("${scope} use updatedInput:${UPDATEDINPUT_HOOKS}. The updatedInput field is silently ignored for Agent tool calls — the original prompt is used instead. Use decision:block to reject unsafe Agent prompts rather than trying to rewrite them. (see claude-code#39814)")
    fi
done

# Worktree isolation silent failure warning (claude-code#39886)
if has_hook worktree-guard; then
    WARNINGS+=("Worktree isolation can silently fail. The Agent tool's isolation:worktree option may run the agent in the main repo instead of a worktree, with worktreePath:done and worktreeBranch:undefined. worktree-guard protects ExitWorktree but cannot detect failed worktree creation. Verify agent results if you rely on branch isolation. (see claude-code#39886)")
fi

# Hook stdout corrupts worktree paths (claude-code#40262)
# Any hook returning JSON on stdout can corrupt the worktree path when Agent uses isolation:"worktree".
# The JSON gets concatenated into the path instead of being consumed by the hook protocol.
HOOK_COUNT=0
for hookdir in "${HOME}/.claude/hooks" ".claude/hooks"; do
    [ -d "$hookdir" ] || continue
    for hookfile in "$hookdir"/*; do
        [ -f "$hookfile" ] && HOOK_COUNT=$((HOOK_COUNT + 1))
    done
done
# Also count hooks from settings.json
if [ -f "$SETTINGS_FILE" ]; then
    SETTINGS_HOOK_COUNT=$(python3 -c "
import json,sys
try:
    s=json.load(open(sys.argv[1]))
    c=0
    for ht in s.get('hooks',{}):
        for entry in s['hooks'][ht]:
            for h in entry.get('hooks',[]):
                if h.get('command',''): c+=1
            if entry.get('command',''): c+=1
    print(c)
except: print(0)
" "$SETTINGS_FILE" 2>/dev/null)
    HOOK_COUNT=$((HOOK_COUNT + ${SETTINGS_HOOK_COUNT:-0}))
fi
if [ "$HOOK_COUNT" -gt 0 ]; then
    WARNINGS+=("Hooks and worktree isolation are incompatible on v2.1.86+. Hook stdout JSON is concatenated into the worktree path instead of being consumed by the hook protocol, producing paths like /project/{\"continue\":true}. If you spawn agents with isolation:worktree, expect Path does not exist errors. No workaround except disabling hooks before worktree agent calls. (see claude-code#40262)")
    WARNINGS+=("Hook enforcement does not work in subagents. PreToolUse hooks fire inside Agent-spawned subagents, but the exit code and block decision are silently ignored. A command blocked in the parent session will succeed in a subagent. All hook-based enforcement is parent-session-only. There is no workaround. (see claude-code#40580)")
fi

# additionalDirectories leak across projects (claude-code#40606)
if [ -f "$SETTINGS_FILE" ]; then
    ADDITIONAL_DIRS=$(python3 -c "
import json,sys
try:
    s=json.load(open(sys.argv[1]))
    dirs=s.get('additionalDirectories',[])
    if dirs: print('\n'.join(dirs))
except: pass
" "$SETTINGS_FILE" 2>/dev/null)
    if [ -n "$ADDITIONAL_DIRS" ]; then
        DIR_COUNT=$(echo "$ADDITIONAL_DIRS" | wc -l | tr -d ' ')
        WARNINGS+=("Global settings.json contains ${DIR_COUNT} additionalDirectories entry/entries. These directories are shared across ALL projects — approving file access outside the working directory in one project makes those paths available in every other project, and subagents will search them. Review and remove entries not needed for the current project. (see claude-code#40606)")
    fi
fi

# Glob-special characters in project path break Read permissions (claude-code#40613)
CURRENT_DIR="$(pwd)"
if echo "$CURRENT_DIR" | grep -qE '[{}]' || echo "$CURRENT_DIR" | grep -q '\[' || echo "$CURRENT_DIR" | grep -q '\]'; then
    WARNINGS+=("Your project path contains glob metacharacters ({, }, [, or ]). Claude Code's Read permission matching interprets these as glob patterns instead of literal characters, causing permission failures. Rename the directory to remove these characters. PreToolUse hooks use exact string matching and are unaffected. (see claude-code#40613)")
fi

# Plan mode does not deactivate bypass permissions (claude-code#40623)
if [ -f "$SETTINGS_FILE" ]; then
    HAS_BYPASS=$(python3 -c "
import json,sys
try:
    s=json.load(open(sys.argv[1]))
    if s.get('bypassPermissions'): print('yes')
except: pass
" "$SETTINGS_FILE" 2>/dev/null)
    if [ "$HAS_BYPASS" = "yes" ]; then
        WARNINGS+=("bypassPermissions is enabled globally. Note: entering plan mode does NOT deactivate bypass permissions — the model can execute write operations during what you expect to be a read-only analysis phase. PreToolUse hooks fire regardless of both modes and are the only reliable constraint during plan+bypass overlap. (see claude-code#40623)")
    fi
fi

# Non-enabled marketplace plugins still fire hooks (claude-code#40013)
# Installed-but-not-enabled plugins have their hooks loaded and executed anyway.
MARKETPLACE_DIR="${HOME}/.claude/plugins/marketplaces"
if [ -d "$MARKETPLACE_DIR" ]; then
    ORPHAN_PLUGINS=""
    ENABLED_PLUGINS=$(python3 -c "
import json,sys,os
try:
    sf = os.path.expanduser('~/.claude/settings.json')
    s = json.load(open(sf))
    for p in s.get('enabledPlugins', []):
        print(p.split('/')[-1] if '/' in p else p)
except: pass
" 2>/dev/null)
    for plugin_dir in "$MARKETPLACE_DIR"/*/plugins/*/; do
        [ -d "$plugin_dir" ] || continue
        plugin_name=$(basename "$plugin_dir")
        if ! echo "$ENABLED_PLUGINS" | grep -qF "$plugin_name" 2>/dev/null; then
            # Check if it actually has hooks
            if [ -d "${plugin_dir}hooks" ] || ls "${plugin_dir}"*.sh >/dev/null 2>&1; then
                ORPHAN_PLUGINS="${ORPHAN_PLUGINS} ${plugin_name}"
            fi
        fi
    done
    if [ -n "$ORPHAN_PLUGINS" ]; then
        WARNINGS+=("Non-enabled marketplace plugins with hooks detected:${ORPHAN_PLUGINS}. These plugins are NOT in your enabledPlugins list but their hooks still fire on every session. Remove unwanted plugin directories from ${MARKETPLACE_DIR} to prevent unauthorized hook execution. (see claude-code#40013)")
    fi

    # Marketplace plugins with hooks installed silently (claude-code#40036)
    # Even enabled plugins may have hooks the user never consented to.
    PLUGINS_WITH_HOOKS=""
    for plugin_dir in "$MARKETPLACE_DIR"/*/plugins/*/; do
        [ -d "$plugin_dir" ] || continue
        plugin_name=$(basename "$plugin_dir")
        if [ -d "${plugin_dir}hooks" ]; then
            # Count hook files
            hook_count=$(find "${plugin_dir}hooks" -type f 2>/dev/null | wc -l | tr -d ' ')
            if [ "$hook_count" -gt 0 ]; then
                PLUGINS_WITH_HOOKS="${PLUGINS_WITH_HOOKS} ${plugin_name}(${hook_count} hooks)"
            fi
        fi
    done
    if [ -n "$PLUGINS_WITH_HOOKS" ]; then
        WARNINGS+=("Marketplace plugins with executable hooks:${PLUGINS_WITH_HOOKS}. The /plugin install flow does not disclose that these plugins include hooks. These hooks run on every session with your full user privileges and no consent prompt. Inspect hook contents: ls ~/.claude/plugins/marketplaces/*/plugins/*/hooks/ (see claude-code#40036)")
    fi
fi

# Stop hooks do not fire in VSCode extension (claude-code#40029)
if has_hook_type "Stop"; then
    WARNINGS+=("Stop hooks are configured but do not fire in the VSCode extension. If you use Claude Code in VSCode, your Stop hooks are silently skipped. PreToolUse, PostToolUse, and SessionStart hooks work in both CLI and VSCode. (see claude-code#40029)")
fi

# UserPromptSubmit hooks can silently fail to deliver systemMessage (claude-code#40647)
if has_hook_type "UserPromptSubmit"; then
    WARNINGS+=("UserPromptSubmit hooks are configured but their systemMessage delivery is intermittently unreliable. The hook command fires and returns valid JSON, but the injected systemMessage may not reach the model. For safety enforcement, prefer PreToolUse hooks which gate on the decision field rather than systemMessage injection. (see claude-code#40647)")
fi

# Stop hooks receive stale transcript data (claude-code#40655)
if has_hook_type "Stop"; then
    WARNINGS+=("Stop hooks fire before the transcript JSONL file is fully flushed to disk. Any Stop hook that reads the transcript to inspect the assistant's last output will see stale data missing the final content blocks (15-44ms race window, 64% failure rate measured). This affects completion detection, audit logging, and post-session analysis. No reliable workaround exists. (see claude-code#40655)")
fi

# WorktreeCreate/WorktreeRemove hooks ignored by EnterWorktree tool (claude-code#36205)
if has_hook_type "WorktreeCreate" || has_hook_type "WorktreeRemove"; then
    WARNINGS+=("WorktreeCreate/WorktreeRemove hooks are configured but the EnterWorktree tool does not fire them. Worktree hooks only fire when worktree isolation is triggered by the system (background agents), not when the model explicitly calls EnterWorktree. Custom VCS setup in worktree hooks may not execute. (see claude-code#36205)")
fi

# TaskCreated hooks — available since v2.1.84
if has_hook_type "TaskCreated"; then
    WARNINGS+=("TaskCreated hooks are configured. These fire when a task is created via TaskCreate. Note: TaskCreated hooks cannot block task creation (decision field is ignored). They are observe-only, useful for logging or notifications but not enforcement.")
fi

# SubagentStop hooks — subagent-scoped lifecycle
if has_hook_type "SubagentStop"; then
    WARNINGS+=("SubagentStop hooks are configured. These fire when a spawned subagent completes, providing the last_assistant_message field. Note: background agents may not inherit all hook configurations from the parent session. (see claude-code#40818)")
fi

# PreToolUse hooks on EnterPlanMode — hook output deprioritized (claude-code#41051)
_check_planmode_matcher() {
    local sf="$1"
    [ -f "$sf" ] || return 1
    python3 - "$sf" << 'PYEOF_PM'
import json,sys
try:
    s=json.load(open(sys.argv[1]))
    found = False
    for entry in s.get('hooks',{}).get('PreToolUse',[]):
        m = entry.get('matcher','')
        if 'EnterPlanMode' in m:
            found = True
            break
    print('yes' if found else 'no')
except Exception:
    print('no')
PYEOF_PM
}
for sf in "$SETTINGS_FILE" "$PROJECT_SETTINGS"; do
    _PM_RESULT=$(_check_planmode_matcher "$sf" 2>/dev/null) || _PM_RESULT="no"
    if [ "$_PM_RESULT" = "yes" ]; then
        WARNINGS+=("PreToolUse hook targets EnterPlanMode. Hook output injected via system-reminder is deprioritized by plan mode's own detailed system prompt, which arrives in the same turn. The model will follow plan mode's Phase 1-5 workflow and ignore the hook's instructions. Use decision:block to gate entry, or move logic to a separate event. (see claude-code#41051)")
        break
    fi
done

# bypassPermissions in settings.local.json is silently ignored (claude-code#40014)
SETTINGS_LOCAL="${HOME}/.claude/settings.local.json"
[ ! -f "$SETTINGS_LOCAL" ] && SETTINGS_LOCAL=".claude/settings.local.json"
if [ -f "$SETTINGS_LOCAL" ]; then
    HAS_BYPASS_LOCAL=$(python3 -c "
import json,sys
try:
    s=json.load(open(sys.argv[1]))
    pm = s.get('permission-mode','') or s.get('permissions',{}).get('permissionMode','') or s.get('permissions',{}).get('dangerouslySkipPermissions','')
    if pm: print('true')
    else: print('false')
except: print('false')
" "$SETTINGS_LOCAL" 2>/dev/null)
    if [ "$HAS_BYPASS_LOCAL" = "true" ]; then
        WARNINGS+=("settings.local.json sets permission/bypass configuration, but these settings are silently ignored. The only working method to enable bypass mode is the CLI flag --dangerously-skip-permissions. Remove the setting to avoid confusion. (see claude-code#40014)")
    fi
fi

# Sandbox allowedDomains HTTP bypass (claude-code#40213)
# allowedDomains only filters HTTPS CONNECT — plain HTTP passes through unfiltered.
if [ -f "$SETTINGS_FILE" ]; then
    HAS_ALLOWED_DOMAINS=$(python3 - "$SETTINGS_FILE" << 'PYEOF_AD'
import json, sys
try:
    s = json.load(open(sys.argv[1]))
    sandbox = s.get("sandbox", {})
    network = sandbox.get("network", {})
    domains = network.get("allowedDomains", [])
    if domains:
        print("true")
    else:
        print("false")
except:
    print("false")
PYEOF_AD
    )
    if [ "$HAS_ALLOWED_DOMAINS" = "true" ]; then
        WARNINGS+=("sandbox.network.allowedDomains is configured but only filters HTTPS traffic. Plain HTTP requests (curl http://...) bypass domain filtering entirely. A prompt injection payload can exfiltrate data over HTTP even with allowedDomains set. Use bash-guard to detect outbound HTTP requests, or configure OS-level firewall rules for defense in depth. (see claude-code#40213)")
    fi
fi

# Supply-chain: detect suspicious project-level .claude/settings.json (claude-code#38319)
# A malicious repo can include .claude/settings.json that adds hooks or loosens permissions.
# Project settings merge with user settings — they can ADD hooks and allow rules.
if [ -f "$PROJECT_SETTINGS" ]; then
    SUPPLY_CHAIN_FLAGS=$(python3 - "$PROJECT_SETTINGS" << 'PYEOF_SC'
import json, sys, re
flags = []
try:
    with open(sys.argv[1]) as f:
        s = json.load(f)
    perms = s.get("permissions", {})
    # Flag 1: Project sets bypassPermissions
    if perms.get("permissionMode") == "bypassPermissions":
        flags.append("sets permissionMode to bypassPermissions (all tool calls auto-approved)")
    # Flag 2: Overly broad allow rules
    for rule in perms.get("allow", []):
        r = rule if isinstance(rule, str) else ""
        if r in ("Bash", "Bash(*)", "Bash(**)", "*"):
            flags.append(f"allow rule '{r}' permits all Bash commands")
        elif re.search(r'sudo|rm\s+-rf|curl.*\|.*bash|wget.*\|.*bash|chmod\s+777|mkfs|dd\s+if=', r, re.I):
            flags.append(f"allow rule contains dangerous command: {r[:60]}")
    # Flag 3: Project spoofs companyAnnouncements (claude-code#39998)
    announcements = s.get("companyAnnouncements")
    if announcements:
        flags.append(f"sets companyAnnouncements — messages will appear as if from your company (social engineering risk)")
    # Flag 4: Project hooks that reference external URLs or suspicious commands
    all_hook_types = ["PreToolUse", "PostToolUse", "SessionStart", "SessionEnd",
                      "Stop", "SubagentStop", "TaskCreated", "WorktreeCreate",
                      "WorktreeRemove", "UserPromptSubmit", "Notification"]
    for hook_type in all_hook_types:
        for entry in s.get("hooks", {}).get(hook_type, []):
            cmds = []
            for hook in entry.get("hooks", []):
                cmd = hook.get("command", "")
                if cmd: cmds.append(cmd)
            cmd = entry.get("command", "")
            if cmd: cmds.append(cmd)
            for cmd in cmds:
                if re.search(r'https?://', cmd):
                    flags.append(f"project hook contacts external URL: {cmd[:80]}")
                if re.search(r'base64\s+-d|eval\s|python.*-c|node\s+-e', cmd):
                    flags.append(f"project hook runs inline code: {cmd[:80]}")
except Exception:
    pass
for f in flags:
    print(f)
PYEOF_SC
    )
    if [ -n "$SUPPLY_CHAIN_FLAGS" ]; then
        WARNINGS+=("PROJECT SUPPLY-CHAIN RISK: This repo contains .claude/settings.json with suspicious entries:")
        while IFS= read -r flag; do
            [ -z "$flag" ] && continue
            WARNINGS+=("  -> $flag")
        done <<< "$SUPPLY_CHAIN_FLAGS"
        WARNINGS+=("Review .claude/settings.json carefully. Project settings merge with your user settings and can add hooks or allow rules. (see claude-code#38319)")
    fi
fi

# Hooks using bare "decision":"warn" without hookSpecificOutput are silently dropped (claude-code#40380)
for hookdir in "${HOME}/.claude/hooks" ".claude/hooks"; do
    [ -d "$hookdir" ] || continue
    WARN_HOOKS=""
    for hookfile in "$hookdir"/*; do
        [ -f "$hookfile" ] || continue
        # Detect hooks that output decision:warn but don't use hookSpecificOutput
        if grep -qlE '"decision".*"warn"|"warn".*"decision"' "$hookfile" 2>/dev/null; then
            if ! grep -qlE 'hookSpecificOutput' "$hookfile" 2>/dev/null; then
                WARN_HOOKS="${WARN_HOOKS} $(basename "$hookfile")"
            fi
        fi
    done
    if [ -n "$WARN_HOOKS" ]; then
        scope="Hook(s)"
        [ "$hookdir" = ".claude/hooks" ] && scope="Project hook(s)"
        WARNINGS+=("${scope} use bare decision:warn without hookSpecificOutput:${WARN_HOOKS}. Warn-level hook responses without hookSpecificOutput are silently dropped — neither the user nor the model sees the warning. Use hookSpecificOutput with permissionDecision:allow and additionalContext instead. (see claude-code#40380)")
    fi
done
# Also check settings.json hook commands for the same pattern
for _cfg in "$SETTINGS_FILE" "$PROJECT_SETTINGS"; do
    [ -f "$_cfg" ] || continue
    _BARE_WARN=$(python3 - "$_cfg" << 'PYEOF_WARN'
import json, sys, re
try:
    s = json.load(open(sys.argv[1]))
    hooks = s.get("hooks", {})
    for hook_type in hooks:
        for entry in hooks[hook_type]:
            cmd = ""
            for h in entry.get("hooks", []):
                cmd += h.get("command", "") + " "
            cmd += entry.get("command", "")
            if re.search(r'"decision".*"warn"|"warn".*"decision"', cmd):
                if "hookSpecificOutput" not in cmd:
                    print("true")
                    sys.exit(0)
    print("false")
except:
    print("false")
PYEOF_WARN
    )
    if [ "$_BARE_WARN" = "true" ]; then
        WARNINGS+=("Settings hook commands reference decision:warn without hookSpecificOutput. Warn-level responses are silently dropped. Use hookSpecificOutput with permissionDecision:allow and additionalContext to surface warnings to the model. (see claude-code#40380)")
        break
    fi
done

# Session-level permission caching bypasses allow list in sandbox mode (claude-code#40384)
# Approving one git commit auto-approves ALL subsequent git commits without prompting.
if [ -f "$SETTINGS_FILE" ]; then
    _HAS_SANDBOX=$(python3 -c "
import json,sys
try:
    s=json.load(open(sys.argv[1]))
    print('true' if s.get('sandbox',{}).get('enabled') else 'false')
except: print('false')
" "$SETTINGS_FILE" 2>/dev/null)
    if [ "$_HAS_SANDBOX" = "true" ]; then
        WARNINGS+=("Sandbox mode enabled. Session-level permission caching may bypass your allow list: approving one 'git commit' auto-approves ALL subsequent 'git commit' calls without re-prompting. If you expect per-invocation prompts for sensitive commands, use a PreToolUse hook to enforce them. (see claude-code#40384)")
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

check "worktree-guard (prevents data loss on worktree exit)" 10 \
    "$(has_hook worktree-guard && echo true || echo false)" \
    "No worktree-guard: exiting a worktree silently deletes branches with unmerged commits (anthropics/claude-code#38287)" \
    "curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/worktree-guard/install.sh | bash"

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

# Warn if deny rules exist without bash-guard: deny rules only match the first
# line/command, so multi-line scripts and compound commands bypass them entirely.
# See: claude-code#38119, claude-code#37662
if has_hook permissions && ! has_hook bash-guard; then
    HAS_DENY=false
    if [ -f "$SETTINGS_FILE" ]; then
        HAS_DENY=$(python3 -c "
import json,sys
try:
    s=json.load(open(sys.argv[1]))
    d=s.get('permissions',{}).get('deny',[])
    print('true' if d else 'false')
except: print('false')
" "$SETTINGS_FILE" 2>/dev/null)
    fi
    if [ "$HAS_DENY" = "true" ]; then
        printf "\n  ${YELLOW}⚠${NC}  Deny rules alone are bypassable: multi-line commands, compound\n"
        printf "     statements (cmd1 && cmd2), and leading comments bypass pattern matching.\n"
        printf "     bash-guard inspects full command content and catches these cases.\n"
        printf "     ${DIM}See: claude-code#38119, claude-code#37662${NC}\n"
        ISSUES+=("Deny rules without bash-guard: deny patterns only match the first line/command. Multi-line scripts (# comment + rm -rf /), compound commands (echo ok && rm -rf /), and other bypass techniques are not caught. bash-guard provides deterministic full-content analysis.")
    fi
fi

# Glob wildcard injection in allow rules (claude-code#40344)
# Allow rules with * match across shell operators (&&, ;, ||, |), enabling command injection
if has_hook permissions; then
    GLOB_INJECTION_RULES=$(python3 - "$SETTINGS_FILE" << 'PYEOF_GLOB'
import json, sys, re
try:
    with open(sys.argv[1]) as f:
        s = json.load(f)
    allow_rules = s.get("permissions", {}).get("allow", [])
    flagged = []
    for rule in allow_rules:
        r = rule if isinstance(rule, str) else ""
        # Flag Bash allow rules containing * wildcards
        if r.startswith("Bash(") and "*" in r:
            flagged.append(r)
    for r in flagged:
        print(r)
except Exception:
    pass
PYEOF_GLOB
    )
    if [ -n "$GLOB_INJECTION_RULES" ]; then
        printf "\n  ${RED}⚠${NC}  ${BOLD}SECURITY: Glob wildcards in Bash allow rules enable command injection${NC}\n"
        printf "     The * wildcard matches shell operators (&&, ;, ||, |), so an allow\n"
        printf "     rule like Bash(git -C * status) also silently allows:\n"
        printf "       git -C /repo && rm -rf / && git status\n"
        printf "     Affected rules:\n"
        while IFS= read -r rule; do
            [ -z "$rule" ] && continue
            printf "       ${RED}→${NC} %s\n" "$rule"
        done <<< "$GLOB_INJECTION_RULES"
        printf "     Fix: use a PreToolUse hook to parse commands structurally instead\n"
        printf "     of relying on glob-based allow rules.\n"
        printf "     ${DIM}See: claude-code#40344${NC}\n"
        ISSUES+=("SECURITY: Bash allow rules with * wildcards are vulnerable to command injection. The * matches across shell operators (&&, ;, |), so any command containing the allowed prefix can chain arbitrary commands. Use PreToolUse hooks (like bash-guard) for structural command validation instead of glob-based allow rules.")
    fi
fi

# bypassPermissions on agents ignores project allowlist (claude-code#40343)
if [ -f "$SETTINGS_FILE" ]; then
    HAS_BYPASS_AGENTS=$(python3 - "$SETTINGS_FILE" << 'PYEOF_BPA'
import json, sys
try:
    with open(sys.argv[1]) as f:
        s = json.load(f)
    agents = s.get("agents", {})
    for name, config in agents.items():
        if isinstance(config, dict) and config.get("mode") == "bypassPermissions":
            print(name)
except Exception:
    pass
PYEOF_BPA
    )
    if [ -n "$HAS_BYPASS_AGENTS" ]; then
        printf "\n  ${YELLOW}⚠${NC}  Agents with bypassPermissions ignore project-level allowlists entirely.\n"
        printf "     These agents can execute any tool (Write, Edit, rm, git) with no checks:\n"
        while IFS= read -r agent_name; do
            [ -z "$agent_name" ] && continue
            printf "       ${YELLOW}→${NC} %s\n" "$agent_name"
        done <<< "$HAS_BYPASS_AGENTS"
        printf "     bypassPermissions skips per-tool prompts AND the project allowlist.\n"
        printf "     Use PreToolUse hooks for enforcement that cannot be bypassed by agent mode.\n"
        printf "     ${DIM}See: claude-code#40343${NC}\n"
    fi
fi

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

    # Check for worktree safety rules not covered by worktree-guard
    if ! has_hook worktree-guard; then
        if grep -qiE 'worktree|merge.*before.*exit|push.*before.*exit|unmerged.*commit' CLAUDE.md 2>/dev/null; then
            RULE_SUGGESTIONS+=("worktree-guard — your CLAUDE.md mentions worktree safety")
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

# === Section 8a: Hook Inventory ===
# Show all registered hooks, both from Boucle-framework and custom/third-party
KNOWN_HOOKS="bash-guard git-safe file-guard branch-guard worktree-guard session-log read-once enforce-hooks enforce"
CUSTOM_HOOKS=()
TOTAL_HOOKS=0
BOUCLE_HOOKS=0

if [ -n "$ALL_HOOK_CMDS" ]; then
    while IFS= read -r cmd_entry; do
        [ -z "$cmd_entry" ] && continue
        TOTAL_HOOKS=$((TOTAL_HOOKS + 1))
        # Check if this is a known Boucle-framework hook
        is_known=false
        for known in $KNOWN_HOOKS; do
            if echo "$cmd_entry" | grep -q "$known"; then
                is_known=true
                BOUCLE_HOOKS=$((BOUCLE_HOOKS + 1))
                break
            fi
        done
        if [ "$is_known" = "false" ]; then
            # Extract just the command part (after hook_type:source:)
            cmd_part="${cmd_entry#*:*:}"
            hook_basename=$(basename "$cmd_part" | head -c 50)
            hook_type="${cmd_entry%%:*}"
            CUSTOM_HOOKS+=("$hook_type: $hook_basename")
        fi
    done <<< "$ALL_HOOK_CMDS"

    if [ ${#CUSTOM_HOOKS[@]} -gt 0 ]; then
        echo ""
        printf "${BLUE}Hook Inventory${NC}\n"
        printf "  %d hook(s) registered" "$TOTAL_HOOKS"
        if [ "$BOUCLE_HOOKS" -gt 0 ]; then
            printf " (%d Boucle-framework" "$BOUCLE_HOOKS"
            printf ", %d custom/third-party)\n" "${#CUSTOM_HOOKS[@]}"
        else
            printf " (all custom/third-party)\n"
        fi
        for custom in "${CUSTOM_HOOKS[@]}"; do
            printf "  ${DIM}%s${NC}\n" "$custom"
        done
    fi
fi

# === Section 8b: Hook Health ===
# Verify that registered hooks actually exist and are executable
HOOK_HEALTH_ISSUES=0
HOOK_PATHS=""

# Collect hook paths from both user and project settings
_extract_hook_paths() {
    local file="$1"
    [ -f "$file" ] || return 0
    python3 - "$file" << 'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        s = json.load(f)
    all_hook_types = ["PreToolUse", "PostToolUse", "SessionStart", "SessionEnd",
                      "Stop", "SubagentStop", "TaskCreated", "WorktreeCreate",
                      "WorktreeRemove", "UserPromptSubmit", "Notification"]
    for hook_type in all_hook_types:
        for entry in s.get("hooks", {}).get(hook_type, []):
            for hook in entry.get("hooks", []):
                cmd = hook.get("command", "")
                if cmd: print(cmd)
            cmd = entry.get("command", "")
            if cmd: print(cmd)
except Exception:
    pass
PYEOF
}

HOOK_PATHS=$(_extract_hook_paths "$SETTINGS_FILE" 2>/dev/null)
if [ -f "$PROJECT_SETTINGS" ]; then
    PROJECT_HOOK_PATHS=$(_extract_hook_paths "$PROJECT_SETTINGS" 2>/dev/null)
    if [ -n "$PROJECT_HOOK_PATHS" ]; then
        if [ -n "$HOOK_PATHS" ]; then
            HOOK_PATHS="$HOOK_PATHS"$'\n'"$PROJECT_HOOK_PATHS"
        else
            HOOK_PATHS="$PROJECT_HOOK_PATHS"
        fi
    fi
fi

# Deduplicate hook paths (same hook in user+project = show once)
if [ -n "$HOOK_PATHS" ]; then
    HOOK_PATHS=$(echo "$HOOK_PATHS" | sort -u)
fi

if [ -n "$HOOK_PATHS" ]; then
    echo ""
    printf "${BLUE}Hook Health${NC}\n"
    while IFS= read -r hook_path; do
        [ -z "$hook_path" ] && continue
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
        elif echo "$hook_cmd" | grep -q "worktree-guard"; then
            verify_hook "worktree-guard (git state dependent)" "$hook_cmd" "$NONMATCH_PAYLOAD" "skip"
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
