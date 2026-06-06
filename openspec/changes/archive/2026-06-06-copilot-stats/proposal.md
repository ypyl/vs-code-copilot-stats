## Why

After enabling Copilot OTel SQLite export via `setup-otel.ps1`, users have a `.db` file full of span data but no way to turn it into actionable stats. They need per-session token breakdowns, daily/weekly/monthly aggregation, and cost estimation against GitHub's published model pricing. A simple script that queries the SQLite DB and produces readable reports fills this gap.

## What Changes

- New PowerShell script `copilot-stats.ps1` that queries the exported SQLite database
- New `model-pricing.json` rate card mapping model IDs to per-token prices from GitHub's pricing page
- Script supports multiple report modes: per-session breakdown, daily/weekly/monthly aggregation, and cost analysis
- Uses Python's built-in `sqlite3` module for database queries (zero additional install on Windows dev machines)
- Filters out internal Copilot overhead calls (session naming, progress messages, context summarization, embeddings)
- Maps internal OTel model IDs (`oswe-vscode-prime`, `gpt-4o-mini-2024-07-18`) to friendly pricing names via the external pricing config

## Capabilities

### New Capabilities

- `copilot-stats`: SQLite-based Copilot usage analysis and cost estimation. Queries the exported `agent-traces.db`, extracts per-session token counts by model, computes daily/weekly/monthly aggregates, and estimates cost against the published GitHub Copilot pricing model. Outputs structured JSON for piping or saving.

### Modified Capabilities

None — this is a new tool with no existing capabilities to modify.

## Impact

- New file: `copilot-stats.ps1` (main script, ~250 lines)
- New file: `model-pricing.json` (rate card, ~50 lines, user-updatable)
- Depends on: Python 3.12+ with `sqlite3` stdlib (already on the user's machine)
- Depends on: `setup-otel.ps1` having been run (SQLite exporter enabled, DB exported)
- No external PowerShell modules or npm packages required
