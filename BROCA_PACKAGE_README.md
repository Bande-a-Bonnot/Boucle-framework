# Broca Memory for Claude Desktop

**Get persistent memory in Claude Desktop in under 5 minutes.**

This package contains everything you need to add file-based memory to Claude Desktop, so Claude can remember facts, preferences, and insights across conversations.

## Quick Start

### One-Line Installation
```bash
curl -s https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/install-broca.sh | bash
```

### Manual Installation
1. Download `install-broca.sh`
2. Run: `chmod +x install-broca.sh && ./install-broca.sh`
3. Restart Claude Desktop
4. Test: Ask Claude to "Remember this: I like dark themes"

## What You Get

- 💾 **Persistent memory** across Claude sessions
- 📁 **File-based storage** (no databases needed)
- 🏷️ **Tagging and search** for easy retrieval
- 📝 **Human-readable** Markdown files you can edit
- 🔗 **Memory relationships** and journaling
- 📊 **Memory statistics** and management

## Files in This Package

- `BROCA_FOR_CLAUDE_DESKTOP.md` - Complete setup guide and documentation
- `install-broca.sh` - Automated installer for macOS
- `uninstall-broca.sh` - Clean removal tool
- `BROCA_PACKAGE_README.md` - This file

## Example Usage

Once installed, you can use these commands in Claude:

**Remember information:**
```
Remember this: I prefer TypeScript over JavaScript for larger projects
Tags: preferences, programming
```

**Search memories:**
```
Search for: programming preferences
```

**Get memory stats:**
```
Show my memory statistics
```

**Create relationships:**
```
Remember: Redux has too much boilerplate
Tags: programming, state-management

Relate the TypeScript preference to the Redux opinion as "supports_preference"
```

## Memory Storage

Your memories are stored as readable Markdown files in `~/claude-memory/`:

```
claude-memory/
├── memory/
│   ├── knowledge/
│   │   ├── 2026-03-03_typescript-preference.md
│   │   └── 2026-03-03_redux-opinion.md
│   ├── journal/
│   └── RELATIONS.md
└── boucle.toml
```

Each memory file contains:
```markdown
---
type: fact
tags: [preferences, programming]
created: 2026-03-03_12-30-15
confidence: 0.8
---

# TypeScript Preference

I prefer TypeScript over JavaScript for larger projects.
```

## Backup Your Memories

Since memories are just files, backup is simple:
```bash
cd ~/claude-memory
git init && git add . && git commit -m "My Claude memories"
```

Or copy to cloud storage:
```bash
cp -r ~/claude-memory/ ~/Dropbox/claude-memory-backup/
```

## Uninstallation

```bash
./uninstall-broca.sh
```

This removes the Broca binary and Claude Desktop configuration, but leaves your memory files intact.

## Requirements

- macOS (currently)
- Claude Desktop app
- Rust/Cargo (automatically installed if missing)

## Troubleshooting

**Claude doesn't see memory tools:**
- Restart Claude Desktop completely
- Check that `boucle` is in your PATH: `which boucle`

**Installation fails:**
- Make sure you have write access to `/usr/local/bin/`
- Try running installer with `sudo` if needed

**Memory search not working:**
- Check memory files exist in `~/claude-memory/memory/knowledge/`
- Use simpler search terms

## Support

For issues or questions:
- Create an issue at: https://github.com/Bande-a-Bonnot/Boucle-framework
- Check the full documentation in `BROCA_FOR_CLAUDE_DESKTOP.md`

---

**Transform your Claude conversations from ephemeral to persistent.** 🧠✨