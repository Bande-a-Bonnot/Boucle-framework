# session-log: PostToolUse hook for Claude Code (PowerShell)
# Windows-native equivalent of hook.sh — no external dependencies needed.
#
# Logs every tool call with timestamp, tool name, and key parameters.
# Helps answer "what did Claude do while I was away?"
#
# Hook type: PostToolUse (fires after every tool call)
# Output: ~/.claude/session-logs/YYYY-MM-DD.jsonl
#
# Install:
#   Add to .claude/settings.json:
#   "hooks": { "PostToolUse": [{ "type": "command", "command": "pwsh -File /path/to/hook.ps1" }] }
#
# Env vars:
#   SESSION_LOG_DISABLED=1    Disable logging entirely
#   SESSION_LOG_DIR=path      Override log directory (default: ~/.claude/session-logs)
#
# MIT License - https://github.com/Bande-a-Bonnot/Boucle-framework

$ErrorActionPreference = 'SilentlyContinue'

# Allow disabling via env var
if ($env:SESSION_LOG_DISABLED -eq '1') { exit 0 }

# Read hook input from stdin
try {
    $rawInput = [Console]::In.ReadToEnd()
    $hookInput = $rawInput | ConvertFrom-Json
} catch {
    exit 0
}

$toolName = $hookInput.tool_name
if (-not $toolName) { exit 0 }

# Extract the most useful detail per tool type
$toolInput = $hookInput.tool_input
$detail = ''

if ($toolInput) {
    if ($toolInput.file_path) {
        $detail = $toolInput.file_path
    } elseif ($toolInput.command) {
        $detail = $toolInput.command
        if ($detail.Length -gt 200) { $detail = $detail.Substring(0, 200) }
    } elseif ($toolInput.pattern) {
        $path = if ($toolInput.path) { $toolInput.path } else { '.' }
        $detail = "$($toolInput.pattern) in $path"
    } elseif ($toolInput.file) {
        $detail = $toolInput.file
    } elseif ($toolInput.query) {
        $detail = [string]$toolInput.query
        if ($detail.Length -gt 200) { $detail = $detail.Substring(0, 200) }
    } else {
        # First property as fallback
        $props = $toolInput.PSObject.Properties | Select-Object -First 1
        if ($props) {
            $val = [string]$props.Value
            if ($val.Length -gt 100) { $val = $val.Substring(0, 100) }
            $detail = "$($props.Name)=$val"
        }
    }
}

# Extract tool response status
$toolResponse = $hookInput.tool_response
$status = $null
$exitCode = $null

if ($toolResponse -is [string] -and $toolResponse) {
    # Bash tool: check for exit code
    if ($toolResponse.StartsWith('Exit code ')) {
        try {
            $firstLine = ($toolResponse -split "`n")[0]
            $exitCode = [int]($firstLine -replace 'Exit code ', '')
        } catch { }
    }

    # General error detection
    $lower = $toolResponse.Substring(0, [Math]::Min(500, $toolResponse.Length)).ToLower()
    $errorSignals = @('error:', 'fatal:', 'permission denied', 'not found',
                      'exit code ', 'command not found', 'failed')
    foreach ($sig in $errorSignals) {
        if ($lower.Contains($sig)) {
            $status = 'error'
            break
        }
    }
}

if ($toolName -eq 'Bash' -and $null -eq $exitCode -and $toolResponse -and -not $status) {
    $exitCode = 0
}

# Timestamp
$now = [System.DateTimeOffset]::UtcNow
$ts = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
$dateStr = $now.ToString('yyyy-MM-dd')

# Session ID
$session = if ($env:CLAUDE_SESSION_ID) { $env:CLAUDE_SESSION_ID }
           elseif ($env:CLAUDE_CODE_SESSION) { $env:CLAUDE_CODE_SESSION }
           else { [string][long]($now.ToUnixTimeSeconds()) }

# Log directory
$logDir = if ($env:SESSION_LOG_DIR) { $env:SESSION_LOG_DIR }
          else { Join-Path $HOME '.claude' 'session-logs' }

if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# Build log entry
$entry = [ordered]@{
    ts      = $ts
    session = $session
    tool    = $toolName
}

if ($detail) { $entry['detail'] = $detail }
$entry['cwd'] = (Get-Location).Path
if ($null -ne $exitCode) { $entry['exit_code'] = $exitCode }
if ($status) { $entry['status'] = $status }

# Append to daily log file
$logFile = Join-Path $logDir "$dateStr.jsonl"
$json = $entry | ConvertTo-Json -Compress
Add-Content -Path $logFile -Value $json -Encoding UTF8

# Always exit 0 - logging should never block Claude
exit 0
