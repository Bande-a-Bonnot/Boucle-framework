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
echo ""
echo "Done. enforce-hooks is active for this project."

# Show what rules were detected
ENFORCE_PY=".claude/hooks/enforce-hooks.py"
if [ -f "$ENFORCE_PY" ] && [ -f "CLAUDE.md" ]; then
    COUNT=$(python3 "$ENFORCE_PY" --scan --json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('enforceable',[])))" 2>/dev/null || echo "0")
    if [ "$COUNT" -gt 0 ]; then
        echo ""
        echo "Enforcing $COUNT rule(s) from your CLAUDE.md:"
        python3 "$ENFORCE_PY" --scan --json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
for r in d.get('enforceable', [])[:8]:
    print(f'  [{r[\"hook_type\"]}] {r[\"description\"]}')
if len(d.get('enforceable', [])) > 8:
    print(f'  ... and {len(d[\"enforceable\"]) - 8} more')
" 2>/dev/null || true
    else
        echo ""
        echo "No @enforced rules found yet. Add some to your CLAUDE.md:"
        echo ""
        echo "  ## Safety @enforced"
        echo "  - Never modify .env files"
        echo "  - Do not use git push --force"
        echo "  - Always run tests before committing"
    fi
    echo ""
    echo "Next steps:"
    echo "  python3 .claude/hooks/enforce-hooks.py --smoke-test   # verify hooks work"
    echo "  python3 .claude/hooks/enforce-hooks.py --armor        # protect hooks from deletion"
fi
