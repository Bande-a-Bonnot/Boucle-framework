#!/bin/bash
# Boucle hooks installer — discover and install Claude Code hooks
# Usage: curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash
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
    branch-guard)  echo "Prevent direct commits to main/master (feature-branch workflow)" ;;
    session-log)   echo "Audit trail — log every tool call to JSONL" ;;
    *)             echo "Unknown hook" ;;
  esac
}

ALL_HOOKS="read-once file-guard git-safe bash-guard branch-guard session-log"

# Check prerequisites
if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 not found. Install Python 3 and try again." >&2
    exit 1
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
  echo -e "  ${CYAN}${hook}${RESET}  ${desc}  [${status}]"
done
echo ""

# Parse arguments or ask interactively
if [ $# -gt 0 ]; then
  selected="$*"
else
  echo -e "${BOLD}Which hooks to install?${RESET}"
  echo "  Enter hook names separated by spaces, or 'all' for everything"
  echo -n "> "
  read -r input
  if [ "$input" = "all" ]; then
    selected="$ALL_HOOKS"
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
    read-once|file-guard|git-safe|bash-guard|branch-guard|session-log) ;;
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
import json, sys, os

settings_path = sys.argv[1]
hooks_to_add = sys.argv[2:]

with open(settings_path) as f:
    try:
        settings = json.load(f)
    except (json.JSONDecodeError, ValueError):
        settings = {}

if "hooks" not in settings:
    settings["hooks"] = {}

for hook in hooks_to_add:
    # session-log fires after tool calls; safety hooks fire before
    event = "PostToolUse" if hook == "session-log" else "PreToolUse"
    command = os.path.expanduser("~/.claude/" + hook + "/hook.sh")
    entry = {"hooks": [{"type": "command", "command": command, "timeout": 5000}]}

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
echo -e "${GREEN}${BOLD}Done!${RESET} Hooks are active for your next Claude Code session."
echo ""
echo "Manage hooks:"
echo "  View config:  cat ~/.claude/settings.json"
echo "  Uninstall:    rm -rf ~/.claude/<hook-name>"
echo ""
echo -e "${DIM}https://github.com/Bande-a-Bonnot/Boucle-framework/tree/main/tools${RESET}"
