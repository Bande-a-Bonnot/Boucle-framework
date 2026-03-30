# Boucle hooks installer for Windows (PowerShell)
# Native PowerShell hooks for Claude Code — no bash, no jq, no WSL required.
#
# Usage:
#   iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) }"
#   iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } recommended"
#   iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } file-guard git-safe"
#   iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } all"

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Hooks
)

$ErrorActionPreference = 'Stop'

$Repo = "https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools"
$SettingsPath = Join-Path $HOME ".claude" "settings.json"

# Hook catalog
$HookCatalog = [ordered]@{
    'bash-guard'     = @{ Desc = 'Block dangerous bash commands (rm -rf, sudo, curl|bash, cloud destroy)'; Event = 'PreToolUse' }
    'file-guard'     = @{ Desc = 'Block modifications to sensitive files (.env, keys)'; Event = 'PreToolUse' }
    'git-safe'       = @{ Desc = 'Prevent destructive git operations (force push, reset --hard)'; Event = 'PreToolUse' }
    'branch-guard'   = @{ Desc = 'Prevent direct commits to main/master (feature-branch workflow)'; Event = 'PreToolUse' }
    'read-once'      = @{ Desc = 'Prevent redundant file reads, save tokens (~2000/read)'; Event = 'PreToolUse' }
    'worktree-guard' = @{ Desc = 'Prevent worktree exit with uncommitted/unmerged changes'; Event = 'PreToolUse' }
    'session-log'    = @{ Desc = 'Audit trail - log every tool call to JSONL'; Event = 'PostToolUse' }
}

$AllHookNames = @($HookCatalog.Keys)
$RecommendedHooks = @('bash-guard', 'git-safe', 'file-guard')

Write-Host ""
Write-Host "Boucle Hooks for Claude Code (PowerShell)" -ForegroundColor White
Write-Host "Native Windows hooks - no bash or jq required" -ForegroundColor DarkGray
Write-Host ""

# Show available hooks and their status
foreach ($name in $AllHookNames) {
    $info = $HookCatalog[$name]
    $hookDir = Join-Path $HOME ".claude" $name
    $hookFile = Join-Path $hookDir "hook.ps1"
    if (Test-Path $hookFile) {
        $status = "installed"
        $statusColor = "Green"
    } else {
        $status = "not installed"
        $statusColor = "DarkGray"
    }
    Write-Host "  " -NoNewline
    Write-Host "$name" -ForegroundColor Cyan -NoNewline
    Write-Host "  $($info.Desc)  [" -NoNewline
    Write-Host "$status" -ForegroundColor $statusColor -NoNewline
    Write-Host "]"
}
Write-Host ""

# Parse arguments or ask interactively
if ($Hooks -and $Hooks.Count -gt 0) {
    if ($Hooks[0] -eq 'all') {
        $selected = $AllHookNames
    } elseif ($Hooks[0] -eq 'recommended') {
        $selected = $RecommendedHooks
        Write-Host "Installing recommended hooks: bash-guard, git-safe, file-guard" -ForegroundColor White
    } else {
        $selected = $Hooks
    }
} else {
    Write-Host "Which hooks to install?" -ForegroundColor White
    Write-Host "  'recommended'  bash-guard + git-safe + file-guard (start here)"
    Write-Host "  'all'          all hooks"
    Write-Host "  or enter hook names separated by spaces"
    $userInput = Read-Host ">"
    $userInput = $userInput.Trim()
    if ($userInput -eq 'all') {
        $selected = $AllHookNames
    } elseif ($userInput -eq 'recommended') {
        $selected = $RecommendedHooks
        Write-Host "Installing recommended hooks: bash-guard, git-safe, file-guard" -ForegroundColor White
    } elseif ($userInput -ne '') {
        $selected = $userInput -split '\s+'
    } else {
        Write-Host "Nothing selected. Exiting."
        exit 0
    }
}

Write-Host ""

# Install each selected hook
$installed = @()
foreach ($hook in $selected) {
    if (-not $HookCatalog.Contains($hook)) {
        Write-Host "  Unknown hook: $hook" -ForegroundColor Yellow
        Write-Host "  Available: $($AllHookNames -join ', ')"
        continue
    }

    $installDir = Join-Path $HOME ".claude" $hook
    Write-Host "Installing " -NoNewline
    Write-Host "$hook" -ForegroundColor Cyan -NoNewline
    Write-Host "..."

    if (-not (Test-Path $installDir)) {
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    }

    # Download hook.ps1
    $hookFile = Join-Path $installDir "hook.ps1"
    try {
        $content = Invoke-RestMethod -Uri "$Repo/$hook/hook.ps1" -ErrorAction Stop
        Set-Content -Path $hookFile -Value $content -Encoding UTF8
    } catch {
        Write-Host "  Error: download failed for $hook. Skipping." -ForegroundColor Yellow
        continue
    }

    # Verify download is not empty
    if (-not (Test-Path $hookFile) -or (Get-Item $hookFile).Length -eq 0) {
        Write-Host "  Error: downloaded $hook/hook.ps1 is empty. Skipping." -ForegroundColor Yellow
        continue
    }

    # Download extra files depending on hook
    if ($hook -eq 'file-guard') {
        # Create a default .file-guard config if none exists in cwd
        $configPath = Join-Path (Get-Location) ".file-guard"
        if (-not (Test-Path $configPath)) {
            Write-Host "  Tip: create a .file-guard file in your project root listing files to protect." -ForegroundColor DarkGray
            Write-Host "  Example: .env, *.pem, credentials.*, .ssh/" -ForegroundColor DarkGray
        }
    }

    Write-Host "  Downloaded to $installDir" -ForegroundColor Green
    $installed += $hook
}

if ($installed.Count -eq 0) {
    Write-Host "No hooks installed."
    exit 0
}

Write-Host ""
Write-Host "Configuring hooks in $SettingsPath..."

# Ensure settings directory exists
$settingsDir = Split-Path $SettingsPath -Parent
if (-not (Test-Path $settingsDir)) {
    New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
}

# Load or create settings.json
if (Test-Path $SettingsPath) {
    $raw = Get-Content $SettingsPath -Raw -ErrorAction SilentlyContinue
    if (-not $raw -or $raw.Trim() -eq '') {
        $settings = @{}
    } else {
        # Strip JSONC comments (// and /* */) before parsing
        $cleaned = $raw
        # Remove single-line comments (not inside strings - simplified)
        $cleaned = $cleaned -replace '(?m)^\s*//.*$', ''
        # Remove inline comments after values (simplified, may not handle all edge cases)
        $cleaned = $cleaned -replace '(?<=,|{|\[)\s*//.*$', ''
        try {
            $settings = $cleaned | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        } catch {
            Write-Host "  Warning: settings.json contains JSONC comments. Creating backup." -ForegroundColor Yellow
            Copy-Item $SettingsPath "$SettingsPath.bak" -Force
            try {
                $settings = $cleaned | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            } catch {
                Write-Host "  Error: $SettingsPath is not valid JSON. Aborting." -ForegroundColor Red
                exit 1
            }
        }
    }
} else {
    $settings = @{}
}

if (-not $settings.ContainsKey('hooks')) {
    $settings['hooks'] = @{}
}

foreach ($hook in $installed) {
    $info = $HookCatalog[$hook]
    $event = $info.Event
    $hookFile = Join-Path $HOME ".claude" $hook "hook.ps1"
    $command = "pwsh -File `"$hookFile`""

    $entry = @{
        hooks = @(
            @{
                type    = "command"
                command = $command
                timeout = 5000
            }
        )
    }
    # worktree-guard uses ExitWorktree matcher for efficiency
    if ($hook -eq 'worktree-guard') {
        $entry['matcher'] = 'ExitWorktree'
    }

    if (-not $settings['hooks'].ContainsKey($event)) {
        $settings['hooks'][$event] = @()
    }

    # Check if hook is already configured
    $alreadyExists = $false
    foreach ($h in $settings['hooks'][$event]) {
        $cmd = $null
        if ($h -is [hashtable] -or $h -is [System.Collections.IDictionary]) {
            $cmd = $h['command']
            if (-not $cmd -and $h.ContainsKey('hooks')) {
                foreach ($hk in $h['hooks']) {
                    if ($hk -is [hashtable] -or $hk -is [System.Collections.IDictionary]) {
                        $cmd = $hk['command']
                        if ($cmd) { break }
                    }
                }
            }
        }
        if ($cmd -and $cmd -like "*$hook*hook.ps1*") {
            $alreadyExists = $true
            break
        }
    }

    if (-not $alreadyExists) {
        $settings['hooks'][$event] += $entry
        Write-Host "  Added $hook to $event hooks"
    } else {
        Write-Host "  $hook already configured"
    }
}

# Save settings.json
$settings | ConvertTo-Json -Depth 10 | Set-Content $SettingsPath -Encoding UTF8
Write-Host ""

# Post-install verification
Write-Host "Verifying hooks..." -ForegroundColor White
Write-Host ""

$verifyOk = 0
$verifyFail = 0
$verifySkip = 0

foreach ($hook in $installed) {
    $hookFile = Join-Path $HOME ".claude" $hook "hook.ps1"
    if (-not (Test-Path $hookFile)) {
        Write-Host "  WARN: $hook file not found" -ForegroundColor Yellow
        $verifyFail++
        continue
    }

    switch ($hook) {
        'git-safe' {
            $payload = '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}'
            try {
                $result = $payload | pwsh -File $hookFile 2>$null
                if ($result -match '"block"') {
                    Write-Host "  OK" -ForegroundColor Green -NoNewline
                    Write-Host ": $hook blocked test payload (git push --force)"
                    $verifyOk++
                } else {
                    Write-Host "  WARN" -ForegroundColor Yellow -NoNewline
                    Write-Host ": $hook did not block test payload"
                    $verifyFail++
                }
            } catch {
                Write-Host "  WARN" -ForegroundColor Yellow -NoNewline
                Write-Host ": $hook returned an error"
                $verifyFail++
            }
        }
        'branch-guard' {
            # branch-guard needs git context, skip if no git repo
            try {
                $payload = '{"tool_name":"Bash","tool_input":{"command":"echo test"}}'
                $result = $payload | pwsh -File $hookFile 2>$null
                Write-Host "  SKIP" -ForegroundColor DarkGray -NoNewline
                Write-Host ": $hook (needs git repo context to verify)"
                $verifySkip++
            } catch {
                Write-Host "  SKIP" -ForegroundColor DarkGray -NoNewline
                Write-Host ": $hook (needs git repo context)"
                $verifySkip++
            }
        }
        'session-log' {
            $payload = '{"tool_name":"Read","tool_input":{"file_path":"C:\\verify-test"}}'
            try {
                $null = $payload | pwsh -File $hookFile 2>$null
                Write-Host "  OK" -ForegroundColor Green -NoNewline
                Write-Host ": $hook accepted test payload without error"
                $verifyOk++
            } catch {
                Write-Host "  WARN" -ForegroundColor Yellow -NoNewline
                Write-Host ": $hook returned an error"
                $verifyFail++
            }
        }
        'file-guard' {
            # file-guard always blocks relative paths in Write/Edit (no config needed)
            $payload = '{"tool_name":"Write","tool_input":{"file_path":"relative/path.txt","content":"test"}}'
            try {
                $result = $payload | pwsh -File $hookFile 2>$null
                if ($result -match '"block"') {
                    Write-Host "  OK" -ForegroundColor Green -NoNewline
                    Write-Host ": $hook blocked test payload (relative path write)"
                    $verifyOk++
                } else {
                    Write-Host "  WARN" -ForegroundColor Yellow -NoNewline
                    Write-Host ": $hook did not block test payload"
                    $verifyFail++
                }
            } catch {
                Write-Host "  WARN" -ForegroundColor Yellow -NoNewline
                Write-Host ": $hook returned an error"
                $verifyFail++
            }
        }
        'read-once' {
            $payload = '{"tool_name":"Bash","tool_input":{"command":"echo test"}}'
            try {
                $null = $payload | pwsh -File $hookFile 2>$null
                Write-Host "  OK" -ForegroundColor Green -NoNewline
                Write-Host ": $hook accepted non-Read payload (ignored correctly)"
                $verifyOk++
            } catch {
                Write-Host "  WARN" -ForegroundColor Yellow -NoNewline
                Write-Host ": $hook returned an error"
                $verifyFail++
            }
        }
        'worktree-guard' {
            $payload = '{"tool_name":"Bash","tool_input":{"command":"echo test"}}'
            try {
                $null = $payload | pwsh -File $hookFile 2>$null
                Write-Host "  OK" -ForegroundColor Green -NoNewline
                Write-Host ": $hook accepted non-ExitWorktree payload (ignored correctly)"
                $verifyOk++
            } catch {
                Write-Host "  WARN" -ForegroundColor Yellow -NoNewline
                Write-Host ": $hook returned an error"
                $verifyFail++
            }
        }
        'bash-guard' {
            $payload = '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}'
            try {
                $result = $payload | pwsh -File $hookFile 2>$null
                if ($result -match '"block"') {
                    Write-Host "  OK" -ForegroundColor Green -NoNewline
                    Write-Host ": $hook blocked test payload (rm -rf /)"
                    $verifyOk++
                } else {
                    Write-Host "  WARN" -ForegroundColor Yellow -NoNewline
                    Write-Host ": $hook did not block test payload"
                    $verifyFail++
                }
            } catch {
                Write-Host "  WARN" -ForegroundColor Yellow -NoNewline
                Write-Host ": $hook returned an error"
                $verifyFail++
            }
        }
        default {
            Write-Host "  SKIP" -ForegroundColor DarkGray -NoNewline
            Write-Host ": $hook (no automated test available)"
            $verifySkip++
        }
    }
}

Write-Host ""
if ($verifyFail -gt 0) {
    Write-Host "Installed with warnings." -ForegroundColor Yellow
    Write-Host "$verifyOk passed, $verifyFail warnings, $verifySkip skipped."
} else {
    Write-Host "Done! " -ForegroundColor Green -NoNewline
    Write-Host "$verifyOk hooks verified, $verifySkip skipped. Active for your next Claude Code session."
}
Write-Host ""
Write-Host "Manage hooks:"
Write-Host "  View config:  Get-Content ~/.claude/settings.json"
Write-Host "  Uninstall:    Remove-Item -Recurse ~/.claude/<hook-name>"
Write-Host ""
Write-Host "Bash hooks also available (macOS/Linux):" -ForegroundColor DarkGray
Write-Host "  curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash" -ForegroundColor DarkGray
Write-Host ""
