# file-guard

A [Claude Code hook](https://docs.anthropic.com/en/docs/claude-code/hooks) that protects specified files and directories from being accessed or modified.

Two protection levels:
- **Write protection** (default): Claude can read protected files but cannot modify them.
- **Access denial** (`[deny]` section): Claude cannot read, search, or modify denied files at all.

## Why

AI coding assistants are powerful — but sometimes too powerful. You might not want Claude modifying your `.env`, overwriting your SSH keys, or touching production configs. And sometimes you need to block access entirely: codegen output, large generated files, or data that Claude should never read. `file-guard` handles both.

## Install

### One-liner

```bash
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/file-guard/install.sh | bash
```

### Manual

1. Download `hook.sh` to `~/.claude/hooks/file-guard.sh`
2. Make it executable: `chmod +x ~/.claude/hooks/file-guard.sh`
3. Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "type": "command",
        "command": "~/.claude/hooks/file-guard.sh"
      }
    ]
  }
}
```

4. Create `.file-guard` in your project root (see "Auto-detect" below, or create manually):

```
.env
.env.*
*.pem
*.key
secrets/
```

## Auto-detect sensitive files

Instead of writing `.file-guard` manually, scan your project for common sensitive files:

```bash
# Preview what would be protected (no files written)
bash init.sh --dry-run

# Generate .file-guard from detected files
bash init.sh

# Add newly detected patterns to an existing .file-guard
bash init.sh --append
```

Detects: `.env` files, certificates (`*.pem`, `*.key`, `*.p12`), SSH keys, credentials files, framework secrets (Rails `master.key`, WordPress `wp-config.php`, Django `local_settings.py`), Terraform state, secret directories, and more.

The generated config is yours to edit -- review and adjust patterns after running.

## Config

The `.file-guard` file lists protected paths, one per line:

| Pattern | What it matches |
|---------|----------------|
| `.env` | Exact file `.env` |
| `.env.*` | Glob: `.env.local`, `.env.production`, etc. |
| `*.pem` | All PEM files in any directory |
| `credentials.*` | `credentials.json`, `credentials.yaml`, etc. |
| `secrets/` | Everything under `secrets/` (trailing slash = directory) |
| `# comment` | Ignored (comments and blank lines) |
| `[deny]` | Section header: everything below is access-denied |
| `[write]` | Section header: switch back to write-protect mode |

## What it protects against

### Write-protect mode (default)

| Tool | Detection |
|------|-----------|
| **Write** | Checks `file_path` against protected patterns |
| **Edit** | Checks `file_path` against protected patterns |
| **Bash** | Detects modifying commands (`rm`, `mv`, `>`, `>>`, etc.) targeting protected paths |
| **Read, Grep, Glob** | Allowed (read-only operations are safe for write-protected files) |

### Access denial mode (`[deny]` section)

| Tool | Detection |
|------|-----------|
| **Read** | Checks `file_path` against denied patterns |
| **Grep** | Checks search `path` against denied patterns |
| **Glob** | Checks search `path` against denied patterns |
| **Write/Edit** | Checks `file_path` against denied patterns |
| **Bash** | Blocks any command referencing denied paths (read or write) |

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `FILE_GUARD_CONFIG` | `.file-guard` | Path to config file |
| `FILE_GUARD_DISABLED` | `0` | Set to `1` to disable |
| `FILE_GUARD_LOG` | `0` | Set to `1` for debug logging to stderr |

## Example

```
# .file-guard

# Write-protected: Claude can read these but not modify them
.env
.env.*
*.pem
*.key
credentials.*

# Infrastructure
terraform.tfstate
.ssh/

# Production configs
config/production/

# Access denied: Claude cannot read, search, or modify these at all
[deny]
codegen/
generated/
*.generated.ts
```

With this config, Claude can `cat .env` to check config format, but cannot modify it. If Claude tries to read anything under `codegen/`:

```
file-guard: reading "codegen/models.ts" is denied (matches [deny] pattern "codegen/"). Check .file-guard config.
```

This blocks Read, Grep, Glob, Write, Edit, and Bash access to denied paths. Useful for large generated codebases where Claude should use an MCP server instead of reading files directly.

## Pairs well with

- [read-once](../read-once/) — prevents redundant file reads, saves tokens
- Both hooks can run together in your PreToolUse pipeline

## Testing

```bash
bash test.sh       # hook tests (86 assertions)
bash test-init.sh  # init scanner tests (33 assertions)
```

## License

MIT
