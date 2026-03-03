# Broca for Claude Desktop

Add persistent file-based memory to Claude Desktop in 5 minutes.

## What is Broca?

Broca is a file-based memory system for AI agents. Instead of losing context between conversations, Claude can remember facts, decisions, and insights across sessions. Your memories are stored as readable Markdown files that you can edit, version with git, and backup anywhere.

## Features

- 💾 **Persistent memory** across Claude sessions
- 📁 **File-based** - no databases, just Markdown files
- 🏷️ **Tagging and search** for easy retrieval
- 🔗 **Relationships** between memories
- 📝 **Human-readable** - edit your memories directly
- 📊 **Memory statistics** and management
- ⚡ **Fast search** with relevance ranking

## Quick Setup

### 1. Install Boucle

**Option A: Download Binary (Recommended)**
```bash
# Download latest release (when available)
curl -L https://github.com/Bande-a-Bonnot/Boucle-framework/releases/latest/download/boucle-macos -o boucle
chmod +x boucle
sudo mv boucle /usr/local/bin/
```

**Option B: Build from Source**
```bash
git clone https://github.com/Bande-a-Bonnot/Boucle-framework.git
cd Boucle-framework
cargo build --release
sudo cp target/release/boucle /usr/local/bin/
```

### 2. Initialize Memory

```bash
# Create a memory directory
mkdir ~/claude-memory
cd ~/claude-memory

# Initialize Broca
boucle init --name claude-memory
```

### 3. Add to Claude Desktop

Add this to your Claude Desktop MCP configuration:

**macOS**: `~/Library/Application Support/Claude/claude_desktop_config.json`

```json
{
  "mcpServers": {
    "broca": {
      "command": "boucle",
      "args": ["mcp", "--stdio"],
      "cwd": "~/claude-memory"
    }
  }
}
```

### 4. Restart Claude Desktop

Close and reopen Claude Desktop. You should now have Broca memory tools available.

## Usage Examples

### Basic Memory Operations

```
Remember this: I prefer TypeScript over JavaScript for larger projects
Tags: preferences, programming, javascript, typescript
```

```
Search for: programming preferences
```

### Project Memory

```
Remember: Project X uses PostgreSQL database with connection pool of 20
Tags: project-x, database, postgresql
```

```
Recall: How many connections in Project X database?
```

### Decision Tracking

```
Remember: Decided to use React Query for state management after comparing with Redux
Reason: Better TypeScript support and less boilerplate
Tags: decisions, react, state-management
```

```
Show memories tagged: decisions
```

## Available Memory Tools

- **Remember**: Store new information with tags
- **Recall**: Search memories by content
- **Search Tags**: Find memories with specific tags
- **Show Memory**: Get details about specific memories
- **Relate Memories**: Create connections between memories
- **Journal**: Add timestamped journal entries
- **Memory Stats**: View memory system statistics

## Memory File Structure

Your memories are stored as readable Markdown files:

```
claude-memory/
├── memory/
│   ├── knowledge/
│   │   ├── 2026-03-03_12-30-15_typescript-preference.md
│   │   ├── 2026-03-03_12-35-22_project-x-database.md
│   │   └── ...
│   ├── journal/
│   │   └── 2026-03-03_12-40-10.md
│   ├── RELATIONS.md
│   └── INDEX.txt
└── boucle.toml
```

Each memory file contains:

```markdown
---
type: fact
tags: [preferences, programming, typescript]
created: 2026-03-03_12-30-15
confidence: 0.8
---

# TypeScript Preference

I prefer TypeScript over JavaScript for larger projects because of better tooling and type safety.
```

## Backup Your Memories

Since memories are just files, backup is simple:

```bash
# Version control
cd ~/claude-memory
git init
git add .
git commit -m "Initial memories"

# Backup to cloud
rsync -av memory/ ~/Dropbox/claude-memory/
```

## Troubleshooting

### Claude Desktop doesn't see Broca tools

1. Check that `boucle` is in your PATH: `which boucle`
2. Verify config file location and JSON syntax
3. Check Claude Desktop logs for MCP errors
4. Restart Claude Desktop completely

### Memory search isn't finding things

- Use simpler search terms
- Check that memories have relevant tags
- Use "Show Memory Stats" to verify memories are being stored

### Permission errors

```bash
# Fix permissions if needed
chmod +x /usr/local/bin/boucle
```

## Advanced Usage

### Custom Memory Location

```json
{
  "mcpServers": {
    "broca": {
      "command": "boucle",
      "args": ["mcp", "--stdio"],
      "cwd": "/path/to/your/memory/directory"
    }
  }
}
```

### Multiple Memory Spaces

```json
{
  "mcpServers": {
    "work-memory": {
      "command": "boucle",
      "args": ["mcp", "--stdio"],
      "cwd": "~/work-memory"
    },
    "personal-memory": {
      "command": "boucle",
      "args": ["mcp", "--stdio"],
      "cwd": "~/personal-memory"
    }
  }
}
```

## FAQ

**Q: Is my memory data private?**
A: Yes, memories are stored locally on your machine. Nothing is sent to external servers.

**Q: Can I edit memories manually?**
A: Yes! They're just Markdown files. Edit them directly with any text editor.

**Q: What happens if I delete a memory file?**
A: The memory is gone. Make sure to backup important memories.

**Q: Can I share memories between agents?**
A: Yes, multiple MCP clients can use the same memory directory for collaboration.

**Q: How much memory does this use?**
A: Very little. Each memory is a small text file. Even thousands of memories use minimal disk space.

---

**Happy remembering!** 🧠

For issues or questions, visit: https://github.com/Bande-a-Bonnot/Boucle-framework