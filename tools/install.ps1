# Boucle hooks installer for Windows (PowerShell)
# Native PowerShell hooks for Claude Code — no bash, no jq, no WSL required.
#
# Usage:
#   iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) }"
#   iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } recommended"
#   iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } file-guard git-safe"
#   iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } all"
#   iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } help"

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Hooks
)

$ErrorActionPreference = 'Stop'

# Require PowerShell 7+ (pwsh). Windows ships with 5.1 which lacks -AsHashtable
# and Claude Code hooks need `pwsh -File` to run.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "Error: PowerShell 7+ required." -ForegroundColor Red
    Write-Host ""
    Write-Host "You are running PowerShell $($PSVersionTable.PSVersion) (Windows built-in)."
    Write-Host "The hooks need PowerShell 7+ (pwsh) to run."
    Write-Host ""
    Write-Host "Install it:" -ForegroundColor White
    Write-Host "  winget install Microsoft.PowerShell"
    Write-Host "  # or: https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows"
    Write-Host ""
    Write-Host "Then re-run this installer from pwsh (not powershell.exe)."
    exit 1
}

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

# Strip // and /* */ comments from JSONC, respecting quoted strings.
# Claude Code's settings.json uses JSONC format (JSON with comments).
function Strip-JsonComments {
    param([string]$Text)
    $result = [System.Text.StringBuilder]::new()
    $i = 0
    $inString = $false
    while ($i -lt $Text.Length) {
        if ($inString) {
            if ($Text[$i] -eq [char]'\' -and ($i + 1) -lt $Text.Length) {
                [void]$result.Append($Text[$i])
                [void]$result.Append($Text[$i + 1])
                $i += 2
                continue
            }
            if ($Text[$i] -eq [char]'"') { $inString = $false }
            [void]$result.Append($Text[$i])
            $i++
        } else {
            if ($Text[$i] -eq [char]'"') {
                $inString = $true
                [void]$result.Append($Text[$i])
                $i++
            } elseif (($i + 1) -lt $Text.Length -and $Text[$i] -eq [char]'/' -and $Text[$i + 1] -eq [char]'/') {
                while ($i -lt $Text.Length -and $Text[$i] -ne "`n") { $i++ }
            } elseif (($i + 1) -lt $Text.Length -and $Text[$i] -eq [char]'/' -and $Text[$i + 1] -eq [char]'*') {
                $i += 2
                while (($i + 1) -lt $Text.Length -and -not ($Text[$i] -eq [char]'*' -and $Text[$i + 1] -eq [char]'/')) { $i++ }
                $i += 2
            } else {
                [void]$result.Append($Text[$i])
                $i++
            }
        }
    }
    return $result.ToString()
}

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

# Handle help subcommand
if ($Hooks -and $Hooks.Count -gt 0 -and ($Hooks[0] -eq 'help' -or $Hooks[0] -eq '--help' -or $Hooks[0] -eq '-h')) {
    Write-Host "Usage: install.ps1 <command> [args]" -ForegroundColor White
    Write-Host ""
    Write-Host "Commands:" -ForegroundColor White
    Write-Host "  recommended           Install the 3 essential hooks (bash-guard, git-safe, file-guard)"
    Write-Host "  all                   Install all 7 hooks"
    Write-Host "  <hook> [hook...]      Install specific hooks by name"
    Write-Host "  backup                Snapshot settings.json (protects against auto-update wipes)"
    Write-Host "  backup list           Show available backups"
    Write-Host "  restore               Restore the most recent backup"
    Write-Host "  restore <file>        Restore a specific backup"
    Write-Host "  doctor                Diagnose installation health (files, settings, permissions)"
    Write-Host "  help                  Show this help message"
    Write-Host ""
    Write-Host "Available hooks:" -ForegroundColor White
    foreach ($name in $AllHookNames) {
        $info = $HookCatalog[$name]
        $rec = ""
        if ($RecommendedHooks -contains $name) { $rec = " (recommended)" }
        Write-Host "  " -NoNewline
        Write-Host "$name" -ForegroundColor Cyan -NoNewline
        Write-Host "  $($info.Desc)$rec"
    }
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor White
    Write-Host "  install.ps1 recommended           # Start here"
    Write-Host "  install.ps1 all                    # Everything at once"
    Write-Host "  install.ps1 read-once git-safe     # Pick specific hooks"
    exit 0
}

# Handle backup subcommand
$BackupDir = Join-Path (Split-Path $SettingsPath -Parent) "backups"
if ($Hooks -and $Hooks.Count -gt 0 -and $Hooks[0] -eq 'backup') {
    if (-not (Test-Path $SettingsPath)) {
        Write-Host "No settings.json found at $SettingsPath"
        Write-Host "Nothing to back up."
        exit 0
    }

    # backup list
    if ($Hooks.Count -gt 1 -and $Hooks[1] -eq 'list') {
        if (-not (Test-Path $BackupDir)) {
            Write-Host "No backups found."
            Write-Host ""
            Write-Host "Create one with: install.ps1 backup"
            exit 0
        }
        $files = Get-ChildItem -Path $BackupDir -Filter "settings.*.json" -ErrorAction SilentlyContinue | Sort-Object Name
        if ($files.Count -eq 0) {
            Write-Host "No backups found."
            Write-Host ""
            Write-Host "Create one with: install.ps1 backup"
            exit 0
        }
        foreach ($f in $files) {
            Write-Host "  " -NoNewline
            Write-Host "$($f.Name)" -ForegroundColor Cyan -NoNewline
            Write-Host "  $($f.Length) bytes"
        }
        Write-Host ""
        Write-Host "  $($files.Count) backup(s) found in $BackupDir"
        Write-Host ""
        Write-Host "Restore with: install.ps1 restore"
        exit 0
    }

    # Create backup
    if (-not (Test-Path $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    }
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupFile = Join-Path $BackupDir "settings.$timestamp.json"
    Copy-Item $SettingsPath $backupFile

    $size = (Get-Item $backupFile).Length
    Write-Host "Backup created." -ForegroundColor Green
    Write-Host ""
    Write-Host "  File: $backupFile"
    Write-Host "  Size: $size bytes"
    Write-Host ""
    Write-Host "Restore with: install.ps1 restore"
    Write-Host ""
    Write-Host "Tip: Run this before updating Claude Code. If an auto-update" -ForegroundColor DarkGray
    Write-Host "wipes your settings.json, restore will bring your hooks back." -ForegroundColor DarkGray
    exit 0
}

# Handle restore subcommand
if ($Hooks -and $Hooks.Count -gt 0 -and $Hooks[0] -eq 'restore') {
    if (-not (Test-Path $BackupDir)) {
        Write-Host "No backups found in $BackupDir"
        Write-Host ""
        Write-Host "Create one first with: install.ps1 backup"
        exit 1
    }

    $target = $null
    if ($Hooks.Count -gt 1) {
        # Specific file requested
        $name = $Hooks[1]
        $candidate = Join-Path $BackupDir $name
        if (Test-Path $candidate) {
            $target = $candidate
        } elseif (Test-Path $name) {
            $target = $name
        } else {
            Write-Host "Backup not found: " -ForegroundColor Yellow -NoNewline
            Write-Host "$name"
            Write-Host ""
            Write-Host "Available backups:"
            Get-ChildItem -Path $BackupDir -Filter "settings.*.json" | ForEach-Object { Write-Host "  $($_.Name)" }
            exit 1
        }
    } else {
        # Find most recent backup
        $files = Get-ChildItem -Path $BackupDir -Filter "settings.2*.json" -ErrorAction SilentlyContinue | Sort-Object Name
        if ($files.Count -eq 0) {
            Write-Host "No backups found in $BackupDir"
            exit 1
        }
        $target = $files[-1].FullName
    }

    # Validate JSON (accept JSONC with comments)
    $backupRaw = Get-Content $target -Raw
    try {
        $null = $backupRaw | ConvertFrom-Json
    } catch {
        try {
            $null = (Strip-JsonComments $backupRaw) | ConvertFrom-Json
        } catch {
            Write-Host "Warning: " -ForegroundColor Yellow -NoNewline
            Write-Host "Backup is not valid JSON: $(Split-Path $target -Leaf)"
            Write-Host "Aborting restore."
            exit 1
        }
    }

    # Save pre-restore copy
    if (Test-Path $SettingsPath) {
        $preRestore = Join-Path $BackupDir "settings.pre-restore-$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
        Copy-Item $SettingsPath $preRestore
        Write-Host "  Current settings saved to $(Split-Path $preRestore -Leaf)" -ForegroundColor DarkGray
    }

    Copy-Item $target $SettingsPath
    Write-Host "Restored!" -ForegroundColor Green
    Write-Host ""
    Write-Host "  From: $(Split-Path $target -Leaf)"
    Write-Host "  To:   $SettingsPath"
    Write-Host ""
    Write-Host "Changes take effect in your next Claude Code session."
    exit 0
}

# Handle doctor subcommand — diagnose installation health
if ($Hooks -and $Hooks.Count -gt 0 -and $Hooks[0] -eq 'doctor') {
    $doctorErrors = 0
    $doctorWarnings = 0
    $doctorOk = 0

    Write-Host "Running diagnostics..." -ForegroundColor White
    Write-Host ""

    # 1. Check settings.json
    $settings = $null
    $isJsonc = $false
    if (-not (Test-Path $SettingsPath)) {
        Write-Host "  ERROR  settings.json not found at $SettingsPath" -ForegroundColor Red
        Write-Host "         Run the installer to create it, or check Claude Code is installed."
        $doctorErrors++
    } else {
        Write-Host "  OK     settings.json exists" -ForegroundColor Green
        $doctorOk++

        $raw = Get-Content $SettingsPath -Raw -ErrorAction SilentlyContinue
        try {
            $settings = $raw | ConvertFrom-Json -AsHashtable
            Write-Host "  OK     settings.json is valid JSON" -ForegroundColor Green
            $doctorOk++
        } catch {
            # Try JSONC
            try {
                $cleaned = Strip-JsonComments $raw
                $settings = $cleaned | ConvertFrom-Json -AsHashtable
                $isJsonc = $true
                Write-Host "  WARN   settings.json uses JSONC (comments). Some tools may not parse it." -ForegroundColor Yellow
                $doctorWarnings++
            } catch {
                Write-Host "  ERROR  settings.json is not valid JSON or JSONC" -ForegroundColor Red
                $doctorErrors++
            }
        }
    }

    # 2. Check each hook
    Write-Host ""
    Write-Host "Installed hooks:" -ForegroundColor White

    foreach ($name in $AllHookNames) {
        $info = $HookCatalog[$name]
        $hookDir = Join-Path $HOME ".claude" $name
        $hookFile = Join-Path $hookDir "hook.ps1"

        if (-not (Test-Path $hookDir)) {
            Write-Host "  --     $name  not installed" -ForegroundColor DarkGray
            continue
        }

        $issues = @()

        # Check hook.ps1 exists
        if (-not (Test-Path $hookFile)) {
            # Also check hook.sh (bash hooks on Windows via WSL)
            $hookBash = Join-Path $hookDir "hook.sh"
            if (-not (Test-Path $hookBash)) {
                $issues += "missing hook.ps1"
            }
        }

        # Check extra files for read-once
        if ($name -eq 'read-once') {
            $cliPs1 = Join-Path $hookDir "read-once.ps1"
            $cliBash = Join-Path $hookDir "read-once"
            if (-not (Test-Path $cliPs1) -and -not (Test-Path $cliBash)) {
                $issues += "read-once CLI not found (run: install.ps1 upgrade)"
            }
        }

        # Check settings.json registration
        if ($null -ne $settings -and $settings.ContainsKey('hooks')) {
            $event = $info.Event
            $found = $false
            if ($settings['hooks'].ContainsKey($event)) {
                foreach ($entry in $settings['hooks'][$event]) {
                    foreach ($h in $entry['hooks']) {
                        $cmd = $h['command']
                        if ($cmd -and $cmd -like "*$name*") {
                            $found = $true
                            break
                        }
                    }
                    if ($found) { break }
                }
            }
            if (-not $found) {
                $issues += "not registered in settings.json (run: install.ps1 $name)"
            }
        }

        if ($issues.Count -eq 0) {
            Write-Host "  OK     $name  $($info.Desc)" -ForegroundColor Green
            $doctorOk++
        } else {
            Write-Host "  ERROR  $name" -ForegroundColor Red
            foreach ($issue in $issues) {
                Write-Host "         $issue"
                $doctorErrors++
            }
        }
    }

    # 3. Check orphaned entries
    if ($null -ne $settings -and $settings.ContainsKey('hooks')) {
        Write-Host ""
        Write-Host "Settings.json entries:" -ForegroundColor White

        $orphans = @()
        foreach ($event in $settings['hooks'].Keys) {
            foreach ($entry in $settings['hooks'][$event]) {
                foreach ($h in $entry['hooks']) {
                    $cmd = $h['command']
                    if ($cmd -and -not (Test-Path $cmd)) {
                        $orphans += "${event}: $cmd"
                    }
                }
            }
        }

        if ($orphans.Count -gt 0) {
            foreach ($o in $orphans) {
                Write-Host "  WARN   orphaned entry: $o" -ForegroundColor Yellow
                $doctorWarnings++
            }
        } else {
            Write-Host "  OK     no orphaned hook entries" -ForegroundColor Green
            $doctorOk++
        }

        # 4. Check backups
        if (Test-Path $BackupDir) {
            $backups = Get-ChildItem $BackupDir -Filter "settings.*.json" -ErrorAction SilentlyContinue
            if ($backups -and $backups.Count -gt 0) {
                Write-Host "  OK     $($backups.Count) backup(s) available" -ForegroundColor Green
                $doctorOk++
            }
        } else {
            Write-Host "  WARN   no backups found (run: install.ps1 backup)" -ForegroundColor Yellow
            $doctorWarnings++
        }
    }

    # Summary
    Write-Host ""
    if ($doctorErrors -gt 0) {
        Write-Host "$doctorErrors error(s), $doctorWarnings warning(s), $doctorOk ok" -ForegroundColor Red
        exit 1
    } elseif ($doctorWarnings -gt 0) {
        Write-Host "$doctorWarnings warning(s), $doctorOk ok" -ForegroundColor Yellow
        exit 0
    } else {
        Write-Host "All checks passed ($doctorOk ok)" -ForegroundColor Green
        exit 0
    }
}

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
    if ($hook -eq 'read-once') {
        # Download the read-once.ps1 CLI tool (stats, gain, status, verify, clear, etc.)
        $cliFile = Join-Path $installDir "read-once.ps1"
        try {
            $cliContent = Invoke-RestMethod -Uri "$Repo/read-once/read-once.ps1" -ErrorAction Stop
            Set-Content -Path $cliFile -Value $cliContent -Encoding UTF8
            Write-Host "  Downloaded read-once CLI (pwsh read-once.ps1 stats)" -ForegroundColor Green
        } catch {
            Write-Host "  Warning: failed to download read-once.ps1 CLI tool" -ForegroundColor Yellow
        }
    }
    elseif ($hook -eq 'file-guard') {
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
        try {
            $settings = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        } catch {
            # JSON parse failed - try stripping JSONC comments
            $cleaned = Strip-JsonComments $raw
            try {
                $settings = $cleaned | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                Write-Host "  Warning: settings.json contains JSONC comments." -ForegroundColor Yellow
                Write-Host "  Comments will be removed when saving. Backup created at $SettingsPath.bak" -ForegroundColor Yellow
                Copy-Item $SettingsPath "$SettingsPath.bak" -Force
            } catch {
                Write-Host "  Error: $SettingsPath is not valid JSON. Aborting." -ForegroundColor Red
                Write-Host "  Try: Get-Content $SettingsPath | ConvertFrom-Json" -ForegroundColor DarkGray
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
