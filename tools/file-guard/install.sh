#!/bin/bash
# file-guard installer for Claude Code
# Usage: curl -sL <raw-url>/install.sh | bash
#
# Installs the file-guard hook into your Claude Code settings
# and creates a default .file-guard config if none exists.

set -euo pipefail

HOOK_URL="https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/file-guard/hook.sh"
SETTINGS_DIR="$HOME/.claude"
SETTINGS_FILE="$SETTINGS_DIR/settings.json"
HOOK_DIR="$SETTINGS_DIR/hooks"
HOOK_PATH="$HOOK_DIR/file-guard.sh"

echo "Installing file-guard for Claude Code..."

# Create directories
mkdir -p "$HOOK_DIR"

# Download hook
echo "  Downloading hook..."
if command -v curl &>/dev/null; then
  curl -sL "$HOOK_URL" -o "$HOOK_PATH"
elif command -v wget &>/dev/null; then
  wget -q "$HOOK_URL" -O "$HOOK_PATH"
else
  echo "Error: curl or wget required" >&2
  exit 1
fi
chmod +x "$HOOK_PATH"

# Register in settings.json
echo "  Registering hook..."
if [ -f "$SETTINGS_FILE" ]; then
  # Check if PreToolUse hooks already exist
  if python3 -c "
import json, sys
with open('$SETTINGS_FILE') as f:
    s = json.load(f)
hooks = s.setdefault('hooks', {})
pre = hooks.setdefault('PreToolUse', [])
# Check if already installed
for h in pre:
    if 'file-guard' in h.get('command', ''):
        print('already_installed')
        sys.exit(0)
pre.append({'type': 'command', 'command': '$HOOK_PATH'})
with open('$SETTINGS_FILE', 'w') as f:
    json.dump(s, f, indent=2)
print('added')
" 2>/dev/null; then
    :
  else
    echo "  Warning: Could not auto-register hook. Add manually to $SETTINGS_FILE"
    echo "  hooks.PreToolUse: [{\"type\": \"command\", \"command\": \"$HOOK_PATH\"}]"
  fi
else
  # Create minimal settings
  mkdir -p "$SETTINGS_DIR"
  cat > "$SETTINGS_FILE" <<'SETTINGS'
{
  "hooks": {
    "PreToolUse": [
      {
        "type": "command",
        "command": "HOOK_PATH_PLACEHOLDER"
      }
    ]
  }
}
SETTINGS
  sed -i.bak "s|HOOK_PATH_PLACEHOLDER|$HOOK_PATH|" "$SETTINGS_FILE"
  rm -f "$SETTINGS_FILE.bak"
fi

# Create default .file-guard if none exists
if [ ! -f ".file-guard" ]; then
  echo "  Creating default .file-guard config..."
  cat > ".file-guard" <<'GUARD'
# file-guard: Protected files and directories
# One pattern per line. Comments (#) and blank lines ignored.
#
# Examples:
#   .env              - exact file match
#   .env.*            - glob pattern (matches .env.local, .env.production)
#   secrets/          - entire directory (trailing slash)
#   *.pem             - all PEM files anywhere
#   credentials.*     - all credentials files

# Secrets and credentials
.env
.env.*
*.pem
*.key

# Common sensitive files
# credentials.*
# secrets/
# .ssh/
GUARD
  echo "  Created .file-guard — edit to customize protected files"
else
  echo "  .file-guard already exists — keeping your config"
fi

echo ""
echo "Done! file-guard is now active."
echo ""
echo "Protected files are listed in .file-guard (one per line)."
echo "Test it: ask Claude to 'write to .env' — it should be blocked."
echo ""
echo "Config:"
echo "  Hook: $HOOK_PATH"
echo "  Protected files: .file-guard"
echo "  Disable: FILE_GUARD_DISABLED=1"
echo "  Debug: FILE_GUARD_LOG=1"
