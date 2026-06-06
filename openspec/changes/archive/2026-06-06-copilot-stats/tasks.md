## 1. Pricing model

- [x] 1.1 Create `model-pricing.json` with all providers and models from GitHub pricing page
- [x] 1.2 Add `aliases` section mapping OTel model IDs to pricing names (`oswe-vscode-prime` → `raptor-mini`)
- [x] 1.3 Add `internal_agents` list (`title`, `progressMessages`, `summarizeVirtualTools`)
- [x] 1.4 Add `internal_models` list (`gpt-4o-mini-2024-07-18`, `text-embedding-3-small-512`)
- [x] 1.5 Include `credit_usd_rate: 0.01` and default fallback pricing

## 2. Script skeleton and parameters

- [x] 2.1 Create `copilot-stats.ps1` with param block: `-DbPath` (mandatory), `-Sessions`, `-Daily`, `-Weekly`, `-Monthly`, `-Cost` switches, `-OutputFile` (optional)
- [x] 2.2 Add script-level help comment with synopsis, description, parameters, and examples for all modes
- [x] 2.3 Implement default mode: `-Daily` when no mode switch is specified

## 3. Environment and database validation

- [x] 3.1 Check Python 3 is available on PATH; exit with clear error if not
- [x] 3.2 Validate `-DbPath` exists and is a readable file
- [x] 3.3 Verify expected tables exist (`spans`, `span_attributes`) via Python `PRAGMA table_info`
- [x] 3.4 Warn if expected columns are missing but attempt to proceed

## 4. Python SQLite query helper

- [x] 4.1 Build a PowerShell function `Invoke-SqliteQuery` that constructs a Python one-liner, executes it, and returns parsed JSON
- [x] 4.2 Handle Python errors gracefully: capture stderr, report meaningful messages
- [x] 4.3 Use parameterized embedding of the DB path (handle spaces and special characters)

## 5. Internal overhead filtering

- [x] 5.1 Load `internal_agents` and `internal_models` from `model-pricing.json`
- [x] 5.2 Build SQL WHERE clause that excludes matching spans
- [x] 5.3 Also exclude spans where `name` contains `embeddings`

## 6. Pricing model loading

- [x] 6.1 Load `model-pricing.json` from script directory; warn if missing but continue
- [x] 6.2 Build a lookup function that resolves OTel model ID → pricing entry via aliases
- [x] 6.3 Compute cost: `(input/1e6 × input_price) + (output/1e6 × output_price) + (cache/1e6 × cache_price)`
- [x] 6.4 Convert USD cost to AI credits (÷ 0.01)

## 7. Session extraction (Sessions mode)

- [x] 7.1 Query `invoke_agent` spans with token counts from `span_attributes`
- [x] 7.2 Extract timestamp, agent name, model, input/output/cached tokens, turn count per session
- [x] 7.3 Map model IDs to friendly names via pricing aliases
- [x] 7.4 Compute per-session cost
- [x] 7.5 Format and output session records as JSON array

## 8. Daily, weekly, and monthly aggregation

- [x] 8.1 Build SQL query with `GROUP BY` date (converted from `start_time_ms`)
- [x] 8.2 Sum tokens and cost per date/model combination
- [x] 8.3 Implement `-Daily` mode output
- [x] 8.4 Implement `-Weekly` mode using ISO week grouping
- [x] 8.5 Implement `-Monthly` mode using calendar month grouping

## 9. Cost breakdown (Cost mode)

- [x] 9.1 Aggregate tokens by model across all sessions
- [x] 9.2 For each model, show pricing tier applied, token counts, USD cost, and AI credits
- [x] 9.3 Add grand total row
- [x] 9.4 Flag models with no pricing entry as "unpriced"

## 10. Output formatting

- [x] 10.1 Build JSON output object with metadata (report_type, generated_at, db_path) and data array
- [x] 10.2 Write JSON to stdout using `ConvertTo-Json -Depth 6`
- [x] 10.3 Support `-OutputFile` parameter to also save to a file
- [x] 10.4 Format numeric values consistently (tokens as integers, cost rounded to 4 decimal places)

## 11. Error handling and edge cases

- [x] 11.1 Handle empty database (no spans) — print "No data found" and exit cleanly
- [x] 11.2 Handle database with no `invoke_agent` spans — warn but still report chat/tool counts
- [x] 11.3 Handle pricing config with missing model entries — show "unpriced" instead of crashing
- [x] 11.4 Handle malformed JSON in model-pricing.json — report parse error with line info
