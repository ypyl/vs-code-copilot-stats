## Context

VS Code Copilot Chat with the SQLite span exporter (`setup-otel.ps1`) writes span data to a local database. The user exports this via **Chat: Export Agent Traces DB** to a `.db` file. The database contains a `spans` table with columns for span name, model, token counts, timestamps, agent type, and conversation ID, plus a `span_attributes` table for additional key-value metadata.

The user's machine has Python 3.12 with the `sqlite3` standard library module. PowerShell 5.1 is available as the scripting shell. The `sqlite3` CLI is NOT installed.

The GitHub Copilot pricing page defines per-million-token rates for ~25 models across 5 providers (OpenAI, Anthropic, Google, GitHub fine-tuned, Microsoft), with 1 AI credit = $0.01 USD.

## Goals / Non-Goals

**Goals:**
- Query the exported SQLite database and produce per-session token breakdowns by model
- Aggregate sessions into daily, weekly, and monthly summaries
- Calculate estimated cost using the GitHub pricing model
- Filter out internal Copilot overhead spans (title generation, progress messages, context summarization, embeddings)
- Map internal OTel model IDs to friendly pricing names via an external config file
- Output structured JSON for piping, saving, or further processing
- Work with zero additional installs (Python stdlib only)

**Non-Goals:**
- Real-time monitoring or live dashboards (batch analysis only)
- Editing or writing to the SQLite database (read-only)
- Tracking code completions or inline suggestions (agent chat interactions only)
- Supporting the JSONL file exporter format
- Cross-platform support beyond Windows (Python dependency is cross-platform, but PowerShell paths are Windows-specific)
- Historical trend analysis across multiple exported DBs (single DB per run)

## Decisions

### Decision 1: Python as SQLite engine, PowerShell as orchestrator

**Chosen**: `copilot-stats.ps1` calls `python -c "..."` with embedded SQL, receives JSON on stdout, and formats the report in PowerShell.

**Rationale**: PowerShell has no built-in SQLite module. The `sqlite3` CLI is not installed on this machine. Python's `sqlite3` is in the standard library, installed and ready. The interface is simple: PowerShell builds a Python script string, executes it, parses JSON output.

**Alternative considered**: Bundle `System.Data.SQLite.dll` and use `Add-Type`. Rejected because it requires downloading and maintaining a binary dependency. Python is already on every dev machine and works cross-platform if the script ever needs to run elsewhere.

### Decision 2: External pricing config file

**Chosen**: `model-pricing.json` — a separate JSON file mapping model identifiers to per-million-token prices, with an `aliases` section mapping OTel IDs to pricing names.

**Rationale**: Pricing changes independently of the script. Users can update the JSON without touching PowerShell code. The structure supports multiple providers, cache-read token pricing, and tiered pricing (e.g., long context thresholds).

Format:
```json
{
  "credit_usd_rate": 0.01,
  "providers": {
    "github": {
      "raptor-mini": { "input": 0.25, "output": 2.00 }
    }
  },
  "aliases": {
    "oswe-vscode-prime": "raptor-mini"
  },
  "internal_agents": ["title", "progressMessages", "summarizeVirtualTools"],
  "internal_models": ["gpt-4o-mini-2024-07-18", "text-embedding-3-small-512"]
}
```

### Decision 3: Filter internal overhead by `agent_name` and `request_model`

**Chosen**: Filter out spans where `agent_name` is in a configurable list of internal agents OR `request_model` is in a list of internal models. Both lists live in `model-pricing.json`.

**Rationale**: The `spans` table's `agent_name` column contains values like `title`, `progressMessages`, `summarizeVirtualTools` for internal Copilot operations. The `request_model` column reveals `gpt-4o-mini-2024-07-18` and `text-embedding-3-small-512` as internal-only models. Filtering both ensures only user-facing model usage is counted.

### Decision 4: Report modes as script switches

**Chosen**: Five mutually-exclusive switches: `-Sessions`, `-Daily`, `-Weekly`, `-Monthly`, `-Cost`. Exactly one must be specified (or default to `-Daily`).

**Rationale**: Each mode queries the DB differently and produces different output. Keeping them as switches makes the UX clear. The `-Cost` mode is orthogonal — it shows pricing breakdown across all models, useful after any of the aggregation modes.

**Alternative considered**: A single `-Mode` parameter with a string value. Rejected because switches provide tab-completion and are more discoverable.

### Decision 5: Token data source priority

**Chosen**: For `invoke_agent` spans, read token counts from `span_attributes` (keys `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`). For `chat` spans, use the `input_tokens` and `output_tokens` columns directly.

**Rationale**: The SQLite schema stores session-level token totals in `span_attributes` for `invoke_agent` spans, but per-call token counts in columns for `chat` spans. Session-level reporting uses the attributes; model-breakdown uses the chat columns.

## Risks / Trade-offs

| Risk | Mitigation |
|------|-----------|
| Python not on PATH or wrong version | Script checks for Python at startup, exits with clear error message |
| DB schema changes in future VS Code versions | Script queries `PRAGMA table_info` to verify expected columns exist before running queries |
| Large DB files (heavy user) cause slow queries | SQL queries use `GROUP BY` and aggregation; SQLite handles millions of rows efficiently |
| model-pricing.json gets out of sync with GitHub pricing | External file is user-maintained; script warns if a model in the DB has no pricing entry |
| Span attributes table grows large (key-value per span) | Query uses targeted `WHERE key IN (...)` to fetch only needed attributes |

## Open Questions

None — the DB schema has been inspected with real data, the pricing model has been fetched, and the Python approach has been validated.
