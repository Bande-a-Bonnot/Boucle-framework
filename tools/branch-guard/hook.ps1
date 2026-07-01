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
    $result = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $Reason } } | ConvertTo-Json -Compress -Depth 3
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

function Get-CommandSegments {
    param([string]$Command)

    $segments = @()
    $chars = $Command.ToCharArray()
    $out = New-Object System.Text.StringBuilder
    $inSingleQuote = $false
    $inDoubleQuote = $false
    $escaped = $false

    for ($i = 0; $i -lt $chars.Length; $i++) {
        $c = $chars[$i]
        $next = if ($i + 1 -lt $chars.Length) { $chars[$i + 1] } else { [char]0 }

        if ($escaped) {
            if ($inSingleQuote -or $inDoubleQuote) {
                [void]$out.Append(' ')
            } else {
                [void]$out.Append($c)
            }
            $escaped = $false
            continue
        }

        if ($c -eq '\' -and -not $inSingleQuote) {
            if ($inDoubleQuote) {
                [void]$out.Append(' ')
            } else {
                [void]$out.Append($c)
            }
            $escaped = $true
            continue
        }

        if ($c -eq "'" -and -not $inDoubleQuote) {
            $inSingleQuote = -not $inSingleQuote
            [void]$out.Append(' ')
            continue
        }

        if ($c -eq '"' -and -not $inSingleQuote) {
            $inDoubleQuote = -not $inDoubleQuote
            [void]$out.Append(' ')
            continue
        }

        if ($inSingleQuote -or $inDoubleQuote) {
            [void]$out.Append(' ')
            continue
        }

        if ($c -eq ';' -or $c -eq '|') {
            $segments += $out.ToString()
            [void]$out.Clear()
            if ($c -eq '|' -and $next -eq '|') {
                $i++
            }
            continue
        }

        if ($c -eq '&' -and $next -eq '&') {
            $segments += $out.ToString()
            [void]$out.Clear()
            $i++
            continue
        }

        [void]$out.Append($c)
    }

    $segments += $out.ToString()
    return $segments
}

function Test-GitBinaryToken {
    param([string]$Token)
    $name = [System.IO.Path]::GetFileName($Token)
    if ($name.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
        $name = $name.Substring(0, $name.Length - 4)
    }
    return $name -eq 'git'
}

function Test-AssignmentToken {
    param([string]$Token)
    return $Token -match '^[A-Za-z_][A-Za-z0-9_]*='
}

function Normalize-TargetDir {
    param([string]$TargetDir)
    $dir = $TargetDir.Trim()
    if ($dir.Length -ge 2) {
        $first = $dir.Substring(0, 1)
        $last = $dir.Substring($dir.Length - 1, 1)
        if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
            $dir = $dir.Substring(1, $dir.Length - 2)
        }
    }
    return $dir
}

function Get-LeadingCdTargetDir {
    param([string]$Command)
    if ($Command -match '^\s*cd\s+([^&;|]+)\s*&&') {
        return Normalize-TargetDir $Matches[1]
    }
    return '.'
}

function Test-NewGitCommitSegment {
    param([string]$Segment)

    $words = @($Segment -split '\s+' | Where-Object { $_ })
    if ($words.Count -eq 0) { return $false }

    $i = 0
    while ($i -lt $words.Count) {
        $token = $words[$i]
        if ($token -in @('env', 'command', 'exec') -or (Test-AssignmentToken $token)) {
            $i++
            continue
        }
        break
    }

    if ($i -ge $words.Count -or -not (Test-GitBinaryToken $words[$i])) { return $false }
    $i++
    $targetDir = $script:BranchGuardTargetDir

    while ($i -lt $words.Count) {
        $token = $words[$i]

        if ($token -eq '-C') {
            if ($i + 1 -lt $words.Count) {
                $targetDir = Normalize-TargetDir $words[$i + 1]
            }
            $i += 2
            continue
        }

        if ($token -match '^(-c|--git-dir|--work-tree|--namespace|--exec-path|--config-env)$') {
            $i += 2
            continue
        }

        if ($token -match '^(--git-dir=|--work-tree=|--namespace=|--exec-path=|--config-env=)') {
            $i++
            continue
        }

        if ($token -match '^--$') {
            $i++
            break
        }

        if ($token -match '^-') {
            $i++
            continue
        }

        break
    }

    if ($i -ge $words.Count -or $words[$i] -ne 'commit') { return $false }

    $remaining = @()
    if ($i + 1 -lt $words.Count) {
        $remaining = $words[($i + 1)..($words.Count - 1)]
    }
    if ($remaining -contains '--amend') { return $false }

    $script:BranchGuardTargetDir = $targetDir
    return $true
}

$hasNewCommit = $false
$script:BranchGuardTargetDir = Get-LeadingCdTargetDir $command
foreach ($segment in Get-CommandSegments $command) {
    if (Test-NewGitCommitSegment $segment) {
        $hasNewCommit = $true
        break
    }
}

# Only check actual git commit command segments.
if (-not $hasNewCommit) {
    Write-Log "SKIP: not a git commit"
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

Write-Log "Target directory: $script:BranchGuardTargetDir"

# Get current branch from the repository that the intercepted command targets.
try {
    $currentBranch = git -C $script:BranchGuardTargetDir rev-parse --abbrev-ref HEAD 2>$null
} catch {
    $currentBranch = ''
}
if (-not $currentBranch) {
    Write-Log "SKIP: target is not in a git repo or detached HEAD"
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
