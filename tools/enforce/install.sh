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

# Check we're in a project root (has CLAUDE.md or .claude/ or .git/)
CREATED_CLAUDE_MD=false
if [ ! -f "CLAUDE.md" ] && [ ! -d ".claude" ]; then
    if [ ! -d ".git" ]; then
        echo "No CLAUDE.md, .claude/, or .git/ found in current directory."
        echo "Run this from your project root."
        exit 1
    fi

    # Create a CLAUDE.md with sensible safety defaults
    cat > CLAUDE.md << 'RULES'
## Safety @enforced
- Never modify .env files
- Do not use `git push --force`
- Never run `rm -rf /` or `rm -rf ~` or `rm -rf .`
- Do not commit directly to main

## Guidelines @enforced(warn)
- Always run tests before committing
- Read the relevant test file before editing source code
RULES
    CREATED_CLAUDE_MD=true
    echo "Created CLAUDE.md with safety defaults."
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

    # Install armor (self-protection) automatically
    echo ""
    if python3 "$ENFORCE_PY" --armor 2>/dev/null; then
        echo ""
        echo "Armor installed: hooks are protected from deletion."
    fi

    echo ""
    if [ "$CREATED_CLAUDE_MD" = true ]; then
        echo "A default CLAUDE.md was created. Edit it to match your project:"
        echo "  - Add file paths you want protected"
        echo "  - Add commands you want blocked"
        echo "  - Add @enforced to rules you want hard-blocked"
        echo "  - Use @enforced(warn) for rules that should warn but not block"
        echo ""
    fi
    echo "Verify:"
    echo "  python3 .claude/hooks/enforce-hooks.py --smoke-test   # test hooks work"
    echo "  python3 .claude/hooks/enforce-hooks.py --audit        # check coverage"
fi
