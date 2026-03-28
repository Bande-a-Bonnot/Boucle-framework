# branch-guard: PreToolUse hook for Claude Code (PowerShell)
# Windows-native equivalent of hook.sh — no external dependencies needed.
#
# Prevents commits directly to protected branches (main, master, etc.).
# Forces feature-branch workflow.
#
# Protected branches (default): main, master, production, release
#
# Install:
#   1. Copy hook.ps1 to your project
#   2. Add to .claude/settings.json:
#      "hooks": { "PreToolUse": [{ "type": "command", "command": "pwsh -File /path/to/hook.ps1" }] }
#
# Config (.branch-guard):
#   protect: main
#   protect: master
#   protect: staging
#   allow-merge: true     # allow merge commits on protected branches
#
# Env vars:
#   BRANCH_GUARD_DISABLED=1       Disable the hook entirely
#   BRANCH_GUARD_PROTECTED=main,master   Override protected branch list
#   BRANCH_GUARD_LOG=1            Log all checks to stderr

$ErrorActionPreference = 'Stop'

if ($env:BRANCH_GUARD_DISABLED -eq '1') { exit 0 }

# Helper: write log to stderr
function Write-Log {
    param([string]$Message)
    if ($env:BRANCH_GUARD_LOG -eq '1') {
        [Console]::Error.WriteLine("[branch-guard] $Message")
    }
}

# Helper: output a block decision as JSON
function Block-Tool {
    param([string]$Reason)
    $result = @{ decision = 'block'; reason = $Reason } | ConvertTo-Json -Compress
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

# Only check git commit commands
if ($command -notmatch 'git\s+commit') {
    Write-Log "SKIP: not a git commit"
    exit 0
}

# Skip --amend (amending existing commits is OK on any branch)
if ($command -match '--amend') {
    Write-Log "SKIP: amend (not a new commit)"
    exit 0
}

# Build protected branches list
$protected = @()

if ($env:BRANCH_GUARD_PROTECTED) {
    $protected = $env:BRANCH_GUARD_PROTECTED -split ','
    Write-Log "Protected branches from env: $($protected -join ', ')"
} else {
    $configPath = if ($env:BRANCH_GUARD_CONFIG) { $env:BRANCH_GUARD_CONFIG } else { '.branch-guard' }
    if (Test-Path $configPath) {
        foreach ($rawLine in Get-Content $configPath) {
            $line = ($rawLine -replace '#.*$', '').Trim()
            if (-not $line) { continue }
            if ($line -match '^protect:\s*(.+)$') {
                $protected += $Matches[1].Trim()
            }
        }
        Write-Log "Protected branches from config: $($protected -join ', ')"
    }

    # Defaults if nothing configured
    if ($protected.Count -eq 0) {
        $protected = @('main', 'master', 'production', 'release')
        Write-Log "Protected branches (defaults): $($protected -join ', ')"
    }
}

# Get current branch
try {
    $currentBranch = git rev-parse --abbrev-ref HEAD 2>$null
} catch {
    $currentBranch = ''
}
if (-not $currentBranch) {
    Write-Log "SKIP: not in a git repo or detached HEAD"
    exit 0
}

Write-Log "Current branch: $currentBranch"

# Check if current branch is protected
foreach ($p in $protected) {
    if ($currentBranch -eq $p) {
        Block-Tool "branch-guard: Direct commit to '$currentBranch' is not allowed. Protected branches require feature-branch workflow. Suggestion: Create a feature branch first: git checkout -b feature/your-change"
    }
}

Write-Log "ALLOW: branch '$currentBranch' is not protected"
exit 0
