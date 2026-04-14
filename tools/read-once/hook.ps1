# read-once: PreToolUse hook for Claude Code Read tool (PowerShell)
# Windows-native equivalent of hook.sh — no external dependencies needed.
#
# Prevents redundant file reads within a session by tracking what's been read.
# When a file is re-read and hasn't changed (same mtime), blocks the read
# and tells Claude the content is already in context.
#
# Diff mode: When a file HAS changed since the last read, instead of allowing
# a full re-read, shows only what changed (the diff). Saves 80-95% of tokens.
# Enable with READ_ONCE_DIFF=1.
#
# Compaction-aware: cache entries expire after READ_ONCE_TTL seconds
# (default 1200 = 20 minutes). After expiry, re-reads are allowed because
# Claude may have compacted the context and lost the earlier content.
#
# Install:
#   1. Copy hook.ps1 to your project
#   2. Add to .claude/settings.json:
#      "hooks": { "PreToolUse": [{ "type": "command", "command": "pwsh -File /path/to/hook.ps1" }] }
#
# Config (env vars):
#   READ_ONCE_MODE=warn     "warn" (default) allows read with advisory, "deny" blocks it.
#   READ_ONCE_TTL=1200      Seconds before a cached read expires (default: 1200)
#   READ_ONCE_DIFF=1        Show only diff when files change (default: 0)
#   READ_ONCE_DIFF_MAX=40   Max diff lines before falling back to full re-read (default: 40)
#   READ_ONCE_DISABLED=1    Disable the hook entirely

$ErrorActionPreference = 'Stop'

if ($env:READ_ONCE_DISABLED -eq '1') { exit 0 }

# Read hook input from stdin
$rawInput = [Console]::In.ReadToEnd()
$hookInput = $rawInput | ConvertFrom-Json

$toolName = $hookInput.tool_name

# Only handle Read tool
if ($toolName -ne 'Read') { exit 0 }

$filePath = $hookInput.tool_input.file_path
$sessionId = $hookInput.session_id
$offset = $hookInput.tool_input.offset
$limit = $hookInput.tool_input.limit

if (-not $filePath -or -not $sessionId) { exit 0 }

# Partial reads (offset/limit) are never cached
if ($offset -or $limit) { exit 0 }

# Session-scoped cache directory
$cacheDir = Join-Path $HOME '.claude' 'read-once'
if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }

# Config
$mode = if ($env:READ_ONCE_MODE) { $env:READ_ONCE_MODE } else { 'warn' }
$ttl = if ($env:READ_ONCE_TTL) { [int]$env:READ_ONCE_TTL } else { 1200 }
$diffMode = ($env:READ_ONCE_DIFF -eq '1')
$diffMax = if ($env:READ_ONCE_DIFF_MAX) { [int]$env:READ_ONCE_DIFF_MAX } else { 40 }

if ($diffMode) {
    $snapDir = Join-Path $cacheDir 'snapshots'
    if (-not (Test-Path $snapDir)) { New-Item -ItemType Directory -Path $snapDir -Force | Out-Null }
}

$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

# Helper: compute SHA256 hash of a string (first 16 hex chars)
function Get-ShortHash {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hash = $sha.ComputeHash($bytes)
    $hex = ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
    return $hex.Substring(0, 16)
}

# Auto-cleanup: remove session caches older than 24h (runs at most once per hour)
$cleanupMarker = Join-Path $cacheDir '.last-cleanup'
$lastCleanup = 0
if (Test-Path $cleanupMarker) {
    $content = (Get-Content $cleanupMarker -ErrorAction SilentlyContinue).Trim()
    if ($content -match '^\d+$') { $lastCleanup = [long]$content }
}
if (($now - $lastCleanup) -gt 3600) {
    Get-ChildItem -Path $cacheDir -Filter 'session-*.jsonl' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -lt (Get-Date).AddDays(-1).ToUniversalTime() } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    if ($diffMode -and (Test-Path $snapDir)) {
        Get-ChildItem -Path $snapDir -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTimeUtc -lt (Get-Date).AddDays(-1).ToUniversalTime() } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    Set-Content -Path $cleanupMarker -Value $now
}

$sessionHash = Get-ShortHash $sessionId
$cacheFile = Join-Path $cacheDir "session-${sessionHash}.jsonl"
$statsFile = Join-Path $cacheDir 'stats.jsonl'

if ($diffMode) {
    $pathHash = Get-ShortHash $filePath
    $snapFile = Join-Path $snapDir "${sessionHash}-${pathHash}"
}

# Check file exists
if (-not (Test-Path $filePath -PathType Leaf)) { exit 0 }

# Get current mtime as Unix epoch
$fileInfo = Get-Item $filePath
$currentMtime = [string][DateTimeOffset]::new($fileInfo.LastWriteTimeUtc).ToUnixTimeSeconds()

# File size for token estimation (~4 chars per token, line numbers add ~70%)
$fileSize = $fileInfo.Length
$estimatedTokens = [int](($fileSize / 4) * 1.7)

# Check cache for previous read of this file
$cachedMtime = ''
$cachedTs = ''
if (Test-Path $cacheFile) {
    $lines = Get-Content $cacheFile -ErrorAction SilentlyContinue
    foreach ($line in $lines) {
        try {
            $entry = $line | ConvertFrom-Json
            if ($entry.path -eq $filePath) {
                $cachedMtime = [string]$entry.mtime
                $cachedTs = [string]$entry.ts
            }
        } catch {}
    }
}

if ($cachedMtime -and $cachedMtime -eq $currentMtime) {
    # File hasn't changed since last read. Check TTL.
    $entryAge = 0
    if ($cachedTs -match '^\d+$') {
        $entryAge = $now - [long]$cachedTs
    }

    if ($entryAge -ge $ttl) {
        # Cache expired -- allow re-read
        $record = @{ path = $filePath; mtime = $currentMtime; ts = $now; tokens = $estimatedTokens } | ConvertTo-Json -Compress
        Add-Content -Path $cacheFile -Value $record
        $stat = @{ ts = $now; path = $filePath; tokens = $estimatedTokens; session = $sessionHash; event = 'expired' } | ConvertTo-Json -Compress
        Add-Content -Path $statsFile -Value $stat
        if ($diffMode) { Copy-Item $filePath $snapFile -Force }
        exit 0
    }

    # Cache hit -- file unchanged and within TTL
    $minutesAgo = [int]($entryAge / 60)
    $stat = @{ ts = $now; path = $filePath; tokens_saved = $estimatedTokens; session = $sessionHash; event = 'hit' } | ConvertTo-Json -Compress
    Add-Content -Path $statsFile -Value $stat

    # Calculate cumulative session savings
    $sessionSaved = $estimatedTokens
    if (Test-Path $statsFile) {
        $total = 0
        foreach ($sline in Get-Content $statsFile -ErrorAction SilentlyContinue) {
            if ($sline -match [regex]::Escape("`"session`":`"${sessionHash}`"") -and $sline -match '"event":"hit"') {
                try {
                    $sentry = $sline | ConvertFrom-Json
                    $total += [int]$sentry.tokens_saved
                } catch {}
            }
        }
        if ($total -gt 0) { $sessionSaved = $total }
    }

    $baseName = Split-Path $filePath -Leaf
    $ttlMin = [int]($ttl / 60)

    # Cost estimate (Sonnet $3/MTok)
    $costInfo = ''
    if ($sessionSaved -gt 0) {
        $cost = [math]::Round($sessionSaved * 3 / 1000000, 4)
        $costInfo = " (~`$$cost saved at Sonnet rates)"
    }

    $reason = "read-once: ${baseName} (~${estimatedTokens} tokens) already in context (read ${minutesAgo}m ago, unchanged). Re-read allowed after ${ttlMin}m. Session savings: ~${sessionSaved} tokens${costInfo}."

    if ($mode -eq 'deny') {
        $result = @{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress -Depth 3
        Write-Output $result
    } else {
        # Warn mode (default) -- allow with advisory
        $output = @{
            hookSpecificOutput = @{
                hookEventName = 'PreToolUse'
                permissionDecision = 'allow'
                permissionDecisionReason = $reason
            }
        } | ConvertTo-Json -Compress
        Write-Output $output
    }
    exit 0
}

# Cache miss or file changed
if ($cachedMtime -and $diffMode -and (Test-Path $snapFile -ErrorAction SilentlyContinue)) {
    # File changed + diff mode + we have a snapshot
    $oldLines = Get-Content $snapFile -ErrorAction SilentlyContinue
    $newLines = Get-Content $filePath -ErrorAction SilentlyContinue
    $diffs = Compare-Object $oldLines $newLines -IncludeEqual:$false
    $diffLineCount = ($diffs | Measure-Object).Count

    if ($diffLineCount -gt 0 -and $diffLineCount -le $diffMax) {
        # Build a simple diff output
        $diffLines = @()
        foreach ($d in $diffs) {
            if ($d.SideIndicator -eq '<=') {
                $diffLines += "- $($d.InputObject)"
            } elseif ($d.SideIndicator -eq '=>') {
                $diffLines += "+ $($d.InputObject)"
            }
        }
        $diffText = $diffLines -join "`n"
        $diffTokens = $diffLineCount * 10
        $tokensSaved = [math]::Max(0, $estimatedTokens - $diffTokens)

        # Update cache and snapshot
        $record = @{ path = $filePath; mtime = $currentMtime; ts = $now; tokens = $estimatedTokens } | ConvertTo-Json -Compress
        Add-Content -Path $cacheFile -Value $record
        Copy-Item $filePath $snapFile -Force
        $stat = @{ ts = $now; path = $filePath; tokens_saved = $tokensSaved; session = $sessionHash; event = 'diff' } | ConvertTo-Json -Compress
        Add-Content -Path $statsFile -Value $stat

        $baseName = Split-Path $filePath -Leaf
        $reason = "read-once: ${baseName} changed since last read. You already have the previous version in context. Here are only the changes (saving ~${tokensSaved} tokens):\n\n${diffText}\n\nApply this diff mentally to your cached version of the file."

        if ($mode -eq 'deny') {
            $result = @{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress -Depth 3
            Write-Output $result
        } else {
            $output = @{
                hookSpecificOutput = @{
                    hookEventName = 'PreToolUse'
                    permissionDecision = 'allow'
                    permissionDecisionReason = $reason
                }
            } | ConvertTo-Json -Compress
            Write-Output $output
        }
        exit 0
    }
    # Diff too large -- fall through to full re-read
}

# Record the read
$record = @{ path = $filePath; mtime = $currentMtime; ts = $now; tokens = $estimatedTokens } | ConvertTo-Json -Compress
Add-Content -Path $cacheFile -Value $record

# Save snapshot for future diffs
if ($diffMode) {
    Copy-Item $filePath $snapFile -Force
}

# Log the event
$eventType = if ($cachedMtime) { 'changed' } else { 'miss' }
$stat = @{ ts = $now; path = $filePath; tokens = $estimatedTokens; session = $sessionHash; event = $eventType } | ConvertTo-Json -Compress
Add-Content -Path $statsFile -Value $stat

# Allow the read
exit 0
