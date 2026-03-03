#!/bin/bash
# Broca for Claude Desktop Installer
# Installs file-based memory system for Claude Desktop

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}🧠 Broca for Claude Desktop Installer${NC}"
echo "Adding persistent memory to Claude Desktop..."
echo

# Check if we're on macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    echo -e "${RED}❌ This installer currently only supports macOS${NC}"
    echo "For other platforms, please build from source:"
    echo "https://github.com/Bande-a-Bonnot/Boucle-framework"
    exit 1
fi

# Check if Rust/Cargo is available
if ! command -v cargo &> /dev/null; then
    echo -e "${YELLOW}⚠️  Rust not found. Installing via rustup...${NC}"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source ~/.cargo/env
fi

# Create temporary directory
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

echo -e "${BLUE}📥 Downloading Boucle framework...${NC}"
git clone https://github.com/Bande-a-Bonnot/Boucle-framework.git
cd Boucle-framework

echo -e "${BLUE}🔨 Building Broca...${NC}"
cargo build --release

echo -e "${BLUE}📦 Installing Broca binary...${NC}"
sudo cp target/release/boucle /usr/local/bin/
chmod +x /usr/local/bin/boucle

# Set up memory directory
MEMORY_DIR="$HOME/claude-memory"
echo -e "${BLUE}📁 Setting up memory directory at $MEMORY_DIR...${NC}"
mkdir -p "$MEMORY_DIR"
cd "$MEMORY_DIR"

# Initialize Broca
/usr/local/bin/boucle init --name claude-memory

# Set up Claude Desktop configuration
CLAUDE_CONFIG_DIR="$HOME/Library/Application Support/Claude"
CLAUDE_CONFIG_FILE="$CLAUDE_CONFIG_DIR/claude_desktop_config.json"

echo -e "${BLUE}⚙️  Configuring Claude Desktop...${NC}"
mkdir -p "$CLAUDE_CONFIG_DIR"

# Check if config file exists
if [[ -f "$CLAUDE_CONFIG_FILE" ]]; then
    echo -e "${YELLOW}⚠️  Existing Claude Desktop config found${NC}"
    cp "$CLAUDE_CONFIG_FILE" "$CLAUDE_CONFIG_FILE.backup.$(date +%Y%m%d_%H%M%S)"
    echo "Backup created: $CLAUDE_CONFIG_FILE.backup.*"

    # Try to add Broca to existing config
    if command -v jq &> /dev/null; then
        # Use jq to safely merge configuration
        jq '.mcpServers.broca = {
            "command": "boucle",
            "args": ["mcp", "--stdio"],
            "cwd": "'$MEMORY_DIR'"
        }' "$CLAUDE_CONFIG_FILE" > "$CLAUDE_CONFIG_FILE.tmp"
        mv "$CLAUDE_CONFIG_FILE.tmp" "$CLAUDE_CONFIG_FILE"
    else
        echo -e "${YELLOW}⚠️  jq not found. Please manually add Broca to your Claude Desktop config:${NC}"
        echo
        echo "Add this to $CLAUDE_CONFIG_FILE:"
        echo '{
  "mcpServers": {
    "broca": {
      "command": "boucle",
      "args": ["mcp", "--stdio"],
      "cwd": "'$MEMORY_DIR'"
    }
  }
}'
    fi
else
    # Create new config file
    cat > "$CLAUDE_CONFIG_FILE" << EOF
{
  "mcpServers": {
    "broca": {
      "command": "boucle",
      "args": ["mcp", "--stdio"],
      "cwd": "$MEMORY_DIR"
    }
  }
}
EOF
fi

# Cleanup
cd /
rm -rf "$TEMP_DIR"

echo
echo -e "${GREEN}✅ Broca installation complete!${NC}"
echo
echo "Next steps:"
echo -e "${BLUE}1.${NC} Restart Claude Desktop completely"
echo -e "${BLUE}2.${NC} Try these commands in Claude:"
echo "   • Remember this: I prefer dark themes"
echo "   • Search for: preferences"
echo
echo "Your memories are stored in: $MEMORY_DIR/memory/"
echo
echo -e "${GREEN}🧠 Happy remembering!${NC}"

# Test installation
echo
echo -e "${BLUE}🧪 Testing installation...${NC}"
if /usr/local/bin/boucle --version; then
    echo -e "${GREEN}✅ Broca binary installed successfully${NC}"
else
    echo -e "${RED}❌ Installation test failed${NC}"
    exit 1
fi

if [[ -d "$MEMORY_DIR" ]]; then
    echo -e "${GREEN}✅ Memory directory created${NC}"
else
    echo -e "${RED}❌ Memory directory creation failed${NC}"
    exit 1
fi

if [[ -f "$CLAUDE_CONFIG_FILE" ]]; then
    echo -e "${GREEN}✅ Claude Desktop configuration updated${NC}"
else
    echo -e "${RED}❌ Claude Desktop configuration failed${NC}"
    exit 1
fi

echo
echo -e "${GREEN}🎉 All tests passed! Broca is ready to use.${NC}"