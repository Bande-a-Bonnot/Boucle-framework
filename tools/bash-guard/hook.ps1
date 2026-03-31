# bash-guard: PreToolUse hook for Claude Code (PowerShell)
# Windows-native equivalent of hook.sh — no external dependencies needed.
#
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
#   1. Copy hook.ps1 to your project
#   2. Add to .claude/settings.json:
#      "hooks": { "PreToolUse": [{ "type": "command", "command": "pwsh -File /path/to/hook.ps1" }] }
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

$ErrorActionPreference = 'Stop'

if ($env:BASH_GUARD_DISABLED -eq '1') { exit 0 }

# Helper: write log to stderr
function Write-Log {
    param([string]$Message)
    if ($env:BASH_GUARD_LOG -eq '1') {
        [Console]::Error.WriteLine("[bash-guard] $Message")
    }
}

# Helper: output a block decision as JSON
function Block-Tool {
    param([string]$Reason)
    $result = @{ hookSpecificOutput = @{ permissionDecision = 'deny'; permissionDecisionReason = $Reason } } | ConvertTo-Json -Compress -Depth 3
    Write-Output $result
    exit 0
}

# Read hook input from stdin
$rawInput = [Console]::In.ReadToEnd()
$hookInput = $rawInput | ConvertFrom-Json

$toolName = $hookInput.tool_name

# Only check Bash commands
if ($toolName -ne 'Bash') { exit 0 }

$command = $hookInput.tool_input.command
if (-not $command) { exit 0 }

# Load allowlist and denylist from .bash-guard config
$allowed = @()
$denied = @()
$configPath = if ($env:BASH_GUARD_CONFIG) { $env:BASH_GUARD_CONFIG } else { '.bash-guard' }
if (Test-Path $configPath) {
    foreach ($rawLine in Get-Content $configPath) {
        $line = ($rawLine -replace '#.*$', '').Trim()
        if (-not $line) { continue }
        if ($line -match '^allow:\s*(.+)$') {
            $allowed += $Matches[1].Trim()
        } elseif ($line -match '^deny:\s*(.+)$') {
            $denied += $Matches[1].Trim()
        }
    }
}

# Check if an operation is allowed via config
function Test-Allowed {
    param([string]$Op)
    foreach ($a in $allowed) {
        if ($a -eq $Op) {
            Write-Log "ALLOWED by config: $Op"
            return $true
        }
    }
    return $false
}

# --- Custom deny rules (from .bash-guard config) ---
foreach ($deniedPattern in $denied) {
    if ($command -match "(^|\s|;|&&|\|\|)${deniedPattern}") {
        Block-Tool "bash-guard: Command matches deny rule '${deniedPattern}' in .bash-guard config. Suggestion: Remove the deny rule or add a matching allow rule to override."
    }
}

# --- Dangerous operation checks ---

# rm -rf on critical/broad paths
if ($command -match 'rm\s+(-[a-zA-Z]*r[a-zA-Z]*f|(-[a-zA-Z]*f[a-zA-Z]*r))\s') {
    # Check for critical targets
    if ($command -match 'rm\s+-[rRf]+\s+(/(\s|$)|/\*|~(/|\s|$)|\.\.|/usr|/etc|/var|/home|/System|/Library|\$HOME)') {
        if (-not (Test-Allowed 'rm -rf')) {
            Block-Tool 'bash-guard: rm -rf targeting a critical system path. This would cause irreversible data loss. Suggestion: Be specific about which files to delete, or add ''allow: rm -rf'' to .bash-guard.'
        }
    }
    # Check for wildcard-only targets
    if ($command -match 'rm\s+-[rRf]+\s+\*\s*$') {
        if (-not (Test-Allowed 'rm -rf')) {
            Block-Tool 'bash-guard: rm -rf * would recursively delete everything in the current directory. Suggestion: Be specific about which files to delete, or add ''allow: rm -rf'' to .bash-guard.'
        }
    }
}

# chmod -R with dangerous permissions (777, 000)
if ($command -match 'chmod\s+(-[a-zA-Z]*R|--recursive)\s') {
    if ($command -match 'chmod\s+.*\s(777|000|666)\s') {
        if (-not (Test-Allowed 'chmod -R')) {
            Block-Tool 'bash-guard: Recursive chmod with dangerous permissions (777/000/666) affects all files in the tree. Suggestion: Apply permissions to specific files, or add ''allow: chmod -R'' to .bash-guard.'
        }
    }
}

# chown -R to root or broad changes
if ($command -match 'chown\s+(-[a-zA-Z]*R|--recursive)\s.*\s(/|~|/usr|/etc|/var|/home)') {
    if (-not (Test-Allowed 'chown -R')) {
        Block-Tool 'bash-guard: Recursive chown on a critical path can break system permissions. Suggestion: Be specific about which directory to change, or add ''allow: chown -R'' to .bash-guard.'
    }
}

# Pipe to shell (curl|sh, wget|bash, curl|bash, etc.)
if ($command -match '(curl|wget)\s.*\|\s*(sh|bash|zsh|dash|ksh|source|eval)') {
    if (-not (Test-Allowed 'pipe-to-shell')) {
        Block-Tool 'bash-guard: Piping downloaded content directly to a shell executes untrusted code. Suggestion: Download the script first, review it, then run it. Or add ''allow: pipe-to-shell'' to .bash-guard.'
    }
}

# sudo and alternatives (privilege escalation)
if ($command -match '(^|[;&|]\s*)sudo\s') {
    if (-not (Test-Allowed 'sudo')) {
        Block-Tool 'bash-guard: sudo escalates to root privileges. AI agents should not run commands as root. Suggestion: Run without sudo, or add ''allow: sudo'' to .bash-guard.'
    }
}
if ($command -match '(^|[;&\|]\s*)(pkexec|doas)\s') {
    if (-not (Test-Allowed 'sudo')) {
        Block-Tool 'bash-guard: pkexec/doas escalates to root privileges, same as sudo. AI agents should not run commands as root. Suggestion: Run without privilege escalation, or add ''allow: sudo'' to .bash-guard.'
    }
}
if ($command -match '(^|[;&\|]\s*)su\s+(-c\s|root)') {
    if (-not (Test-Allowed 'sudo')) {
        Block-Tool 'bash-guard: su -c or su root escalates to root privileges. AI agents should not run commands as root. Suggestion: Run without privilege escalation, or add ''allow: sudo'' to .bash-guard.'
    }
}

# kill -9 on broad targets (-1, 0, or no specific PID)
if ($command -match 'kill\s+-9\s+(-1|0)\b') {
    if (-not (Test-Allowed 'kill -9')) {
        Block-Tool 'bash-guard: kill -9 -1 or kill -9 0 would kill all your processes. Suggestion: Specify a specific PID, or add ''allow: kill -9'' to .bash-guard.'
    }
}
# killall without specific process
if ($command -match 'killall\s+-9\s') {
    if (-not (Test-Allowed 'kill -9')) {
        Block-Tool 'bash-guard: killall -9 force-kills all matching processes without cleanup. Suggestion: Use regular kill (without -9) to allow graceful shutdown, or add ''allow: kill -9'' to .bash-guard.'
    }
}

# mkfs (format filesystem)
if ($command -match 'mkfs') {
    if (-not (Test-Allowed 'mkfs')) {
        Block-Tool 'bash-guard: mkfs formats a filesystem, destroying all existing data on the device. Suggestion: Add ''allow: mkfs'' to .bash-guard if you really need to format a device.'
    }
}

# diskutil destructive operations (macOS) — #37984: eraseDisk destroyed 87GB of personal data
if ($command -match '(^|[;&\|]\s*)diskutil\s+(eraseDisk|eraseVolume|partitionDisk)') {
    if (-not (Test-Allowed 'disk-util')) {
        Block-Tool 'bash-guard: diskutil erase/partition permanently destroys all data on the target disk. Suggestion: Add ''allow: disk-util'' to .bash-guard if you really need this.'
    }
}
if ($command -match '(^|[;&\|]\s*)diskutil\s+apfs\s+deleteContainer') {
    if (-not (Test-Allowed 'disk-util')) {
        Block-Tool 'bash-guard: diskutil apfs deleteContainer permanently removes an APFS container and all its volumes. Suggestion: Add ''allow: disk-util'' to .bash-guard if you really need this.'
    }
}

# Partition table tools (fdisk, gdisk, parted, sfdisk — Linux/macOS)
if ($command -match '(^|[;&\|]\s*)(fdisk|gdisk|sfdisk)\s') {
    if (-not (Test-Allowed 'disk-util')) {
        Block-Tool 'bash-guard: fdisk/gdisk/sfdisk modifies disk partition tables, which can cause total data loss. Suggestion: Add ''allow: disk-util'' to .bash-guard if you really need this.'
    }
}
if ($command -match '(^|[;&\|]\s*)parted\s') {
    if (-not (Test-Allowed 'disk-util')) {
        Block-Tool 'bash-guard: parted modifies disk partition tables, which can cause total data loss. Suggestion: Add ''allow: disk-util'' to .bash-guard if you really need this.'
    }
}

# wipefs (filesystem signature wipe)
if ($command -match '(^|[;&\|]\s*)wipefs\s') {
    if (-not (Test-Allowed 'disk-util')) {
        Block-Tool 'bash-guard: wipefs removes filesystem signatures, making data on the device inaccessible. Suggestion: Add ''allow: disk-util'' to .bash-guard if you really need this.'
    }
}

# dd writing to block devices (exclude safe targets like /dev/null, /dev/zero)
if ($command -match 'dd\s.*of=/dev/') {
    if ($command -notmatch 'dd\s.*of=/dev/(null|zero|stdout|stderr)') {
        if (-not (Test-Allowed 'dd')) {
            Block-Tool 'bash-guard: dd writing to a device can overwrite your entire drive or partition. Suggestion: Double-check the target device, or add ''allow: dd'' to .bash-guard.'
        }
    }
}

# Writing to system directories with redirects
if ($command -match '>\s*/(etc|usr|System|Library|boot|sbin)/') {
    if (-not (Test-Allowed 'system-write')) {
        Block-Tool 'bash-guard: Redirecting output to a system directory can break your OS. Suggestion: Write to a local project file instead, or add ''allow: system-write'' to .bash-guard.'
    }
}

# eval on variables (code injection risk)
if ($command -match 'eval\s+.*\$[A-Za-z_]') {
    if (-not (Test-Allowed 'eval')) {
        Block-Tool 'bash-guard: eval on variables is a code injection risk — the variable content is executed as code. Suggestion: Use the variable directly without eval, or add ''allow: eval'' to .bash-guard.'
    }
}

# npm global install
if ($command -match 'npm\s+install\s+-g\b') {
    if (-not (Test-Allowed 'global-install')) {
        Block-Tool 'bash-guard: Global npm install modifies system-wide packages. Suggestion: Use npx or local install instead, or add ''allow: global-install'' to .bash-guard.'
    }
}

# Docker destructive commands (data loss via volume/container removal)
if ($command -match 'docker(-compose|\s+compose)\s+down\s.*-v') {
    if (-not (Test-Allowed 'docker-destroy')) {
        Block-Tool 'bash-guard: docker compose down -v removes named volumes, causing permanent data loss. Suggestion: Use ''docker compose down'' without -v to keep volumes, or add ''allow: docker-destroy'' to .bash-guard.'
    }
}
if ($command -match 'docker\s+system\s+prune') {
    if (-not (Test-Allowed 'docker-destroy')) {
        Block-Tool 'bash-guard: docker system prune removes unused containers, networks, and images. Suggestion: Add ''allow: docker-destroy'' to .bash-guard if you need this.'
    }
}
if ($command -match 'docker\s+volume\s+(prune|rm)\b') {
    if (-not (Test-Allowed 'docker-destroy')) {
        Block-Tool 'bash-guard: Removing Docker volumes destroys persistent data. Suggestion: Add ''allow: docker-destroy'' to .bash-guard if you need this.'
    }
}

# prisma db push (destructive schema sync, bypasses migrations — #33183: wiped 276 accounts)
if ($command -match '(^|\s|;|&&|\|\|)(npx\s+)?prisma\s+db\s+push') {
    if (-not (Test-Allowed 'db-destroy')) {
        Block-Tool 'bash-guard: prisma db push applies schema changes directly without migrations. This has destroyed production databases. Suggestion: Use ''prisma migrate dev'' or ''prisma migrate deploy'' instead, or add ''allow: db-destroy'' to .bash-guard.'
    }
}

# Database CLI destructive commands
if ($command -match '(^|\s|;|&&|\|\|)dropdb\s') {
    if (-not (Test-Allowed 'db-destroy')) {
        Block-Tool 'bash-guard: dropdb permanently deletes a PostgreSQL database. Suggestion: Add ''allow: db-destroy'' to .bash-guard if you need this.'
    }
}
if ($command -imatch 'DROP\s+(DATABASE|TABLE)') {
    if (-not (Test-Allowed 'db-destroy')) {
        Block-Tool 'bash-guard: Destructive SQL command (DROP DATABASE/TABLE) causes permanent data loss. Suggestion: Add ''allow: db-destroy'' to .bash-guard if you need this.'
    }
}
if ($command -imatch 'TRUNCATE\s+') {
    # Exclude filesystem truncate command (has -s/-c/-r flags)
    if ($command -notmatch 'truncate\s+-') {
        if (-not (Test-Allowed 'db-destroy')) {
            Block-Tool 'bash-guard: SQL TRUNCATE causes permanent data loss. Suggestion: Add ''allow: db-destroy'' to .bash-guard if you need this.'
        }
    }
}
if ($command -match '(db:drop|db:wipe|migrate:fresh|fixtures:load|db:seed:replant)') {
    if (-not (Test-Allowed 'db-destroy')) {
        Block-Tool 'bash-guard: ORM command that destroys or replaces database contents. Suggestion: Add ''allow: db-destroy'' to .bash-guard if you need this.'
    }
}

# Environment variable dumps (credential exposure)
if ($command -match '(^|\s|;|&&|\|\|)(env|printenv)\s*($|\||\;|&&|\|\||>|2>)') {
    if (-not (Test-Allowed 'env-dump')) {
        Block-Tool 'bash-guard: Dumping all environment variables exposes API keys, tokens, and secrets in the output. Suggestion: Access specific variables with ''echo $VAR_NAME'' or ''printenv VAR_NAME'', or add ''allow: env-dump'' to .bash-guard.'
    }
}
if ($command -match '(^|\s|;|&&|\|\|)export\s+-p\s*($|\||\;|&&|\|\||>)') {
    if (-not (Test-Allowed 'env-dump')) {
        Block-Tool 'bash-guard: export -p lists all exported variables, potentially exposing secrets. Suggestion: Access specific variables directly, or add ''allow: env-dump'' to .bash-guard.'
    }
}

# Reading credential files directly
if ($command -match '(cat|less|more|head|tail|bat)\s+.*\.(env|pem|key|p12|pfx|credentials|secret)(\s|$)') {
    if (-not (Test-Allowed 'read-secrets')) {
        Block-Tool 'bash-guard: Reading credential files may expose secrets in the output. Suggestion: Reference specific non-secret values instead, or add ''allow: read-secrets'' to .bash-guard.'
    }
}

# Debug trace mode (leaks secrets in trace output)
if ($command -match '(bash|sh|zsh)\s+-[a-zA-Z]*x') {
    if (-not (Test-Allowed 'debug-trace')) {
        Block-Tool 'bash-guard: Running scripts with -x traces all commands with expanded variables, exposing secrets in output. Suggestion: Remove the -x flag, or add ''allow: debug-trace'' to .bash-guard.'
    }
}
if ($command -match '(^|\s|;|&&|\|\|)set\s+-[a-zA-Z]*x') {
    if (-not (Test-Allowed 'debug-trace')) {
        Block-Tool 'bash-guard: set -x enables debug tracing which prints all variables including secrets. Suggestion: Remove set -x, or add ''allow: debug-trace'' to .bash-guard.'
    }
}

# Cloud infrastructure destruction (terraform, aws, kubectl, gcloud, pulumi)
if ($command -match '(^|\s|;|&&|\|\|)terraform\s+destroy') {
    if (-not (Test-Allowed 'infra-destroy')) {
        Block-Tool 'bash-guard: terraform destroy removes cloud infrastructure. This can take down production services. Suggestion: Use ''terraform plan -destroy'' to preview first, or add ''allow: infra-destroy'' to .bash-guard.'
    }
}
if ($command -match '(^|\s|;|&&|\|\|)pulumi\s+destroy') {
    if (-not (Test-Allowed 'infra-destroy')) {
        Block-Tool 'bash-guard: pulumi destroy removes cloud infrastructure. Suggestion: Use ''pulumi preview --diff'' first, or add ''allow: infra-destroy'' to .bash-guard.'
    }
}
if ($command -match 'aws\s+s3\s+(rm|rb)\s.*--recursive') {
    if (-not (Test-Allowed 'infra-destroy')) {
        Block-Tool 'bash-guard: Recursive S3 deletion permanently removes objects from the bucket. Suggestion: Remove specific keys instead, or add ''allow: infra-destroy'' to .bash-guard.'
    }
}
if ($command -match 'kubectl\s+delete\s+(namespace|ns|all|deployment|statefulset)\s') {
    if (-not (Test-Allowed 'infra-destroy')) {
        Block-Tool 'bash-guard: kubectl delete removes Kubernetes resources, potentially taking down production services. Suggestion: Verify the target cluster and namespace first, or add ''allow: infra-destroy'' to .bash-guard.'
    }
}
if ($command -match 'gcloud\s.*(delete|destroy)\s') {
    if (-not (Test-Allowed 'infra-destroy')) {
        Block-Tool 'bash-guard: gcloud delete/destroy removes Google Cloud resources. Suggestion: Verify the target project first, or add ''allow: infra-destroy'' to .bash-guard.'
    }
}
if ($command -match '(^|\s|;|&&|\|\|)helm\s+(uninstall|delete)\s') {
    if (-not (Test-Allowed 'infra-destroy')) {
        Block-Tool 'bash-guard: helm uninstall removes a Kubernetes release and all its resources. Suggestion: Use ''helm list'' to verify the release first, or add ''allow: infra-destroy'' to .bash-guard.'
    }
}
if ($command -match 'kubectl\s+drain\s') {
    if (-not (Test-Allowed 'infra-destroy')) {
        Block-Tool 'bash-guard: kubectl drain evicts all pods from a node, causing service disruption. Suggestion: Verify the node and use --dry-run first, or add ''allow: infra-destroy'' to .bash-guard.'
    }
}
if ($command -match 'kubectl\s+scale\s.*--replicas[= ]*0\b') {
    if (-not (Test-Allowed 'infra-destroy')) {
        Block-Tool 'bash-guard: kubectl scale --replicas=0 stops all pods for the resource, taking the service offline. Suggestion: Verify the target resource first, or add ''allow: infra-destroy'' to .bash-guard.'
    }
}
if ($command -match '(^|\s|;|&&|\|\|)az\s+(group|resource|vm|webapp|functionapp|sql\s+server)\s+delete\s') {
    if (-not (Test-Allowed 'infra-destroy')) {
        Block-Tool 'bash-guard: Azure CLI delete removes cloud resources permanently. Suggestion: Verify the resource group and subscription first, or add ''allow: infra-destroy'' to .bash-guard.'
    }
}
if ($command -match '(^|\s|;|&&|\|\|)doctl\s.*(delete|destroy)\s') {
    if (-not (Test-Allowed 'infra-destroy')) {
        Block-Tool 'bash-guard: DigitalOcean CLI delete/destroy removes cloud resources. Suggestion: Verify the target first, or add ''allow: infra-destroy'' to .bash-guard.'
    }
}
if ($command -match '(^|\s|;|&&|\|\|)(flyctl|fly)\s+(apps\s+)?destroy\s') {
    if (-not (Test-Allowed 'infra-destroy')) {
        Block-Tool 'bash-guard: Fly.io destroy removes the application and all its machines. Suggestion: Verify the app name first, or add ''allow: infra-destroy'' to .bash-guard.'
    }
}
if ($command -match '(^|\s|;|&&|\|\|)heroku\s+apps:destroy\s') {
    if (-not (Test-Allowed 'infra-destroy')) {
        Block-Tool 'bash-guard: heroku apps:destroy permanently removes the application and all add-ons. Suggestion: Verify the app name first, or add ''allow: infra-destroy'' to .bash-guard.'
    }
}
if ($command -match '(^|\s|;|&&|\|\|)vercel\s+(rm|remove)\s') {
    if (-not (Test-Allowed 'infra-destroy')) {
        Block-Tool 'bash-guard: vercel rm removes deployments or projects. Suggestion: Verify the target first, or add ''allow: infra-destroy'' to .bash-guard.'
    }
}
if ($command -match '(^|\s|;|&&|\|\|)netlify\s+sites:delete\s') {
    if (-not (Test-Allowed 'infra-destroy')) {
        Block-Tool 'bash-guard: netlify sites:delete permanently removes the site. Suggestion: Verify the site name first, or add ''allow: infra-destroy'' to .bash-guard.'
    }
}
if ($command -match 'aws\s+ec2\s+terminate-instances\s') {
    if (-not (Test-Allowed 'infra-destroy')) {
        Block-Tool 'bash-guard: aws ec2 terminate-instances permanently destroys EC2 instances. Suggestion: Verify instance IDs first, or add ''allow: infra-destroy'' to .bash-guard.'
    }
}
if ($command -match 'aws\s+(rds|dynamodb|elasticache|lambda)\s+delete-') {
    if (-not (Test-Allowed 'infra-destroy')) {
        Block-Tool 'bash-guard: AWS CLI delete command permanently removes cloud resources. Suggestion: Verify the resource identifier first, or add ''allow: infra-destroy'' to .bash-guard.'
    }
}
if ($command -match 'aws\s+cloudformation\s+delete-stack\s') {
    if (-not (Test-Allowed 'infra-destroy')) {
        Block-Tool 'bash-guard: aws cloudformation delete-stack tears down the entire stack and all its resources. Suggestion: Verify the stack name first, or add ''allow: infra-destroy'' to .bash-guard.'
    }
}

# Additional database destruction patterns
if ($command -match '(doctrine:schema:drop|sequelize\s+db:drop|typeorm\s+schema:drop)') {
    if (-not (Test-Allowed 'db-destroy')) {
        Block-Tool 'bash-guard: ORM schema drop command permanently destroys database structure. Suggestion: Add ''allow: db-destroy'' to .bash-guard if you need this.'
    }
}
if ($command -match 'redis-cli\s.*(FLUSHALL|FLUSHDB)') {
    if (-not (Test-Allowed 'db-destroy')) {
        Block-Tool 'bash-guard: Redis FLUSHALL/FLUSHDB permanently deletes all data in the Redis instance. Suggestion: Add ''allow: db-destroy'' to .bash-guard if you need this.'
    }
}
if ($command -match '(wp\s+db\s+(reset|clean)|drush\s+sql-drop)') {
    if (-not (Test-Allowed 'db-destroy')) {
        Block-Tool 'bash-guard: CMS database destruction command causes permanent data loss. Suggestion: Add ''allow: db-destroy'' to .bash-guard if you need this.'
    }
}
if ($command -match '(mongosh?|mongo)\s.*dropDatabase') {
    if (-not (Test-Allowed 'db-destroy')) {
        Block-Tool 'bash-guard: MongoDB dropDatabase permanently removes the entire database. Suggestion: Add ''allow: db-destroy'' to .bash-guard if you need this.'
    }
}

# Mass file deletion (find -delete, find -exec rm, xargs rm)
if ($command -match 'find\s.*\s-delete\b') {
    if (-not (Test-Allowed 'mass-delete')) {
        Block-Tool 'bash-guard: find with -delete permanently removes all matching files without confirmation. Suggestion: Use -print first to preview, or add ''allow: mass-delete'' to .bash-guard.'
    }
}
if ($command -match 'find\s.*-exec\s+rm\s') {
    if (-not (Test-Allowed 'mass-delete')) {
        Block-Tool 'bash-guard: find with -exec rm permanently removes matching files in bulk. Suggestion: Use -print first to preview, or add ''allow: mass-delete'' to .bash-guard.'
    }
}
if ($command -match '\|\s*xargs\s.*rm\b') {
    if (-not (Test-Allowed 'mass-delete')) {
        Block-Tool 'bash-guard: Piping to xargs rm deletes files in bulk without individual confirmation. Suggestion: Review the file list first, or add ''allow: mass-delete'' to .bash-guard.'
    }
}

# git clean -fdx (removes all untracked files including gitignored)
if ($command -match 'git\s+clean\s+-[a-zA-Z]*f') {
    if (-not (Test-Allowed 'git-clean')) {
        Block-Tool 'bash-guard: git clean -f permanently removes untracked files. With -x it also removes gitignored files (build artifacts, .env, etc.). Suggestion: Use ''git clean -n'' for a dry run first, or add ''allow: git-clean'' to .bash-guard.'
    }
}

# Docker host mounts (escape directory restrictions — #37621)
if ($command -match 'docker\s+run\s.*-v\s+/[^:]*:') {
    if (-not (Test-Allowed 'docker-mount')) {
        Block-Tool 'bash-guard: Docker run with host volume mount can access files outside the allowed directory. Suggestion: Mount only project-specific paths, or add ''allow: docker-mount'' to .bash-guard.'
    }
}

# Docker exec (arbitrary commands in containers with potential host access)
if ($command -match '(^|\s|;|&&|\|\|)docker\s+exec\s') {
    if (-not (Test-Allowed 'docker-exec')) {
        Block-Tool 'bash-guard: docker exec runs commands in a container that may have elevated privileges or host access. Suggestion: Add ''allow: docker-exec'' to .bash-guard if you need container access.'
    }
}

# File destruction alternatives (workaround bypasses for rm — Pattern E)
if ($command -match '(^|[;&\|]\s*)shred\s') {
    if (-not (Test-Allowed 'shred')) {
        Block-Tool 'bash-guard: shred securely overwrites files, making recovery impossible. Suggestion: Use rm instead (allows recovery from backups), or add ''allow: shred'' to .bash-guard.'
    }
}
if ($command -match '(^|[;&\|]\s*)truncate\s+-s\s*0\s') {
    if (-not (Test-Allowed 'truncate')) {
        Block-Tool 'bash-guard: truncate -s 0 empties files, causing silent data loss without deleting them. Suggestion: Add ''allow: truncate'' to .bash-guard if you need this.'
    }
}

# Disk overwrite via /dev/zero or /dev/urandom targeting devices (regular files are OK)
if ($command -match 'dd\s.*if=/dev/(zero|urandom).*of=/dev/') {
    if ($command -notmatch 'dd\s.*of=/dev/(null|zero|stdout|stderr)') {
        if (-not (Test-Allowed 'dd')) {
            Block-Tool 'bash-guard: dd from /dev/zero or /dev/urandom to a device overwrites the entire device, destroying all data. Suggestion: Add ''allow: dd'' to .bash-guard if you need this.'
        }
    }
}

# Data exfiltration: uploading local files via curl/wget to remote servers
if ($command -match 'curl\s.*(-d\s*@|-F\s+[^=]+=@|--data-binary\s+@|--data\s+@|--data-urlencode\s+@|--upload-file\s)') {
    if (-not (Test-Allowed 'file-upload')) {
        Block-Tool 'bash-guard: curl is uploading a local file to a remote server. This could exfiltrate sensitive data. Suggestion: Inline the data instead of referencing a file, or add ''allow: file-upload'' to .bash-guard.'
    }
}
if ($command -match 'wget\s.*(--post-file|--body-file)\s') {
    if (-not (Test-Allowed 'file-upload')) {
        Block-Tool 'bash-guard: wget is uploading a local file to a remote server. This could exfiltrate sensitive data. Suggestion: Use curl with inline data instead, or add ''allow: file-upload'' to .bash-guard.'
    }
}

# Programmatic env dumps (scripting language one-liners that dump all env vars)
if ($command -match 'python[23]?\s+-c\s.*os\.environ') {
    if (-not (Test-Allowed 'env-dump')) {
        Block-Tool 'bash-guard: Python one-liner accessing os.environ exposes all environment variables including secrets. Suggestion: Access specific variables with os.getenv(''VAR''), or add ''allow: env-dump'' to .bash-guard.'
    }
}
# Match process.env (dump all) but not process.env.HOME (specific access)
if ($command -match 'node\s+-e\s.*process\.env($|[^.\[a-zA-Z])') {
    if (-not (Test-Allowed 'env-dump')) {
        Block-Tool 'bash-guard: Node.js one-liner accessing process.env exposes all environment variables including secrets. Suggestion: Access specific variables with process.env.VAR, or add ''allow: env-dump'' to .bash-guard.'
    }
}
if ($command -match 'ruby\s+-e\s.*ENV') {
    if (-not (Test-Allowed 'env-dump')) {
        Block-Tool 'bash-guard: Ruby one-liner accessing ENV exposes all environment variables including secrets. Suggestion: Access specific variables with ENV[''VAR''], or add ''allow: env-dump'' to .bash-guard.'
    }
}

# Process environment file access (Linux /proc/*/environ)
if ($command -match '(cat|less|more|head|tail|strings)\s+/proc/[^/]+/environ') {
    if (-not (Test-Allowed 'env-dump')) {
        Block-Tool 'bash-guard: Reading /proc/*/environ exposes all environment variables of a process including secrets. Suggestion: Access specific variables directly, or add ''allow: env-dump'' to .bash-guard.'
    }
}

# SSH private key access
if ($command -match '(cat|less|more|head|tail|bat)\s+.*\.ssh/(id_|.*\.pem|.*key)') {
    if (-not (Test-Allowed 'read-secrets')) {
        Block-Tool 'bash-guard: Reading SSH private keys exposes credentials that grant server access. Suggestion: Use ssh-agent or reference the key path in SSH config, or add ''allow: read-secrets'' to .bash-guard.'
    }
}

# Shell history access (may contain passwords/tokens typed at prompts)
if ($command -match '(cat|less|more|head|tail|bat)\s+.*(\.bash_history|\.zsh_history|\.sh_history|\.history)') {
    if (-not (Test-Allowed 'read-secrets')) {
        Block-Tool 'bash-guard: Shell history files may contain passwords, tokens, and API keys typed at prompts. Suggestion: Search for specific commands with grep instead, or add ''allow: read-secrets'' to .bash-guard.'
    }
}

# System database modification via sqlite3 (#37888: 59 sqlite3 commands corrupted VSCode state.vscdb)
if ($command -match 'sqlite3\s+.*\.(vscdb|vscdb-wal|vscdb-shm)') {
    if (-not (Test-Allowed 'system-db')) {
        Block-Tool 'bash-guard: sqlite3 targeting a VSCode database (.vscdb). This has destroyed IDE session history and Codex functionality (#37888). Suggestion: Do not modify VSCode internal databases, or add ''allow: system-db'' to .bash-guard.'
    }
}
if ($command -match 'sqlite3\s+.*(Application Support/Code|\.vscode|\.cursor|\.config/(Code|Cursor)|\.vscode-server)') {
    if (-not (Test-Allowed 'system-db')) {
        Block-Tool 'bash-guard: sqlite3 targeting an IDE internal database. Modifying these can corrupt sessions, settings, and extensions. Suggestion: Only use sqlite3 on your project databases, or add ''allow: system-db'' to .bash-guard.'
    }
}

# Mount point deletion (#36640: rm -rf on NFS mount destroyed production user data)
if ($command -match 'rm\s+-[rRf]+\s+/(mnt|media|Volumes|nfs|mount)/') {
    if (-not (Test-Allowed 'mount-delete')) {
        Block-Tool 'bash-guard: rm -rf targeting a mount point path. NFS/SMB/external volumes may contain production data (#36640). Suggestion: Check mount status with ''mount'' or ''findmnt'' first, or add ''allow: mount-delete'' to .bash-guard.'
    }
}

# Network exfiltration via netcat/socat (piping files to remote hosts)
if ($command -match '(nc|ncat|netcat|socat)\s.*<\s') {
    if (-not (Test-Allowed 'file-upload')) {
        Block-Tool 'bash-guard: Piping file content through netcat/socat sends data to a remote host without encryption or logging. Suggestion: Use curl or scp instead, or add ''allow: file-upload'' to .bash-guard.'
    }
}

# --- Here-string/here-doc to shell (bypass via redirection instead of pipe) ---

# Here-string: bash <<< "command", sh <<< 'command'
if ($command -match '(bash|sh|zsh|dash|ksh)\s+<<<\s') {
    if (-not (Test-Allowed 'here-exec')) {
        Block-Tool 'bash-guard: Here-string feeds content directly to a shell interpreter, bypassing safety checks. Suggestion: Run the command directly instead of via here-string. Or add ''allow: here-exec'' to .bash-guard.'
    }
}

# Here-doc: bash << EOF, sh << 'DELIM', bash <<-EOF (with indent stripping)
if ($command -match '(bash|sh|zsh|dash|ksh)\s+<<-?\s*[''"]?[A-Za-z_]') {
    if (-not (Test-Allowed 'here-exec')) {
        Block-Tool 'bash-guard: Here-document feeds content directly to a shell interpreter, bypassing safety checks. Suggestion: Run the commands directly instead of via here-doc. Or add ''allow: here-exec'' to .bash-guard.'
    }
}

# eval with string literal (not just variables): eval "rm -rf /"
if ($command -match '(^|[;&\|]\s*)eval\s+[''"]') {
    if (-not (Test-Allowed 'eval')) {
        Block-Tool 'bash-guard: eval with a string literal executes arbitrary code that bypasses pattern matching. Suggestion: Run the command directly without eval. Or add ''allow: eval'' to .bash-guard.'
    }
}

# xargs piping to shell interpreter: xargs -I{} bash -c {} or xargs sh -c
if ($command -match '\|\s*xargs\s.*\b(bash|sh|zsh|dash|ksh)\s+-c\b') {
    if (-not (Test-Allowed 'decode-exec')) {
        Block-Tool 'bash-guard: Piping through xargs to a shell interpreter executes arbitrary commands that bypass safety checks. Suggestion: Process the data directly instead of piping through a shell. Or add ''allow: decode-exec'' to .bash-guard.'
    }
}

# --- Encoding bypass detection ---

# base64 decode piped to shell (includes openssl base64 variant)
if ($command -match '(base64\s+(-d|--decode|-D)|openssl\s+(base64|enc)\s+-d)\s*\|.*\s*(bash|sh|zsh|dash|ksh|source|eval)') {
    if (-not (Test-Allowed 'decode-exec')) {
        Block-Tool 'bash-guard: Decoding base64 content and piping to shell executes hidden commands that bypass all safety checks. Suggestion: Decode to a file first, review it, then run it. Or add ''allow: decode-exec'' to .bash-guard.'
    }
}

# base64 decode via command substitution to shell
if ($command -match '(bash|sh|zsh)\s+-c\s.*\$\(.*base64\s+(-d|--decode|-D)') {
    if (-not (Test-Allowed 'decode-exec')) {
        Block-Tool 'bash-guard: Executing base64-decoded content via command substitution bypasses all safety checks. Suggestion: Decode to a file first, review it, then run it. Or add ''allow: decode-exec'' to .bash-guard.'
    }
}

# hex decode piped to shell (xxd -r)
if ($command -match 'xxd\s+-r.*\|.*\s*(bash|sh|zsh|dash|ksh|source|eval)') {
    if (-not (Test-Allowed 'decode-exec')) {
        Block-Tool 'bash-guard: Decoding hex content and piping to shell executes hidden commands that bypass all safety checks. Suggestion: Decode to a file first, review it, then run it. Or add ''allow: decode-exec'' to .bash-guard.'
    }
}

# printf hex/octal escapes piped to shell
if ($command -match 'printf\s+[''"]\\(x[0-9a-fA-F]|[0-7]{3}).*\|.*\s*(bash|sh|zsh|dash|ksh|source|eval)') {
    if (-not (Test-Allowed 'decode-exec')) {
        Block-Tool 'bash-guard: printf with escape sequences piped to shell executes hidden commands that bypass all safety checks. Suggestion: Write the command directly instead of encoding it. Or add ''allow: decode-exec'' to .bash-guard.'
    }
}

# Process substitution with network downloads: bash <(curl ...) or sh <(wget ...)
if ($command -match '(bash|sh|zsh|dash|ksh)\s+<\(\s*(curl|wget)\s') {
    if (-not (Test-Allowed 'pipe-to-shell')) {
        Block-Tool 'bash-guard: Process substitution downloads and executes code without saving it for review. Suggestion: Download the script first, review it, then run it. Or add ''allow: pipe-to-shell'' to .bash-guard.'
    }
}

# Reversed string piped to shell (obfuscation: echo '/ fr- mr' | rev | bash)
if ($command -match '\|\s*rev\s*\|.*\s*(bash|sh|zsh|dash|ksh|source|eval)') {
    if (-not (Test-Allowed 'decode-exec')) {
        Block-Tool 'bash-guard: Reversing a string and piping to shell is an obfuscation technique to hide dangerous commands. Suggestion: Write the command directly instead of reversing it. Or add ''allow: decode-exec'' to .bash-guard.'
    }
}

# Programming language shell execution (subprocess, os.system, system())
if ($command -match 'python[23]?\s+-c\s.*\b(subprocess|os\.system|os\.popen)\b') {
    if (-not (Test-Allowed 'lang-exec')) {
        Block-Tool 'bash-guard: Python one-liner executing shell commands via subprocess/os.system bypasses bash-guard checks. Suggestion: Run the shell command directly instead of wrapping it in Python. Or add ''allow: lang-exec'' to .bash-guard.'
    }
}
if ($command -match 'ruby\s+-e\s.*\b(system|exec|%x|Kernel\.)') {
    if (-not (Test-Allowed 'lang-exec')) {
        Block-Tool 'bash-guard: Ruby one-liner executing shell commands bypasses bash-guard checks. Suggestion: Run the shell command directly instead of wrapping it in Ruby. Or add ''allow: lang-exec'' to .bash-guard.'
    }
}
if ($command -match 'perl\s+-e\s.*\b(system|exec|qx)') {
    if (-not (Test-Allowed 'lang-exec')) {
        Block-Tool 'bash-guard: Perl one-liner executing shell commands bypasses bash-guard checks. Suggestion: Run the shell command directly instead of wrapping it in Perl. Or add ''allow: lang-exec'' to .bash-guard.'
    }
}
if ($command -match 'node\s+-e\s.*child_process') {
    if (-not (Test-Allowed 'lang-exec')) {
        Block-Tool 'bash-guard: Node.js one-liner executing shell commands via child_process bypasses bash-guard checks. Suggestion: Run the shell command directly instead of wrapping it in Node. Or add ''allow: lang-exec'' to .bash-guard.'
    }
}

# In-place file editing via interpreters (bypasses file-guard, #40408)
# perl -i, perl -pi, perl -i.bak — in-place edit like sed -i
if ($command -match '(^|[;&\|]\s*)perl\s+(-[A-Za-z]*i|-i[^\s]*)') {
    if (-not (Test-Allowed 'inplace-edit')) {
        Block-Tool 'bash-guard: Perl in-place file editing (perl -i) modifies files directly, bypassing file-guard protection. Reported in claude-code#40408. Suggestion: Use Edit tool instead, which respects file-guard rules. Or add ''allow: inplace-edit'' to .bash-guard.'
    }
}
# ruby -i — in-place edit
if ($command -match '(^|[;&\|]\s*)ruby\s+(-[A-Za-z]*i|-i[^\s]*)') {
    if (-not (Test-Allowed 'inplace-edit')) {
        Block-Tool 'bash-guard: Ruby in-place file editing (ruby -i) modifies files directly, bypassing file-guard protection. Suggestion: Use Edit tool instead, which respects file-guard rules. Or add ''allow: inplace-edit'' to .bash-guard.'
    }
}
# sed -i — in-place edit (most common form)
if ($command -match '(^|[;&\|]\s*)sed\s+(-[A-Za-z]*i|-i[^\s]*)') {
    if (-not (Test-Allowed 'inplace-edit')) {
        Block-Tool 'bash-guard: sed in-place editing (sed -i) modifies files directly, bypassing file-guard protection. Suggestion: Use Edit tool instead, which respects file-guard rules. Or add ''allow: inplace-edit'' to .bash-guard.'
    }
}

# --- Gaps identified from competitive analysis ---

# LD_PRELOAD / LD_LIBRARY_PATH injection (hijacks library loading)
if ($command -match '(^|\s|;|&&|\|\|)(LD_PRELOAD|LD_LIBRARY_PATH)=') {
    if (-not (Test-Allowed 'env-inject')) {
        Block-Tool 'bash-guard: Setting LD_PRELOAD or LD_LIBRARY_PATH allows hijacking shared library loading to inject malicious code. Suggestion: Remove the LD_ variable assignment, or add ''allow: env-inject'' to .bash-guard.'
    }
}

# IFS manipulation (changes command parsing semantics)
if ($command -match '(^|\s|;|&&|\|\|)(export\s+)?IFS=') {
    if (-not (Test-Allowed 'env-inject')) {
        Block-Tool 'bash-guard: Setting IFS changes how the shell parses commands, which can alter the behavior of scripts in unexpected ways. Suggestion: Remove the IFS assignment, or add ''allow: env-inject'' to .bash-guard.'
    }
}

# Wrapper commands hiding dangerous operations (timeout rm, nohup rm, env rm, etc.)
if ($command -match '(^|[;&\|]\s*)(timeout|time|nice|nohup|strace|ltrace|unbuffer|caffeinate)\s+.*(rm\s+-[rRf]|mkfs|dd\s|shred|wipefs|fdisk|gdisk|parted|sfdisk|chmod\s.*777|chown\s.*-R)') {
    if (-not (Test-Allowed 'wrapper-bypass')) {
        Block-Tool 'bash-guard: A wrapper command (timeout/nohup/strace/etc.) is hiding a dangerous operation. The wrapped command would cause irreversible damage. Suggestion: Run the command directly so it can be properly checked, or add ''allow: wrapper-bypass'' to .bash-guard.'
    }
}

# Credential file copy/move/scp (exfiltration via file operations)
if ($command -match '(cp|mv|scp|rsync)\s+.*(\.ssh/|\.aws/|\.gnupg/|\.netrc|\.npmrc|\.docker/config)') {
    if (-not (Test-Allowed 'cred-copy')) {
        Block-Tool 'bash-guard: Copying or moving credential files (.ssh/, .aws/, .gnupg/, .netrc) could exfiltrate secrets. Suggestion: Reference credentials via their standard paths instead. Or add ''allow: cred-copy'' to .bash-guard.'
    }
}

# macOS Keychain access (credential theft)
if ($command -match '(^|[;&\|]\s*)security\s+(find-generic-password|find-internet-password|delete-generic-password|delete-internet-password|add-generic-password|dump-keychain)') {
    if (-not (Test-Allowed 'keychain')) {
        Block-Tool 'bash-guard: Accessing the macOS Keychain can read, modify, or delete stored passwords and certificates. Suggestion: Add ''allow: keychain'' to .bash-guard if you need Keychain access.'
    }
}

# crontab modification (persistence mechanism)
if ($command -match '(^|[;&\|]\s*)crontab\s+-[erl]') {
    if (-not (Test-Allowed 'scheduled-tasks')) {
        Block-Tool 'bash-guard: Modifying crontab installs scheduled tasks that persist after this session. Suggestion: Add ''allow: scheduled-tasks'' to .bash-guard if you need to modify cron.'
    }
}

# launchctl load/unload (macOS persistence)
if ($command -match '(^|[;&\|]\s*)launchctl\s+(load|unload|submit|bootstrap|bootout)') {
    if (-not (Test-Allowed 'scheduled-tasks')) {
        Block-Tool 'bash-guard: launchctl modifies persistent macOS services that run outside this session. Suggestion: Add ''allow: scheduled-tasks'' to .bash-guard if you need to manage launch agents.'
    }
}

# Generic pipe to eval (not just curl/wget)
if ($command -match '\|\s*eval\b') {
    if (-not (Test-Allowed 'eval')) {
        Block-Tool 'bash-guard: Piping output directly to eval executes arbitrary content as shell code. Suggestion: Assign to a variable and inspect before evaluating. Or add ''allow: eval'' to .bash-guard.'
    }
}

# Pipe to fish shell (missing from our shell list)
if ($command -match '(curl|wget)\s.*\|\s*fish\b') {
    if (-not (Test-Allowed 'pipe-to-shell')) {
        Block-Tool 'bash-guard: Piping downloaded content to fish shell executes untrusted code. Suggestion: Download the script first, review it, then run it. Or add ''allow: pipe-to-shell'' to .bash-guard.'
    }
}

# systemctl service management
if ($command -match '(^|[;&\|]\s*)systemctl\s+(start|stop|restart|disable|enable|mask)\s') {
    if (-not (Test-Allowed 'service-mgmt')) {
        Block-Tool 'bash-guard: systemctl modifies system services which can affect system stability and security. Suggestion: Add ''allow: service-mgmt'' to .bash-guard if you need to manage services.'
    }
}

# SysV service management
if ($command -match '(^|[;&\|]\s*)service\s+\S+\s+(start|stop|restart)') {
    if (-not (Test-Allowed 'service-mgmt')) {
        Block-Tool 'bash-guard: service start/stop/restart modifies running system services. Suggestion: Add ''allow: service-mgmt'' to .bash-guard if you need to manage services.'
    }
}

# ssh-keygen (key generation) and ssh-add (agent operations)
if ($command -match '(^|[;&\|]\s*)ssh-keygen\s') {
    if (-not (Test-Allowed 'ssh-keys')) {
        Block-Tool 'bash-guard: ssh-keygen creates or modifies SSH keys which grant remote server access. Suggestion: Add ''allow: ssh-keys'' to .bash-guard if you need to generate SSH keys.'
    }
}
if ($command -match '(^|[;&\|]\s*)ssh-add\s') {
    if (-not (Test-Allowed 'ssh-keys')) {
        Block-Tool 'bash-guard: ssh-add loads SSH private keys into the agent, granting access to remote servers. Suggestion: Add ''allow: ssh-keys'' to .bash-guard if you need to manage SSH agent keys.'
    }
}

# pkill -9 (mass process termination)
if ($command -match '(^|[;&\|]\s*)pkill\s+-9\s') {
    if (-not (Test-Allowed 'kill -9')) {
        Block-Tool 'bash-guard: pkill -9 force-kills matching processes without graceful shutdown. Suggestion: Use pkill without -9 for graceful termination, or add ''allow: kill -9'' to .bash-guard.'
    }
}

# git push --force (overwrites remote history, can destroy teammates' work)
if ($command -match '(^|[;&\|]\s*)git\s+push\s+.*(-f\b|--force\b|--force-with-lease\b)') {
    if (-not (Test-Allowed 'git-force-push')) {
        Block-Tool 'bash-guard: git push --force overwrites remote history and can destroy other contributors'' work. Suggestion: Use ''git push'' without --force, or add ''allow: git-force-push'' to .bash-guard.'
    }
}

# git filter-branch (history rewriting, data loss risk)
if ($command -match '(^|[;&\|]\s*)git\s+filter-branch\b') {
    if (-not (Test-Allowed 'git-rewrite')) {
        Block-Tool 'bash-guard: git filter-branch rewrites repository history, which can cause data loss and force-push requirements. Suggestion: Use git filter-repo instead (safer), or add ''allow: git-rewrite'' to .bash-guard.'
    }
}

# docker rm -f (force remove containers)
if ($command -match '(^|[;&\|]\s*)docker\s+rm\s+-[a-zA-Z]*f') {
    if (-not (Test-Allowed 'docker-destroy')) {
        Block-Tool 'bash-guard: docker rm -f force-removes running containers without graceful shutdown. Suggestion: Stop the container first with ''docker stop'', or add ''allow: docker-destroy'' to .bash-guard.'
    }
}

# yarn/pnpm global installs (missing from npm-only check)
if ($command -match '(yarn|pnpm)\s+global\s+add\b') {
    if (-not (Test-Allowed 'global-install')) {
        Block-Tool 'bash-guard: Global package install modifies system-wide packages. Suggestion: Use local install instead, or add ''allow: global-install'' to .bash-guard.'
    }
}

# passwd (password change)
if ($command -match '(^|[;&\|]\s*)passwd\b') {
    if (-not (Test-Allowed 'passwd')) {
        Block-Tool 'bash-guard: passwd changes user passwords. AI agents should not modify user credentials. Suggestion: Add ''allow: passwd'' to .bash-guard if you need this.'
    }
}

# pip/pip3 install --target (writes packages to arbitrary paths, sandbox escape — #41103)
if ($command -match 'pip3?\s+install\s.*--target') {
    if (-not (Test-Allowed 'pip-target')) {
        Block-Tool 'bash-guard: pip install --target writes packages to an arbitrary directory, bypassing sandbox confinement. Suggestion: Install without --target (uses default location), or add ''allow: pip-target'' to .bash-guard.'
    }
}

# pip/pip3 install --user (writes to ~/.local outside sandbox — #41103)
if ($command -match 'pip3?\s+install\s.*--user') {
    if (-not (Test-Allowed 'pip-user')) {
        Block-Tool 'bash-guard: pip install --user writes packages to ~/.local which may be outside the sandbox. Suggestion: Install without --user (uses project virtualenv), or add ''allow: pip-user'' to .bash-guard.'
    }
}

# Deep path traversal (4+ levels of ../ is likely a sandbox escape attempt — #41103)
if ($command -match '(\.\./){4,}') {
    if (-not (Test-Allowed 'path-traversal')) {
        Block-Tool 'bash-guard: Deep path traversal (4+ levels of ../) may be an attempt to escape a sandboxed directory. Suggestion: Use absolute paths or navigate to the target directory first. Or add ''allow: path-traversal'' to .bash-guard.'
    }
}

Write-Log "ALLOW: $command"
exit 0
