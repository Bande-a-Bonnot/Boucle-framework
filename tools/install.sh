#!/bin/bash
# Boucle hooks installer — discover and install Claude Code hooks
# Usage: curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash
# Or:    curl ... | bash -s -- recommended
# Or:    curl ... | bash -s -- read-once file-guard git-safe
# Or:    curl ... | bash -s -- list
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
  echo "  upgrade               Re-download all installed hooks to latest version"
  echo "  uninstall <hook>      Remove a specific hook (files + settings.json entry)"
  echo "  uninstall all         Remove all hooks"
  echo "  backup                Snapshot settings.json (protects against auto-update wipes)"
  echo "  backup list           Show available backups"
  echo "  restore               Restore the most recent backup"
  echo "  restore <file>        Restore a specific backup"
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
  echo "  install.sh upgrade                # Update to latest"
  echo "  install.sh uninstall read-once    # Remove one hook"
  echo "  install.sh backup                 # Snapshot before updating Claude Code"
  echo "  install.sh restore                # Restore after a wipe"
  exit 0
fi

# Handle list subcommand — show installed hooks
if [ $# -gt 0 ] && [ "$1" = "list" ]; then
  found=0
  for hook in $ALL_HOOKS; do
    dir="${HOME}/.claude/${hook}"
    if [ -d "$dir" ] && [ -f "$dir/hook.sh" ]; then
      desc=$(hook_desc "$hook")
      echo -e "  ${GREEN}installed${RESET}  ${CYAN}${hook}${RESET}  ${desc}"
      found=$((found + 1))
    fi
  done
  if [ "$found" -eq 0 ]; then
    echo "  No hooks installed."
  else
    echo ""
    echo "  $found hook(s) installed."
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

  if [ "$upgraded" -gt 0 ]; then
    echo ""
    echo -e "${GREEN}${BOLD}Done!${RESET} Updated $upgraded hook(s). Changes take effect in your next Claude Code session."
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
    file-guard)
      # file-guard always blocks relative paths in Write/Edit (no config needed)
      result=$(echo '{"tool_name":"Write","tool_input":{"file_path":"relative/path.txt","content":"test"}}' | "$hook_path" 2>/dev/null || true)
      if echo "$result" | grep -q '"block"'; then
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
echo "  List installed: curl -fsSL $INSTALL_URL | bash -s -- list"
echo "  Upgrade all:    curl -fsSL $INSTALL_URL | bash -s -- upgrade"
echo "  Uninstall one:  curl -fsSL $INSTALL_URL | bash -s -- uninstall <hook-name>"
echo "  Uninstall all:  curl -fsSL $INSTALL_URL | bash -s -- uninstall all"
echo "  Backup:         curl -fsSL $INSTALL_URL | bash -s -- backup"
echo "  Restore:        curl -fsSL $INSTALL_URL | bash -s -- restore"
echo "  Full check:     curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify"
echo ""
echo -e "${DIM}https://github.com/Bande-a-Bonnot/Boucle-framework/tree/main/tools${RESET}"
