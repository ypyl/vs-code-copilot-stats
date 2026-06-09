# VS Code Copilot Stats

Track GitHub Copilot usage and costs from VS Code's built-in OpenTelemetry exporter. Zero cloud dependencies — everything runs locally.

## How it works

```
  VS Code                    Your machine                   Output
  ───────                    ────────────                   ──────
  Copilot Chat ──▶ SQLite DB ──▶ Export .db ──▶ copilot-stats.ps1 ──▶ JSON report
  (auto)           (internal)     (one click)     (this tool)          with costs
```

1. **`setup-otel.ps1`** — enables Copilot's built-in OTel SQLite exporter (one-time)
2. Use Copilot normally
3. **Ctrl+Shift+P → "Chat: Export Agent Traces DB"** — saves a `.db` file
4. **`copilot-stats.ps1`** — queries the DB and produces usage/cost reports

## Quick start

```powershell
# 1. Enable OTel (one-time)
.\setup-otel.ps1

# 2. Use Copilot, then export the DB
#    Ctrl+Shift+P → type "Export Agent Traces" → save .db file

# 3. Get stats
.\copilot-stats.ps1 -DbPath agent-traces.db -Daily
.\copilot-stats.ps1 -DbPath agent-traces.db -Sessions
.\copilot-stats.ps1 -DbPath agent-traces.db -Cost

# Optional: enable full prompt capture to inspect LLM request content
.\setup-content-capture.ps1
```

## Commands

### `setup-otel.ps1`

Enables the Copilot SQLite span exporter in VS Code settings. Cleans up any stale file-exporter settings from prior setups.

```powershell
.\setup-otel.ps1
.\setup-otel.ps1 -SettingsPath "C:\custom\settings.json"
```

### `copilot-stats.ps1`

Queries an exported `.db` file and produces JSON reports.

```powershell
# Per-session breakdown (token counts, model, duration, cost per session)
.\copilot-stats.ps1 -DbPath agent-traces.db -Sessions

# Daily aggregation (default mode)
.\copilot-stats.ps1 -DbPath agent-traces.db -Daily

# Weekly / Monthly aggregation
.\copilot-stats.ps1 -DbPath agent-traces.db -Weekly
.\copilot-stats.ps1 -DbPath agent-traces.db -Monthly

# Filter to a specific period
.\copilot-stats.ps1 -DbPath agent-traces.db -Daily -Period "2026-06-06"
.\copilot-stats.ps1 -DbPath agent-traces.db -Weekly -Period "2026-W23"
.\copilot-stats.ps1 -DbPath agent-traces.db -Monthly -Period "2026-06"

# Cost breakdown by model
.\copilot-stats.ps1 -DbPath agent-traces.db -Cost

# Export full LLM prompt content (requires content capture enabled)
.\copilot-stats.ps1 -DbPath agent-traces.db -Prompts
.\copilot-stats.ps1 -DbPath agent-traces.db -Prompts -OutputFile prompts.json

# Save report to file
.\copilot-stats.ps1 -DbPath agent-traces.db -Daily -OutputFile report.json

# Limit results (applied at SQL level — most recent N records, top N by tokens for -Cost)
.\copilot-stats.ps1 -DbPath agent-traces.db -Sessions -TopN 10
.\copilot-stats.ps1 -DbPath agent-traces.db -Cost -TopN 5
.\copilot-stats.ps1 -DbPath agent-traces.db -Prompts -TopN 3
```

## Example output

### Sessions mode
```json
{
  "report_type": "sessions",
  "data": [
    {
      "date": "2026-06-06",
      "model": "raptor-mini",
      "input_tokens": 50550,
      "output_tokens": 859,
      "cache_tokens": 38000,
      "cache_write_tokens": 0,
      "duration_sec": 18.0,
      "turns": 2,
      "cost_usd": 0.015,
      "cost_credits": 1.50
    }
  ]
}
```

### Prompts mode
```json
{
  "report_type": "prompts",
  "data": [
    {
      "date": "2026-06-06",
      "model": "raptor-mini",
      "input_tokens": 50550,
      "output_tokens": 859,
      "cache_tokens": 38000,
      "cache_write_tokens": 0,
      "cost_usd": 0.0044,
      "cost_credits": 0.44,
      "session_summary": "Debug auth flow",
      "content_available": true,
      "content_chars": 184320,
      "prompt_content": "[full LLM prompt text — system messages, context, history, user request]"
    }
  ],
  "summary": {
    "total_sessions": 12,
    "sessions_with_content": 8,
    "sessions_without_content": 4,
    "note": "Content capture must be enabled (setup-content-capture.ps1) for prompt_content to appear."
  }
}
```

### Cost mode
```json
{
  "report_type": "cost",
  "data": [
    {
      "model": "raptor-mini",
      "calls": 23,
      "input_tokens": 1119304,
      "output_tokens": 16609,
      "cache_tokens": 450000,
      "cache_write_tokens": 0,
      "cost_usd": 0.3384,
      "cost_credits": 33.84
    }
  ],
  "totals": {
    "input_tokens": 1119304,
    "output_tokens": 16609,
    "cache_tokens": 450000,
    "cache_write_tokens": 0,
    "cost_usd": 0.3384,
    "cost_credits": 33.84
  }
}
```

## What gets tracked

| Metric | Source |
|--------|--------|
| Token usage (input/output/cache/cache_write) | `invoke_agent` and `chat` spans |
| Full LLM prompt content | `gen_ai.input.messages` attribute (content capture required) |
| Models used | `gen_ai.request.model` |
| Sessions per day/week/month | `invoke_agent` spans grouped by date |
| Turn count per session | `copilot_chat.turn_count` attribute |
| Agent duration | `start_time_ms` → `end_time_ms` |
| Tool calls | `execute_tool` spans |
| Estimated cost | Calculated from `model-pricing.json` |

## What gets filtered out

Copilot runs internal operations that aren't billed to you. These are automatically excluded:

- **Session naming** (`title`)
- **Progress messages** (`progressMessages`)
- **Context summarization** (`summarizeVirtualTools`)
- **Semantic search embeddings** (`text-embedding-3-small-512`)
- **Internal model calls** (`gpt-4o-mini-2024-07-18`)

## Pricing model

`model-pricing.json` contains per-million-token rates for all GitHub Copilot models across 5 providers (OpenAI, Anthropic, Google, GitHub fine-tuned, Microsoft). 1 AI credit = $0.01 USD.

### Cost calculation

Cached input tokens are a **subset** of total input tokens, not additional. The cost formula is:

```
uncached_input = total_input - cached_input
cost = (uncached_input × input_rate + cached_input × cache_input_rate + output × output_rate + cache_write × cache_write_rate) / 1,000,000
```

Cache write tokens (Anthropic models only) are priced at the `cache_write` rate when present.

### Tiered pricing

GPT-5.4 and GPT-5.5 use tiered pricing based on input token count per request:

| Model | Tier | Threshold | Input | Cached Input | Output |
|-------|------|-----------|-------|-------------|--------|
| GPT-5.4 | Default | ≤ 272K | $2.50 | $0.25 | $15.00 |
| GPT-5.4 | Long context | > 272K | $5.00 | $0.50 | $22.50 |
| GPT-5.5 | Default | ≤ 272K | $5.00 | $0.50 | $30.00 |
| GPT-5.5 | Long context | > 272K | $10.00 | $1.00 | $45.00 |

Tiers are defined as an array of `{ threshold, input, cache_input, output }` objects in `model-pricing.json`. The tool selects the first tier where the request's input tokens ≤ threshold.

When GitHub updates pricing, edit this file. To map a new OTel model ID to a pricing entry, add it to the `aliases` section:

```json
{
  "aliases": {
    "oswe-vscode-prime": "raptor-mini",
    "some-new-model-id": "gpt-5.4-mini"
  }
}
```

## Requirements

- Windows with PowerShell 5.1+
- Python 3 with `sqlite3` (standard library, no pip install needed)
- VS Code with Copilot Chat extension

## Files

```
copilot-stats/
├── README.md
├── setup-otel.ps1              Enable OTel SQLite exporter in VS Code
├── setup-content-capture.ps1   Toggle full prompt/response capture
├── copilot-stats.ps1           Query exported DB, produce usage/cost reports
└── model-pricing.json          Rate card for all GitHub Copilot models
```
