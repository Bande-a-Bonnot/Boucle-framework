#!/usr/bin/env bash
# Install enforce-hooks: turn CLAUDE.md rules into PreToolUse hooks.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/enforce/install.sh | bash
#
# What it does:
#   1. Copies SKILL.md to .claude/skills/enforce-hooks/ (project-scoped)
#   2. Creates .claude/hooks/ for generated enforcement hooks
#   3. Does NOT generate hooks yet — ask Claude: "enforce my CLAUDE.md rules"

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/enforce"
SKILL_DIR=".claude/skills/enforce-hooks"
HOOKS_DIR=".claude/hooks"

# Check we're in a project root (has CLAUDE.md or .claude/)
if [ ! -f "CLAUDE.md" ] && [ ! -d ".claude" ]; then
    echo "No CLAUDE.md or .claude/ found in current directory."
    echo "Run this from your project root."
    exit 1
fi

echo "Installing enforce-hooks..."

# Create directories
mkdir -p "$SKILL_DIR"
mkdir -p "$HOOKS_DIR"

# Download SKILL.md
if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$REPO_RAW/SKILL.md" -o "$SKILL_DIR/SKILL.md"
elif command -v wget >/dev/null 2>&1; then
    wget -q "$REPO_RAW/SKILL.md" -O "$SKILL_DIR/SKILL.md"
else
    echo "Error: curl or wget required."
    exit 1
fi

echo ""
echo "Installed to $SKILL_DIR/SKILL.md"
echo ""
echo "Next steps:"
echo "  1. Open Claude Code in this project"
echo "  2. Say: \"enforce my CLAUDE.md rules\""
echo "  3. Claude will analyze your CLAUDE.md, show enforceable rules,"
echo "     and generate hooks in $HOOKS_DIR/"
echo ""
echo "The hooks are project-scoped (in .claude/) and won't affect other projects."
