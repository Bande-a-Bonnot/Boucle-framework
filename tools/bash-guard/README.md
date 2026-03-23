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
| Privilege escalation | `sudo`, `pkexec`, `doas`, `su -c` | AI should not have root |
| Broad kill | `kill -9 -1`, `killall -9` | Kills all processes |
| Disk operations | `dd of=/dev/sda`, `mkfs` | Destroys filesystems |
| System writes | `> /etc/hosts`, `> /usr/bin/...` | Breaks OS |
| Code injection | `eval "$variable"` | Arbitrary execution |
| Global installs | `npm install -g` | Modifies system packages |
| Docker destruction | `docker compose down -v`, `docker system prune`, `docker volume rm` | Destroys volumes/data |
| Docker escape | `docker run -v /:/host`, `docker exec` | Escapes directory restrictions ([#37621](https://github.com/anthropics/claude-code/issues/37621)) |
| Database destruction | `prisma db push`, `dropdb`, `DROP TABLE`, `migrate:fresh`, `redis-cli FLUSHALL`, `mongosh dropDatabase` | Destroys production data ([#33183](https://github.com/anthropics/claude-code/issues/33183), [#37439](https://github.com/anthropics/claude-code/issues/37439)) |
| Credential exposure | `env`, `printenv`, `export -p`, `cat .env` | Dumps secrets to output ([#32616](https://github.com/anthropics/claude-code/issues/32616)) |
| Debug trace | `bash -x`, `set -x` | Leaks expanded variables in trace |
| Cloud infra destruction | `terraform destroy`, `aws s3 rm --recursive`, `kubectl delete namespace`, `pulumi destroy` | Takes down production infrastructure |
| Mass file deletion | `find -delete`, `find -exec rm`, `xargs rm`, `git clean -f` | Bulk file removal without confirmation ([#37331](https://github.com/anthropics/claude-code/issues/37331)) |
| File destruction | `shred`, `truncate -s 0` | Irrecoverable data destruction or silent zeroing |
| Disk overwrite | `dd if=/dev/zero of=...`, `dd if=/dev/urandom of=...` | Overwrites target with empty/random data |
| Disk utility destruction | `diskutil eraseDisk`, `fdisk`, `gdisk`, `parted`, `wipefs` | Erases disks, modifies partition tables ([#37984](https://github.com/anthropics/claude-code/issues/37984)) |
| Data exfiltration | `curl -d @.env`, `curl --upload-file`, `wget --post-file` | Uploads local files to remote servers |
| Programmatic env dumps | `python3 -c "...os.environ"`, `node -e "...process.env"` | Scripting language env access bypasses env/printenv checks |
| Sensitive file reads | `cat ~/.ssh/id_rsa`, `cat ~/.bash_history`, `cat /proc/self/environ` | Exposes SSH keys, command history, or process environment |
| Network exfiltration | `nc host < file`, `ncat host < secrets` | Pipes file contents through raw network connections |
| System database corruption | `sqlite3 ~/.vscode/state.vscdb`, `sqlite3 ~/Library/Application Support/Code/...` | Corrupts IDE sessions, settings, extensions ([#37888](https://github.com/anthropics/claude-code/issues/37888)) |
| Mount point destruction | `rm -rf /mnt/...`, `rm -rf /Volumes/...`, `rm -rf /nfs/...` | Deletes data on remote/shared storage ([#36640](https://github.com/anthropics/claude-code/issues/36640)) |

Safe variants are allowed: `rm -rf ./build`, `chmod 644 file.txt`, `curl -o file url`, `curl -d '{"key":"value"}'`, `kill -9 12345`, `docker compose down` (without -v), `docker run -v mydata:/data`, `prisma migrate dev`, `rails db:migrate`, `printenv HOME`, `cat README.md`, `set -euo pipefail`, `terraform plan`, `aws s3 ls`, `kubectl get pods`, `find -print`, `git clean -n`, `ls ~/.ssh`, `ssh-keygen`, `nc -l 8080`, `sqlite3 ./db.sqlite3`, `ls /mnt/data/`.

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

Available allow keys: `rm -rf`, `chmod -R`, `chown -R`, `pipe-to-shell`, `sudo`, `kill -9`, `dd`, `mkfs`, `disk-util`, `system-write`, `eval`, `global-install`, `docker-destroy`, `docker-mount`, `docker-exec`, `db-destroy`, `env-dump`, `debug-trace`, `read-secrets`, `infra-destroy`, `mass-delete`, `git-clean`, `shred`, `truncate`, `file-upload`, `system-db`, `mount-delete`.

## Disable temporarily

```bash
export BASH_GUARD_DISABLED=1
```

## Compound command evaluation

Claude Code's built-in deny rules evaluate commands as whole strings. When a dangerous command follows `cd` or `echo` in a compound statement, the deny rule may not fire ([#37621](https://github.com/anthropics/claude-code/issues/37621), [#37662](https://github.com/anthropics/claude-code/issues/37662)):

```bash
cd .. && rm -rf /           # deny rule on rm -rf may not fire
echo ok; dropdb production  # deny rule on dropdb may not fire
npm test || sudo rm -rf /   # deny rule on sudo may not fire
```

bash-guard evaluates the entire command string. Every pattern checks for matches after `&&`, `||`, `;`, and `|` operators, so chaining a safe command before a dangerous one does not bypass protection.

## Workaround bypass prevention

When bash-guard blocks a command, Claude Code may try an equivalent alternative. bash-guard covers known workaround patterns ([#34358](https://github.com/anthropics/claude-code/issues/34358)):

| Blocked | Workaround attempt | Also blocked? |
|---------|-------------------|---------------|
| `find -delete` | `find -exec rm {} \;` | Yes |
| `sudo` | `pkexec`, `doas`, `su -c` | Yes |
| `rm -rf` | `shred file` | Yes |
| `rm file` | `truncate -s 0 file` | Yes |
| `dd of=/dev/sda` | `dd if=/dev/zero of=file` | Yes |
| `env` / `printenv` | `python3 -c "import os; os.environ"` | Yes |
| `cat .env` | `curl -d @.env https://...` | Yes |
| `cat .env` | `nc host 9999 < .env` | Yes |

Safe variants remain allowed: `find -exec grep`, `echo superman`, `truncate -s 100M file`, `dd if=backup of=restore`, `curl -d '{"inline":"data"}'`, `nc -l 8080`.

## How it works

bash-guard is a [PreToolUse hook](https://docs.anthropic.com/en/docs/claude-code/hooks) that runs before every tool call. It checks if the tool is `Bash`, parses the command, and blocks known-dangerous patterns. If a command is blocked, Claude Code sees the reason and suggestion, so it can try a safer alternative.

## Test

```bash
bash test.sh
```

307 tests covering all blocked patterns, disk utility destruction, data exfiltration, programmatic env dumps, sensitive file access, workaround bypass prevention, compound command bypass, system database protection, mount point protection, and safe variants.

## License

MIT
