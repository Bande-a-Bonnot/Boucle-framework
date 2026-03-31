#!/bin/bash
# bash-guard: PreToolUse hook for Claude Code
# Prevents dangerous bash commands that can cause irreversible damage.
#
# Blocked operations:
#   - rm -rf on critical paths (/, ~, *, ..)
#   - chmod/chown -R with dangerous permissions
#   - Piping untrusted content to shell (curl|sh, wget|bash)
#   - sudo (privilege escalation)
#   - kill -9 on broad targets
#   - dd/mkfs targeting disks
#   - Disk utility destruction (diskutil erase/partition, fdisk, gdisk, parted, sfdisk, wipefs)
#   - Overwriting system directories
#   - Docker data destruction (compose down -v, system prune, volume rm)
#   - Docker escape (host mounts, docker exec)
#   - Database destruction (prisma db push, dropdb, DROP/TRUNCATE, db:drop, migrate:fresh,
#     doctrine:schema:drop, sequelize db:drop, redis FLUSHALL, mongo dropDatabase, wp db reset)
#   - Credential exposure (env/printenv dumps, export -p, bash -x, set -x, cat .env/.pem/.key)
#   - Cloud infrastructure destruction (terraform destroy, pulumi destroy, aws s3 rm --recursive,
#     kubectl delete namespace/deployment, gcloud delete)
#   - Mass file deletion (find -delete, find -exec rm, xargs rm, git clean -f)
#   - Privilege escalation alternatives (pkexec, doas, su -c/root)
#   - File destruction bypasses (shred, truncate -s 0, dd from /dev/zero)
#   - Data exfiltration (curl/wget file upload, netcat/socat piping)
#   - Programmatic env dumps (python os.environ, node process.env, ruby ENV)
#   - Sensitive file reads (SSH private keys, shell history, /proc/*/environ)
#   - System database corruption (sqlite3 on VSCode .vscdb, IDE internals, app config DBs)
#   - Mount point destruction (rm -rf on /mnt, /media, /Volumes, NFS paths)
#   - Encoding bypasses (base64/hex/octal decode piped to shell, reversed strings)
#   - Process substitution downloads (bash <(curl ...), sh <(wget ...))
#   - Programming language shell wrappers (python subprocess, ruby system, perl exec, node child_process)
#   - Here-string/here-doc to shell (bash <<< "cmd", sh << EOF, bypasses pipe detection)
#   - eval with string literals (eval "rm -rf /")
#   - xargs to shell interpreter (xargs bash -c)
#   - LD_PRELOAD/LD_LIBRARY_PATH injection (library hijacking)
#   - IFS manipulation (command parsing hijack)
#   - Wrapper command bypass (timeout/nohup/strace hiding dangerous ops)
#   - Credential file copy/move/scp (.ssh/, .aws/, .gnupg/, .netrc)
#   - macOS Keychain access (security find-generic-password, dump-keychain)
#   - Scheduled task persistence (crontab, launchctl)
#   - System service management (systemctl, service start/stop)
#   - SSH key generation and agent management (ssh-keygen, ssh-add)
#   - git push --force (overwrites remote history)
#   - git filter-branch (history rewriting)
#   - docker rm -f (force container removal)
#   - passwd (credential modification)
#   - pkill -9 (mass process termination)
#   - yarn/pnpm global installs
#
# Install:
#   curl -sL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/bash-guard/install.sh | bash
#
# Config (.bash-guard):
#   allow: sudo           # whitelist specific operations
#   allow: rm -rf
#   allow: pipe-to-shell
#   deny: rm              # block ALL rm commands (not just rm -rf on critical paths)
#   deny: unlink          # block unlink commands
#   deny: find.*-delete   # block find with -delete flag (regex supported)
#
# Env vars:
#   BASH_GUARD_DISABLED=1    Disable the hook entirely
#   BASH_GUARD_LOG=1         Log all checks to stderr

set -euo pipefail

if [ "${BASH_GUARD_DISABLED:-0}" = "1" ]; then
  exit 0
fi

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only check Bash commands
if [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
if [ -z "$COMMAND" ]; then
  exit 0
fi

log() {
  if [ "${BASH_GUARD_LOG:-0}" = "1" ]; then
    echo "[bash-guard] $*" >&2
  fi
}

# Load allowlist and denylist from .bash-guard config
ALLOWED=()
DENIED=()
CONFIG="${BASH_GUARD_CONFIG:-.bash-guard}"
if [ -f "$CONFIG" ]; then
  while IFS= read -r line; do
    line=$(echo "$line" | sed 's/#.*//' | xargs)
    [ -z "$line" ] && continue
    if [[ "$line" == allow:* ]]; then
      pattern=$(echo "$line" | sed 's/^allow:\s*//' | xargs)
      ALLOWED+=("$pattern")
    elif [[ "$line" == deny:* ]]; then
      pattern=$(echo "$line" | sed 's/^deny:\s*//' | xargs)
      DENIED+=("$pattern")
    fi
  done < "$CONFIG"
fi

# Check if an operation is allowed via config
is_allowed() {
  local op="$1"
  for a in "${ALLOWED[@]+"${ALLOWED[@]}"}"; do
    if [ "$a" = "$op" ]; then
      log "ALLOWED by config: $op"
      return 0
    fi
  done
  return 1
}

block() {
  local reason="$1"
  local suggestion="${2:-}"
  local msg="bash-guard: $reason"
  if [ -n "$suggestion" ]; then
    msg="$msg Suggestion: $suggestion"
  fi
  jq -cn --arg r "$msg" '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":$r}}'
  exit 0
}

# --- Custom deny rules (from .bash-guard config) ---
for denied in "${DENIED[@]+"${DENIED[@]}"}"; do
  if echo "$COMMAND" | grep -qE "(^|\s|;|&&|\|\|)${denied}" 2>/dev/null; then
    block "Command matches deny rule '${denied}' in .bash-guard config." "Remove the deny rule or add a matching allow rule to override."
  fi
done

# --- Dangerous operation checks ---

# rm -rf on critical/broad paths
if echo "$COMMAND" | grep -qE 'rm\s+(-[a-zA-Z]*r[a-zA-Z]*f|(-[a-zA-Z]*f[a-zA-Z]*r))\s' 2>/dev/null; then
  # Check for critical targets
  if echo "$COMMAND" | grep -qE 'rm\s+-[rRf]+\s+(/(\s|$)|/\*|~(/|\s|$)|\.\.|/usr|/etc|/var|/home|/System|/Library|\$HOME)' 2>/dev/null; then
    is_allowed "rm -rf" || block "rm -rf targeting a critical system path. This would cause irreversible data loss." "Be specific about which files to delete, or add 'allow: rm -rf' to .bash-guard."
  fi
  # Check for wildcard-only targets
  if echo "$COMMAND" | grep -qE 'rm\s+-[rRf]+\s+\*\s*$' 2>/dev/null; then
    is_allowed "rm -rf" || block "rm -rf * would recursively delete everything in the current directory." "Be specific about which files to delete, or add 'allow: rm -rf' to .bash-guard."
  fi
fi

# chmod -R with dangerous permissions (777, 000)
if echo "$COMMAND" | grep -qE 'chmod\s+(-[a-zA-Z]*R|--recursive)\s' 2>/dev/null; then
  if echo "$COMMAND" | grep -qE 'chmod\s+.*\s(777|000|666)\s' 2>/dev/null; then
    is_allowed "chmod -R" || block "Recursive chmod with dangerous permissions (777/000/666) affects all files in the tree." "Apply permissions to specific files, or add 'allow: chmod -R' to .bash-guard."
  fi
fi

# chown -R to root or broad changes
if echo "$COMMAND" | grep -qE 'chown\s+(-[a-zA-Z]*R|--recursive)\s.*\s(/|~|/usr|/etc|/var|/home)' 2>/dev/null; then
  is_allowed "chown -R" || block "Recursive chown on a critical path can break system permissions." "Be specific about which directory to change, or add 'allow: chown -R' to .bash-guard."
fi

# Pipe to shell (curl|sh, wget|bash, curl|bash, etc.)
if echo "$COMMAND" | grep -qE '(curl|wget)\s.*\|\s*(sh|bash|zsh|dash|ksh|source|eval)' 2>/dev/null; then
  is_allowed "pipe-to-shell" || block "Piping downloaded content directly to a shell executes untrusted code." "Download the script first, review it, then run it. Or add 'allow: pipe-to-shell' to .bash-guard."
fi

# sudo and alternatives (privilege escalation)
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)sudo\s' 2>/dev/null; then
  is_allowed "sudo" || block "sudo escalates to root privileges. AI agents should not run commands as root." "Run without sudo, or add 'allow: sudo' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)(pkexec|doas)\s' 2>/dev/null; then
  is_allowed "sudo" || block "pkexec/doas escalates to root privileges, same as sudo. AI agents should not run commands as root." "Run without privilege escalation, or add 'allow: sudo' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)su\s+(-c\s|root)' 2>/dev/null; then
  is_allowed "sudo" || block "su -c or su root escalates to root privileges. AI agents should not run commands as root." "Run without privilege escalation, or add 'allow: sudo' to .bash-guard."
fi

# kill -9 on broad targets (-1, 0, or no specific PID)
if echo "$COMMAND" | grep -qE 'kill\s+-9\s+(-1|0)\b' 2>/dev/null; then
  is_allowed "kill -9" || block "kill -9 -1 or kill -9 0 would kill all your processes." "Specify a specific PID, or add 'allow: kill -9' to .bash-guard."
fi
# killall without specific process
if echo "$COMMAND" | grep -qE 'killall\s+-9\s' 2>/dev/null; then
  is_allowed "kill -9" || block "killall -9 force-kills all matching processes without cleanup." "Use regular kill (without -9) to allow graceful shutdown, or add 'allow: kill -9' to .bash-guard."
fi

# mkfs (format filesystem)
if echo "$COMMAND" | grep -qE 'mkfs' 2>/dev/null; then
  is_allowed "mkfs" || block "mkfs formats a filesystem, destroying all existing data on the device." "Add 'allow: mkfs' to .bash-guard if you really need to format a device."
fi

# diskutil destructive operations (macOS) — #37984: eraseDisk destroyed 87GB of personal data
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)diskutil\s+(eraseDisk|eraseVolume|partitionDisk)' 2>/dev/null; then
  is_allowed "disk-util" || block "diskutil erase/partition permanently destroys all data on the target disk." "Add 'allow: disk-util' to .bash-guard if you really need this."
fi
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)diskutil\s+apfs\s+deleteContainer' 2>/dev/null; then
  is_allowed "disk-util" || block "diskutil apfs deleteContainer permanently removes an APFS container and all its volumes." "Add 'allow: disk-util' to .bash-guard if you really need this."
fi

# Partition table tools (fdisk, gdisk, parted, sfdisk — Linux/macOS)
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)(fdisk|gdisk|sfdisk)\s' 2>/dev/null; then
  is_allowed "disk-util" || block "fdisk/gdisk/sfdisk modifies disk partition tables, which can cause total data loss." "Add 'allow: disk-util' to .bash-guard if you really need this."
fi
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)parted\s' 2>/dev/null; then
  is_allowed "disk-util" || block "parted modifies disk partition tables, which can cause total data loss." "Add 'allow: disk-util' to .bash-guard if you really need this."
fi

# wipefs (filesystem signature wipe)
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)wipefs\s' 2>/dev/null; then
  is_allowed "disk-util" || block "wipefs removes filesystem signatures, making data on the device inaccessible." "Add 'allow: disk-util' to .bash-guard if you really need this."
fi

# dd writing to block devices (exclude safe targets like /dev/null, /dev/zero)
if echo "$COMMAND" | grep -qE 'dd\s.*of=/dev/' 2>/dev/null; then
  if ! echo "$COMMAND" | grep -qE 'dd\s.*of=/dev/(null|zero|stdout|stderr)' 2>/dev/null; then
    is_allowed "dd" || block "dd writing to a device can overwrite your entire drive or partition." "Double-check the target device, or add 'allow: dd' to .bash-guard."
  fi
fi

# Writing to system directories with redirects
if echo "$COMMAND" | grep -qE '>\s*/(etc|usr|System|Library|boot|sbin)/' 2>/dev/null; then
  is_allowed "system-write" || block "Redirecting output to a system directory can break your OS." "Write to a local project file instead, or add 'allow: system-write' to .bash-guard."
fi

# eval on variables (code injection risk)
if echo "$COMMAND" | grep -qE 'eval\s+.*\$[A-Za-z_]' 2>/dev/null; then
  is_allowed "eval" || block "eval on variables is a code injection risk — the variable content is executed as code." "Use the variable directly without eval, or add 'allow: eval' to .bash-guard."
fi

# npm global install
if echo "$COMMAND" | grep -qE 'npm\s+install\s+-g\b' 2>/dev/null; then
  is_allowed "global-install" || block "Global npm install modifies system-wide packages." "Use npx or local install instead, or add 'allow: global-install' to .bash-guard."
fi

# Docker destructive commands (data loss via volume/container removal)
if echo "$COMMAND" | grep -qE 'docker(-compose|\s+compose)\s+down\s.*-v' 2>/dev/null; then
  is_allowed "docker-destroy" || block "docker compose down -v removes named volumes, causing permanent data loss." "Use 'docker compose down' without -v to keep volumes, or add 'allow: docker-destroy' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE 'docker\s+system\s+prune' 2>/dev/null; then
  is_allowed "docker-destroy" || block "docker system prune removes unused containers, networks, and images." "Add 'allow: docker-destroy' to .bash-guard if you need this."
fi
if echo "$COMMAND" | grep -qE 'docker\s+volume\s+(prune|rm)\b' 2>/dev/null; then
  is_allowed "docker-destroy" || block "Removing Docker volumes destroys persistent data." "Add 'allow: docker-destroy' to .bash-guard if you need this."
fi

# prisma db push (destructive schema sync, bypasses migrations — #33183: wiped 276 accounts)
if echo "$COMMAND" | grep -qE '(^|\s|;|&&|\|\|)(npx\s+)?prisma\s+db\s+push' 2>/dev/null; then
  is_allowed "db-destroy" || block "prisma db push applies schema changes directly without migrations. This has destroyed production databases." "Use 'prisma migrate dev' or 'prisma migrate deploy' instead, or add 'allow: db-destroy' to .bash-guard."
fi

# Database CLI destructive commands
if echo "$COMMAND" | grep -qE '(^|\s|;|&&|\|\|)dropdb\s' 2>/dev/null; then
  is_allowed "db-destroy" || block "dropdb permanently deletes a PostgreSQL database." "Add 'allow: db-destroy' to .bash-guard if you need this."
fi
if echo "$COMMAND" | grep -qiE "DROP\s+(DATABASE|TABLE)" 2>/dev/null; then
  is_allowed "db-destroy" || block "Destructive SQL command (DROP DATABASE/TABLE) causes permanent data loss." "Add 'allow: db-destroy' to .bash-guard if you need this."
fi
if echo "$COMMAND" | grep -qiE "TRUNCATE\s+" 2>/dev/null; then
  # Exclude filesystem truncate command (has -s/-c/-r flags)
  if ! echo "$COMMAND" | grep -qE 'truncate\s+-' 2>/dev/null; then
    is_allowed "db-destroy" || block "SQL TRUNCATE causes permanent data loss." "Add 'allow: db-destroy' to .bash-guard if you need this."
  fi
fi
if echo "$COMMAND" | grep -qE '(db:drop|db:wipe|migrate:fresh|fixtures:load|db:seed:replant)' 2>/dev/null; then
  is_allowed "db-destroy" || block "ORM command that destroys or replaces database contents." "Add 'allow: db-destroy' to .bash-guard if you need this."
fi

# Environment variable dumps (credential exposure)
if echo "$COMMAND" | grep -qE '(^|\s|;|&&|\|\|)(env|printenv)\s*($|\||;|&&|\|\||>|2>)' 2>/dev/null; then
  is_allowed "env-dump" || block "Dumping all environment variables exposes API keys, tokens, and secrets in the output." "Access specific variables with 'echo \$VAR_NAME' or 'printenv VAR_NAME', or add 'allow: env-dump' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE '(^|\s|;|&&|\|\|)export\s+-p\s*($|\||;|&&|\|\||>)' 2>/dev/null; then
  is_allowed "env-dump" || block "export -p lists all exported variables, potentially exposing secrets." "Access specific variables directly, or add 'allow: env-dump' to .bash-guard."
fi

# Reading credential files directly
if echo "$COMMAND" | grep -qE '(cat|less|more|head|tail|bat)\s+.*\.(env|pem|key|p12|pfx|credentials|secret)(\s|$)' 2>/dev/null; then
  is_allowed "read-secrets" || block "Reading credential files may expose secrets in the output." "Reference specific non-secret values instead, or add 'allow: read-secrets' to .bash-guard."
fi

# Debug trace mode (leaks secrets in trace output)
if echo "$COMMAND" | grep -qE '(bash|sh|zsh)\s+-[a-zA-Z]*x' 2>/dev/null; then
  is_allowed "debug-trace" || block "Running scripts with -x traces all commands with expanded variables, exposing secrets in output." "Remove the -x flag, or add 'allow: debug-trace' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE '(^|\s|;|&&|\|\|)set\s+-[a-zA-Z]*x' 2>/dev/null; then
  is_allowed "debug-trace" || block "set -x enables debug tracing which prints all variables including secrets." "Remove set -x, or add 'allow: debug-trace' to .bash-guard."
fi

# Cloud infrastructure destruction (terraform, aws, kubectl, gcloud, pulumi)
if echo "$COMMAND" | grep -qE '(^|\s|;|&&|\|\|)terraform\s+destroy' 2>/dev/null; then
  is_allowed "infra-destroy" || block "terraform destroy removes cloud infrastructure. This can take down production services." "Use 'terraform plan -destroy' to preview first, or add 'allow: infra-destroy' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE '(^|\s|;|&&|\|\|)pulumi\s+destroy' 2>/dev/null; then
  is_allowed "infra-destroy" || block "pulumi destroy removes cloud infrastructure." "Use 'pulumi preview --diff' first, or add 'allow: infra-destroy' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE 'aws\s+s3\s+(rm|rb)\s.*--recursive' 2>/dev/null; then
  is_allowed "infra-destroy" || block "Recursive S3 deletion permanently removes objects from the bucket." "Remove specific keys instead, or add 'allow: infra-destroy' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE 'kubectl\s+delete\s+(namespace|ns|all|deployment|statefulset)\s' 2>/dev/null; then
  is_allowed "infra-destroy" || block "kubectl delete removes Kubernetes resources, potentially taking down production services." "Verify the target cluster and namespace first, or add 'allow: infra-destroy' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE 'gcloud\s.*(delete|destroy)\s' 2>/dev/null; then
  is_allowed "infra-destroy" || block "gcloud delete/destroy removes Google Cloud resources." "Verify the target project first, or add 'allow: infra-destroy' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE '(^|\s|;|&&|\|\|)helm\s+(uninstall|delete)\s' 2>/dev/null; then
  is_allowed "infra-destroy" || block "helm uninstall removes a Kubernetes release and all its resources." "Use 'helm list' to verify the release first, or add 'allow: infra-destroy' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE 'kubectl\s+drain\s' 2>/dev/null; then
  is_allowed "infra-destroy" || block "kubectl drain evicts all pods from a node, causing service disruption." "Verify the node and use --dry-run first, or add 'allow: infra-destroy' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE 'kubectl\s+scale\s.*--replicas[= ]*0\b' 2>/dev/null; then
  is_allowed "infra-destroy" || block "kubectl scale --replicas=0 stops all pods for the resource, taking the service offline." "Verify the target resource first, or add 'allow: infra-destroy' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE '(^|\s|;|&&|\|\|)az\s+(group|resource|vm|webapp|functionapp|sql\s+server)\s+delete\s' 2>/dev/null; then
  is_allowed "infra-destroy" || block "Azure CLI delete removes cloud resources permanently." "Verify the resource group and subscription first, or add 'allow: infra-destroy' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE '(^|\s|;|&&|\|\|)doctl\s.*(delete|destroy)\s' 2>/dev/null; then
  is_allowed "infra-destroy" || block "DigitalOcean CLI delete/destroy removes cloud resources." "Verify the target first, or add 'allow: infra-destroy' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE '(^|\s|;|&&|\|\|)(flyctl|fly)\s+(apps\s+)?destroy\s' 2>/dev/null; then
  is_allowed "infra-destroy" || block "Fly.io destroy removes the application and all its machines." "Verify the app name first, or add 'allow: infra-destroy' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE '(^|\s|;|&&|\|\|)heroku\s+apps:destroy\s' 2>/dev/null; then
  is_allowed "infra-destroy" || block "heroku apps:destroy permanently removes the application and all add-ons." "Verify the app name first, or add 'allow: infra-destroy' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE '(^|\s|;|&&|\|\|)vercel\s+(rm|remove)\s' 2>/dev/null; then
  is_allowed "infra-destroy" || block "vercel rm removes deployments or projects." "Verify the target first, or add 'allow: infra-destroy' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE '(^|\s|;|&&|\|\|)netlify\s+sites:delete\s' 2>/dev/null; then
  is_allowed "infra-destroy" || block "netlify sites:delete permanently removes the site." "Verify the site name first, or add 'allow: infra-destroy' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE 'aws\s+ec2\s+terminate-instances\s' 2>/dev/null; then
  is_allowed "infra-destroy" || block "aws ec2 terminate-instances permanently destroys EC2 instances." "Verify instance IDs first, or add 'allow: infra-destroy' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE 'aws\s+(rds|dynamodb|elasticache|lambda)\s+delete-' 2>/dev/null; then
  is_allowed "infra-destroy" || block "AWS CLI delete command permanently removes cloud resources." "Verify the resource identifier first, or add 'allow: infra-destroy' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE 'aws\s+cloudformation\s+delete-stack\s' 2>/dev/null; then
  is_allowed "infra-destroy" || block "aws cloudformation delete-stack tears down the entire stack and all its resources." "Verify the stack name first, or add 'allow: infra-destroy' to .bash-guard."
fi

# Additional database destruction patterns
if echo "$COMMAND" | grep -qE '(doctrine:schema:drop|sequelize\s+db:drop|typeorm\s+schema:drop)' 2>/dev/null; then
  is_allowed "db-destroy" || block "ORM schema drop command permanently destroys database structure." "Add 'allow: db-destroy' to .bash-guard if you need this."
fi
if echo "$COMMAND" | grep -qE 'redis-cli\s.*(FLUSHALL|FLUSHDB)' 2>/dev/null; then
  is_allowed "db-destroy" || block "Redis FLUSHALL/FLUSHDB permanently deletes all data in the Redis instance." "Add 'allow: db-destroy' to .bash-guard if you need this."
fi
if echo "$COMMAND" | grep -qE '(wp\s+db\s+(reset|clean)|drush\s+sql-drop)' 2>/dev/null; then
  is_allowed "db-destroy" || block "CMS database destruction command causes permanent data loss." "Add 'allow: db-destroy' to .bash-guard if you need this."
fi
if echo "$COMMAND" | grep -qE '(mongosh?|mongo)\s.*dropDatabase' 2>/dev/null; then
  is_allowed "db-destroy" || block "MongoDB dropDatabase permanently removes the entire database." "Add 'allow: db-destroy' to .bash-guard if you need this."
fi

# Mass file deletion (find -delete, find -exec rm, xargs rm)
if echo "$COMMAND" | grep -qE 'find\s.*\s-delete\b' 2>/dev/null; then
  is_allowed "mass-delete" || block "find with -delete permanently removes all matching files without confirmation." "Use -print first to preview, or add 'allow: mass-delete' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE 'find\s.*-exec\s+rm\s' 2>/dev/null; then
  is_allowed "mass-delete" || block "find with -exec rm permanently removes matching files in bulk." "Use -print first to preview, or add 'allow: mass-delete' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE '\|\s*xargs\s.*rm\b' 2>/dev/null; then
  is_allowed "mass-delete" || block "Piping to xargs rm deletes files in bulk without individual confirmation." "Review the file list first, or add 'allow: mass-delete' to .bash-guard."
fi

# git clean -fdx (removes all untracked files including gitignored)
if echo "$COMMAND" | grep -qE 'git\s+clean\s+-[a-zA-Z]*f' 2>/dev/null; then
  is_allowed "git-clean" || block "git clean -f permanently removes untracked files. With -x it also removes gitignored files (build artifacts, .env, etc.)." "Use 'git clean -n' for a dry run first, or add 'allow: git-clean' to .bash-guard."
fi

# Docker host mounts (escape directory restrictions — #37621)
if echo "$COMMAND" | grep -qE 'docker\s+run\s.*-v\s+/[^:]*:' 2>/dev/null; then
  is_allowed "docker-mount" || block "Docker run with host volume mount can access files outside the allowed directory." "Mount only project-specific paths, or add 'allow: docker-mount' to .bash-guard."
fi

# Docker exec (arbitrary commands in containers with potential host access)
if echo "$COMMAND" | grep -qE '(^|\s|;|&&|\|\|)docker\s+exec\s' 2>/dev/null; then
  is_allowed "docker-exec" || block "docker exec runs commands in a container that may have elevated privileges or host access." "Add 'allow: docker-exec' to .bash-guard if you need container access."
fi

# File destruction alternatives (workaround bypasses for rm — Pattern E)
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)shred\s' 2>/dev/null; then
  is_allowed "shred" || block "shred securely overwrites files, making recovery impossible." "Use rm instead (allows recovery from backups), or add 'allow: shred' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)truncate\s+-s\s*0\s' 2>/dev/null; then
  is_allowed "truncate" || block "truncate -s 0 empties files, causing silent data loss without deleting them." "Add 'allow: truncate' to .bash-guard if you need this."
fi

# Disk overwrite via /dev/zero or /dev/urandom targeting devices (regular files are OK)
if echo "$COMMAND" | grep -qE 'dd\s.*if=/dev/(zero|urandom).*of=/dev/' 2>/dev/null; then
  if ! echo "$COMMAND" | grep -qE 'dd\s.*of=/dev/(null|zero|stdout|stderr)' 2>/dev/null; then
    is_allowed "dd" || block "dd from /dev/zero or /dev/urandom to a device overwrites the entire device, destroying all data." "Add 'allow: dd' to .bash-guard if you need this."
  fi
fi

# Data exfiltration: uploading local files via curl/wget to remote servers
if echo "$COMMAND" | grep -qE 'curl\s.*(-d\s*@|-F\s+[^=]+=@|--data-binary\s+@|--data\s+@|--data-urlencode\s+@|--upload-file\s)' 2>/dev/null; then
  is_allowed "file-upload" || block "curl is uploading a local file to a remote server. This could exfiltrate sensitive data." "Inline the data instead of referencing a file, or add 'allow: file-upload' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE 'wget\s.*(--post-file|--body-file)\s' 2>/dev/null; then
  is_allowed "file-upload" || block "wget is uploading a local file to a remote server. This could exfiltrate sensitive data." "Use curl with inline data instead, or add 'allow: file-upload' to .bash-guard."
fi

# Programmatic env dumps (scripting language one-liners that dump all env vars)
if echo "$COMMAND" | grep -qE 'python[23]?\s+-c\s.*os\.environ' 2>/dev/null; then
  is_allowed "env-dump" || block "Python one-liner accessing os.environ exposes all environment variables including secrets." "Access specific variables with os.getenv('VAR'), or add 'allow: env-dump' to .bash-guard."
fi
# Match process.env (dump all) but not process.env.HOME (specific access)
if echo "$COMMAND" | grep -qE 'node\s+-e\s.*process\.env($|[^.\[a-zA-Z])' 2>/dev/null; then
  is_allowed "env-dump" || block "Node.js one-liner accessing process.env exposes all environment variables including secrets." "Access specific variables with process.env.VAR, or add 'allow: env-dump' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE 'ruby\s+-e\s.*ENV' 2>/dev/null; then
  is_allowed "env-dump" || block "Ruby one-liner accessing ENV exposes all environment variables including secrets." "Access specific variables with ENV['VAR'], or add 'allow: env-dump' to .bash-guard."
fi

# Process environment file access (Linux /proc/*/environ)
if echo "$COMMAND" | grep -qE '(cat|less|more|head|tail|strings)\s+/proc/[^/]+/environ' 2>/dev/null; then
  is_allowed "env-dump" || block "Reading /proc/*/environ exposes all environment variables of a process including secrets." "Access specific variables directly, or add 'allow: env-dump' to .bash-guard."
fi

# SSH private key access
if echo "$COMMAND" | grep -qE '(cat|less|more|head|tail|bat)\s+.*\.ssh/(id_|.*\.pem|.*key)' 2>/dev/null; then
  is_allowed "read-secrets" || block "Reading SSH private keys exposes credentials that grant server access." "Use ssh-agent or reference the key path in SSH config, or add 'allow: read-secrets' to .bash-guard."
fi

# Shell history access (may contain passwords/tokens typed at prompts)
if echo "$COMMAND" | grep -qE '(cat|less|more|head|tail|bat)\s+.*(\.bash_history|\.zsh_history|\.sh_history|\.history)' 2>/dev/null; then
  is_allowed "read-secrets" || block "Shell history files may contain passwords, tokens, and API keys typed at prompts." "Search for specific commands with grep instead, or add 'allow: read-secrets' to .bash-guard."
fi

# System database modification via sqlite3 (#37888: 59 sqlite3 commands corrupted VSCode state.vscdb)
if echo "$COMMAND" | grep -qE 'sqlite3\s+.*\.(vscdb|vscdb-wal|vscdb-shm)' 2>/dev/null; then
  is_allowed "system-db" || block "sqlite3 targeting a VSCode database (.vscdb). This has destroyed IDE session history and Codex functionality (#37888)." "Do not modify VSCode internal databases, or add 'allow: system-db' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE "sqlite3\s+.*(Application Support/Code|\.vscode|\.cursor|\.config/(Code|Cursor)|\.vscode-server)" 2>/dev/null; then
  is_allowed "system-db" || block "sqlite3 targeting an IDE internal database. Modifying these can corrupt sessions, settings, and extensions." "Only use sqlite3 on your project databases, or add 'allow: system-db' to .bash-guard."
fi

# Mount point deletion (#36640: rm -rf on NFS mount destroyed production user data)
if echo "$COMMAND" | grep -qE 'rm\s+-[rRf]+\s+/(mnt|media|Volumes|nfs|mount)/' 2>/dev/null; then
  is_allowed "mount-delete" || block "rm -rf targeting a mount point path. NFS/SMB/external volumes may contain production data (#36640)." "Check mount status with 'mount' or 'findmnt' first, or add 'allow: mount-delete' to .bash-guard."
fi

# Network exfiltration via netcat/socat (piping files to remote hosts)
if echo "$COMMAND" | grep -qE '(nc|ncat|netcat|socat)\s.*<\s' 2>/dev/null; then
  is_allowed "file-upload" || block "Piping file content through netcat/socat sends data to a remote host without encryption or logging." "Use curl or scp instead, or add 'allow: file-upload' to .bash-guard."
fi

# --- Here-string/here-doc to shell (bypass via redirection instead of pipe) ---
# `bash <<< "rm -rf /"` and `bash << EOF` bypass ALL pipe-based detection above.
# These patterns detect command execution via shell redirection.

# Here-string: bash <<< "command", sh <<< 'command'
if echo "$COMMAND" | grep -qE '(bash|sh|zsh|dash|ksh)\s+<<<\s' 2>/dev/null; then
  is_allowed "here-exec" || block "Here-string feeds content directly to a shell interpreter, bypassing safety checks." "Run the command directly instead of via here-string. Or add 'allow: here-exec' to .bash-guard."
fi

# Here-doc: bash << EOF, sh << 'DELIM', bash <<-EOF (with indent stripping)
if echo "$COMMAND" | grep -qE "(bash|sh|zsh|dash|ksh)\s+<<-?\s*['\"]?[A-Za-z_]" 2>/dev/null; then
  is_allowed "here-exec" || block "Here-document feeds content directly to a shell interpreter, bypassing safety checks." "Run the commands directly instead of via here-doc. Or add 'allow: here-exec' to .bash-guard."
fi

# eval with string literal (not just variables): eval "rm -rf /"
if echo "$COMMAND" | grep -qE "(^|[;&|]\s*)eval\s+['\"]" 2>/dev/null; then
  is_allowed "eval" || block "eval with a string literal executes arbitrary code that bypasses pattern matching." "Run the command directly without eval. Or add 'allow: eval' to .bash-guard."
fi

# xargs piping to shell interpreter: xargs -I{} bash -c {} or xargs sh -c
if echo "$COMMAND" | grep -qE '\|\s*xargs\s.*\b(bash|sh|zsh|dash|ksh)\s+-c\b' 2>/dev/null; then
  is_allowed "decode-exec" || block "Piping through xargs to a shell interpreter executes arbitrary commands that bypass safety checks." "Process the data directly instead of piping through a shell. Or add 'allow: decode-exec' to .bash-guard."
fi

# --- Encoding bypass detection ---
# Encoded commands bypass ALL pattern matching above. An LLM tricked into running
# `echo "cm0gLXJmIC8=" | base64 -d | bash` would execute `rm -rf /` undetected.
# These patterns detect decode-to-shell pipelines regardless of encoded content.

# base64 decode piped to shell (includes openssl base64 variant)
if echo "$COMMAND" | grep -qE '(base64\s+(-d|--decode|-D)|openssl\s+(base64|enc)\s+-d)\s*\|.*\s*(bash|sh|zsh|dash|ksh|source|eval)' 2>/dev/null; then
  is_allowed "decode-exec" || block "Decoding base64 content and piping to shell executes hidden commands that bypass all safety checks." "Decode to a file first, review it, then run it. Or add 'allow: decode-exec' to .bash-guard."
fi

# base64 decode via command substitution to shell
if echo "$COMMAND" | grep -qE '(bash|sh|zsh)\s+-c\s.*\$\(.*base64\s+(-d|--decode|-D)' 2>/dev/null; then
  is_allowed "decode-exec" || block "Executing base64-decoded content via command substitution bypasses all safety checks." "Decode to a file first, review it, then run it. Or add 'allow: decode-exec' to .bash-guard."
fi

# hex decode piped to shell (xxd -r)
if echo "$COMMAND" | grep -qE 'xxd\s+-r.*\|.*\s*(bash|sh|zsh|dash|ksh|source|eval)' 2>/dev/null; then
  is_allowed "decode-exec" || block "Decoding hex content and piping to shell executes hidden commands that bypass all safety checks." "Decode to a file first, review it, then run it. Or add 'allow: decode-exec' to .bash-guard."
fi

# printf hex/octal escapes piped to shell
if echo "$COMMAND" | grep -qE "printf\s+['\"]\\\\(x[0-9a-fA-F]|[0-7]{3}).*\|.*\s*(bash|sh|zsh|dash|ksh|source|eval)" 2>/dev/null; then
  is_allowed "decode-exec" || block "printf with escape sequences piped to shell executes hidden commands that bypass all safety checks." "Write the command directly instead of encoding it. Or add 'allow: decode-exec' to .bash-guard."
fi

# Process substitution with network downloads: bash <(curl ...) or sh <(wget ...)
if echo "$COMMAND" | grep -qE '(bash|sh|zsh|dash|ksh)\s+<\(\s*(curl|wget)\s' 2>/dev/null; then
  is_allowed "pipe-to-shell" || block "Process substitution downloads and executes code without saving it for review." "Download the script first, review it, then run it. Or add 'allow: pipe-to-shell' to .bash-guard."
fi

# Reversed string piped to shell (obfuscation: echo '/ fr- mr' | rev | bash)
if echo "$COMMAND" | grep -qE '\|\s*rev\s*\|.*\s*(bash|sh|zsh|dash|ksh|source|eval)' 2>/dev/null; then
  is_allowed "decode-exec" || block "Reversing a string and piping to shell is an obfuscation technique to hide dangerous commands." "Write the command directly instead of reversing it. Or add 'allow: decode-exec' to .bash-guard."
fi

# Programming language shell execution (subprocess, os.system, system())
if echo "$COMMAND" | grep -qE 'python[23]?\s+-c\s.*\b(subprocess|os\.system|os\.popen)\b' 2>/dev/null; then
  is_allowed "lang-exec" || block "Python one-liner executing shell commands via subprocess/os.system bypasses bash-guard checks." "Run the shell command directly instead of wrapping it in Python. Or add 'allow: lang-exec' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE "ruby\s+-e\s.*\b(system|exec|%x|Kernel\.)" 2>/dev/null; then
  is_allowed "lang-exec" || block "Ruby one-liner executing shell commands bypasses bash-guard checks." "Run the shell command directly instead of wrapping it in Ruby. Or add 'allow: lang-exec' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE "perl\s+-e\s.*\b(system|exec|qx)" 2>/dev/null; then
  is_allowed "lang-exec" || block "Perl one-liner executing shell commands bypasses bash-guard checks." "Run the shell command directly instead of wrapping it in Perl. Or add 'allow: lang-exec' to .bash-guard."
fi
if echo "$COMMAND" | grep -qE 'node\s+-e\s.*child_process' 2>/dev/null; then
  is_allowed "lang-exec" || block "Node.js one-liner executing shell commands via child_process bypasses bash-guard checks." "Run the shell command directly instead of wrapping it in Node. Or add 'allow: lang-exec' to .bash-guard."
fi

# In-place file editing via interpreters (bypasses file-guard, #40408)
# perl -i, perl -pi, perl -i.bak — in-place edit like sed -i
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)perl\s+(-[A-Za-z]*i|-i[^\s]*)' 2>/dev/null; then
  is_allowed "inplace-edit" || block "Perl in-place file editing (perl -i) modifies files directly, bypassing file-guard protection. Reported in claude-code#40408." "Use Edit tool instead, which respects file-guard rules. Or add 'allow: inplace-edit' to .bash-guard."
fi
# ruby -i — in-place edit
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)ruby\s+(-[A-Za-z]*i|-i[^\s]*)' 2>/dev/null; then
  is_allowed "inplace-edit" || block "Ruby in-place file editing (ruby -i) modifies files directly, bypassing file-guard protection." "Use Edit tool instead, which respects file-guard rules. Or add 'allow: inplace-edit' to .bash-guard."
fi
# sed -i — in-place edit (most common form)
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)sed\s+(-[A-Za-z]*i|-i[^\s]*)' 2>/dev/null; then
  is_allowed "inplace-edit" || block "sed in-place editing (sed -i) modifies files directly, bypassing file-guard protection." "Use Edit tool instead, which respects file-guard rules. Or add 'allow: inplace-edit' to .bash-guard."
fi

# --- Gaps identified from competitive analysis (RoaringFerrum/bash-guardian, buildatscale-tv) ---

# LD_PRELOAD / LD_LIBRARY_PATH injection (hijacks library loading)
if echo "$COMMAND" | grep -qE '(^|\s|;|&&|\|\|)(LD_PRELOAD|LD_LIBRARY_PATH)=' 2>/dev/null; then
  is_allowed "env-inject" || block "Setting LD_PRELOAD or LD_LIBRARY_PATH allows hijacking shared library loading to inject malicious code." "Remove the LD_ variable assignment, or add 'allow: env-inject' to .bash-guard."
fi

# IFS manipulation (changes command parsing semantics)
if echo "$COMMAND" | grep -qE '(^|\s|;|&&|\|\|)(export\s+)?IFS=' 2>/dev/null; then
  is_allowed "env-inject" || block "Setting IFS changes how the shell parses commands, which can alter the behavior of scripts in unexpected ways." "Remove the IFS assignment, or add 'allow: env-inject' to .bash-guard."
fi

# Wrapper commands hiding dangerous operations (timeout rm, nohup rm, env rm, etc.)
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)(timeout|time|nice|nohup|strace|ltrace|unbuffer|caffeinate)\s+.*(rm\s+-[rRf]|mkfs|dd\s|shred|wipefs|fdisk|gdisk|parted|sfdisk|chmod\s.*777|chown\s.*-R)' 2>/dev/null; then
  is_allowed "wrapper-bypass" || block "A wrapper command (timeout/nohup/strace/etc.) is hiding a dangerous operation. The wrapped command would cause irreversible damage." "Run the command directly so it can be properly checked, or add 'allow: wrapper-bypass' to .bash-guard."
fi

# Credential file copy/move/scp (exfiltration via file operations)
if echo "$COMMAND" | grep -qE '(cp|mv|scp|rsync)\s+.*(\.ssh/|\.aws/|\.gnupg/|\.netrc|\.npmrc|\.docker/config)' 2>/dev/null; then
  is_allowed "cred-copy" || block "Copying or moving credential files (.ssh/, .aws/, .gnupg/, .netrc) could exfiltrate secrets." "Reference credentials via their standard paths instead. Or add 'allow: cred-copy' to .bash-guard."
fi

# macOS Keychain access (credential theft)
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)security\s+(find-generic-password|find-internet-password|delete-generic-password|delete-internet-password|add-generic-password|dump-keychain)' 2>/dev/null; then
  is_allowed "keychain" || block "Accessing the macOS Keychain can read, modify, or delete stored passwords and certificates." "Add 'allow: keychain' to .bash-guard if you need Keychain access."
fi

# crontab modification (persistence mechanism)
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)crontab\s+-[erl]' 2>/dev/null; then
  is_allowed "scheduled-tasks" || block "Modifying crontab installs scheduled tasks that persist after this session." "Add 'allow: scheduled-tasks' to .bash-guard if you need to modify cron."
fi

# launchctl load/unload (macOS persistence)
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)launchctl\s+(load|unload|submit|bootstrap|bootout)' 2>/dev/null; then
  is_allowed "scheduled-tasks" || block "launchctl modifies persistent macOS services that run outside this session." "Add 'allow: scheduled-tasks' to .bash-guard if you need to manage launch agents."
fi

# Generic pipe to eval (not just curl/wget)
if echo "$COMMAND" | grep -qE '\|\s*eval\b' 2>/dev/null; then
  is_allowed "eval" || block "Piping output directly to eval executes arbitrary content as shell code." "Assign to a variable and inspect before evaluating. Or add 'allow: eval' to .bash-guard."
fi

# Pipe to fish shell (missing from our shell list)
if echo "$COMMAND" | grep -qE '(curl|wget)\s.*\|\s*fish\b' 2>/dev/null; then
  is_allowed "pipe-to-shell" || block "Piping downloaded content to fish shell executes untrusted code." "Download the script first, review it, then run it. Or add 'allow: pipe-to-shell' to .bash-guard."
fi

# systemctl service management
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)systemctl\s+(start|stop|restart|disable|enable|mask)\s' 2>/dev/null; then
  is_allowed "service-mgmt" || block "systemctl modifies system services which can affect system stability and security." "Add 'allow: service-mgmt' to .bash-guard if you need to manage services."
fi

# SysV service management
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)service\s+\S+\s+(start|stop|restart)' 2>/dev/null; then
  is_allowed "service-mgmt" || block "service start/stop/restart modifies running system services." "Add 'allow: service-mgmt' to .bash-guard if you need to manage services."
fi

# ssh-keygen (key generation) and ssh-add (agent operations)
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)ssh-keygen\s' 2>/dev/null; then
  is_allowed "ssh-keys" || block "ssh-keygen creates or modifies SSH keys which grant remote server access." "Add 'allow: ssh-keys' to .bash-guard if you need to generate SSH keys."
fi
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)ssh-add\s' 2>/dev/null; then
  is_allowed "ssh-keys" || block "ssh-add loads SSH private keys into the agent, granting access to remote servers." "Add 'allow: ssh-keys' to .bash-guard if you need to manage SSH agent keys."
fi

# pkill -9 (mass process termination)
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)pkill\s+-9\s' 2>/dev/null; then
  is_allowed "kill -9" || block "pkill -9 force-kills matching processes without graceful shutdown." "Use pkill without -9 for graceful termination, or add 'allow: kill -9' to .bash-guard."
fi

# git push --force (overwrites remote history, can destroy teammates' work)
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)git\s+push\s+.*(-f\b|--force\b|--force-with-lease\b)' 2>/dev/null; then
  is_allowed "git-force-push" || block "git push --force overwrites remote history and can destroy other contributors' work." "Use 'git push' without --force, or add 'allow: git-force-push' to .bash-guard."
fi

# git filter-branch (history rewriting, data loss risk)
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)git\s+filter-branch\b' 2>/dev/null; then
  is_allowed "git-rewrite" || block "git filter-branch rewrites repository history, which can cause data loss and force-push requirements." "Use git filter-repo instead (safer), or add 'allow: git-rewrite' to .bash-guard."
fi

# docker rm -f (force remove containers)
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)docker\s+rm\s+-[a-zA-Z]*f' 2>/dev/null; then
  is_allowed "docker-destroy" || block "docker rm -f force-removes running containers without graceful shutdown." "Stop the container first with 'docker stop', or add 'allow: docker-destroy' to .bash-guard."
fi

# yarn/pnpm global installs (missing from npm-only check)
if echo "$COMMAND" | grep -qE '(yarn|pnpm)\s+global\s+add\b' 2>/dev/null; then
  is_allowed "global-install" || block "Global package install modifies system-wide packages." "Use local install instead, or add 'allow: global-install' to .bash-guard."
fi

# passwd (password change)
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)passwd\b' 2>/dev/null; then
  is_allowed "passwd" || block "passwd changes user passwords. AI agents should not modify user credentials." "Add 'allow: passwd' to .bash-guard if you need this."
fi

# pip/pip3 install --target (writes packages to arbitrary paths, sandbox escape — #41103)
if echo "$COMMAND" | grep -qE 'pip3?\s+install\s.*--target' 2>/dev/null; then
  is_allowed "pip-target" || block "pip install --target writes packages to an arbitrary directory, bypassing sandbox confinement." "Install without --target (uses default location), or add 'allow: pip-target' to .bash-guard."
fi

# pip/pip3 install --user (writes to ~/.local outside sandbox — #41103)
if echo "$COMMAND" | grep -qE 'pip3?\s+install\s.*--user' 2>/dev/null; then
  is_allowed "pip-user" || block "pip install --user writes packages to ~/.local which may be outside the sandbox." "Install without --user (uses project virtualenv), or add 'allow: pip-user' to .bash-guard."
fi

# Deep path traversal (4+ levels of ../ is likely a sandbox escape attempt — #41103)
if echo "$COMMAND" | grep -qE '(\.\./){4,}' 2>/dev/null; then
  is_allowed "path-traversal" || block "Deep path traversal (4+ levels of ../) may be an attempt to escape a sandboxed directory." "Use absolute paths or navigate to the target directory first. Or add 'allow: path-traversal' to .bash-guard."
fi

log "ALLOW: $COMMAND"
exit 0
