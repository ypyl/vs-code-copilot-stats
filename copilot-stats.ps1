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
    param([string]$OtelModelId)

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

    if ($pricing.models.PSObject.Properties[$pricingKey]) {
        return $pricing.models.PSObject.Properties[$pricingKey].Value
    }
    return $null
}

function Get-Cost {
    param($Pricing, $InTokens, $OutTokens, $CacheTok)

    if (-not $Pricing) { return $null }

    $tokensIn = [double]$InTokens
    $tokensOut = [double]$OutTokens
    $tokensCache = [double]$CacheTok

    $inCost = $tokensIn / 1000000.0 * [double]$Pricing.input
    $outCost = $tokensOut / 1000000.0 * [double]$Pricing.output
    $cacheCost = 0.0
    if ($Pricing.cache_input -and $CacheTok) {
        $cacheCost = $tokensCache / 1000000.0 * [double]$Pricing.cache_input
    }
    $totalUsd = $inCost + $outCost + $cacheCost
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
        $attrSql = "SELECT key, value FROM span_attributes WHERE span_id = '$sid' AND key IN ('gen_ai.usage.input_tokens', 'gen_ai.usage.output_tokens', 'gen_ai.usage.cache_read.input_tokens', 'copilot_chat.user_request')"
        $attrs = Invoke-SqliteQuery -Sql $attrSql -Db $resolvedDbPath

        $inputTokens = 0; $outputTokens = 0; $cacheTokens = 0
        $userRequest = ""
        if ($attrs) {
            foreach ($a in $attrs) {
                switch ($a.key) {
                    'gen_ai.usage.input_tokens'           { $inputTokens = [int]$a.value }
                    'gen_ai.usage.output_tokens'          { $outputTokens = [int]$a.value }
                    'gen_ai.usage.cache_read.input_tokens' { $cacheTokens = [int]$a.value }
                    'copilot_chat.user_request'           { $userRequest = $a.value }
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
        $priceInfo = Get-PriceInfo -OtelModelId $span.request_model
        $c = Get-Cost -Pricing $priceInfo -InTokens $inputTokens -OutTokens $outputTokens -CacheTok $cacheTokens
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
            cost_usd        = if ($c) { $c.usd } else { $null }
            cost_credits    = if ($c) { $c.credits } else { $null }
            conversation_id = $span.conversation_id
            session_summary = $summary
        }
    }
    $report.data = $sessionData
}
elseif ($Cost) {
    # Cost breakdown by model — aggregate chat spans
    $sql = @"
SELECT
    request_model,
    SUM(COALESCE(input_tokens, 0)) AS total_input,
    SUM(COALESCE(output_tokens, 0)) AS total_output,
    SUM(COALESCE(cached_tokens, 0)) AS total_cache,
    COUNT(*) AS call_count
FROM spans
$filterClause
  AND name LIKE 'chat%'
GROUP BY request_model
ORDER BY total_input DESC
"@
    $modelRows = Invoke-SqliteQuery -Sql $sql -Db $resolvedDbPath
    if (-not $modelRows) { $modelRows = @() }

    $costData = @()
    $grandInput = 0; $grandOutput = 0; $grandCache = 0; $grandUsd = 0.0; $grandCredits = 0.0
    foreach ($r in $modelRows) {
        $modelName = Format-ModelName -OtelId $r.request_model
        $priceInfo = Get-PriceInfo -OtelModelId $r.request_model
        $c = Get-Cost -Pricing $priceInfo -InTokens $r.total_input -OutTokens $r.total_output -CacheTok $r.total_cache

        $grandInput += [int]$r.total_input
        $grandOutput += [int]$r.total_output
        $grandCache += [int]$r.total_cache
        if ($c) { $grandUsd += $c.usd; $grandCredits += $c.credits }

        $costData += [ordered]@{
            model        = $modelName
            model_raw    = $r.request_model
            calls        = [int]$r.call_count
            input_tokens = [int]$r.total_input
            output_tokens = [int]$r.total_output
            cache_tokens = [int]$r.total_cache
            cost_usd     = if ($c) { $c.usd } else { $null }
            cost_credits = if ($c) { $c.credits } else { $null }
            priced       = ($priceInfo -ne $null)
        }
    }

    $report.data = $costData
    $report.totals = [ordered]@{
        input_tokens  = $grandInput
        output_tokens = $grandOutput
        cache_tokens  = $grandCache
        cost_usd      = [math]::Round($grandUsd, 4)
        cost_credits  = [math]::Round($grandCredits, 2)
    }
}
else {
    # Daily / Weekly / Monthly aggregation
    $groupExpr = "date(start_time_ms / 1000, 'unixepoch')"
    $groupLabel = "date"
    if ($Weekly) {
        $groupExpr = "strftime('%G-W%V', start_time_ms / 1000, 'unixepoch')"
        $groupLabel = "week"
    } elseif ($Monthly) {
        $groupExpr = "strftime('%Y-%m', start_time_ms / 1000, 'unixepoch')"
        $groupLabel = "month"
    }

    # Get sessions aggregated by period
    $sql = "SELECT $groupExpr AS period, s.request_model, COUNT(*) AS session_count, SUM(COALESCE((SELECT value FROM span_attributes WHERE span_id = s.span_id AND key = 'gen_ai.usage.input_tokens'), '0')) AS total_input, SUM(COALESCE((SELECT value FROM span_attributes WHERE span_id = s.span_id AND key = 'gen_ai.usage.output_tokens'), '0')) AS total_output, SUM(COALESCE((SELECT value FROM span_attributes WHERE span_id = s.span_id AND key = 'gen_ai.usage.cache_read.input_tokens'), '0')) AS total_cache FROM spans s $filterClause AND s.name LIKE 'invoke_agent%' GROUP BY period, s.request_model"
    if ($Period) {
        $sql += " HAVING period = '$Period'"
    }
    $sql += " ORDER BY period, s.request_model"
    $aggRows = Invoke-SqliteQuery -Sql $sql -Db $resolvedDbPath
    if (-not $aggRows) { $aggRows = @() }

    # Group by period
    $periods = [ordered]@{}
    foreach ($r in $aggRows) {
        $period = $r.period
        if (-not $periods.Contains($period)) {
            $periods[$period] = @{
                $groupLabel = $period
                sessions    = 0
                models      = @()
                total_input  = 0
                total_output = 0
                total_cache  = 0
                cost_usd     = 0.0
                cost_credits = 0.0
            }
        }
        $p = $periods[$period]
        $p.sessions += [int]$r.session_count
        $p.total_input += [int]$r.total_input
        $p.total_output += [int]$r.total_output
        $p.total_cache += [int]$r.total_cache

        $priceInfo = Get-PriceInfo -OtelModelId $r.request_model
        $c = Get-Cost -Pricing $priceInfo -InTokens $r.total_input -OutTokens $r.total_output -CacheTok $r.total_cache
        if ($c) { $p.cost_usd += $c.usd; $p.cost_credits += $c.credits }

        $p.models += [ordered]@{
            model         = Format-ModelName -OtelId $r.request_model
            model_raw     = $r.request_model
            sessions      = [int]$r.session_count
            input_tokens  = [int]$r.total_input
            output_tokens = [int]$r.total_output
            cache_tokens  = [int]$r.total_cache
            cost_usd      = if ($c) { $c.usd } else { $null }
            cost_credits  = if ($c) { $c.credits } else { $null }
        }
    }

    foreach ($p in $periods.Values) {
        $p.cost_usd = [math]::Round($p.cost_usd, 4)
        $p.cost_credits = [math]::Round($p.cost_credits, 2)
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
