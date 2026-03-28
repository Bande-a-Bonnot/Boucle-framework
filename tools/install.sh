#!/bin/bash
# Boucle hooks installer — discover and install Claude Code hooks
# Usage: curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash
# Or:    curl ... | bash -s -- recommended
# Or:    curl ... | bash -s -- read-once file-guard git-safe
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

# Check prerequisites
if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 not found. Install Python 3 and try again." >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo -e "${YELLOW}Warning: jq not found. Hooks require jq to parse Claude Code input.${RESET}"
    echo "  Install: brew install jq (macOS) or apt install jq (Linux)"
    echo "  Without jq, installed hooks will fail silently at runtime."
    echo ""
    echo -n "Continue anyway? [y/N] "
    if [ -t 0 ]; then
      read -r answer
      [ "$answer" = "y" ] || [ "$answer" = "Y" ] || exit 1
    else
      echo "Non-interactive mode: aborting. Install jq first." >&2
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
  echo -e "${BOLD}Which hooks to install?${RESET}"
  echo "  'recommended'  bash-guard + git-safe + file-guard (start here)"
  echo "  'all'          all 7 hooks"
  echo "  or enter hook names separated by spaces"
  echo -n "> "
  read -r input
  if [ "$input" = "all" ]; then
    selected="$ALL_HOOKS"
  elif [ "$input" = "recommended" ]; then
    selected="$RECOMMENDED_HOOKS"
    echo -e "${BOLD}Installing recommended hooks:${RESET} bash-guard, git-safe, file-guard"
  else
    selected="$input"
  fi
fi

if [ -z "$selected" ]; then
  echo "Nothing selected. Exiting."
  exit 0
fi

echo ""

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

  # Verify download is not empty
  if [ ! -s "${install_dir}/hook.sh" ]; then
    echo -e "  ${YELLOW}Error: downloaded ${hook}/hook.sh is empty. Skipping.${RESET}" >&2
    continue
  fi

  # Download extra files depending on hook
  case "$hook" in
    read-once)
      if ! $DL "${REPO}/${hook}/read-once" > "${install_dir}/read-once" 2>/dev/null; then
        echo -e "  ${YELLOW}Warning: failed to download read-once CLI${RESET}" >&2
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
    # worktree-guard uses ExitWorktree matcher for efficiency
    if hook == "worktree-guard":
        entry["matcher"] = "ExitWorktree"

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
      if echo "$result" | grep -q '"block"'; then
        echo -e "  ${GREEN}OK${RESET}: ${hook} blocked test payload (rm -rf /)"
        verify_ok=$((verify_ok + 1))
      else
        echo -e "  ${YELLOW}WARN${RESET}: ${hook} did not block test payload"
        verify_fail=$((verify_fail + 1))
      fi
      ;;
    git-safe)
      result=$(echo '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}' | "$hook_path" 2>/dev/null || true)
      if echo "$result" | grep -q '"block"'; then
        echo -e "  ${GREEN}OK${RESET}: ${hook} blocked test payload (git push --force)"
        verify_ok=$((verify_ok + 1))
      else
        echo -e "  ${YELLOW}WARN${RESET}: ${hook} did not block test payload"
        verify_fail=$((verify_fail + 1))
      fi
      ;;
    branch-guard)
      result=$(echo '{"tool_name":"Bash","tool_input":{"command":"git commit -m test"}}' | BRANCH_GUARD_PROTECTED="main" GIT_BRANCH="main" "$hook_path" 2>/dev/null || true)
      if echo "$result" | grep -q '"block"'; then
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
echo "Manage hooks:"
echo "  View config:  cat ~/.claude/settings.json"
echo "  Uninstall:    rm -rf ~/.claude/<hook-name>"
echo "  Full check:   curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify"
echo ""
echo -e "${DIM}https://github.com/Bande-a-Bonnot/Boucle-framework/tree/main/tools${RESET}"
