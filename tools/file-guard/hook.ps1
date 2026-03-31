# file-guard: PreToolUse hook for Claude Code (PowerShell)
# Windows-native equivalent of hook.sh — no external dependencies needed.
#
# Protects specified files and directories from being accessed or modified.
#
# Two protection levels:
#   - Write protection (default): blocks Write, Edit, and modifying Bash commands
#   - Access denial ([deny] section): blocks Read, Grep, Glob, and all Bash access
#
# Install:
#   1. Copy hook.ps1 to your project
#   2. Create .file-guard in your project root (one path per line)
#   3. Add to .claude/settings.json:
#      "hooks": { "PreToolUse": [{ "type": "command", "command": "pwsh -File /path/to/hook.ps1" }] }
#
# Config file (.file-guard):
#   One path per line. Supports:
#   - Exact paths: .env, secrets/api-key.txt
#   - Directory prefixes (trailing /): config/, .ssh/
#   - Shell globs: *.pem, credentials.*
#   - Comments (#) and blank lines ignored
#   - [deny] section header: blocks ALL access (reads too)
#
# Env vars:
#   FILE_GUARD_CONFIG=path    Override config file location (default: .file-guard)
#   FILE_GUARD_DISABLED=1     Disable the hook entirely
#   FILE_GUARD_LOG=1          Log all checks to stderr (for debugging)

$ErrorActionPreference = 'Stop'

# Allow disabling via env var
if ($env:FILE_GUARD_DISABLED -eq '1') { exit 0 }

# Helper: write log to stderr
function Write-Log {
    param([string]$Message)
    if ($env:FILE_GUARD_LOG -eq '1') {
        [Console]::Error.WriteLine("[file-guard] $Message")
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
if (-not $toolName) { exit 0 }

# Reject relative paths in Write/Edit (always active, no config needed)
if ($toolName -eq 'Write' -or $toolName -eq 'Edit') {
    $filePath = $hookInput.tool_input.file_path
    if ($filePath -and -not ([System.IO.Path]::IsPathRooted($filePath))) {
        $absoluteHint = Join-Path (Get-Location) $filePath
        Block-Tool "file-guard: relative path `"$filePath`" rejected. Write/Edit require absolute paths to prevent writing to the wrong location. Try: $absoluteHint"
    }
}

# Find config file
$configPath = if ($env:FILE_GUARD_CONFIG) { $env:FILE_GUARD_CONFIG } else { '.file-guard' }
if (-not (Test-Path $configPath)) { exit 0 }

# Parse protected patterns from config (two sections)
$writePatterns = @()
$denyPatterns = @()
$currentSection = 'write'

foreach ($rawLine in Get-Content $configPath) {
    # Strip comments and whitespace
    $line = ($rawLine -replace '#.*$', '').Trim()
    if (-not $line) { continue }

    # Section headers
    if ($line -eq '[deny]') { $currentSection = 'deny'; continue }
    if ($line -eq '[write]' -or $line -eq '[protect]') { $currentSection = 'write'; continue }

    switch ($currentSection) {
        'write' { $writePatterns += $line }
        'deny'  { $denyPatterns += $line }
    }
}

# Nothing to protect
if ($writePatterns.Count -eq 0 -and $denyPatterns.Count -eq 0) { exit 0 }

# Determine which tools to intercept
switch ($toolName) {
    { $_ -in 'Write', 'Edit', 'Bash' } {
        # Always check (write protection + deny)
    }
    { $_ -in 'Read', 'Grep', 'Glob' } {
        if ($denyPatterns.Count -eq 0) { exit 0 }
    }
    default { exit 0 }
}

# Normalize a path: resolve ./ and .. components, make relative to project root
function Normalize-TargetPath {
    param([string]$p)
    # Strip leading ./
    if ($p.StartsWith('./')) { $p = $p.Substring(2) }
    if ($p.StartsWith('.\')) { $p = $p.Substring(2) }

    # Normalize separators to forward slash
    $p = $p -replace '\\', '/'

    # Make absolute path relative to project root
    $root = (Get-Location).Path -replace '\\', '/'
    if ($p.StartsWith('/') -or ($p.Length -ge 2 -and $p[1] -eq ':')) {
        # Absolute path: try to make relative
        if ($p.StartsWith("$root/")) {
            $p = $p.Substring($root.Length + 1)
        } elseif ($p -eq $root) {
            $p = '.'
        } else {
            return $p
        }
    }

    # Collapse .. segments
    if ($p -match '\.\.') {
        $parts = $p -split '/'
        $result = [System.Collections.Generic.List[string]]::new()
        foreach ($part in $parts) {
            if ($part -eq '..') {
                if ($result.Count -gt 0 -and $result[-1] -ne '..') {
                    $result.RemoveAt($result.Count - 1)
                } else {
                    $result.Add('..')
                }
            } elseif ($part -ne '.' -and $part -ne '') {
                $result.Add($part)
            }
        }
        $p = if ($result.Count -gt 0) { $result -join '/' } else { '.' }
    }

    return $p
}

# Check if a path matches any pattern in a list
# Returns the matched pattern string, or $null
function Test-PathMatch {
    param(
        [string]$Target,
        [string[]]$Patterns
    )

    $Target = Normalize-TargetPath $Target

    foreach ($rawPattern in $Patterns) {
        $pattern = $rawPattern -replace '^\./', ''
        $pattern = $pattern -replace '\\', '/'

        # Directory prefix match (pattern ends with /)
        if ($pattern.EndsWith('/')) {
            if ($Target.StartsWith($pattern) -or $Target -eq $pattern.TrimEnd('/')) {
                Write-Log "MATCH: '$Target' matches directory pattern '$pattern'"
                return $pattern
            }
            continue
        }

        # Exact match
        if ($Target -eq $pattern) {
            Write-Log "MATCH: '$Target' exact match '$pattern'"
            return $pattern
        }

        # Glob match on basename
        $basename = Split-Path $Target -Leaf
        if ($basename -like $pattern) {
            Write-Log "MATCH: '$Target' glob match '$pattern'"
            return $pattern
        }

        # Full path glob match
        if ($Target -like $pattern) {
            Write-Log "MATCH: '$Target' full path glob '$pattern'"
            return $pattern
        }
    }

    return $null
}

# Extract target path based on tool and check against patterns
switch ($toolName) {
    'Write' {
        $target = $hookInput.tool_input.file_path
        if (-not $target) { exit 0 }
        $target = Normalize-TargetPath $target

        if ($denyPatterns.Count -gt 0) {
            $matched = Test-PathMatch -Target $target -Patterns $denyPatterns
            if ($matched) {
                Block-Tool "file-guard: access to `"$target`" is denied (matches [deny] pattern `"$matched`"). Check .file-guard config."
            }
        }
        if ($writePatterns.Count -gt 0) {
            $matched = Test-PathMatch -Target $target -Patterns $writePatterns
            if ($matched) {
                Block-Tool "file-guard: `"$target`" is protected (matches pattern `"$matched`"). Check .file-guard config to modify protections."
            }
        }
    }

    'Edit' {
        $target = $hookInput.tool_input.file_path
        if (-not $target) { exit 0 }
        $target = Normalize-TargetPath $target

        if ($denyPatterns.Count -gt 0) {
            $matched = Test-PathMatch -Target $target -Patterns $denyPatterns
            if ($matched) {
                Block-Tool "file-guard: access to `"$target`" is denied (matches [deny] pattern `"$matched`"). Check .file-guard config."
            }
        }
        if ($writePatterns.Count -gt 0) {
            $matched = Test-PathMatch -Target $target -Patterns $writePatterns
            if ($matched) {
                Block-Tool "file-guard: `"$target`" is protected (matches pattern `"$matched`"). Check .file-guard config to modify protections."
            }
        }
    }

    'Read' {
        $target = $hookInput.tool_input.file_path
        if (-not $target) { exit 0 }
        $target = Normalize-TargetPath $target

        $matched = Test-PathMatch -Target $target -Patterns $denyPatterns
        if ($matched) {
            Block-Tool "file-guard: reading `"$target`" is denied (matches [deny] pattern `"$matched`"). Check .file-guard config."
        }
    }

    'Grep' {
        $target = $hookInput.tool_input.path
        if (-not $target) { exit 0 }
        $target = Normalize-TargetPath $target

        $matched = Test-PathMatch -Target $target -Patterns $denyPatterns
        if ($matched) {
            Block-Tool "file-guard: searching `"$target`" is denied (matches [deny] pattern `"$matched`"). Check .file-guard config."
        }
    }

    'Glob' {
        $target = $hookInput.tool_input.path
        if (-not $target) { exit 0 }
        $target = Normalize-TargetPath $target

        $matched = Test-PathMatch -Target $target -Patterns $denyPatterns
        if ($matched) {
            Block-Tool "file-guard: listing `"$target`" is denied (matches [deny] pattern `"$matched`"). Check .file-guard config."
        }
    }

    'Bash' {
        $command = $hookInput.tool_input.command
        if (-not $command) { exit 0 }

        # Check deny patterns: ANY reference blocks the command
        foreach ($rawPattern in $denyPatterns) {
            $pattern = $rawPattern -replace '^\./', ''

            if ($pattern.EndsWith('/')) {
                $dir = $pattern.TrimEnd('/')
                if ($command.Contains($dir)) {
                    Write-Log "BASH DENY: command references denied directory '$pattern'"
                    Block-Tool "file-guard: command references denied path `"$pattern`" (matches [deny] in .file-guard). Check .file-guard config."
                }
            } else {
                if ($command.Contains($pattern)) {
                    Write-Log "BASH DENY: command references denied file '$pattern'"
                    Block-Tool "file-guard: command references denied path `"$pattern`" (matches [deny] in .file-guard). Check .file-guard config."
                }
            }
        }

        # Check write-protect patterns: only modifying operations
        foreach ($rawPattern in $writePatterns) {
            $pattern = $rawPattern -replace '^\./', ''
            if ($pattern.EndsWith('/')) { continue }

            if ($command -match '(rm|mv|cp|chmod|chown|truncate|shred)\s|>\s*|>>') {
                if ($command.Contains($pattern)) {
                    Write-Log "BASH MATCH: command contains modifier + pattern '$pattern'"
                    Block-Tool "file-guard: command may modify protected path `"$pattern`" (matches .file-guard config). Use FILE_GUARD_DISABLED=1 to override."
                }
            }
        }
    }
}

# No match - allow
Write-Log "ALLOW: $toolName"
exit 0
