# read-once CLI (PowerShell) -- view stats, manage cache, install hook
#
# Usage:
#   pwsh read-once.ps1 stats         Show token savings for current/recent sessions
#   pwsh read-once.ps1 gain          Same as stats (RTK-style)
#   pwsh read-once.ps1 status        Quick health check
#   pwsh read-once.ps1 verify        Full diagnostic with dry-run test
#   pwsh read-once.ps1 clear         Clear session cache (start fresh)
#   pwsh read-once.ps1 install       Install hook to ~/.claude/read-once/hook.ps1
#   pwsh read-once.ps1 upgrade       Update installed hook to latest version
#   pwsh read-once.ps1 uninstall     Remove hook from .claude/settings.json
#   pwsh read-once.ps1 help          Show this help

param(
    [Parameter(Position=0)]
    [string]$Command = 'help'
)

$ErrorActionPreference = 'Stop'

$CacheDir = Join-Path $HOME '.claude' 'read-once'
$StatsFile = Join-Path $CacheDir 'stats.jsonl'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HookSource = Join-Path $ScriptDir 'hook.ps1'
$SettingsFile = Join-Path $HOME '.claude' 'settings.json'
$InstalledHook = Join-Path $CacheDir 'hook.ps1'

function Show-Stats {
    if (-not (Test-Path $StatsFile)) {
        Write-Host "No read-once data yet. Stats appear after your first Claude Code session with the hook installed."
        return
    }

    $lines = Get-Content $StatsFile -ErrorAction SilentlyContinue
    if (-not $lines -or $lines.Count -eq 0) {
        Write-Host "No reads tracked yet."
        return
    }

    $totalHits = 0
    $totalDiffs = 0
    $totalMisses = 0
    $totalChanged = 0
    $totalExpired = 0
    $tokensSaved = 0
    $tokensAllowed = 0
    $sessions = @{}
    $hitFiles = @{}

    foreach ($line in $lines) {
        try {
            $entry = $line | ConvertFrom-Json
            $ev = $entry.event

            switch ($ev) {
                'hit' {
                    $totalHits++
                    $tokensSaved += [int]($entry.tokens_saved)
                    if ($entry.path) {
                        $base = Split-Path $entry.path -Leaf
                        if ($hitFiles.ContainsKey($base)) { $hitFiles[$base]++ } else { $hitFiles[$base] = 1 }
                    }
                }
                'diff' {
                    $totalDiffs++
                    $tokensSaved += [int]($entry.tokens_saved)
                }
                'miss' {
                    $totalMisses++
                    $tokensAllowed += [int]($entry.tokens)
                }
                'changed' {
                    $totalChanged++
                    $tokensAllowed += [int]($entry.tokens)
                }
                'expired' {
                    $totalExpired++
                    $tokensAllowed += [int]($entry.tokens)
                }
            }

            if ($entry.session) { $sessions[$entry.session] = $true }
        } catch {}
    }

    $totalReads = $totalHits + $totalDiffs + $totalMisses + $totalChanged + $totalExpired
    $tokensTotal = $tokensAllowed + $tokensSaved

    if ($totalReads -eq 0) {
        Write-Host "No reads tracked yet."
        return
    }

    $savingsPct = if ($tokensTotal -gt 0) { [int]($tokensSaved * 100 / $tokensTotal) } else { 0 }

    $ttl = if ($env:READ_ONCE_TTL) { [int]$env:READ_ONCE_TTL } else { 1200 }
    $ttlMin = [int]($ttl / 60)

    Write-Host "read-once - file read deduplication for Claude Code"
    Write-Host ""
    Write-Host "  Total file reads:    $totalReads"
    Write-Host "  Cache hits:          $totalHits (blocked re-reads)"
    if ($totalDiffs -gt 0) {
        Write-Host "  Diff hits:           $totalDiffs (changed files - sent diff only)"
    }
    Write-Host "  First reads:         $totalMisses"
    Write-Host "  Changed files:       $totalChanged (full re-read after modification)"
    Write-Host "  TTL expired:         $totalExpired (re-read after ${ttlMin}m - compaction safety)"
    Write-Host ""
    Write-Host "  Tokens saved:        ~$tokensSaved"
    Write-Host "  Read token total:    ~$tokensTotal"
    Write-Host "  Savings:             ${savingsPct}%"

    # Cost estimates
    if ($tokensSaved -gt 0) {
        $costSonnet = [math]::Round($tokensSaved * 3 / 1000000, 4)
        $costOpus = [math]::Round($tokensSaved * 15 / 1000000, 4)
        Write-Host "  Est. cost saved:     `$$costSonnet (Sonnet) / `$$costOpus (Opus)"
    }
    Write-Host ""

    if ($totalHits -gt 0 -and $hitFiles.Count -gt 0) {
        Write-Host "  Top re-read files:"
        $hitFiles.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5 | ForEach-Object {
            Write-Host "    $($_.Value)x  $($_.Key)"
        }
        Write-Host ""
    }

    Write-Host "  Sessions tracked:    $($sessions.Count)"
    Write-Host "  Cache TTL:           $ttlMin minutes (READ_ONCE_TTL=${ttl}s)"
}

function Show-Status {
    Write-Host "read-once status"
    Write-Host ""

    # Check hook file
    if (Test-Path $InstalledHook) {
        Write-Host "  Hook file:     $InstalledHook (exists)"
    } else {
        Write-Host "  Hook file:     NOT INSTALLED - run: pwsh read-once.ps1 install"
    }

    # Check settings.json
    if ((Test-Path $SettingsFile) -and (Select-String -Path $SettingsFile -Pattern 'read-once' -Quiet)) {
        Write-Host "  Settings:      Configured in ~/.claude/settings.json"
    } else {
        Write-Host "  Settings:      NOT configured - run: pwsh read-once.ps1 install"
    }

    # Check stats
    if (Test-Path $StatsFile) {
        $total = (Get-Content $StatsFile).Count
        $hits = (Select-String -Path $StatsFile -Pattern '"event":"hit"' | Measure-Object).Count
        Write-Host "  Data:          $total events, $hits hits"
    } else {
        Write-Host "  Data:          No data yet"
    }

    $ttl = if ($env:READ_ONCE_TTL) { $env:READ_ONCE_TTL } else { '1200' }
    Write-Host "  TTL:           ${ttl}s ($([int]([int]$ttl/60))m)"
    Write-Host "  Disabled:      $(if ($env:READ_ONCE_DISABLED) { $env:READ_ONCE_DISABLED } else { '0' })"
}

function Install-Hook {
    if (-not (Test-Path (Split-Path $SettingsFile))) {
        New-Item -ItemType Directory -Path (Split-Path $SettingsFile) -Force | Out-Null
    }
    if (-not (Test-Path $SettingsFile)) {
        Write-Host "No .claude/settings.json found. Creating one."
        '{}' | Set-Content $SettingsFile
    }

    # Check if hook already installed
    if ((Select-String -Path $SettingsFile -Pattern 'read-once' -Quiet)) {
        Write-Host "read-once hook is already installed."
        return
    }

    # Copy hook to stable path
    if (-not (Test-Path $CacheDir)) {
        New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    }

    if (-not (Test-Path $HookSource)) {
        Write-Host "Error: hook.ps1 not found at $HookSource"
        exit 1
    }

    Copy-Item $HookSource $InstalledHook -Force

    # Update settings.json
    $settings = Get-Content $SettingsFile -Raw | ConvertFrom-Json

    if (-not $settings.hooks) {
        $settings | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([PSCustomObject]@{})
    }
    if (-not $settings.hooks.PreToolUse) {
        $settings.hooks | Add-Member -NotePropertyName 'PreToolUse' -NotePropertyValue @()
    }

    $hookEntry = [PSCustomObject]@{
        matcher = 'Read'
        hooks = @(
            [PSCustomObject]@{
                type = 'command'
                command = "pwsh -File ~/.claude/read-once/hook.ps1"
            }
        )
    }

    $settings.hooks.PreToolUse += $hookEntry
    $settings | ConvertTo-Json -Depth 10 | Set-Content $SettingsFile

    Write-Host "read-once hook installed."
    Write-Host "Hook: $InstalledHook"
    Write-Host ""
    Write-Host "Your Claude Code sessions will now track and deduplicate file reads."
    Write-Host "The hook is installed at a stable path - you can move or delete the source repo."
}

function Invoke-Upgrade {
    if (-not (Test-Path $InstalledHook)) {
        Write-Host "Hook not installed yet. Run: pwsh read-once.ps1 install"
        exit 1
    }
    if (-not (Test-Path $HookSource)) {
        Write-Host "Error: source hook.ps1 not found at $HookSource"
        exit 1
    }
    Copy-Item $HookSource $InstalledHook -Force
    Write-Host "Hook upgraded to latest version."
}

function Invoke-Uninstall {
    if (-not (Test-Path $SettingsFile)) {
        Write-Host "No settings file found."
        return
    }

    $settings = Get-Content $SettingsFile -Raw | ConvertFrom-Json

    if ($settings.hooks -and $settings.hooks.PreToolUse) {
        $filtered = @($settings.hooks.PreToolUse | Where-Object {
            $cmd = $_.hooks[0].command
            -not ($cmd -and $cmd -match 'read-once')
        })
        $settings.hooks.PreToolUse = $filtered
    }

    $settings | ConvertTo-Json -Depth 10 | Set-Content $SettingsFile
    Write-Host "read-once hook removed from settings."
}

function Clear-Cache {
    $removed = 0
    Get-ChildItem -Path $CacheDir -Filter 'session-*.jsonl' -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item $_.FullName -Force
        $removed++
    }
    Write-Host "Session cache cleared ($removed files). Stats preserved."
    Write-Host "To clear stats too: Remove-Item $StatsFile"
}

function Invoke-Verify {
    $issues = 0
    $checks = 0
    $passed = 0

    function Check-Pass { param([string]$Msg)
        $script:checks++; $script:passed++
        Write-Host "  [ok]   $Msg"
    }
    function Check-Fail { param([string]$Msg, [string]$Fix)
        $script:checks++; $script:issues++
        Write-Host "  [FAIL] $Msg"
        if ($Fix) { Write-Host "         Fix: $Fix" }
    }
    function Check-Warn { param([string]$Msg)
        $script:checks++
        Write-Host "  [warn] $Msg"
    }

    Write-Host "read-once verify"
    Write-Host ""

    # --- Dependencies ---
    Write-Host "Dependencies:"

    $psVer = $PSVersionTable.PSVersion
    if ($psVer.Major -ge 7) {
        Check-Pass "PowerShell $psVer (7+ required)"
    } else {
        Check-Fail "PowerShell $psVer (7+ required)" "winget install Microsoft.PowerShell"
    }

    Check-Pass "ConvertFrom-Json available (built-in)"

    Write-Host ""

    # --- Installation ---
    Write-Host "Installation:"

    if (Test-Path $InstalledHook) {
        Check-Pass "Hook file exists at $InstalledHook"
        # Check if installed hook matches source
        if ((Test-Path $HookSource) -and ($HookSource -ne $InstalledHook)) {
            $srcHash = (Get-FileHash $HookSource -Algorithm SHA256).Hash
            $instHash = (Get-FileHash $InstalledHook -Algorithm SHA256).Hash
            if ($srcHash -eq $instHash) {
                Check-Pass "Installed hook matches source (up to date)"
            } else {
                Check-Warn "Installed hook differs from source (run: pwsh read-once.ps1 upgrade)"
            }
        }
    } else {
        Check-Fail "Hook file not found at $InstalledHook" "pwsh read-once.ps1 install"
    }

    if (Test-Path $SettingsFile) {
        Check-Pass "~/.claude/settings.json exists"
        try {
            $settings = Get-Content $SettingsFile -Raw | ConvertFrom-Json
            Check-Pass "settings.json is valid JSON"

            $readHooks = @($settings.hooks.PreToolUse | Where-Object { $_.matcher -eq 'Read' })
            if ($readHooks.Count -gt 0) {
                Check-Pass "PreToolUse Read matcher configured"
                $hookCmd = $readHooks[0].hooks[0].command
                if ($hookCmd) {
                    $expanded = $hookCmd -replace '^~', $HOME
                    # Extract the file path from "pwsh -File <path>" or just "<path>"
                    if ($expanded -match '-File\s+(.+)$') {
                        $hookPath = $Matches[1].Trim()
                    } else {
                        $hookPath = $expanded
                    }
                    $hookPath = $hookPath -replace '^~', $HOME
                    if (Test-Path $hookPath) {
                        Check-Pass "Hook command path resolves ($hookCmd)"
                    } else {
                        Check-Fail "Hook command path does not exist: $hookCmd" "pwsh read-once.ps1 install"
                    }
                }
            } else {
                Check-Fail "No PreToolUse Read matcher in settings.json" "pwsh read-once.ps1 install"
            }
        } catch {
            Check-Fail "settings.json is invalid JSON" "Check for syntax errors"
        }
    } else {
        Check-Fail "~/.claude/settings.json not found" "pwsh read-once.ps1 install"
    }

    Write-Host ""

    # --- Dry-run test ---
    Write-Host "Dry-run test:"

    $testHook = if (Test-Path $InstalledHook) { $InstalledHook } elseif (Test-Path $HookSource) { $HookSource } else { $null }

    if ($testHook) {
        $testTmp = Join-Path ([System.IO.Path]::GetTempPath()) "read-once-verify-$PID"
        New-Item -ItemType Directory -Path $testTmp -Force | Out-Null
        $testFile = Join-Path $testTmp 'verify-test-file.txt'
        'read-once verify test content' | Set-Content $testFile

        $testSession = "verify-$(Get-Date -UFormat %s)-$PID"
        $testInput = @{
            tool_name = 'Read'
            tool_input = @{ file_path = $testFile }
            session_id = $testSession
        } | ConvertTo-Json -Compress

        # First read
        try {
            $env:HOME_BACKUP = $env:HOME
            $env:HOME = $testTmp
            $firstOutput = $testInput | pwsh -File $testHook 2>$null
            $env:HOME = $env:HOME_BACKUP

            if (-not $firstOutput) {
                Check-Pass "First read: allowed (no output = pass-through)"
            } else {
                Check-Warn "First read: unexpected output (expected empty for first read)"
            }

            # Second read
            $env:HOME = $testTmp
            $secondOutput = $testInput | pwsh -File $testHook 2>$null
            $env:HOME = $env:HOME_BACKUP

            if ($secondOutput) {
                try {
                    $parsed = $secondOutput | ConvertFrom-Json
                    Check-Pass "Second read: produced valid JSON response"
                    if ($parsed.decision -or $parsed.hookSpecificOutput.permissionDecision) {
                        $mode = if ($parsed.decision) { 'deny' } else { 'warn' }
                        Check-Pass "Second read: correctly detected re-read (mode: $mode)"
                    } else {
                        Check-Warn "Second read: output format unexpected"
                    }
                } catch {
                    Check-Fail "Second read: output is not valid JSON" "Check hook.ps1 for output formatting issues"
                }
            } else {
                Check-Fail "Second read: no output (should have blocked or warned)" "Hook may not be caching reads correctly"
            }
        } catch {
            $env:HOME = $env:HOME_BACKUP
            Check-Fail "Dry-run failed: $_" "Check hook.ps1 for errors"
        }

        Remove-Item $testTmp -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Check-Warn "Skipping dry-run (no hook found)"
    }

    Write-Host ""

    # --- Configuration ---
    Write-Host "Configuration:"
    $mode = if ($env:READ_ONCE_MODE) { $env:READ_ONCE_MODE } else { 'warn' }
    $ttl = if ($env:READ_ONCE_TTL) { $env:READ_ONCE_TTL } else { '1200' }
    $diff = if ($env:READ_ONCE_DIFF) { $env:READ_ONCE_DIFF } else { '0' }
    $disabled = if ($env:READ_ONCE_DISABLED) { $env:READ_ONCE_DISABLED } else { '0' }
    Write-Host "  Mode:     $mode (READ_ONCE_MODE)"
    Write-Host "  TTL:      ${ttl}s ($([int]([int]$ttl/60))m) (READ_ONCE_TTL)"
    Write-Host "  Diff:     $diff (READ_ONCE_DIFF)"
    Write-Host "  Disabled: $disabled (READ_ONCE_DISABLED)"
    Write-Host ""

    # --- Summary ---
    if ($issues -eq 0) {
        Write-Host "$passed/$checks checks passed. read-once is ready."
    } else {
        Write-Host "$passed/$checks checks passed, $issues issue(s) found."
        Write-Host "Fix the issues above, then run 'pwsh read-once.ps1 verify' again."
        exit 1
    }
}

function Show-Help {
    Write-Host "read-once - Stop Claude Code from re-reading files it already has"
    Write-Host ""
    Write-Host "Usage:"
    Write-Host "  pwsh read-once.ps1 stats       Show token savings"
    Write-Host "  pwsh read-once.ps1 gain        Same as stats (RTK-style)"
    Write-Host "  pwsh read-once.ps1 status      Quick health check"
    Write-Host "  pwsh read-once.ps1 verify      Full diagnostic with dry-run test"
    Write-Host "  pwsh read-once.ps1 clear       Clear session cache"
    Write-Host "  pwsh read-once.ps1 install     Install hook to ~/.claude/"
    Write-Host "  pwsh read-once.ps1 upgrade     Update hook to latest version"
    Write-Host "  pwsh read-once.ps1 uninstall   Remove hook"
    Write-Host ""
    Write-Host "How it works:"
    Write-Host "  A PreToolUse hook intercepts Read calls. When Claude tries to"
    Write-Host "  re-read a file it already read this session (and the file hasn't"
    Write-Host "  changed), the hook blocks the read and tells Claude the content"
    Write-Host "  is already in context. Saves ~2000+ tokens per prevented re-read."
    Write-Host ""
    Write-Host "Compaction safety:"
    Write-Host "  Cache entries expire after READ_ONCE_TTL seconds (default: 1200 = 20m)."
    Write-Host "  After expiry, re-reads are allowed because Claude may have compacted"
    Write-Host "  the context window and lost the earlier content."
    Write-Host ""
    Write-Host "Config (environment variables):"
    Write-Host "  READ_ONCE_MODE=warn     'warn' (default) allows read with advisory."
    Write-Host "                          'deny' blocks reads entirely (maximum savings)."
    Write-Host "  READ_ONCE_TTL=1200      Cache TTL in seconds (default: 1200)"
    Write-Host "  READ_ONCE_DISABLED=1    Disable the hook entirely"
}

# Dispatch
switch ($Command.ToLower()) {
    { $_ -in 'stats', 'gain' } { Show-Stats }
    'status'                    { Show-Status }
    'install'                   { Install-Hook }
    'upgrade'                   { Invoke-Upgrade }
    'uninstall'                 { Invoke-Uninstall }
    'clear'                     { Clear-Cache }
    { $_ -in 'verify', 'check', 'test' } { Invoke-Verify }
    { $_ -in 'help', '--help', '-h' }    { Show-Help }
    default {
        Write-Host "Unknown command: $Command"
        Write-Host "Run 'pwsh read-once.ps1 help' for usage."
        exit 1
    }
}
