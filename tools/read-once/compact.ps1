# read-once: PostCompact hook — clears session cache after context compaction.
# Windows-native equivalent of compact.sh — no external dependencies needed.
#
# When Claude compacts the conversation, it loses file contents from context.
# This hook resets the read-once cache so those files can be re-read immediately,
# replacing the TTL-based workaround (which could be up to 20 minutes late).
#
# Install: Add to .claude/settings.json hooks.PostCompact
#   "PostCompact": [{ "type": "command", "command": "pwsh -File /path/to/compact.ps1" }]
#
# See also: hook.ps1 (the PreToolUse hook that tracks reads)

$ErrorActionPreference = 'Stop'

$rawInput = [Console]::In.ReadToEnd()
$hookInput = $rawInput | ConvertFrom-Json

$sessionId = $hookInput.session_id
if (-not $sessionId) { exit 0 }

$cacheDir = Join-Path $HOME '.claude' 'read-once'

# Must hash session_id the same way hook.ps1 does
$sha = [System.Security.Cryptography.SHA256]::Create()
$bytes = [System.Text.Encoding]::UTF8.GetBytes($sessionId)
$hash = $sha.ComputeHash($bytes)
$hex = ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
$sessionHash = $hex.Substring(0, 16)

$cacheFile = Join-Path $cacheDir "session-${sessionHash}.jsonl"
$statsFile = Join-Path $cacheDir 'stats.jsonl'

# Count entries being cleared (for stats)
$cleared = 0
if (Test-Path $cacheFile) {
    $cleared = (Get-Content $cacheFile -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
    Remove-Item $cacheFile -Force -ErrorAction SilentlyContinue
}

# Clear snapshots for this session (diff mode)
$snapDir = Join-Path $cacheDir 'snapshots'
if (Test-Path $snapDir) {
    Get-ChildItem -Path $snapDir -Filter "${sessionHash}-*" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# Log the compaction event
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
if ($cleared -gt 0) {
    $stat = @{ ts = $now; session = $sessionHash; event = 'compact'; cleared = $cleared } | ConvertTo-Json -Compress
    if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
    Add-Content -Path $statsFile -Value $stat
}

exit 0
