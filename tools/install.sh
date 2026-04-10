#!/bin/bash
# Boucle hooks installer — discover and install Claude Code hooks
# Usage: curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash
# Or:    curl ... | bash -s -- recommended
# Or:    curl ... | bash -s -- read-once file-guard git-safe
# Or:    curl ... | bash -s -- list
# Or:    curl ... | bash -s -- verify
# Or:    curl ... | bash -s -- upgrade
# Or:    curl ... | bash -s -- uninstall read-once
# Or:    curl ... | bash -s -- uninstall all
# Or:    curl ... | bash -s -- backup
# Or:    curl ... | bash -s -- backup list
# Or:    curl ... | bash -s -- restore
# Or:    curl ... | bash -s -- restore <file>
# Or:    curl ... | bash -s -- help
set -euo pipefail

REPO="https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools"
SETTINGS="${HOME}/.claude/settings.json"

# Colors (if terminal supports them)
if [ -t 1 ]; then
  BOLD='\033[1m'
  DIM='\033[2m'
  GREEN='\033[32m'
  YELLOW='\033[33m'
  CYAN='\033[36m'
  RESET='\033[0m'
else
  BOLD=''
  DIM=''
  GREEN=''
  YELLOW=''
  CYAN=''
  RESET=''
fi

echo ""
echo -e "${BOLD}Boucle Hooks for Claude Code${RESET}"
echo -e "${DIM}Safety hooks that protect your codebase${RESET}"
echo ""

# Hook catalog (no associative arrays — bash 3 compatible)
hook_desc() {
  case "$1" in
    read-once)   echo "Skip re-reading unchanged files (saves tokens)" ;;
    file-guard)  echo "Block modifications to sensitive files (.env, keys)" ;;
    git-safe)    echo "Prevent destructive git operations (force push, reset --hard)" ;;
    bash-guard)    echo "Block dangerous bash commands (rm -rf /, sudo, curl|bash)" ;;
    branch-guard)    echo "Prevent direct commits to main/master (feature-branch workflow)" ;;
    worktree-guard)  echo "Prevent data loss when exiting worktrees (unmerged commits)" ;;
    session-log)     echo "Audit trail — log every tool call to JSONL" ;;
    *)               echo "Unknown hook" ;;
  esac
}

ALL_HOOKS="read-once file-guard git-safe bash-guard branch-guard worktree-guard session-log"
RECOMMENDED_HOOKS="bash-guard git-safe file-guard"

# Handle help subcommand
if [ $# -gt 0 ] && { [ "$1" = "help" ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; }; then
  echo -e "${BOLD}Usage:${RESET} install.sh <command> [args]"
  echo ""
  echo -e "${BOLD}Commands:${RESET}"
  echo "  recommended           Install the 3 essential hooks (bash-guard, git-safe, file-guard)"
  echo "  all                   Install all 7 hooks"
  echo "  <hook> [hook...]      Install specific hooks by name"
  echo "  list                  Show which hooks are currently installed"
  echo "  verify                Test all installed hooks with real payloads"
  echo "  upgrade               Re-download all installed hooks to latest version"
  echo "  uninstall <hook>      Remove a specific hook (files + settings.json entry)"
  echo "  uninstall all         Remove all hooks"
  echo "  backup                Snapshot settings.json (protects against auto-update wipes)"
  echo "  backup list           Show available backups"
  echo "  restore               Restore the most recent backup"
  echo "  restore <file>        Restore a specific backup"
  echo "  check                 Run safety audit on your Claude Code setup"
  echo "  doctor                Diagnose installation health (files, settings, permissions)"
  echo "  help                  Show this help message"
  echo ""
  echo -e "${BOLD}Available hooks:${RESET}"
  for hook in $ALL_HOOKS; do
    desc=$(hook_desc "$hook")
    rec=""
    case " $RECOMMENDED_HOOKS " in
      *" $hook "*) rec=" ${YELLOW}(recommended)${RESET}" ;;
    esac
    echo -e "  ${CYAN}${hook}${RESET}  ${desc}${rec}"
  done
  echo ""
  echo -e "${BOLD}Examples:${RESET}"
  echo "  install.sh recommended           # Start here"
  echo "  install.sh all                    # Everything at once"
  echo "  install.sh read-once git-safe     # Pick specific hooks"
  echo "  install.sh list                   # See what you have"
  echo "  install.sh verify                 # Test hooks with payloads"
  echo "  install.sh upgrade                # Update to latest"
  echo "  install.sh uninstall read-once    # Remove one hook"
  echo "  install.sh backup                 # Snapshot before updating Claude Code"
  echo "  install.sh restore                # Restore after a wipe"
  echo "  install.sh check                  # Run safety audit"
  echo "  install.sh doctor                 # Check installation health"
  exit 0
fi

# Handle check subcommand — download and run safety-check audit
if [ $# -gt 0 ] && [ "$1" = "check" ]; then
  DL="curl -fsSL"
  if ! command -v curl >/dev/null 2>&1; then
    if command -v wget >/dev/null 2>&1; then
      DL="wget -q -O -"
    else
      echo "Error: curl or wget required" >&2
      exit 1
    fi
  fi

  echo -e "${BOLD}Running safety audit...${RESET}"
  echo ""

  tmpfile=$(mktemp)
  trap 'rm -f "$tmpfile"' EXIT

  if $DL "https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh" > "$tmpfile" 2>/dev/null; then
    if [ -s "$tmpfile" ]; then
      chmod +x "$tmpfile"
      bash "$tmpfile"
    else
      echo -e "${YELLOW}Warning: downloaded empty file. Check your network connection.${RESET}" >&2
      exit 1
    fi
  else
    echo -e "${YELLOW}Warning: could not download safety-check. Check your network connection.${RESET}" >&2
    exit 1
  fi
  exit 0
fi

# Handle doctor subcommand — diagnose installation health
if [ $# -gt 0 ] && [ "$1" = "doctor" ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 required for doctor command" >&2
    exit 1
  fi
  python3 - "$SETTINGS" "$HOME" "$ALL_HOOKS" << 'PYEOF'
import sys, json, os, re

settings_path = sys.argv[1]
home = sys.argv[2]
all_hooks = sys.argv[3].split()

# JSONC stripper (handles comments in settings.json)
def strip_jsonc(text):
    out = []; i = 0; n = len(text)
    while i < n:
        if text[i] == '"':
            out.append(text[i]); i += 1
            while i < n and text[i] != '"':
                if text[i] == '\\': out.append(text[i]); i += 1
                if i < n: out.append(text[i]); i += 1
            if i < n: out.append(text[i]); i += 1
        elif i + 1 < n and text[i:i+2] == '//':
            while i < n and text[i] != '\n': i += 1
        elif i + 1 < n and text[i:i+2] == '/*':
            i += 2
            while i + 1 < n and text[i:i+2] != '*/': i += 1
            i += 2
        else:
            out.append(text[i]); i += 1
    return ''.join(out)

def load_settings(path):
    """Load settings.json, handling JSONC. Returns (settings, is_jsonc, error)."""
    if not os.path.isfile(path):
        return None, False, "not_found"
    with open(path) as f:
        raw = f.read()
    try:
        return json.loads(raw), False, None
    except (json.JSONDecodeError, ValueError):
        pass
    try:
        return json.loads(strip_jsonc(raw)), True, None
    except (json.JSONDecodeError, ValueError):
        return None, False, "invalid"

hook_descs = {
    "read-once": "Skip re-reading unchanged files (saves tokens)",
    "file-guard": "Block modifications to sensitive files (.env, keys)",
    "git-safe": "Prevent destructive git operations (force push, reset --hard)",
    "bash-guard": "Block dangerous bash commands (rm -rf /, sudo, curl|bash)",
    "branch-guard": "Prevent direct commits to main/master (feature-branch workflow)",
    "worktree-guard": "Prevent data loss when exiting worktrees (unmerged commits)",
    "session-log": "Audit trail — log every tool call to JSONL",
}

errors = 0
warnings = 0
ok_count = 0

def ok(msg):
    global ok_count; ok_count += 1; print(f"  OK     {msg}")
def warn(msg):
    global warnings; warnings += 1; print(f"  WARN   {msg}")
def error(msg):
    global errors; errors += 1; print(f"  ERROR  {msg}")
def dim(msg):
    print(f"  --     {msg}")

print("Running diagnostics...")
print()

# 0. Check Claude Code is available
import shutil, subprocess
claude_path = shutil.which("claude")
if claude_path:
    ok(f"Claude Code found at {claude_path}")
    try:
        ver = subprocess.check_output([claude_path, "--version"], stderr=subprocess.DEVNULL, timeout=5).decode().strip()
        ok(f"Version: {ver}")
    except Exception:
        warn("Could not determine Claude Code version")
else:
    warn("'claude' not found on PATH (hooks run inside Claude Code sessions, not standalone)")

# 1. Check settings.json
settings, is_jsonc, err = load_settings(settings_path)
if err == "not_found":
    error(f"settings.json not found at {settings_path}")
    print("         Run the installer to create it, or check Claude Code is installed.")
elif err == "invalid":
    ok("settings.json exists")
    error("settings.json is not valid JSON or JSONC")
else:
    ok("settings.json exists")
    if is_jsonc:
        warn("settings.json uses JSONC (comments). Some tools may not parse it.")
    else:
        ok("settings.json is valid JSON")

# 2. Check each hook
print()
print("Installed hooks:")

for hook in all_hooks:
    hook_dir = os.path.join(home, ".claude", hook)
    if not os.path.isdir(hook_dir):
        dim(f"{hook}  not installed")
        continue

    issues = []

    # Check hook.sh exists
    hook_sh = os.path.join(hook_dir, "hook.sh")
    if not os.path.isfile(hook_sh):
        issues.append(f"missing hook.sh")
    elif not os.access(hook_sh, os.X_OK):
        issues.append(f"hook.sh not executable (run: chmod +x {hook_sh})")

    # Check extra files
    if hook == "read-once":
        cli_bash = os.path.join(hook_dir, "read-once")
        cli_ps1 = os.path.join(hook_dir, "read-once.ps1")
        if not os.path.isfile(cli_bash) and not os.path.isfile(cli_ps1):
            issues.append("read-once CLI not found (run: install.sh upgrade)")

    # Check settings.json registration
    expected_matchers = {
        "read-once": "Read",
        "bash-guard": "Bash",
        "worktree-guard": "ExitWorktree",
    }
    if settings is not None:
        event = "PostToolUse" if hook == "session-log" else "PreToolUse"
        found = False
        found_entry = None
        if "hooks" in settings and event in settings["hooks"]:
            for entry in settings["hooks"][event]:
                for h in entry.get("hooks", []):
                    if hook in h.get("command", ""):
                        found = True
                        found_entry = entry
                        break
                if found:
                    break
        if not found:
            issues.append(f"not registered in settings.json (run: install.sh {hook})")
        elif hook in expected_matchers and found_entry is not None:
            if found_entry.get("matcher") != expected_matchers[hook]:
                issues.append(f"missing matcher (fires on ALL tools instead of just {expected_matchers[hook]}; run: install.sh upgrade)")

    if not issues:
        desc = hook_descs.get(hook, "")
        ok(f"{hook}  {desc}")
    else:
        error(hook)
        for issue in issues:
            print(f"         {issue}")

# 3. Check orphaned entries
if settings is not None:
    print()
    print("Settings.json entries:")
    orphans = []
    if "hooks" in settings:
        for event, entries in settings["hooks"].items():
            for entry in entries:
                for h in entry.get("hooks", []):
                    cmd = h.get("command", "")
                    if cmd and not os.path.isfile(cmd):
                        orphans.append(f"{event}: {cmd}")
    if orphans:
        for o in orphans:
            warn(f"orphaned entry: {o}")
    else:
        ok("no orphaned hook entries")

    # 4. Check backups
    backup_dir = os.path.join(home, ".claude", "backups")
    if os.path.isdir(backup_dir):
        backups = [f for f in os.listdir(backup_dir) if f.startswith("settings.") and f.endswith(".json")]
        if backups:
            ok(f"{len(backups)} backup(s) available")
    else:
        warn("no backups found (run: install.sh backup)")

# Summary
print()
if errors > 0:
    print(f"{errors} error(s), {warnings} warning(s), {ok_count} ok")
    print()
    print("Fix errors above, then re-run: install.sh doctor")
    print("Still stuck? https://github.com/Bande-a-Bonnot/Boucle-framework/issues")
    sys.exit(1)
elif warnings > 0:
    print(f"{warnings} warning(s), {ok_count} ok. Hooks should work fine.")
    sys.exit(0)
else:
    print(f"All checks passed ({ok_count} ok)")
    sys.exit(0)
PYEOF
  exit $?
fi

# Handle list subcommand — show all hooks with install status
if [ $# -gt 0 ] && [ "$1" = "list" ]; then
  found=0
  for hook in $ALL_HOOKS; do
    dir="${HOME}/.claude/${hook}"
    desc=$(hook_desc "$hook")
    if [ -d "$dir" ] && [ -f "$dir/hook.sh" ]; then
      echo -e "  ${GREEN}✓${RESET}  ${CYAN}${hook}${RESET}  ${desc}"
      found=$((found + 1))
    fi
  done
  echo ""
  if [ "$found" -eq 0 ]; then
    echo "  No hooks installed. Get started: install.sh recommended"
  else
    echo "  $found hooks installed. Add more: install.sh <hook-name>"
  fi
  exit 0
fi

# Handle verify subcommand — test all installed hooks with real payloads
if [ $# -gt 0 ] && [ "$1" = "verify" ]; then
  echo -e "${BOLD}Verifying installed hooks...${RESET}"
  echo ""

  v_ok=0
  v_fail=0
  v_skip=0
  v_found=0

  for hook in $ALL_HOOKS; do
    hook_path="${HOME}/.claude/${hook}/hook.sh"
    [ -d "${HOME}/.claude/${hook}" ] && [ -f "$hook_path" ] || continue
    v_found=$((v_found + 1))

    if [ ! -x "$hook_path" ]; then
      echo -e "  ${YELLOW}WARN${RESET}: ${hook} is not executable"
      v_fail=$((v_fail + 1))
      continue
    fi

    case "$hook" in
      bash-guard)
        result=$(echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | "$hook_path" 2>/dev/null || true)
        if echo "$result" | grep -q '"deny"'; then
          echo -e "  ${GREEN}OK${RESET}  ${hook}  blocked rm -rf /"
          v_ok=$((v_ok + 1))
        else
          echo -e "  ${YELLOW}WARN${RESET}  ${hook}  did not block rm -rf /"
          v_fail=$((v_fail + 1))
        fi
        ;;
      git-safe)
        result=$(echo '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}' | "$hook_path" 2>/dev/null || true)
        if echo "$result" | grep -q '"deny"'; then
          echo -e "  ${GREEN}OK${RESET}  ${hook}  blocked git push --force"
          v_ok=$((v_ok + 1))
        else
          echo -e "  ${YELLOW}WARN${RESET}  ${hook}  did not block git push --force"
          v_fail=$((v_fail + 1))
        fi
        ;;
      file-guard)
        result=$(echo '{"tool_name":"Write","tool_input":{"file_path":"relative/path.txt","content":"test"}}' | "$hook_path" 2>/dev/null || true)
        if echo "$result" | grep -q '"deny"'; then
          echo -e "  ${GREEN}OK${RESET}  ${hook}  blocked relative path write"
          v_ok=$((v_ok + 1))
        else
          echo -e "  ${YELLOW}WARN${RESET}  ${hook}  did not block relative path write"
          v_fail=$((v_fail + 1))
        fi
        ;;
      branch-guard)
        # branch-guard uses git rev-parse to detect the current branch, so we
        # can only test it meaningfully when actually on a protected branch
        current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
        result=$(echo '{"tool_name":"Bash","tool_input":{"command":"git commit -m test"}}' | BRANCH_GUARD_PROTECTED="main,master" "$hook_path" 2>/dev/null || true)
        if echo "$result" | grep -q '"deny"'; then
          echo -e "  ${GREEN}OK${RESET}  ${hook}  blocked commit on ${current_branch}"
          v_ok=$((v_ok + 1))
        elif [ "$current_branch" = "main" ] || [ "$current_branch" = "master" ]; then
          echo -e "  ${YELLOW}WARN${RESET}  ${hook}  did not block commit on ${current_branch}"
          v_fail=$((v_fail + 1))
        else
          echo -e "  ${DIM}SKIP${RESET}  ${hook}  current branch '${current_branch}' is not protected (test requires main/master)"
          v_skip=$((v_skip + 1))
        fi
        ;;
      worktree-guard)
        if echo '{"tool_name":"Bash","tool_input":{"command":"echo test"}}' | "$hook_path" >/dev/null 2>&1; then
          echo -e "  ${GREEN}OK${RESET}  ${hook}  passes non-ExitWorktree tools"
          v_ok=$((v_ok + 1))
        else
          echo -e "  ${YELLOW}WARN${RESET}  ${hook}  returned an error"
          v_fail=$((v_fail + 1))
        fi
        ;;
      session-log)
        if echo '{"tool_name":"Read","tool_input":{"file_path":"/tmp/verify-test"}}' | "$hook_path" >/dev/null 2>&1; then
          echo -e "  ${GREEN}OK${RESET}  ${hook}  accepted payload without error"
          v_ok=$((v_ok + 1))
        else
          echo -e "  ${YELLOW}WARN${RESET}  ${hook}  returned an error"
          v_fail=$((v_fail + 1))
        fi
        ;;
      read-once)
        if echo '{"tool_name":"Read","tool_input":{"file_path":"/tmp/verify-test"}}' | "$hook_path" >/dev/null 2>&1; then
          echo -e "  ${GREEN}OK${RESET}  ${hook}  accepted payload without error"
          v_ok=$((v_ok + 1))
        else
          echo -e "  ${YELLOW}WARN${RESET}  ${hook}  returned an error"
          v_fail=$((v_fail + 1))
        fi
        ;;
      *)
        echo -e "  ${DIM}SKIP${RESET}  ${hook}  no automated test"
        v_skip=$((v_skip + 1))
        ;;
    esac
  done

  if [ "$v_found" -eq 0 ]; then
    echo "  No hooks installed. Run: install.sh recommended"
    exit 1
  fi

  echo ""
  if [ "$v_fail" -gt 0 ]; then
    echo -e "${YELLOW}${BOLD}$v_ok passed, $v_fail warnings, $v_skip skipped.${RESET}"
    echo "  Run doctor for details: install.sh doctor"
  else
    echo -e "${GREEN}${BOLD}All $v_ok hooks verified, $v_skip skipped.${RESET}"
  fi
  exit 0
fi

# Handle upgrade subcommand — re-download all installed hooks
if [ $# -gt 0 ] && [ "$1" = "upgrade" ]; then
  DL="curl -fsSL"
  if ! command -v curl >/dev/null 2>&1; then
    if command -v wget >/dev/null 2>&1; then
      DL="wget -q -O -"
    else
      echo "Error: curl or wget required" >&2
      exit 1
    fi
  fi

  upgraded=0
  for hook in $ALL_HOOKS; do
    dir="${HOME}/.claude/${hook}"
    if [ -d "$dir" ] && [ -f "$dir/hook.sh" ]; then
      echo -e "  Upgrading ${CYAN}${hook}${RESET}..."
      if $DL "${REPO}/${hook}/hook.sh" > "${dir}/hook.sh.new" 2>/dev/null; then
        if [ -s "${dir}/hook.sh.new" ]; then
          if cmp -s "${dir}/hook.sh" "${dir}/hook.sh.new"; then
            echo -e "    ${DIM}already up to date${RESET}"
            rm -f "${dir}/hook.sh.new"
          else
            mv "${dir}/hook.sh.new" "${dir}/hook.sh"
            chmod +x "${dir}/hook.sh"
            echo -e "    ${GREEN}updated${RESET}"
            upgraded=$((upgraded + 1))
          fi
        else
          echo -e "    ${YELLOW}download empty, skipped${RESET}"
          rm -f "${dir}/hook.sh.new"
        fi
        # Also upgrade extra files
        case "$hook" in
          read-once)
            if $DL "${REPO}/${hook}/read-once" > "${dir}/read-once.new" 2>/dev/null && [ -s "${dir}/read-once.new" ]; then
              if ! cmp -s "${dir}/read-once" "${dir}/read-once.new"; then
                mv "${dir}/read-once.new" "${dir}/read-once"
                chmod +x "${dir}/read-once"
              else
                rm -f "${dir}/read-once.new"
              fi
            else
              rm -f "${dir}/read-once.new"
            fi
            ;;
          file-guard)
            if $DL "${REPO}/${hook}/init.sh" > "${dir}/init.sh.new" 2>/dev/null && [ -s "${dir}/init.sh.new" ]; then
              if ! cmp -s "${dir}/init.sh" "${dir}/init.sh.new"; then
                mv "${dir}/init.sh.new" "${dir}/init.sh"
                chmod +x "${dir}/init.sh"
              else
                rm -f "${dir}/init.sh.new"
              fi
            else
              rm -f "${dir}/init.sh.new"
            fi
            ;;
        esac
      else
        echo -e "    ${YELLOW}download failed, skipped${RESET}"
      fi
    fi
  done

  # Fix missing matchers in settings.json for hooks that target one tool/event.
  matcher_fixes=0
  if [ -f "$SETTINGS" ] && command -v python3 >/dev/null 2>&1; then
    matcher_fixes=$(python3 - "$SETTINGS" << 'PYEOF'
import json, sys, os
sf = sys.argv[1]
try:
    with open(sf) as f:
        raw = f.read()
    # Strip JSONC comments
    lines = []
    for line in raw.split('\n'):
        stripped = line.lstrip()
        if stripped.startswith('//'):
            continue
        lines.append(line)
    settings = json.loads('\n'.join(lines))
except:
    print("0"); sys.exit(0)
fixes = 0
matchers = {"read-once": "Read", "bash-guard": "Bash", "worktree-guard": "ExitWorktree"}
for event in settings.get("hooks", {}):
    for entry in settings["hooks"][event]:
        if not isinstance(entry, dict):
            continue
        # Check nested hooks format
        cmd = ""
        for h in entry.get("hooks", []):
            c = h.get("command", "")
            if c: cmd = c; break
        if not cmd:
            cmd = entry.get("command", "")
        for hook_name, expected_matcher in matchers.items():
            if hook_name in cmd and entry.get("matcher") != expected_matcher:
                entry["matcher"] = expected_matcher
                fixes += 1
if fixes > 0:
    with open(sf, 'w') as f:
        json.dump(settings, f, indent=2)
        f.write('\n')
print(fixes)
PYEOF
    )
    if [ "$matcher_fixes" -gt 0 ] 2>/dev/null; then
      echo -e "  ${GREEN}Fixed${RESET} $matcher_fixes missing matcher(s) in settings.json"
      echo "    (read-once now only fires on Read tool calls, not every tool call)"
    fi
  fi

  if [ "$upgraded" -gt 0 ] || [ "${matcher_fixes:-0}" -gt 0 ] 2>/dev/null; then
    echo ""
    echo -e "${GREEN}${BOLD}Done!${RESET} Changes take effect in your next Claude Code session."
  else
    echo ""
    echo "All hooks are up to date."
  fi
  exit 0
fi

# Handle uninstall subcommand (doesn't need jq)
if [ $# -gt 0 ] && [ "$1" = "uninstall" ]; then
  shift

  if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 required for settings.json cleanup" >&2
    exit 1
  fi

  if [ $# -eq 0 ]; then
    echo -e "${BOLD}Usage:${RESET} install.sh uninstall <hook-name> [hook-name...] | all"
    echo ""
    echo "Installed hooks:"
    found=0
    for hook in $ALL_HOOKS; do
      if [ -d "${HOME}/.claude/${hook}" ]; then
        desc=$(hook_desc "$hook")
        echo -e "  ${CYAN}${hook}${RESET}  ${desc}"
        found=1
      fi
    done
    if [ $found -eq 0 ]; then
      echo "  (none)"
    fi
    exit 0
  fi

  if [ "$1" = "all" ]; then
    to_remove=""
    for hook in $ALL_HOOKS; do
      if [ -d "${HOME}/.claude/${hook}" ]; then
        to_remove="${to_remove} ${hook}"
      fi
    done
    if [ -z "$to_remove" ]; then
      echo "No hooks installed. Nothing to remove."
      exit 0
    fi
  else
    to_remove="$*"
  fi

  echo ""
  removed=""
  for hook in $to_remove; do
    case "$hook" in
      read-once|file-guard|git-safe|bash-guard|branch-guard|worktree-guard|session-log) ;;
      *)
        echo -e "  ${YELLOW}Unknown hook: ${hook}${RESET} (available: ${ALL_HOOKS})"
        continue
        ;;
    esac

    dir="${HOME}/.claude/${hook}"
    if [ -d "$dir" ]; then
      rm -rf "$dir"
      echo -e "  ${GREEN}✓${RESET} Removed ${CYAN}${hook}${RESET}"
      removed="${removed} ${hook}"
    else
      echo -e "  ${DIM}SKIP${RESET} ${hook} (not installed)"
    fi
  done

  # Clean up settings.json
  if [ -n "$removed" ] && [ -f "$SETTINGS" ]; then
    echo ""
    echo "Cleaning settings.json..."
    python3 - "$SETTINGS" $removed << 'PYEOF'
import json, sys, os, re

settings_path = sys.argv[1]
hooks_to_remove = sys.argv[2:]

def strip_jsonc(text):
    """Strip // and /* */ comments from JSONC, respecting quoted strings."""
    out, i, n = [], 0, len(text)
    in_str = False
    while i < n:
        if in_str:
            if text[i] == '\\' and i + 1 < n:
                out.append(text[i:i+2]); i += 2; continue
            if text[i] == '"': in_str = False
            out.append(text[i]); i += 1
        else:
            if text[i] == '"':
                in_str = True; out.append(text[i]); i += 1
            elif i + 1 < n and text[i:i+2] == '//':
                while i < n and text[i] != '\n': i += 1
            elif i + 1 < n and text[i:i+2] == '/*':
                i += 2
                while i + 1 < n and text[i:i+2] != '*/': i += 1
                i += 2
            else:
                out.append(text[i]); i += 1
    return ''.join(out)

with open(settings_path) as f:
    raw = f.read()
try:
    settings = json.loads(raw)
except (json.JSONDecodeError, ValueError):
    settings = json.loads(strip_jsonc(raw))

if "hooks" not in settings:
    sys.exit(0)

for hook in hooks_to_remove:
    command = os.path.expanduser("~/.claude/" + hook + "/hook.sh")
    for event in list(settings["hooks"].keys()):
        entries = settings["hooks"][event]
        original_len = len(entries)
        settings["hooks"][event] = [
            h for h in entries
            if not (
                isinstance(h, dict) and (
                    h.get("command", "") == command or
                    any(hk.get("command", "") == command
                        for hk in h.get("hooks", []))
                )
            )
        ]
        if len(settings["hooks"][event]) < original_len:
            print("  Removed " + hook + " from " + event)
        # Clean up empty event arrays
        if not settings["hooks"][event]:
            del settings["hooks"][event]

# Clean up empty hooks object
if "hooks" in settings and not settings["hooks"]:
    del settings["hooks"]

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYEOF
  fi

  echo ""
  count=$(echo $removed | wc -w | tr -d ' ')
  if [ "$count" -gt "0" ]; then
    echo -e "${GREEN}${BOLD}Done!${RESET} Removed ${count} hook(s). Changes take effect in your next Claude Code session."
  else
    echo "No hooks were removed."
  fi
  exit 0
fi

# Handle backup subcommand — snapshot settings.json before Claude Code updates
BACKUP_DIR="${HOME}/.claude/backups"
if [ $# -gt 0 ] && [ "$1" = "backup" ]; then
  shift

  if [ ! -f "$SETTINGS" ]; then
    echo "No settings.json found at $SETTINGS"
    echo "Nothing to back up."
    exit 0
  fi

  # backup list — show available backups
  if [ $# -gt 0 ] && [ "$1" = "list" ]; then
    if [ ! -d "$BACKUP_DIR" ]; then
      echo "No backups found."
      echo ""
      echo "Create one with: install.sh backup"
      exit 0
    fi
    count=0
    for f in "$BACKUP_DIR"/settings.*.json; do
      [ -f "$f" ] || continue
      fname=$(basename "$f")
      ts=$(echo "$fname" | sed 's/settings\.\(.*\)\.json/\1/' | tr '-' ' ' | tr '_' ' ')
      size=$(wc -c < "$f" | tr -d ' ')
      echo -e "  ${CYAN}${fname}${RESET}  ${size} bytes  ${DIM}${ts}${RESET}"
      count=$((count + 1))
    done
    if [ "$count" -eq 0 ]; then
      echo "No backups found."
      echo ""
      echo "Create one with: install.sh backup"
    else
      echo ""
      echo "  $count backup(s) found in $BACKUP_DIR"
      echo ""
      echo "Restore with: install.sh restore"
    fi
    exit 0
  fi

  # Create backup
  mkdir -p "$BACKUP_DIR"
  timestamp=$(date +%Y%m%d_%H%M%S)
  backup_file="$BACKUP_DIR/settings.${timestamp}.json"
  cp "$SETTINGS" "$backup_file"

  # Count hooks in the backup
  hook_count=0
  if command -v python3 >/dev/null 2>&1; then
    hook_count=$(python3 -c "
import json, sys
def strip_jsonc(t):
    o,i,n,s=[],0,len(t),False
    while i<n:
        if s:
            if t[i]=='\\\\' and i+1<n: o.append(t[i:i+2]);i+=2;continue
            if t[i]=='\"': s=False
            o.append(t[i]);i+=1
        else:
            if t[i]=='\"': s=True;o.append(t[i]);i+=1
            elif i+1<n and t[i:i+2]=='//':
                while i<n and t[i]!='\n': i+=1
            elif i+1<n and t[i:i+2]=='/*':
                i+=2
                while i+1<n and t[i:i+2]!='*/': i+=1
                i+=2
            else: o.append(t[i]);i+=1
    return ''.join(o)
try:
    with open(sys.argv[1]) as f: raw = f.read()
    try: s = json.loads(raw)
    except: s = json.loads(strip_jsonc(raw))
    events = s.get('hooks', {})
    cmds = set()
    for ev in events.values():
        for h in ev:
            if isinstance(h, dict):
                c = h.get('command', '')
                if c: cmds.add(c)
                for sub in h.get('hooks', []):
                    c = sub.get('command', '')
                    if c: cmds.add(c)
    print(len(cmds))
except: print(0)
" "$backup_file" 2>/dev/null)
  fi

  size=$(wc -c < "$backup_file" | tr -d ' ')
  echo -e "${GREEN}${BOLD}Backup created.${RESET}"
  echo ""
  echo "  File: $backup_file"
  echo "  Size: $size bytes"
  if [ "$hook_count" -gt 0 ]; then
    echo "  Hooks: $hook_count unique hook command(s)"
  fi
  echo ""
  echo "Restore with: install.sh restore"
  echo ""
  echo -e "${DIM}Tip: Run this before updating Claude Code. If an auto-update"
  echo -e "wipes your settings.json, restore will bring your hooks back.${RESET}"
  exit 0
fi

# Handle restore subcommand — restore a settings.json backup
if [ $# -gt 0 ] && [ "$1" = "restore" ]; then
  shift

  if [ ! -d "$BACKUP_DIR" ]; then
    echo "No backups found in $BACKUP_DIR"
    echo ""
    echo "Create one first with: install.sh backup"
    exit 1
  fi

  # If a specific file is given, use it
  if [ $# -gt 0 ]; then
    target="$1"
    # Allow bare filename or full path
    if [ ! -f "$target" ] && [ -f "$BACKUP_DIR/$target" ]; then
      target="$BACKUP_DIR/$target"
    fi
    if [ ! -f "$target" ]; then
      echo -e "${YELLOW}Backup not found:${RESET} $1"
      echo ""
      echo "Available backups:"
      for f in "$BACKUP_DIR"/settings.*.json; do
        [ -f "$f" ] || continue
        echo "  $(basename "$f")"
      done
      exit 1
    fi
  else
    # Find the most recent backup
    target=""
    for f in "$BACKUP_DIR"/settings.*.json; do
      [ -f "$f" ] || continue
      target="$f"
    done
    if [ -z "$target" ]; then
      echo "No backups found in $BACKUP_DIR"
      exit 1
    fi
  fi

  # Validate the backup is valid JSON or JSONC
  if command -v python3 >/dev/null 2>&1; then
    if ! python3 -c "
import json, sys
def strip_jsonc(t):
    o,i,n,s=[],0,len(t),False
    while i<n:
        if s:
            if t[i]=='\\\\' and i+1<n: o.append(t[i:i+2]);i+=2;continue
            if t[i]=='\"': s=False
            o.append(t[i]);i+=1
        else:
            if t[i]=='\"': s=True;o.append(t[i]);i+=1
            elif i+1<n and t[i:i+2]=='//':
                while i<n and t[i]!='\n': i+=1
            elif i+1<n and t[i:i+2]=='/*':
                i+=2
                while i+1<n and t[i:i+2]!='*/': i+=1
                i+=2
            else: o.append(t[i]);i+=1
    return ''.join(o)
with open(sys.argv[1]) as f: raw=f.read()
try: json.loads(raw)
except: json.loads(strip_jsonc(raw))
" "$target" 2>/dev/null; then
      echo -e "${YELLOW}Warning:${RESET} Backup is not valid JSON: $(basename "$target")"
      echo "Aborting restore."
      exit 1
    fi
  fi

  # If current settings.json exists, back it up first
  if [ -f "$SETTINGS" ]; then
    pre_restore="$BACKUP_DIR/settings.pre-restore-$(date +%Y%m%d_%H%M%S).json"
    cp "$SETTINGS" "$pre_restore"
    echo -e "  ${DIM}Current settings saved to $(basename "$pre_restore")${RESET}"
  fi

  cp "$target" "$SETTINGS"
  echo -e "${GREEN}${BOLD}Restored!${RESET}"
  echo ""
  echo "  From: $(basename "$target")"
  echo "  To:   $SETTINGS"
  echo ""
  echo "Changes take effect in your next Claude Code session."
  exit 0
fi

# Check prerequisites
if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 not found. Install Python 3 and try again." >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo -e "${YELLOW}Warning: jq not found.${RESET}"
    echo ""
    echo "  Hooks use jq to parse JSON from Claude Code. Without it,"
    echo "  hooks will silently pass through every command unblocked."
    echo ""
    echo "  Install jq first:"
    echo "    macOS:  brew install jq"
    echo "    Ubuntu: sudo apt install jq"
    echo "    Alpine: apk add jq"
    echo ""
    if [ -t 0 ]; then
      echo -n "Continue anyway? [y/N] "
      read -r answer
      [ "$answer" = "y" ] || [ "$answer" = "Y" ] || exit 1
    else
      echo "  Install jq, then re-run this command." >&2
      exit 1
    fi
fi

# Determine download command
DL="curl -fsSL"
if ! command -v curl >/dev/null 2>&1; then
  if command -v wget >/dev/null 2>&1; then
    DL="wget -q -O -"
  else
    echo "Error: curl or wget required" >&2
    exit 1
  fi
fi

# Show available hooks
for hook in $ALL_HOOKS; do
  dir="${HOME}/.claude/${hook}"
  if [ -d "$dir" ] && [ -f "$dir/hook.sh" ]; then
    status="${GREEN}installed${RESET}"
  else
    status="${DIM}not installed${RESET}"
  fi
  desc=$(hook_desc "$hook")
  # Mark recommended hooks
  rec=""
  case " $RECOMMENDED_HOOKS " in
    *" $hook "*) rec=" ${YELLOW}recommended${RESET}" ;;
  esac
  echo -e "  ${CYAN}${hook}${RESET}  ${desc}  [${status}]${rec}"
done
echo ""

# Parse arguments or ask interactively
if [ $# -gt 0 ]; then
  if [ "$1" = "all" ]; then
    selected="$ALL_HOOKS"
  elif [ "$1" = "recommended" ]; then
    selected="$RECOMMENDED_HOOKS"
    echo -e "${BOLD}Installing recommended hooks:${RESET} bash-guard, git-safe, file-guard"
  else
    selected="$*"
  fi
else
  if [ -t 0 ]; then
    # Interactive: prompt for selection
    echo -e "${BOLD}Which hooks to install?${RESET}"
    echo "  'recommended'  bash-guard + git-safe + file-guard (start here)"
    echo "  'all'          all 7 hooks"
    echo "  or enter hook names separated by spaces"
    echo -n "> "
    read -r input
    if [ "$input" = "all" ]; then
      selected="$ALL_HOOKS"
    elif [ "$input" = "recommended" ] || [ -z "$input" ]; then
      selected="$RECOMMENDED_HOOKS"
      echo -e "${BOLD}Installing recommended hooks:${RESET} bash-guard, git-safe, file-guard"
    else
      selected="$input"
    fi
  else
    # Piped (curl | bash): default to recommended
    selected="$RECOMMENDED_HOOKS"
    echo -e "${BOLD}Installing recommended hooks:${RESET} bash-guard, git-safe, file-guard"
    echo -e "${DIM}(Use 'curl ... | bash -s -- all' to install all hooks)${RESET}"
  fi
fi

if [ -z "$selected" ]; then
  echo "Nothing selected. Exiting."
  exit 0
fi

echo ""

# Warn if Claude Code is not installed (hooks need it to run)
if ! command -v claude >/dev/null 2>&1; then
  echo -e "${YELLOW}Note: 'claude' not found on PATH.${RESET}"
  echo "  Hooks run inside Claude Code sessions. Install Claude Code first if you haven't."
  echo "  Continuing anyway (hooks will activate once Claude Code is installed)."
  echo ""
fi

# Verify ~/.claude is writable before downloading anything
claude_dir="${HOME}/.claude"
mkdir -p "$claude_dir" 2>/dev/null || true
if [ ! -d "$claude_dir" ] || [ ! -w "$claude_dir" ]; then
  echo -e "${YELLOW}Error: ${claude_dir} is not writable.${RESET}" >&2
  echo "  Hooks are installed to ~/.claude/<hook-name>/hook.sh" >&2
  echo "  Check directory permissions and try again." >&2
  exit 1
fi

# Install each selected hook
installed=""
for hook in $selected; do
  # Validate
  case "$hook" in
    read-once|file-guard|git-safe|bash-guard|branch-guard|worktree-guard|session-log) ;;
    *)
      echo -e "${YELLOW}Unknown hook: ${hook}${RESET} (available: ${ALL_HOOKS})"
      continue
      ;;
  esac

  install_dir="${HOME}/.claude/${hook}"
  echo -e "Installing ${CYAN}${hook}${RESET}..."
  mkdir -p "$install_dir"

  # Download hook script
  if ! $DL "${REPO}/${hook}/hook.sh" > "${install_dir}/hook.sh" 2>/dev/null; then
    echo -e "  ${YELLOW}Error: download failed for ${hook}. Skipping.${RESET}" >&2
    continue
  fi
  chmod +x "${install_dir}/hook.sh"

  # Verify download is not empty or an HTML error page
  if [ ! -s "${install_dir}/hook.sh" ]; then
    echo -e "  ${YELLOW}Error: downloaded ${hook}/hook.sh is empty. Skipping.${RESET}" >&2
    rm -f "${install_dir}/hook.sh"
    continue
  fi
  if head -1 "${install_dir}/hook.sh" | grep -qi '<html\|<!doctype\|404:'; then
    echo -e "  ${YELLOW}Error: downloaded ${hook}/hook.sh is not a script (got HTML). Skipping.${RESET}" >&2
    rm -f "${install_dir}/hook.sh"
    continue
  fi

  # Download extra files depending on hook
  case "$hook" in
    read-once)
      if ! $DL "${REPO}/${hook}/read-once" > "${install_dir}/read-once" 2>/dev/null; then
        echo -e "  ${YELLOW}Warning: failed to download read-once CLI. Hook will not work without it.${RESET}" >&2
        echo -e "  ${DIM}Try again, or download manually from: ${REPO}/${hook}/read-once${RESET}" >&2
      else
        chmod +x "${install_dir}/read-once"
      fi
      ;;
    file-guard)
      if ! $DL "${REPO}/${hook}/init.sh" > "${install_dir}/init.sh" 2>/dev/null; then
        echo -e "  ${YELLOW}Warning: failed to download init.sh${RESET}" >&2
      else
        chmod +x "${install_dir}/init.sh"
      fi
      ;;
  esac

  echo -e "  ${GREEN}Downloaded to ${install_dir}${RESET}"
  installed="${installed} ${hook}"
done

if [ -z "$installed" ]; then
  echo "No hooks installed."
  exit 0
fi

echo ""
echo "Configuring hooks in ${SETTINGS}..."

if [ ! -f "$SETTINGS" ]; then
  mkdir -p "$(dirname "$SETTINGS")"
  echo '{}' > "$SETTINGS"
fi

# Use Python to merge hooks into settings.json (handles JSON properly)
python3 - "$SETTINGS" $installed << 'PYEOF'
import json, sys, os, re

settings_path = sys.argv[1]
hooks_to_add = sys.argv[2:]

def strip_jsonc(text):
    """Strip // and /* */ comments from JSONC, respecting quoted strings."""
    out, i, n = [], 0, len(text)
    in_str = False
    while i < n:
        if in_str:
            if text[i] == '\\' and i + 1 < n:
                out.append(text[i:i+2]); i += 2; continue
            if text[i] == '"': in_str = False
            out.append(text[i]); i += 1
        else:
            if text[i] == '"':
                in_str = True; out.append(text[i]); i += 1
            elif i + 1 < n and text[i:i+2] == '//':
                while i < n and text[i] != '\n': i += 1
            elif i + 1 < n and text[i:i+2] == '/*':
                i += 2
                while i + 1 < n and text[i:i+2] != '*/': i += 1
                i += 2
            else:
                out.append(text[i]); i += 1
    return ''.join(out)

with open(settings_path) as f:
    raw = f.read()

try:
    settings = json.loads(raw)
except (json.JSONDecodeError, ValueError):
    # Check if JSONC comments are the cause
    has_comments = bool(re.search(r'(?<!["\w])//[^\n]*|/\*[\s\S]*?\*/', raw))
    if has_comments:
        try:
            settings = json.loads(strip_jsonc(raw))
            print("  Warning: " + settings_path + " contains JSONC comments.")
            print("  Comments will be removed when saving. A backup was created at " + settings_path + ".bak")
            import shutil
            shutil.copy2(settings_path, settings_path + ".bak")
        except (json.JSONDecodeError, ValueError):
            print("  Error: " + settings_path + " is not valid JSON or JSONC. Aborting.")
            sys.exit(1)
    else:
        print("  Error: " + settings_path + " is not valid JSON. Aborting.")
        sys.exit(1)

if "hooks" not in settings:
    settings["hooks"] = {}

for hook in hooks_to_add:
    # session-log fires after tool calls; safety hooks fire before
    event = "PostToolUse" if hook == "session-log" else "PreToolUse"
    command = os.path.expanduser("~/.claude/" + hook + "/hook.sh")
    entry = {"hooks": [{"type": "command", "command": command, "timeout": 5000}]}
    # matchers limit which tool calls trigger the hook, improving performance
    if hook == "worktree-guard":
        entry["matcher"] = "ExitWorktree"
    elif hook == "bash-guard":
        entry["matcher"] = "Bash"
    elif hook == "read-once":
        entry["matcher"] = "Read"

    if event not in settings["hooks"]:
        settings["hooks"][event] = []

    # Check existing entries in both flat and nested formats
    existing = []
    for h in settings["hooks"][event]:
        if isinstance(h, dict):
            cmd = h.get("command", "")
            if not cmd:
                for hk in h.get("hooks", []):
                    c = hk.get("command", "")
                    if c: cmd = c; break
            existing.append(cmd)
    if command not in existing:
        settings["hooks"][event].append(entry)
        print("  Added " + hook + " to " + event + " hooks")
    else:
        print("  " + hook + " already configured")

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYEOF

echo ""

# Post-install verification: send test payloads to confirm hooks work
echo -e "${BOLD}Verifying hooks...${RESET}"
echo ""
verify_ok=0
verify_fail=0
verify_skip=0

for hook in $installed; do
  hook_path="${HOME}/.claude/${hook}/hook.sh"
  if [ ! -x "$hook_path" ]; then
    echo -e "  ${YELLOW}WARN${RESET}: ${hook} is not executable"
    verify_fail=$((verify_fail + 1))
    continue
  fi

  # Test payloads for hooks that can be trivially verified
  case "$hook" in
    bash-guard)
      result=$(echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | "$hook_path" 2>/dev/null || true)
      if echo "$result" | grep -q '"deny"'; then
        echo -e "  ${GREEN}OK${RESET}: ${hook} blocked test payload (rm -rf /)"
        verify_ok=$((verify_ok + 1))
      else
        echo -e "  ${YELLOW}WARN${RESET}: ${hook} did not block test payload"
        verify_fail=$((verify_fail + 1))
      fi
      ;;
    git-safe)
      result=$(echo '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}' | "$hook_path" 2>/dev/null || true)
      if echo "$result" | grep -q '"deny"'; then
        echo -e "  ${GREEN}OK${RESET}: ${hook} blocked test payload (git push --force)"
        verify_ok=$((verify_ok + 1))
      else
        echo -e "  ${YELLOW}WARN${RESET}: ${hook} did not block test payload"
        verify_fail=$((verify_fail + 1))
      fi
      ;;
    branch-guard)
      result=$(echo '{"tool_name":"Bash","tool_input":{"command":"git commit -m test"}}' | BRANCH_GUARD_PROTECTED="main" GIT_BRANCH="main" "$hook_path" 2>/dev/null || true)
      if echo "$result" | grep -q '"deny"'; then
        echo -e "  ${GREEN}OK${RESET}: ${hook} blocked test payload (commit on main)"
        verify_ok=$((verify_ok + 1))
      else
        # branch-guard needs git context, skip if no git repo
        echo -e "  ${DIM}SKIP${RESET}: ${hook} (needs git repo context to verify)"
        verify_skip=$((verify_skip + 1))
      fi
      ;;
    worktree-guard)
      # worktree-guard needs git context, just check it doesn't crash on non-ExitWorktree
      if echo '{"tool_name":"Bash","tool_input":{"command":"echo test"}}' | "$hook_path" >/dev/null 2>&1; then
        echo -e "  ${GREEN}OK${RESET}: ${hook} passes through non-ExitWorktree tools"
        verify_ok=$((verify_ok + 1))
      else
        echo -e "  ${YELLOW}WARN${RESET}: ${hook} returned an error"
        verify_fail=$((verify_fail + 1))
      fi
      ;;
    session-log)
      # session-log just needs to not crash on a valid payload
      if echo '{"tool_name":"Read","tool_input":{"file_path":"/tmp/verify-test"}}' | "$hook_path" >/dev/null 2>&1; then
        echo -e "  ${GREEN}OK${RESET}: ${hook} accepted test payload without error"
        verify_ok=$((verify_ok + 1))
      else
        echo -e "  ${YELLOW}WARN${RESET}: ${hook} returned an error"
        verify_fail=$((verify_fail + 1))
      fi
      ;;
    file-guard)
      # file-guard always blocks relative paths in Write/Edit (no config needed)
      result=$(echo '{"tool_name":"Write","tool_input":{"file_path":"relative/path.txt","content":"test"}}' | "$hook_path" 2>/dev/null || true)
      if echo "$result" | grep -q '"deny"'; then
        echo -e "  ${GREEN}OK${RESET}: ${hook} blocked test payload (relative path write)"
        verify_ok=$((verify_ok + 1))
      else
        echo -e "  ${YELLOW}WARN${RESET}: ${hook} did not block test payload"
        verify_fail=$((verify_fail + 1))
      fi
      ;;
    read-once)
      # read-once should accept a valid Read payload without crashing
      if echo '{"tool_name":"Read","tool_input":{"file_path":"/tmp/verify-test"}}' | "$hook_path" >/dev/null 2>&1; then
        echo -e "  ${GREEN}OK${RESET}: ${hook} accepted test payload without error"
        verify_ok=$((verify_ok + 1))
      else
        echo -e "  ${YELLOW}WARN${RESET}: ${hook} returned an error"
        verify_fail=$((verify_fail + 1))
      fi
      ;;
    *)
      echo -e "  ${DIM}SKIP${RESET}: ${hook} (no automated test available)"
      verify_skip=$((verify_skip + 1))
      ;;
  esac
done

echo ""
if [ $verify_fail -gt 0 ]; then
  echo -e "${YELLOW}${BOLD}Installed with warnings.${RESET} $verify_ok passed, $verify_fail warnings, $verify_skip skipped."
  echo "  Run: curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify"
  echo "  for a full diagnostic."
else
  echo -e "${GREEN}${BOLD}Done!${RESET} $verify_ok hooks verified, $verify_skip skipped. Active for your next Claude Code session."
fi
echo ""
INSTALL_URL="https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh"
echo "Manage hooks:"
echo "  Verify:    curl -fsSL $INSTALL_URL | bash -s -- verify"
echo "  Upgrade:   curl -fsSL $INSTALL_URL | bash -s -- upgrade"
echo "  Uninstall: curl -fsSL $INSTALL_URL | bash -s -- uninstall <hook-name>"
echo "  More:      curl -fsSL $INSTALL_URL | bash -s -- help"
echo ""
echo -e "${BOLD}Verify it works:${RESET}"
echo "  1. Start a new Claude Code session (hooks activate on next session)"
# Show one concrete example based on which hooks were installed
_showed=0
for _h in $installed; do
  case "$_h" in
    bash-guard)
      echo "  2. Ask Claude to run a dangerous command. bash-guard will block it."
      _showed=1; break ;;
    git-safe)
      echo "  2. Ask Claude to force-push. git-safe will prevent it."
      _showed=1; break ;;
    file-guard)
      echo "  2. Ask Claude to edit .env. file-guard will block it."
      _showed=1; break ;;
  esac
done
if [ "$_showed" -eq 0 ]; then
  echo "  2. Your hooks will automatically protect your next session"
fi
echo "  3. If something seems off, run: install.sh doctor"
echo ""
echo -e "${DIM}Docs: https://github.com/Bande-a-Bonnot/Boucle-framework${RESET}"
echo -e "${DIM}Issues: https://github.com/Bande-a-Bonnot/Boucle-framework/issues${RESET}"
