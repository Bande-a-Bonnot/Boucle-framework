#!/bin/bash
# Broca for Claude Desktop Uninstaller
# Removes Broca memory system from Claude Desktop

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${RED}🗑️  Broca Uninstaller${NC}"
echo "Removing Broca memory system..."
echo

# Ask for confirmation
echo -e "${YELLOW}⚠️  This will remove:${NC}"
echo "• Broca binary from /usr/local/bin/boucle"
echo "• Broca configuration from Claude Desktop"
echo
echo -e "${YELLOW}Note: Your memory files in ~/claude-memory will NOT be deleted${NC}"
echo "You can safely remove them manually if desired."
echo
read -p "Continue with uninstallation? [y/N]: " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Uninstallation cancelled."
    exit 0
fi

CLAUDE_CONFIG_DIR="$HOME/Library/Application Support/Claude"
CLAUDE_CONFIG_FILE="$CLAUDE_CONFIG_DIR/claude_desktop_config.json"

# Remove binary
echo -e "${BLUE}🗑️  Removing Broca binary...${NC}"
if [[ -f "/usr/local/bin/boucle" ]]; then
    sudo rm -f /usr/local/bin/boucle
    echo -e "${GREEN}✅ Binary removed${NC}"
else
    echo -e "${YELLOW}⚠️  Binary not found (already removed?)${NC}"
fi

# Update Claude Desktop configuration
echo -e "${BLUE}⚙️  Updating Claude Desktop configuration...${NC}"
if [[ -f "$CLAUDE_CONFIG_FILE" ]]; then
    # Create backup
    cp "$CLAUDE_CONFIG_FILE" "$CLAUDE_CONFIG_FILE.uninstall_backup.$(date +%Y%m%d_%H%M%S)"
    echo "Backup created: $CLAUDE_CONFIG_FILE.uninstall_backup.*"

    if command -v jq &> /dev/null; then
        # Use jq to safely remove Broca from config
        jq 'del(.mcpServers.broca)' "$CLAUDE_CONFIG_FILE" > "$CLAUDE_CONFIG_FILE.tmp"
        mv "$CLAUDE_CONFIG_FILE.tmp" "$CLAUDE_CONFIG_FILE"
        echo -e "${GREEN}✅ Configuration updated${NC}"
    else
        echo -e "${YELLOW}⚠️  jq not found. Please manually remove the 'broca' section from:${NC}"
        echo "$CLAUDE_CONFIG_FILE"
    fi
else
    echo -e "${YELLOW}⚠️  Claude Desktop config not found${NC}"
fi

echo
echo -e "${GREEN}✅ Broca uninstallation complete!${NC}"
echo
echo "Remaining files (not removed):"
echo "• Memory files in ~/claude-memory/"
echo "• Claude Desktop config backups"
echo
echo -e "${BLUE}To completely remove memory files:${NC}"
echo "rm -rf ~/claude-memory/"
echo
echo -e "${BLUE}Restart Claude Desktop to complete removal.${NC}"