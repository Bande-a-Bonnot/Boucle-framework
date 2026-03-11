# file-guard

A [Claude Code hook](https://docs.anthropic.com/en/docs/claude-code/hooks) that protects specified files and directories from being modified.

When Claude tries to write, edit, or run commands that would modify protected files, this hook blocks the operation and explains why.

## Why

AI coding assistants are powerful — but sometimes too powerful. You might not want Claude modifying your `.env`, overwriting your SSH keys, or touching production configs. `file-guard` lets you define exactly which files are off-limits.

## Install

### One-liner

```bash
curl -sL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/file-guard/install.sh | bash
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

## What it protects against

| Tool | Detection |
|------|-----------|
| **Write** | Checks `file_path` against protected patterns |
| **Edit** | Checks `file_path` against protected patterns |
| **Bash** | Detects modifying commands (`rm`, `mv`, `>`, `>>`, etc.) targeting protected paths |
| **Read, Grep, etc.** | Not intercepted (read-only operations are safe) |

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `FILE_GUARD_CONFIG` | `.file-guard` | Path to config file |
| `FILE_GUARD_DISABLED` | `0` | Set to `1` to disable |
| `FILE_GUARD_LOG` | `0` | Set to `1` for debug logging to stderr |

## Example

```
# .file-guard
# Secrets
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
```

With this config, if Claude tries to write to `.env`:

```
file-guard: '.env' is protected (matches pattern '.env'). Check .file-guard config to modify protections.
```

## Pairs well with

- [read-once](../read-once/) — prevents redundant file reads, saves tokens
- Both hooks can run together in your PreToolUse pipeline

## Testing

```bash
bash test.sh       # hook tests (37 assertions)
bash test-init.sh  # init scanner tests (33 assertions)
```

## License

MIT
