# worktree-guard: PreToolUse hook for Claude Code (PowerShell)
# Windows-native equivalent of hook.sh — no external dependencies needed.
#
# Prevents worktree exit when there are uncommitted changes or unmerged commits.
# Without this, worktree cleanup silently deletes branches with all their commits.
#
# Addresses: https://github.com/anthropics/claude-code/issues/38287
#
# What it checks:
#   - Uncommitted changes (staged or unstaged)
#   - Untracked files (new files not yet added)
#   - Commits on current branch not merged into base (main/master)
#   - Commits not pushed to remote (if upstream is set)
#
# Install:
#   1. Copy hook.ps1 to your project
#   2. Add to .claude/settings.json:
#      "hooks": { "PreToolUse": [{ "type": "command", "command": "pwsh -File /path/to/hook.ps1" }] }
#
# Config (.worktree-guard):
#   allow: uncommitted     # skip uncommitted changes check
#   allow: untracked       # skip untracked files check
#   allow: unmerged        # skip unmerged commits check
#   allow: unpushed        # skip unpushed commits check
#   base: develop          # override base branch detection
#
# Env vars:
#   WORKTREE_GUARD_DISABLED=1    Disable the hook entirely
#   WORKTREE_GUARD_LOG=1         Log all checks to stderr

$ErrorActionPreference = 'Stop'

if ($env:WORKTREE_GUARD_DISABLED -eq '1') { exit 0 }

# Helper: write log to stderr
function Write-Log {
    param([string]$Message)
    if ($env:WORKTREE_GUARD_LOG -eq '1') {
        [Console]::Error.WriteLine("[worktree-guard] $Message")
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

# Only check ExitWorktree
if ($toolName -ne 'ExitWorktree') { exit 0 }

# Load config from .worktree-guard
$allowed = @()
$baseOverride = ''

foreach ($cfgPath in @('.worktree-guard', (Join-Path $env:USERPROFILE '.worktree-guard'), (Join-Path $HOME '.worktree-guard'))) {
    if (Test-Path $cfgPath) {
        foreach ($rawLine in Get-Content $cfgPath) {
            $line = ($rawLine -replace '#.*$', '').Trim()
            if (-not $line) { continue }
            if ($line -match '^allow:\s*(.+)$') {
                $allowed += $Matches[1].Trim()
            }
            elseif ($line -match '^base:\s*(.+)$') {
                $baseOverride = $Matches[1].Trim()
            }
        }
        break  # use first config found
    }
}

function Test-Allowed {
    param([string]$Check)
    return ($allowed -contains $Check)
}

# Not inside a git repo? Nothing to check.
try {
    $inGit = git rev-parse --is-inside-work-tree 2>$null
} catch {
    $inGit = $null
}
if ($inGit -ne 'true') {
    Write-Log "SKIP: not in a git repo"
    exit 0
}

try {
    $currentBranch = git rev-parse --abbrev-ref HEAD 2>$null
} catch {
    $currentBranch = ''
}
Write-Log "Current branch: $currentBranch"

# Check 1: Uncommitted changes (staged or unstaged)
if (-not (Test-Allowed 'uncommitted')) {
    $dirty = @(git diff --name-only 2>$null) | Where-Object { $_ }
    $staged = @(git diff --cached --name-only 2>$null) | Where-Object { $_ }
    $changeCount = $dirty.Count + $staged.Count
    if ($changeCount -gt 0) {
        Block-Tool "Working tree has $changeCount uncommitted change(s). Commit or stash before exiting worktree, or add 'allow: uncommitted' to .worktree-guard."
    }
}

# Check 2: Untracked files
if (-not (Test-Allowed 'untracked')) {
    $untracked = @(git ls-files --others --exclude-standard 2>$null) | Where-Object { $_ }
    if ($untracked.Count -gt 0) {
        Block-Tool "$($untracked.Count) untracked file(s) will be lost on worktree exit. Add them with git add, or add 'allow: untracked' to .worktree-guard."
    }
}

# Detect base branch
$base = ''
if ($baseOverride) {
    $base = $baseOverride
} else {
    foreach ($candidate in @('origin/main', 'origin/master', 'main', 'master')) {
        try {
            git rev-parse --verify $candidate 2>$null | Out-Null
            $base = $candidate
            break
        } catch {}
    }
}

if (-not $base) {
    Write-Log "SKIP: no base branch found"
    exit 0
}

Write-Log "Base branch: $base"

# Check 3: Unmerged commits
# Two-tier detection to handle squash merges correctly:
#   Tier 1: git cherry for patch-level equivalence
#   Tier 2: per-file comparison for multi-commit squash merges
if (-not (Test-Allowed 'unmerged')) {
    if ($currentBranch -and $currentBranch -ne 'HEAD') {
        # Tier 1: git cherry compares individual patches
        $cherryOutput = @(git cherry $base $currentBranch 2>$null) | Where-Object { $_ -match '^\+' }

        if ($cherryOutput.Count -gt 0) {
            # Tier 2: fallback for multi-commit squash merges
            try {
                $mergeBase = git merge-base $base $currentBranch 2>$null
            } catch {
                $mergeBase = ''
            }

            if ($mergeBase) {
                $branchFiles = @(git diff --name-only $mergeBase $currentBranch 2>$null) | Where-Object { $_ }
                if ($branchFiles.Count -gt 0) {
                    $stillUnmerged = $false
                    foreach ($changedFile in $branchFiles) {
                        if (-not $changedFile) { continue }
                        # Compare file content between base and branch
                        $diffResult = git diff --quiet $base $currentBranch -- $changedFile 2>$null
                        if ($LASTEXITCODE -ne 0) {
                            $stillUnmerged = $true
                            break
                        }
                    }
                    if (-not $stillUnmerged) {
                        Write-Log "SKIP: all branch changes present on $base (squash merge)"
                        $cherryOutput = @()
                    }
                }
            }
        }

        if ($cherryOutput.Count -gt 0) {
            $firstSha = ($cherryOutput[0] -split '\s+')[1]
            try {
                $firstLog = git log --oneline -1 $firstSha 2>$null
            } catch {
                $firstLog = $firstSha
            }
            Block-Tool "$($cherryOutput.Count) unmerged commit(s) on $currentBranch will be lost. Latest: $firstLog. Merge or cherry-pick into $base before exiting, or add 'allow: unmerged' to .worktree-guard."
        }
    }
}

# Check 4: Unpushed commits (if upstream tracking branch exists)
if (-not (Test-Allowed 'unpushed')) {
    try {
        $upstream = git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>$null
    } catch {
        $upstream = ''
    }
    if ($upstream) {
        $unpushed = @(git log --oneline "$upstream..HEAD" 2>$null) | Where-Object { $_ }
        if ($unpushed.Count -gt 0) {
            Block-Tool "$($unpushed.Count) unpushed commit(s) on $currentBranch. Push before exiting worktree, or add 'allow: unpushed' to .worktree-guard."
        }
    }
}

Write-Log "ALLOW: all checks passed"
exit 0
