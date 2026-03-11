# bash-guard

A Claude Code hook that prevents dangerous bash commands from running.

Claude Code can execute arbitrary bash commands. Most of the time, that's fine. But sometimes — through hallucination, bad instructions, or prompt injection — it can run commands that cause irreversible damage.

bash-guard intercepts these before they execute.

## What it blocks

| Category | Examples | Why |
|----------|----------|-----|
| Recursive delete | `rm -rf /`, `rm -rf ~`, `rm -rf *` | Irreversible data loss |
| Dangerous permissions | `chmod -R 777`, `chmod -R 000` | Security holes or lockouts |
| Pipe to shell | `curl ... \| bash`, `wget ... \| sh` | Executes untrusted code |
| Privilege escalation | `sudo anything` | AI should not have root |
| Broad kill | `kill -9 -1`, `killall -9` | Kills all processes |
| Disk operations | `dd of=/dev/sda`, `mkfs` | Destroys filesystems |
| System writes | `> /etc/hosts`, `> /usr/bin/...` | Breaks OS |
| Code injection | `eval "$variable"` | Arbitrary execution |
| Global installs | `npm install -g` | Modifies system packages |

Safe variants are allowed: `rm -rf ./build`, `chmod 644 file.txt`, `curl -o file url`, `kill -9 12345`.

## Install

```bash
curl -sL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/bash-guard/install.sh | bash
```

Or install all hooks at once:
```bash
curl -sL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- all
```

## Configure exceptions

Create a `.bash-guard` file in your project root:

```
allow: sudo
allow: rm -rf
allow: pipe-to-shell
```

Available allow keys: `rm -rf`, `chmod -R`, `chown -R`, `pipe-to-shell`, `sudo`, `kill -9`, `dd`, `mkfs`, `system-write`, `eval`, `global-install`.

## Disable temporarily

```bash
export BASH_GUARD_DISABLED=1
```

## How it works

bash-guard is a [PreToolUse hook](https://docs.anthropic.com/en/docs/claude-code/hooks) that runs before every tool call. It checks if the tool is `Bash`, parses the command, and blocks known-dangerous patterns. If a command is blocked, Claude Code sees the reason and suggestion, so it can try a safer alternative.

## Test

```bash
bash test.sh
```

48 tests covering all blocked patterns plus safe variants.

## License

MIT
