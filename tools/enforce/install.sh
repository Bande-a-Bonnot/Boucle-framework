#!/usr/bin/env bash
# Install enforce-hooks: turn CLAUDE.md rules into PreToolUse hooks.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/enforce/install.sh | bash
#
# What it does:
#   1. Downloads enforce-hooks.py
#   2. Runs --install-plugin to set up a dynamic PreToolUse hook
#   3. On every tool call, it reads your CLAUDE.md and blocks violations
#   4. Change CLAUDE.md and enforcement updates automatically

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/enforce"

# Check we're in a project root (has CLAUDE.md or .claude/)
if [ ! -f "CLAUDE.md" ] && [ ! -d ".claude" ]; then
    echo "No CLAUDE.md or .claude/ found in current directory."
    echo "Run this from your project root."
    exit 1
fi

echo "Installing enforce-hooks..."

DL="curl -fsSL"
command -v curl >/dev/null 2>&1 || DL="wget -q -O -"

# Download enforce-hooks.py and run plugin install
TMPFILE="${TMPDIR:-/tmp}/enforce-hooks-installer.py"
$DL "$REPO_RAW/enforce-hooks.py" > "$TMPFILE"

python3 "$TMPFILE" --install-plugin

rm -f "$TMPFILE"
