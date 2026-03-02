#!/bin/bash
set -e

echo "🚀 Setting up Boucle GitHub Integration Example"
echo

# Check if boucle binary exists
BOUCLE_BIN="../../target/release/boucle"
if [ ! -f "$BOUCLE_BIN" ]; then
    echo "❌ Boucle binary not found at $BOUCLE_BIN"
    echo "Please build Boucle first: cd ../.. && cargo build --release"
    exit 1
fi

# Create agent directory
AGENT_DIR="github-monitor-agent"
if [ -d "$AGENT_DIR" ]; then
    echo "⚠️  Agent directory $AGENT_DIR already exists"
    read -p "Remove and recreate? (y/N): " confirm
    if [[ $confirm == [yY]* ]]; then
        rm -rf "$AGENT_DIR"
    else
        echo "Setup cancelled"
        exit 1
    fi
fi

echo "📁 Creating agent directory: $AGENT_DIR"
mkdir -p "$AGENT_DIR"
cd "$AGENT_DIR"

echo "🔧 Initializing Boucle agent"
"$BOUCLE_BIN" init --name github-monitor

echo "📋 Copying configuration files"
cp ../boucle.toml . 2>/dev/null || echo "Using default boucle.toml"

echo "📂 Setting up context plugins"
mkdir -p context.d
cp ../context.d/github-stats context.d/
chmod +x context.d/github-stats

echo "🐍 Setting up Python environment"
if command -v python3 &> /dev/null; then
    pip3 install -r ../requirements.txt
    echo "✅ Python dependencies installed"
else
    echo "⚠️  Python 3 not found. Please install dependencies manually:"
    echo "    pip3 install -r ../requirements.txt"
fi

echo "🔑 Environment setup"
if [ ! -f ".env" ]; then
    echo "GITHUB_TOKEN=your_github_token_here" > .env
    echo "📝 Created .env file. Please edit it with your GitHub token:"
    echo "   1. Go to https://github.com/settings/tokens"
    echo "   2. Create a token with 'repo' scope"
    echo "   3. Replace 'your_github_token_here' in .env with your token"
else
    echo "✅ .env file already exists"
fi

echo
echo "🎉 Setup complete! To run your GitHub monitoring agent:"
echo
echo "   cd $AGENT_DIR"
echo "   # Edit .env file with your GitHub token"
echo "   ../../../target/release/boucle run"
echo
echo "To schedule automatic runs every 15 minutes:"
echo "   ../../../target/release/boucle schedule --interval 15m"
echo