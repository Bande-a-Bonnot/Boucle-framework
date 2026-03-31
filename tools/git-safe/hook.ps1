# git-safe: PreToolUse hook for Claude Code (PowerShell)
# Windows-native equivalent of hook.sh — no external dependencies needed.
#
# Prevents destructive git operations that can lose work.
#
# Blocked operations:
#   - git push --force / -f (can rewrite remote history)
#   - git reset --hard (discards uncommitted changes)
#   - git checkout . / git checkout -- <file> (discards changes)
#   - git checkout <ref> -- <path> (overwrites files from ref)
#   - git restore without --staged (discards working tree changes)
#   - git restore --source / -s (overwrites from arbitrary ref)
#   - git clean -f (deletes untracked files permanently)
#   - git branch -D (force-deletes unmerged branches)
#   - git stash drop / clear (permanently deletes stashed work)
#   - git commit --no-verify / -n (skips pre-commit hooks)
#   - git push --delete / origin :branch (removes remote refs)
#   - git reflog expire (destroys recovery data)
#
# Install:
#   1. Copy hook.ps1 to your project
#   2. Add to .claude/settings.json:
#      "hooks": { "PreToolUse": [{ "type": "command", "command": "pwsh -File /path/to/hook.ps1" }] }
#
# Config (.git-safe):
#   allow: push --force    # whitelist specific operations
#   allow: reset --hard
#
# Env vars:
#   GIT_SAFE_DISABLED=1    Disable the hook entirely
#   GIT_SAFE_LOG=1         Log all checks to stderr

$ErrorActionPreference = 'Stop'

if ($env:GIT_SAFE_DISABLED -eq '1') { exit 0 }

# Helper: write log to stderr
function Write-Log {
    param([string]$Message)
    if ($env:GIT_SAFE_LOG -eq '1') {
        [Console]::Error.WriteLine("[git-safe] $Message")
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

# Check if command contains git
if ($command -notmatch '\bgit\b') {
    Write-Log "SKIP: no git command"
    exit 0
}

# Load allowlist from .git-safe config
$allowed = @()
$configPath = if ($env:GIT_SAFE_CONFIG) { $env:GIT_SAFE_CONFIG } else { '.git-safe' }
if (Test-Path $configPath) {
    foreach ($rawLine in Get-Content $configPath) {
        $line = ($rawLine -replace '#.*$', '').Trim()
        if (-not $line) { continue }
        if ($line -match '^allow:\s*(.+)$') {
            $allowed += $Matches[1].Trim()
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

# --- Destructive operation checks ---

# git commit/merge/push --no-verify / -n (skips safety hooks like pre-commit, pre-push)
# See: https://github.com/anthropics/claude-code/issues/40117
if ($command -match 'git\s+(commit|merge|push|cherry-pick|revert|am)\s.*--no-verify') {
    if (-not (Test-Allowed 'no-verify')) {
        Block-Tool "git-safe: git --no-verify skips pre-commit/pre-push hooks, bypassing safety checks like linting, tests, and secret scanning. Suggestion: Remove --no-verify and let hooks run. Fix any issues they report. Add 'allow: no-verify' to .git-safe only if you understand the risk."
    }
}
# Also catch -n shorthand for commit (git commit -n is --no-verify)
if ($command -match 'git\s+commit\s+(-[a-zA-Z]*n[a-zA-Z]*\b|.*\s-[a-zA-Z]*n[a-zA-Z]*\b)') {
    if ($command -notmatch '--no-verify') {
        if (-not (Test-Allowed 'no-verify')) {
            Block-Tool "git-safe: git commit -n skips pre-commit hooks (same as --no-verify). Suggestion: Remove -n and let pre-commit hooks run. Add 'allow: no-verify' to .git-safe only if you understand the risk."
        }
    }
}

# git push --force / -f (but not --force-with-lease which is safer)
if ($command -match 'git\s+push\s.*--force(\s|$)') {
    if ($command -match '--force-with-lease') {
        Write-Log "ALLOW: --force-with-lease is safe"
    } elseif (-not (Test-Allowed 'push --force')) {
        Block-Tool "git-safe: Force push can rewrite remote history and lose commits for other collaborators. Suggestion: Use --force-with-lease instead, or add 'allow: push --force' to .git-safe."
    }
}
if ($command -match 'git\s+push\s+(-[a-zA-Z]*f\b|.*\s-[a-zA-Z]*f\b)') {
    if ($command -notmatch '--force') {
        if (-not (Test-Allowed 'push --force')) {
            Block-Tool "git-safe: Force push (-f) can rewrite remote history and lose commits. Suggestion: Use --force-with-lease instead, or add 'allow: push --force' to .git-safe."
        }
    }
}

# Force push to main/master (extra protection - blocked even with allowlist)
# But --force-with-lease is safe and should be allowed
if ($command -cmatch 'git\s+push\s.*--force.*\s(main|master)(\s|$)') {
    if ($command -notmatch '--force-with-lease') {
        Block-Tool "git-safe: Force push to main/master is extremely dangerous. Suggestion: This is blocked even with 'allow: push --force'. Never force push to main."
    }
}
if ($command -cmatch 'git\s+push\s.*\s(main|master)\s.*--force') {
    if ($command -notmatch '--force-with-lease') {
        Block-Tool "git-safe: Force push to main/master is extremely dangerous. Suggestion: This is blocked even with 'allow: push --force'. Never force push to main."
    }
}

# git reset --hard
if ($command -match 'git\s+reset\s.*--hard') {
    if (-not (Test-Allowed 'reset --hard')) {
        Block-Tool "git-safe: git reset --hard discards all uncommitted changes permanently. Suggestion: Commit or stash changes first, or add 'allow: reset --hard' to .git-safe."
    }
}

# git checkout . (discards working tree changes)
if ($command -match 'git\s+checkout\s+\.\s*$') {
    if (-not (Test-Allowed 'checkout .')) {
        Block-Tool "git-safe: git checkout . discards all uncommitted changes in the working tree. Suggestion: Commit or stash changes first, or add 'allow: checkout .' to .git-safe."
    }
}

# git checkout -- (discards changes to files)
if ($command -match 'git\s+checkout\s+--\s') {
    if (-not (Test-Allowed 'checkout --')) {
        Block-Tool "git-safe: git checkout -- discards uncommitted changes to specified files. Suggestion: Commit or stash first, or add 'allow: checkout --' to .git-safe."
    }
}

# git checkout <ref> -- <path> (overwrites files from ref)
if ($command -match 'git\s+checkout\s+[^-][^ ]*\s+--\s') {
    if (-not (Test-Allowed 'checkout ref --')) {
        Block-Tool "git-safe: git checkout <ref> -- <path> overwrites working tree files with the version from that ref, discarding local changes. Suggestion: Commit or stash changes first, or add 'allow: checkout ref --' to .git-safe."
    }
}

# git restore (various destructive forms)
if ($command -match 'git\s+restore\s') {
    if ($command -match '(--source|-s\s)') {
        if (-not (Test-Allowed 'restore --source')) {
            Block-Tool "git-safe: git restore --source overwrites files from a specific ref, discarding local changes. Suggestion: Commit or stash first, or add 'allow: restore --source' to .git-safe."
        }
    } elseif ($command -match '(--worktree|-W\b)') {
        if (-not (Test-Allowed 'restore')) {
            Block-Tool "git-safe: git restore --worktree discards uncommitted working tree changes. Suggestion: Commit or stash first, or add 'allow: restore' to .git-safe."
        }
    } elseif ($command -notmatch '--staged') {
        if (-not (Test-Allowed 'restore')) {
            Block-Tool "git-safe: git restore without --staged discards uncommitted working tree changes. Suggestion: Use git restore --staged to unstage only, or commit/stash first. Add 'allow: restore' to .git-safe."
        }
    }
}

# git clean -f (deletes untracked files)
if ($command -match 'git\s+clean\s.*-[a-zA-Z]*f') {
    if (-not (Test-Allowed 'clean -f')) {
        Block-Tool "git-safe: git clean -f permanently deletes untracked files. Suggestion: Use git clean -n (dry run) first, or add 'allow: clean -f' to .git-safe."
    }
}

# git branch -D (force-delete unmerged branch) — case-sensitive: -D not -d
if ($command -cmatch 'git\s+branch\s.*-[a-zA-Z]*D') {
    if (-not (Test-Allowed 'branch -D')) {
        Block-Tool "git-safe: git branch -D force-deletes a branch even if not fully merged. Suggestion: Use -d (lowercase) which only deletes merged branches, or add 'allow: branch -D' to .git-safe."
    }
}

# git stash drop / clear
if ($command -match 'git\s+stash\s+drop') {
    if (-not (Test-Allowed 'stash drop')) {
        Block-Tool "git-safe: git stash drop permanently deletes stashed changes. Suggestion: Add 'allow: stash drop' to .git-safe to permit this."
    }
}
if ($command -match 'git\s+stash\s+clear') {
    if (-not (Test-Allowed 'stash clear')) {
        Block-Tool "git-safe: git stash clear permanently deletes all stashed changes. Suggestion: Add 'allow: stash clear' to .git-safe to permit this."
    }
}

# git reflog expire / delete
if ($command -match 'git\s+reflog\s+(expire|delete)') {
    if (-not (Test-Allowed 'reflog expire')) {
        Block-Tool "git-safe: git reflog expire/delete destroys recovery data. Suggestion: This is almost never needed. Add 'allow: reflog expire' to .git-safe if you really need it."
    }
}

# git push --delete (removes remote branches/tags)
if ($command -match 'git\s+push\s.*--delete\s') {
    if (-not (Test-Allowed 'push --delete')) {
        Block-Tool "git-safe: git push --delete permanently removes remote branches or tags. Suggestion: Use 'git branch -d' for local cleanup instead, or add 'allow: push --delete' to .git-safe."
    }
}
# git push origin :branch (alternate delete syntax)
if ($command -match 'git\s+push\s+\S+\s+:[^/\s]') {
    if (-not (Test-Allowed 'push --delete')) {
        Block-Tool "git-safe: git push origin :branch permanently removes a remote branch. Suggestion: Use 'git branch -d' for local cleanup instead, or add 'allow: push --delete' to .git-safe."
    }
}

Write-Log "ALLOW: $command"
exit 0
