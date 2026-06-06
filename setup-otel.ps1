<#
.SYNOPSIS
    Enables Copilot OpenTelemetry SQLite span exporter in VS Code settings.

.DESCRIPTION
    Adds the required settings to VS Code's settings.json to enable the
    Copilot Chat OTel SQLite span exporter. Removes any conflicting
    file-exporter settings from a prior setup. Operates safely on JSONC
    format (preserves comments and formatting). Idempotent for target keys.

.PARAMETER SettingsPath
    Path to VS Code settings.json. If not provided, auto-detects from
    standard VS Code stable and Insiders install locations.

.EXAMPLE
    .\setup-otel.ps1
    Enables SQLite span exporter with auto-detected settings.json.

.EXAMPLE
    .\setup-otel.ps1 -SettingsPath "C:\custom\settings.json"
    Targets a specific settings.json file.
#>

param(
    [string]$SettingsPath
)

# ============================================================
# 1.3 & 1.4 Define target settings and stale keys
# ============================================================
$targetSettings = [ordered]@{
    "github.copilot.chat.otel.enabled"                    = $true
    "github.copilot.chat.otel.dbSpanExporter.enabled"     = $true
}

$staleKeys = @(
    "github.copilot.chat.otel.exporterType",
    "github.copilot.chat.otel.outfile"
)

# ============================================================
# 2.1 Resolve settings.json path
# ============================================================
if ($SettingsPath) {
    $targetPath = $SettingsPath
} else {
    $stablePath = Join-Path $env:APPDATA "Code\User\settings.json"
    $insidersPath = Join-Path $env:APPDATA "Code - Insiders\User\settings.json"

    if (Test-Path $stablePath -PathType Leaf) {
        $targetPath = $stablePath
    } elseif (Test-Path $insidersPath -PathType Leaf) {
        $targetPath = $insidersPath
    } else {
        # 2.2 No settings file found -- will create at stable path
        $targetPath = $stablePath
    }
}

# ============================================================
# 2.3 Check if VS Code is running
# ============================================================
$vsCodeRunning = $false
$vsCodeProcess = Get-Process "Code" -ErrorAction SilentlyContinue
if ($vsCodeProcess) {
    $vsCodeRunning = $true
    Write-Warning "VS Code is currently running. Settings are hot-reloaded, but you may need to restart VS Code for OTel to take effect."
}

# ============================================================
# 3.1 Read settings.json content (or prepare to create)
# ============================================================
$fileExists = Test-Path $targetPath -PathType Leaf

if ($fileExists) {
    # 7.2 Check readability
    try {
        $content = Get-Content $targetPath -Raw -ErrorAction Stop
    } catch {
        Write-Error "Cannot read settings file: $targetPath`n$_"
        exit 1
    }

    if ([string]::IsNullOrWhiteSpace($content)) {
        $content = "{}"
    }
} else {
    $content = "{}"
}

# ============================================================
# 3.2 Validate closing brace exists
# ============================================================
$lastBraceIdx = $content.LastIndexOf('}')
if ($lastBraceIdx -lt 0) {
    Write-Error "settings.json appears malformed: no closing brace '}' found. Aborting."
    exit 1
}

# ============================================================
# 3.3 Basic JSON structure validation (warn but proceed for JSONC)
# ============================================================
try {
    $null = $content | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Warning "settings.json does not parse as strict JSON (likely contains JSONC comments). Proceeding with text-based approach."
}

# ============================================================
# 4.1 & 4.2 Detect which keys are present
# ============================================================
$missingTargetKeys = @()
$existingTargetKeys = @()

foreach ($key in $targetSettings.Keys) {
    $pattern = [regex]::Escape($key)
    if ($content -match $pattern) {
        $existingTargetKeys += $key
    } else {
        $missingTargetKeys += $key
    }
}

$staleKeysFound = @()
foreach ($key in $staleKeys) {
    $pattern = [regex]::Escape($key)
    if ($content -match $pattern) {
        $staleKeysFound += $key
    }
}

# ============================================================
# 4.3 Remove stale key lines from content
# ============================================================
foreach ($key in $staleKeysFound) {
    $escapedKey = [regex]::Escape($key)
    # Match the line containing this key, including optional trailing comma and surrounding whitespace/newlines
    $linePattern = '\s*"' + $escapedKey + '"\s*:\s*[^,\r\n]*,?\s*\r?\n?'
    $content = $content -replace $linePattern, ''
}

# 7.4 Clean up any double commas or trailing comma before closing brace after removal
$content = $content -replace ',(\s*\r?\n\s*})', '$1'
$content = $content -replace ',\s*,', ','

# Recalculate brace position after removals
$lastBraceIdx = $content.LastIndexOf('}')

# ============================================================
# 4.4 Skip if nothing to do (all targets present, nothing stale to remove)
# ============================================================
if ($missingTargetKeys.Count -eq 0 -and $staleKeysFound.Count -eq 0) {
    Write-Host ""
    Write-Host "=== Copilot OTel Setup (SQLite) ===" -ForegroundColor Cyan
    Write-Host ""
    foreach ($key in $targetSettings.Keys) {
        $val = $targetSettings[$key]
        if ($val -is [bool]) {
            $valDisplay = $val.ToString().ToLower()
        } else {
            $valDisplay = $val
        }
        Write-Host "  [ALREADY SET] $key = $valDisplay"
    }
    Write-Host ""
    Write-Host "All settings already configured. Nothing to do."
    Write-Host ""
    Write-Host "To export data: run 'Chat: Export Agent Traces DB' command in VS Code."
    Write-Host ""
    exit 0
}

# ============================================================
# 5.1 Create backup before modifying
# ============================================================
if ($fileExists) {
    $backupPath = "$targetPath.bak"
    try {
        Copy-Item $targetPath $backupPath -Force -ErrorAction Stop
    } catch {
        Write-Error "Failed to create backup at $backupPath`: $_"
        exit 1
    }
} else {
    $backupPath = $null
}

# ============================================================
# 5.2 Build JSON lines for missing target keys
# ============================================================
$indent = "    "
$newSettingLines = @()
foreach ($key in $missingTargetKeys) {
    $value = $targetSettings[$key]
    if ($value -is [bool]) {
        $jsonValue = $value.ToString().ToLower()
    } else {
        $jsonValue = '"' + $value + '"'
    }
    $newSettingLines += "$indent`"$key`": $jsonValue"
}

# ============================================================
# 5.3 Insert new keys before closing brace (JSONC-safe)
# ============================================================
if ($missingTargetKeys.Count -gt 0) {
    $insertBlock = $newSettingLines -join ",`n"
    $beforeBrace = $content.Substring(0, $lastBraceIdx)
    $afterBrace = $content.Substring($lastBraceIdx + 1)

    # 7.3 Handle empty object {} specially
    if ($content.Trim() -eq '{}') {
        $newContent = "{`n$insertBlock`n}`n"
    } else {
        $trimmedBefore = $beforeBrace.TrimEnd()
        if ($trimmedBefore.Length -gt 0) {
            $effectiveLastChar = $trimmedBefore.Substring($trimmedBefore.Length - 1, 1)
        } else {
            $effectiveLastChar = ''
        }

        if ($effectiveLastChar -eq ',' -or $effectiveLastChar -eq '{') {
            $newContent = $beforeBrace + "`n$insertBlock`n}$afterBrace"
        } else {
            $newContent = $beforeBrace.TrimEnd() + ",`n$insertBlock`n}$afterBrace"
        }
    }
} else {
    # No new keys to add, but stale keys were removed -- content already updated
    $newContent = $content
}

# ============================================================
# 5.4 Write modified content back
# ============================================================
$targetDir = Split-Path $targetPath -Parent
if (-not (Test-Path $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
}

try {
    Set-Content -Path $targetPath -Value $newContent -Encoding UTF8 -ErrorAction Stop
} catch {
    Write-Error "Failed to write settings file: $targetPath`n$_"
    if ($backupPath) {
        Write-Host "Backup saved at: $backupPath - you can restore it manually."
    }
    exit 1
}

# ============================================================
# 6.1-6.6 Report results
# ============================================================
Write-Host ""
Write-Host "=== Copilot OTel Setup (SQLite) ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Settings file: $targetPath"
Write-Host ""

foreach ($key in $targetSettings.Keys) {
    $val = $targetSettings[$key]
    if ($val -is [bool]) {
        $valDisplay = $val.ToString().ToLower()
    } else {
        $valDisplay = $val
    }

    if ($key -in $missingTargetKeys) {
        Write-Host "  [ADDED]        $key = $valDisplay" -ForegroundColor Green
    } else {
        Write-Host "  [ALREADY SET]  $key = $valDisplay"
    }
}

foreach ($key in $staleKeysFound) {
    Write-Host "  [REMOVED]      $key" -ForegroundColor Yellow
}

Write-Host ""

if ($backupPath) {
    Write-Host "Backup saved: $backupPath"
} else {
    Write-Host "Settings file was newly created (no backup needed)."
}

Write-Host ""
Write-Host "To export data: run 'Chat: Export Agent Traces DB' command in VS Code." -ForegroundColor Cyan
Write-Host "  (Ctrl+Shift+P -> type 'Export Agent Traces')"
Write-Host ""

if ($vsCodeRunning) {
    Write-Host "Note: Restart VS Code to ensure OTel settings take effect." -ForegroundColor Yellow
    Write-Host ""
}
