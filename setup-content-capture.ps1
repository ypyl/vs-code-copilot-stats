<#
.SYNOPSIS
    Enables or disables Copilot OTel content capture in VS Code settings.

.DESCRIPTION
    Toggles the content capture setting that controls whether full LLM prompt
    and response messages are included in OTel traces. When enabled, attributes
    like gen_ai.input.messages and gen_ai.output.messages appear in span data,
    allowing you to inspect exactly what gets sent to the LLM.

    WARNING: Content capture includes sensitive information such as code,
    file contents, and user prompts. Only enable in trusted environments.

    Operates safely on JSONC format (preserves comments and formatting).
    Idempotent for target keys.

.PARAMETER SettingsPath
    Path to VS Code settings.json. If not provided, auto-detects from
    standard VS Code stable and Insiders install locations.

.PARAMETER Enable
    Enable content capture (default).

.PARAMETER Disable
    Disable content capture.

.PARAMETER Status
    Check current content capture state without making changes.

.EXAMPLE
    .\setup-content-capture.ps1
    Enables content capture with auto-detected settings.json.

.EXAMPLE
    .\setup-content-capture.ps1 -Disable
    Disables content capture.

.EXAMPLE
    .\setup-content-capture.ps1 -Status
    Shows whether content capture is currently enabled.

.EXAMPLE
    .\setup-content-capture.ps1 -SettingsPath "C:\custom\settings.json"
    Targets a specific settings.json file.
#>

param(
    [string]$SettingsPath,
    [switch]$Enable,
    [switch]$Disable,
    [switch]$Status
)

# ============================================================
# Determine mode: default to Enable if no flag specified
# ============================================================
if (-not ($Enable -or $Disable -or $Status)) {
    $Enable = $true
}

$settingKey = "github.copilot.chat.otel.captureContent"

# ============================================================
# Resolve settings.json path
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
        $targetPath = $stablePath
    }
}

# ============================================================
# Check if VS Code is running
# ============================================================
$vsCodeRunning = $false
$vsCodeProcess = Get-Process "Code" -ErrorAction SilentlyContinue
if ($vsCodeProcess) {
    $vsCodeRunning = $true
}

# ============================================================
# Read settings.json content
# ============================================================
$fileExists = Test-Path $targetPath -PathType Leaf

if ($fileExists) {
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
# Detect current state of the setting
# ============================================================
$escapedKey = [regex]::Escape($settingKey)
$currentlyEnabled = $false
$keyPresent = $false

if ($content -match '"' + $escapedKey + '"\s*:\s*(true|false)') {
    $keyPresent = $true
    $currentlyEnabled = ($Matches[1] -eq 'true')
} elseif ($content -match '"' + $escapedKey + '"\s*:\s*("[^"]*")') {
    # String value — treat non-empty as true-ish
    $keyPresent = $true
    $currentlyEnabled = $true
}

# Also check environment variable (takes precedence per VS Code docs)
$envCapture = $env:COPILOT_OTEL_CAPTURE_CONTENT
$envOverride = $false
if ($envCapture -ne $null) {
    $envOverride = $true
    $currentlyEnabled = ($envCapture -eq 'true' -or $envCapture -eq '1')
}

# ============================================================
# Status mode: just report and exit
# ============================================================
if ($Status) {
    Write-Host ""
    Write-Host "=== Copilot Content Capture Status ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Settings file: $targetPath"
    Write-Host ""

    if ($envOverride) {
        Write-Host "  Environment variable: COPILOT_OTEL_CAPTURE_CONTENT=$envCapture" -ForegroundColor Yellow
        Write-Host "  (environment variables take precedence over settings.json)"
    }

    if ($currentlyEnabled) {
        Write-Host "  Content capture: ENABLED" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Full prompt messages (gen_ai.input.messages) are being captured."
        Write-Host "  Use copilot-stats.ps1 to inspect request content."
        Write-Host ""
        Write-Host "  WARNING: Content includes code, file contents, and user prompts." -ForegroundColor Yellow
    } else {
        Write-Host "  Content capture: DISABLED" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Only token counts and metadata are captured."
        Write-Host "  Run '.\setup-content-capture.ps1' to enable full prompt capture."
    }

    if ($keyPresent -and -not $envOverride) {
        Write-Host ""
        Write-Host "  (controlled by settings.json key: $settingKey)"
    }

    Write-Host ""
    exit 0
}

# ============================================================
# Determine target value
# ============================================================
if ($Enable) {
    $targetValue = $true
    $actionVerb = "Enabling"
    $actionColor = "Green"
} else {
    $targetValue = $false
    $actionVerb = "Disabling"
    $actionColor = "Yellow"
}

# ============================================================
# Skip if already in desired state
# ============================================================
if ($currentlyEnabled -eq $targetValue) {
    $stateWord = if ($targetValue) { "enabled" } else { "disabled" }
    Write-Host ""
    Write-Host "=== Copilot Content Capture Setup ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Settings file: $targetPath"
    Write-Host ""
    Write-Host "  Content capture is already $stateWord. Nothing to do." -ForegroundColor Green
    Write-Host ""
    exit 0
}

# ============================================================
# Validate JSON structure
# ============================================================
$lastBraceIdx = $content.LastIndexOf('}')
if ($lastBraceIdx -lt 0) {
    Write-Error "settings.json appears malformed: no closing brace '}' found. Aborting."
    exit 1
}

try {
    $null = $content | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Warning "settings.json does not parse as strict JSON (likely contains JSONC comments). Proceeding with text-based approach."
}

# ============================================================
# Create backup before modifying
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
# Apply the change (JSONC-safe)
# ============================================================
$jsonValue = $targetValue.ToString().ToLower()
$indent = "    "

if ($keyPresent) {
    # Replace existing value in-place
    $pattern = '("' + $escapedKey + '"\s*:\s*)(true|false|"[^"]*")'
    $content = $content -replace $pattern, "`$1$jsonValue"
    $newContent = $content
} else {
    # Insert new key before closing brace
    $newLine = "$indent`"$settingKey`": $jsonValue"
    $beforeBrace = $content.Substring(0, $lastBraceIdx)
    $afterBrace = $content.Substring($lastBraceIdx + 1)

    if ($content.Trim() -eq '{}') {
        $newContent = "{`n$newLine`n}`n"
    } else {
        $trimmedBefore = $beforeBrace.TrimEnd()
        $effectiveLastChar = if ($trimmedBefore.Length -gt 0) {
            $trimmedBefore.Substring($trimmedBefore.Length - 1, 1)
        } else { '' }

        if ($effectiveLastChar -eq ',' -or $effectiveLastChar -eq '{') {
            $newContent = $beforeBrace + "`n$newLine`n}$afterBrace"
        } else {
            $newContent = $beforeBrace.TrimEnd() + ",`n$newLine`n}$afterBrace"
        }
    }
}

# ============================================================
# Write modified content back
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
# Report results
# ============================================================
$stateWord = if ($targetValue) { "ENABLED" } else { "DISABLED" }

Write-Host ""
Write-Host "=== Copilot Content Capture Setup ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Settings file: $targetPath"
Write-Host ""
Write-Host "  Content capture: $stateWord" -ForegroundColor $actionColor
Write-Host "  Key set: $settingKey = $jsonValue"
Write-Host ""

if ($backupPath) {
    Write-Host "Backup saved: $backupPath"
} else {
    Write-Host "Settings file was newly created (no backup needed)."
}

Write-Host ""

if ($targetValue) {
    Write-Host "WARNING: Content capture includes sensitive information:" -ForegroundColor Yellow
    Write-Host "  - Full source code from open files"
    Write-Host "  - Complete conversation history"
    Write-Host "  - User prompts and LLM responses"
    Write-Host "  - Tool call arguments and results"
    Write-Host ""
    Write-Host "Only use this in trusted environments. Disable when done with:" -ForegroundColor Yellow
    Write-Host "  .\setup-content-capture.ps1 -Disable"
} else {
    Write-Host "Content capture disabled. Token counts and metadata are still tracked."
    Write-Host "Re-enable with: .\setup-content-capture.ps1"
}

Write-Host ""

if ($vsCodeRunning) {
    Write-Host "Note: Restart VS Code to ensure content capture setting takes effect." -ForegroundColor Yellow
    Write-Host ""
}
