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
    echo ""
    echo "To get started, create a CLAUDE.md with some rules:"
    echo '  echo "## Safety @enforced" > CLAUDE.md'
    echo '  echo "- Never modify .env files" >> CLAUDE.md'
    echo '  echo "- Do not use git push --force" >> CLAUDE.md'
    echo ""
    echo "Then re-run this installer."
    exit 1
fi

echo "Installing enforce-hooks..."

# Check python3
if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 not found. Install Python 3.6+ and try again." >&2
    exit 1
fi

DL="curl -fsSL"
command -v curl >/dev/null 2>&1 || DL="wget -q -O -"

# Download enforce-hooks.py
TMPFILE="${TMPDIR:-/tmp}/enforce-hooks-installer.py"
if ! $DL "$REPO_RAW/enforce-hooks.py" > "$TMPFILE" 2>/dev/null; then
    echo "Error: download failed. Check your internet connection." >&2
    rm -f "$TMPFILE"
    exit 1
fi

# Verify download is not empty
if [ ! -s "$TMPFILE" ]; then
    echo "Error: downloaded file is empty. URL may have changed." >&2
    rm -f "$TMPFILE"
    exit 1
fi

# Install
if ! python3 "$TMPFILE" --install-plugin; then
    echo "Error: installation failed. Try downloading enforce-hooks.py manually." >&2
    rm -f "$TMPFILE"
    exit 1
fi

rm -f "$TMPFILE"
echo "Done. enforce-hooks is active for this project."
