<#
.SYNOPSIS
    Analyze Copilot Chat OpenTelemetry SQLite export and produce usage stats with cost estimates.

.DESCRIPTION
    Queries the SQLite database exported by VS Code "Chat: Export Agent Traces DB"
    command and produces session, daily, weekly, monthly, or cost reports.
    Uses Python's built-in sqlite3 module for database access (zero additional installs).
    Applies pricing from model-pricing.json to estimate costs in USD and AI credits.

.PARAMETER DbPath
    Path to the exported SQLite database file (required).

.PARAMETER Sessions
    Output per-session breakdown with token counts, model, duration, and cost.

.PARAMETER Daily
    Aggregate sessions by calendar date (default mode).

.PARAMETER Weekly
    Aggregate sessions by ISO week.

.PARAMETER Monthly
    Aggregate sessions by calendar month.

.PARAMETER Cost
    Output cost breakdown by model with pricing tier applied.

.PARAMETER OutputFile
    Optional path to save the JSON report.

.PARAMETER Period
    Filter results to a specific period matching the mode format:
    Daily: "2026-06-06", Weekly: "2026-W23", Monthly: "2026-06"

.EXAMPLE
    .\copilot-stats.ps1 -DbPath agent-traces.db -Daily

.EXAMPLE
    .\copilot-stats.ps1 -DbPath agent-traces.db -Sessions -OutputFile sessions.json

.EXAMPLE
    .\copilot-stats.ps1 -DbPath agent-traces.db -Daily -Period "2026-06-06"
    Show stats for a specific date only.

.EXAMPLE
    .\copilot-stats.ps1 -DbPath agent-traces.db -Weekly -Period "2026-W23"
    Show stats for ISO week 23 of 2026.

.EXAMPLE
    .\copilot-stats.ps1 -DbPath agent-traces.db -Monthly -Period "2026-06"
    Show stats for June 2026 only.

.EXAMPLE
    .\copilot-stats.ps1 -DbPath agent-traces.db -Cost
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$DbPath,

    [switch]$Sessions,
    [switch]$Daily,
    [switch]$Weekly,
    [switch]$Monthly,
    [switch]$Cost,

    [string]$OutputFile,

    [string]$Period
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ============================================================
# Default mode: Daily if nothing specified
# ============================================================
if (-not ($Sessions -or $Daily -or $Weekly -or $Monthly -or $Cost)) {
    $Daily = $true
}

# ============================================================
# Validation: Python available
# ============================================================
$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
if (-not $pythonCmd) {
    $pythonCmd = Get-Command python3 -ErrorAction SilentlyContinue
}
if (-not $pythonCmd) {
    Write-Error "Python 3 is required but not found on PATH. Install Python or add it to PATH."
    exit 1
}

# ============================================================
# Validation: DB file exists
# ============================================================
if (-not (Test-Path $DbPath -PathType Leaf)) {
    Write-Error "Database file not found: $DbPath"
    exit 1
}
$resolvedDbPath = (Resolve-Path $DbPath).ProviderPath

# ============================================================
# Load pricing model
# ============================================================
$pricingPath = Join-Path $scriptDir "model-pricing.json"
$pricing = $null
if (Test-Path $pricingPath) {
    try {
        $pricing = Get-Content $pricingPath -Raw | ConvertFrom-Json
    } catch {
        Write-Warning "model-pricing.json is malformed: $_"
        Write-Warning "Cost estimates will be unavailable."
        $pricing = $null
    }
} else {
    Write-Warning "model-pricing.json not found at $pricingPath"
    Write-Warning "Cost estimates will be unavailable."
}

# ============================================================
# Helper: Invoke Python with SQL query, return parsed JSON
# ============================================================
function Invoke-SqliteQuery {
    param(
        [string]$Sql,
        [string]$Db
    )

    $tempPy = [System.IO.Path]::GetTempFileName() + ".py"

    $pythonCode = @"
import sqlite3, json, sys
try:
    conn = sqlite3.connect(r'$Db')
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    cur.execute(r'''$Sql''')
    rows = [dict(r) for r in cur.fetchall()]
    print(json.dumps(rows, default=str))
except Exception as ex:
    print(json.dumps({"error": str(ex)}))
    sys.exit(1)
"@

    try {
        Set-Content -Path $tempPy -Value $pythonCode -Encoding UTF8
        $result = & $pythonCmd.Source $tempPy 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Python query failed: $result"
            return $null
        }
        $parsed = $result | ConvertFrom-Json
        if ($parsed -is [array] -and $parsed.Count -eq 1 -and $parsed[0].error) {
            Write-Error "SQLite error: $($parsed[0].error)"
            return $null
        }
        return $parsed
    } finally {
        Remove-Item $tempPy -ErrorAction SilentlyContinue
    }
}

# ============================================================
# Validate DB schema
# ============================================================
$tableCheck = Invoke-SqliteQuery -Sql "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name" -Db $resolvedDbPath
if (-not $tableCheck) {
    Write-Error "Failed to read database schema. Is this a valid SQLite file?"
    exit 1
}

$tableNames = $tableCheck | ForEach-Object { $_.name }
if ('spans' -notin $tableNames) {
    Write-Error "Database does not contain a 'spans' table. Is this a Copilot OTel export?"
    exit 1
}

$rowCount = Invoke-SqliteQuery -Sql "SELECT COUNT(*) AS cnt FROM spans" -Db $resolvedDbPath
if (-not $rowCount -or [int]$rowCount[0].cnt -eq 0) {
    Write-Host '{ "report_type": "empty", "message": "No data found in database", "db_path": "' + $resolvedDbPath + '" }'
    exit 0
}

# Check expected columns
$cols = Invoke-SqliteQuery -Sql "PRAGMA table_info('spans')" -Db $resolvedDbPath
$colNames = $cols | ForEach-Object { $_.name }
$expectedCols = @('name', 'start_time_ms', 'request_model', 'agent_name', 'input_tokens', 'output_tokens')
$missingCols = $expectedCols | Where-Object { $_ -notin $colNames }
if ($missingCols) {
    Write-Warning "Missing expected columns in spans table: $($missingCols -join ', ')"
    Write-Warning "Some reports may be incomplete."
}

# ============================================================
# Build filter clause for internal overhead
# ============================================================
$filterClause = ""
if ($pricing) {
    $internalAgents = @()
    $internalModels = @()
    if ($pricing.internal_agents) { $internalAgents = $pricing.internal_agents }
    if ($pricing.internal_models) { $internalModels = $pricing.internal_models }

    $conditions = @()
    if ($internalAgents.Count -gt 0) {
        $quotedAgents = $internalAgents | ForEach-Object { "'" + $_ + "'" }
        $conditions += "agent_name NOT IN ($($quotedAgents -join ', '))"
    }
    if ($internalModels.Count -gt 0) {
        $quotedModels = $internalModels | ForEach-Object { "'" + $_ + "'" }
        $conditions += "request_model NOT IN ($($quotedModels -join ', '))"
    }
    # Also exclude embeddings
    $conditions += "name NOT LIKE 'embeddings%'"

    if ($conditions.Count -gt 0) {
        $filterClause = "WHERE " + ($conditions -join " AND ")
    }
}

# ============================================================
# Pricing lookup helper
# ============================================================
function Get-PriceInfo {
    param([string]$OtelModelId, [int]$InputTokens = 0)

    if (-not $pricing) { return $null }

    # Check aliases first
    $pricingKey = $OtelModelId
    if ($pricing.aliases -and $pricing.aliases.PSObject.Properties[$OtelModelId]) {
        $aliasVal = $pricing.aliases.PSObject.Properties[$OtelModelId].Value
        if ($null -eq $aliasVal -or $aliasVal -eq '') {
            return $null  # explicitly excluded
        }
        $pricingKey = $aliasVal
    }

    if (-not $pricing.models.PSObject.Properties[$pricingKey]) {
        return $null
    }

    $modelPricing = $pricing.models.PSObject.Properties[$pricingKey].Value

    # Check for tiered pricing
    if ($modelPricing.PSObject.Properties['tiers']) {
        $tiers = @($modelPricing.tiers | Sort-Object { [int]$_.threshold })
        foreach ($tier in $tiers) {
            if ($InputTokens -le [int]$tier.threshold) {
                return $tier
            }
        }
        # Fallback: return last tier if none matched
        return $tiers[-1]
    }

    # Flat pricing (backward compatible)
    return $modelPricing
}

function Get-Cost {
    param($Pricing, $InTokens, $OutTokens, $CacheTok, $CacheWriteTok)

    if (-not $Pricing) { return $null }

    $tokensIn = [double]$InTokens
    $tokensOut = [double]$OutTokens
    $tokensCache = [double]$CacheTok
    $tokensCacheWrite = [double]$CacheWriteTok

    # Clamp cache to input (cache is a subset, not additive)
    $effectiveCache = [math]::Min($tokensCache, $tokensIn)
    $uncachedInput = $tokensIn - $effectiveCache

    $inCost = $uncachedInput / 1000000.0 * [double]$Pricing.input
    $outCost = $tokensOut / 1000000.0 * [double]$Pricing.output

    $cacheCost = 0.0
    if ($Pricing.cache_input -and $effectiveCache -gt 0) {
        $cacheCost = $effectiveCache / 1000000.0 * [double]$Pricing.cache_input
    }

    $cacheWriteCost = 0.0
    if ($Pricing.cache_write -and $tokensCacheWrite -gt 0) {
        $cacheWriteCost = $tokensCacheWrite / 1000000.0 * [double]$Pricing.cache_write
    }

    $totalUsd = $inCost + $outCost + $cacheCost + $cacheWriteCost
    $rate = [double]$script:pricing.credit_usd_rate
    $totalCredits = if ($rate -gt 0) { $totalUsd / $rate } else { 0.0 }

    return [PSCustomObject]@{
        usd     = [math]::Round($totalUsd, 4)
        credits = [math]::Round($totalCredits, 2)
    }
}

function Format-ModelName {
    param([string]$OtelId)
    if (-not $pricing) { return $OtelId }
    if ($pricing.aliases -and $pricing.aliases.PSObject.Properties[$OtelId]) {
        $aliasVal = $pricing.aliases.PSObject.Properties[$OtelId].Value
        if ($aliasVal) { return $aliasVal }
    }
    return $OtelId
}

# ============================================================
# Determine mode name for metadata
# ============================================================
$modeName = "daily"
if ($Sessions) { $modeName = "sessions" }
if ($Weekly)   { $modeName = "weekly" }
if ($Monthly)  { $modeName = "monthly" }
if ($Cost)     { $modeName = "cost" }

# ============================================================
# Generate report
# ============================================================
$report = [ordered]@{
    report_type  = $modeName
    generated_at = (Get-Date).ToString('o')
    db_path      = $resolvedDbPath
    data         = @()
}

if ($Sessions) {
    # Per-session breakdown from invoke_agent spans
    $sql = @"
SELECT
    s.span_id,
    s.agent_name,
    s.request_model,
    s.start_time_ms,
    s.end_time_ms,
    s.conversation_id,
    COALESCE(
        (SELECT value FROM span_attributes WHERE span_id = s.span_id AND key = 'copilot_chat.turn_count'),
        '0'
    ) AS turn_count
FROM spans s
$filterClause
  AND s.name LIKE 'invoke_agent%'
ORDER BY s.start_time_ms
"@
    $agentSpans = Invoke-SqliteQuery -Sql $sql -Db $resolvedDbPath
    if (-not $agentSpans) { $agentSpans = @() }

    $sessionData = @()
    foreach ($span in $agentSpans) {
        $sid = $span.span_id
        $attrSql = "SELECT key, value FROM span_attributes WHERE span_id = '$sid' AND key IN ('gen_ai.usage.input_tokens', 'gen_ai.usage.output_tokens', 'gen_ai.usage.cache_read.input_tokens', 'gen_ai.usage.cache_creation.input_tokens', 'copilot_chat.user_request')"
        $attrs = Invoke-SqliteQuery -Sql $attrSql -Db $resolvedDbPath

        $inputTokens = 0; $outputTokens = 0; $cacheTokens = 0; $cacheWriteTokens = 0
        $userRequest = ""
        if ($attrs) {
            foreach ($a in $attrs) {
                switch ($a.key) {
                    'gen_ai.usage.input_tokens'            { $inputTokens = [int]$a.value }
                    'gen_ai.usage.output_tokens'           { $outputTokens = [int]$a.value }
                    'gen_ai.usage.cache_read.input_tokens'  { $cacheTokens = [int]$a.value }
                    'gen_ai.usage.cache_creation.input_tokens' { $cacheWriteTokens = [int]$a.value }
                    'copilot_chat.user_request'            { $userRequest = $a.value }
                }
            }
        }

        # Build session summary from first line of user request
        $summary = "(no summary)"
        if ($userRequest) {
            $firstLine = ($userRequest -split '\n')[0].Trim()
            if ($firstLine.Length -gt 0) {
                if ($firstLine.Length -gt 120) {
                    $summary = $firstLine.Substring(0, 120) + "..."
                } else {
                    $summary = $firstLine
                }
            }
        }

        $modelName = Format-ModelName -OtelId $span.request_model
        $priceInfo = Get-PriceInfo -OtelModelId $span.request_model -InputTokens $inputTokens
        $c = Get-Cost -Pricing $priceInfo -InTokens $inputTokens -OutTokens $outputTokens -CacheTok $cacheTokens -CacheWriteTok $cacheWriteTokens
        $durationSec = if ($span.end_time_ms -and $span.start_time_ms) { [math]::Round(([double]$span.end_time_ms - [double]$span.start_time_ms) / 1000.0, 1) } else { 0 }

        $ts = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$span.start_time_ms)

        $sessionData += [ordered]@{
            timestamp       = $ts.ToString('o')
            date            = $ts.ToString('yyyy-MM-dd')
            agent           = $span.agent_name
            model           = $modelName
            model_raw       = $span.request_model
            duration_sec    = $durationSec
            turns           = [int]$span.turn_count
            input_tokens    = $inputTokens
            output_tokens   = $outputTokens
            cache_tokens    = $cacheTokens
            cache_write_tokens = $cacheWriteTokens
            cost_usd        = if ($c) { $c.usd } else { $null }
            cost_credits    = if ($c) { $c.credits } else { $null }
            conversation_id = $span.conversation_id
            session_summary = $summary
        }
    }
    $report.data = $sessionData
}
elseif ($Cost) {
    # Cost breakdown by model — per-span processing with span_attributes
    $sql = @"
SELECT span_id, request_model
FROM spans
$filterClause
  AND name LIKE 'chat%'
"@
    $chatSpans = Invoke-SqliteQuery -Sql $sql -Db $resolvedDbPath
    if (-not $chatSpans) { $chatSpans = @() }

    # Aggregate per-span costs by model
    $modelAgg = @{}
    foreach ($span in $chatSpans) {
        $sid = $span.span_id
        $attrSql = "SELECT key, value FROM span_attributes WHERE span_id = '$sid' AND key IN ('gen_ai.usage.input_tokens', 'gen_ai.usage.output_tokens', 'gen_ai.usage.cache_read.input_tokens', 'gen_ai.usage.cache_creation.input_tokens')"
        $attrs = Invoke-SqliteQuery -Sql $attrSql -Db $resolvedDbPath

        $inputTokens = 0; $outputTokens = 0; $cacheTokens = 0; $cacheWriteTokens = 0
        if ($attrs) {
            foreach ($a in $attrs) {
                switch ($a.key) {
                    'gen_ai.usage.input_tokens'            { $inputTokens = [int]$a.value }
                    'gen_ai.usage.output_tokens'           { $outputTokens = [int]$a.value }
                    'gen_ai.usage.cache_read.input_tokens'  { $cacheTokens = [int]$a.value }
                    'gen_ai.usage.cache_creation.input_tokens' { $cacheWriteTokens = [int]$a.value }
                }
            }
        }

        $modelKey = $span.request_model
        if (-not $modelAgg.ContainsKey($modelKey)) {
            $modelAgg[$modelKey] = @{
                calls        = 0
                input        = 0
                output       = 0
                cache        = 0
                cache_write  = 0
                cost_usd     = 0.0
                cost_credits = 0.0
            }
        }
        $agg = $modelAgg[$modelKey]
        $agg.calls++
        $agg.input += $inputTokens
        $agg.output += $outputTokens
        $agg.cache += $cacheTokens
        $agg.cache_write += $cacheWriteTokens

        $priceInfo = Get-PriceInfo -OtelModelId $span.request_model -InputTokens $inputTokens
        $c = Get-Cost -Pricing $priceInfo -InTokens $inputTokens -OutTokens $outputTokens -CacheTok $cacheTokens -CacheWriteTok $cacheWriteTokens
        if ($c) { $agg.cost_usd += $c.usd; $agg.cost_credits += $c.credits }
    }

    $costData = @()
    $grandInput = 0; $grandOutput = 0; $grandCache = 0; $grandCacheWrite = 0; $grandUsd = 0.0; $grandCredits = 0.0
    foreach ($modelKey in ($modelAgg.Keys | Sort-Object { $modelAgg[$_].input } -Descending)) {
        $agg = $modelAgg[$modelKey]
        $modelName = Format-ModelName -OtelId $modelKey
        # Use Get-PriceInfo without input tokens just to check if priced
        $priceCheck = Get-PriceInfo -OtelModelId $modelKey

        $grandInput += $agg.input
        $grandOutput += $agg.output
        $grandCache += $agg.cache
        $grandCacheWrite += $agg.cache_write
        $grandUsd += $agg.cost_usd
        $grandCredits += $agg.cost_credits

        $costData += [ordered]@{
            model              = $modelName
            model_raw          = $modelKey
            calls              = $agg.calls
            input_tokens       = $agg.input
            output_tokens      = $agg.output
            cache_tokens       = $agg.cache
            cache_write_tokens = $agg.cache_write
            cost_usd           = [math]::Round($agg.cost_usd, 4)
            cost_credits       = [math]::Round($agg.cost_credits, 2)
            priced             = ($priceCheck -ne $null)
        }
    }

    $report.data = $costData
    $report.totals = [ordered]@{
        input_tokens        = $grandInput
        output_tokens       = $grandOutput
        cache_tokens        = $grandCache
        cache_write_tokens  = $grandCacheWrite
        cost_usd            = [math]::Round($grandUsd, 4)
        cost_credits        = [math]::Round($grandCredits, 2)
    }
}
else {
    # Daily / Weekly / Monthly aggregation — per-span processing
    $groupLabel = "date"
    if ($Weekly) { $groupLabel = "week" }
    elseif ($Monthly) { $groupLabel = "month" }

    # Get individual invoke_agent spans
    $sql = @"
SELECT span_id, request_model, start_time_ms
FROM spans s
$filterClause
  AND s.name LIKE 'invoke_agent%'
ORDER BY start_time_ms
"@
    $agentSpans = Invoke-SqliteQuery -Sql $sql -Db $resolvedDbPath
    if (-not $agentSpans) { $agentSpans = @() }

    # Compute period string for a timestamp
    function Get-Period {
        param([long]$StartTimeMs)
        $dt = [DateTimeOffset]::FromUnixTimeMilliseconds($StartTimeMs)
        if ($Weekly) {
            # ISO week: year + '-W' + week number
            $cal = [System.Globalization.CultureInfo]::InvariantCulture.Calendar
            $week = $cal.GetWeekOfYear($dt.DateTime, [System.Globalization.CalendarWeekRule]::FirstFourDayWeek, [System.DayOfWeek]::Monday)
            # Adjust year for weeks that span Dec/Jan
            if ($week -ge 52 -and $dt.Month -eq 1) { $year = $dt.Year - 1 }
            elseif ($week -eq 1 -and $dt.Month -eq 12) { $year = $dt.Year + 1 }
            else { $year = $dt.Year }
            return "$year-W$($week.ToString('00'))"
        }
        elseif ($Monthly) {
            return $dt.ToString('yyyy-MM')
        }
        else {
            return $dt.ToString('yyyy-MM-dd')
        }
    }

    # Aggregate per-span costs by period, then by model
    $periods = [ordered]@{}
    foreach ($span in $agentSpans) {
        $period = Get-Period -StartTimeMs ([long]$span.start_time_ms)

        # Apply period filter if specified
        if ($Period -and $period -ne $Period) { continue }

        $sid = $span.span_id
        $attrSql = "SELECT key, value FROM span_attributes WHERE span_id = '$sid' AND key IN ('gen_ai.usage.input_tokens', 'gen_ai.usage.output_tokens', 'gen_ai.usage.cache_read.input_tokens', 'gen_ai.usage.cache_creation.input_tokens')"
        $attrs = Invoke-SqliteQuery -Sql $attrSql -Db $resolvedDbPath

        $inputTokens = 0; $outputTokens = 0; $cacheTokens = 0; $cacheWriteTokens = 0
        if ($attrs) {
            foreach ($a in $attrs) {
                switch ($a.key) {
                    'gen_ai.usage.input_tokens'            { $inputTokens = [int]$a.value }
                    'gen_ai.usage.output_tokens'           { $outputTokens = [int]$a.value }
                    'gen_ai.usage.cache_read.input_tokens'  { $cacheTokens = [int]$a.value }
                    'gen_ai.usage.cache_creation.input_tokens' { $cacheWriteTokens = [int]$a.value }
                }
            }
        }

        # Ensure period entry exists
        if (-not $periods.Contains($period)) {
            $periods[$period] = [ordered]@{
                $groupLabel  = $period
                sessions     = 0
                total_input  = 0
                total_output = 0
                total_cache  = 0
                total_cache_write = 0
                cost_usd     = 0.0
                cost_credits = 0.0
                modelAgg     = @{}
            }
        }
        $p = $periods[$period]
        $p.sessions++
        $p.total_input += $inputTokens
        $p.total_output += $outputTokens
        $p.total_cache += $cacheTokens
        $p.total_cache_write += $cacheWriteTokens

        # Aggregate by model within period
        $modelKey = $span.request_model
        if (-not $p.modelAgg.ContainsKey($modelKey)) {
            $p.modelAgg[$modelKey] = @{
                sessions     = 0
                input        = 0
                output       = 0
                cache        = 0
                cache_write  = 0
                cost_usd     = 0.0
                cost_credits = 0.0
            }
        }
        $ma = $p.modelAgg[$modelKey]
        $ma.sessions++
        $ma.input += $inputTokens
        $ma.output += $outputTokens
        $ma.cache += $cacheTokens
        $ma.cache_write += $cacheWriteTokens

        $priceInfo = Get-PriceInfo -OtelModelId $span.request_model -InputTokens $inputTokens
        $c = Get-Cost -Pricing $priceInfo -InTokens $inputTokens -OutTokens $outputTokens -CacheTok $cacheTokens -CacheWriteTok $cacheWriteTokens
        if ($c) { $ma.cost_usd += $c.usd; $ma.cost_credits += $c.credits }
    }

    # Build output from aggregated data
    foreach ($period in $periods.Keys) {
        $p = $periods[$period]
        $p.cost_usd = 0.0; $p.cost_credits = 0.0
        $p.models = @()

        foreach ($modelKey in ($p.modelAgg.Keys | Sort-Object { $p.modelAgg[$_].input } -Descending)) {
            $ma = $p.modelAgg[$modelKey]
            $p.cost_usd += $ma.cost_usd
            $p.cost_credits += $ma.cost_credits

            $p.models += [ordered]@{
                model              = Format-ModelName -OtelId $modelKey
                model_raw          = $modelKey
                sessions           = $ma.sessions
                input_tokens       = $ma.input
                output_tokens      = $ma.output
                cache_tokens       = $ma.cache
                cache_write_tokens = $ma.cache_write
                cost_usd           = [math]::Round($ma.cost_usd, 4)
                cost_credits       = [math]::Round($ma.cost_credits, 2)
            }
        }

        $p.cost_usd = [math]::Round($p.cost_usd, 4)
        $p.cost_credits = [math]::Round($p.cost_credits, 2)
        $p.Remove('modelAgg')
    }

    $report.data = @($periods.Values)
}

# ============================================================
# Output
# ============================================================
$json = $report | ConvertTo-Json -Depth 8

if ($OutputFile) {
    Set-Content -Path $OutputFile -Value $json -Encoding UTF8
    Write-Host "Report saved to: $OutputFile"
}

Write-Host $json
