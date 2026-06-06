## ADDED Requirements

### Requirement: Script accepts database path and report mode

The script SHALL accept a mandatory `-DbPath` parameter pointing to the exported SQLite database file and a report mode switch (`-Sessions`, `-Daily`, `-Weekly`, `-Monthly`, or `-Cost`). The `-Daily` mode SHALL be the default if no mode switch is provided.

#### Scenario: User specifies database and mode

- **WHEN** the script is run with `-DbPath "agent-traces.db" -Weekly`
- **THEN** the script SHALL produce a weekly aggregated report

#### Scenario: User omits mode

- **WHEN** the script is run with `-DbPath "agent-traces.db"` and no mode switch
- **THEN** the script SHALL default to `-Daily` mode

### Requirement: Script validates environment and database

The script SHALL verify that Python 3 is available on PATH, that the specified database file exists and is readable, and that the database contains the expected `spans` and `span_attributes` tables with the required columns.

#### Scenario: Python not available

- **WHEN** Python is not found on PATH
- **THEN** the script SHALL print a clear error message and exit with code 1

#### Scenario: Database file missing

- **WHEN** the specified `-DbPath` does not exist
- **THEN** the script SHALL print an error and exit with code 1

#### Scenario: Database schema mismatch

- **WHEN** the database exists but the `spans` table lacks expected columns (`name`, `start_time_ms`, `request_model`)
- **THEN** the script SHALL print a warning listing missing columns but attempt to proceed with available data

### Requirement: Script filters internal Copilot overhead

The script SHALL exclude spans where `agent_name` matches any entry in the `internal_agents` list or `request_model` matches any entry in the `internal_models` list from `model-pricing.json`. Embeddings spans (`name` containing `embeddings`) SHALL also be excluded.

#### Scenario: Internal title generation span

- **WHEN** a span has `agent_name = "title"` and `request_model = "gpt-4o-mini-2024-07-18"`
- **THEN** that span SHALL be excluded from all reports

#### Scenario: Embeddings span

- **WHEN** a span has `name = "embeddings text-embedding-3-small-512"`
- **THEN** that span SHALL be excluded from all reports

### Requirement: Script produces per-session breakdown

In `-Sessions` mode, the script SHALL output one record per `invoke_agent` span, including: session timestamp, agent name, model name (mapped through pricing aliases), input tokens, output tokens, cached tokens, turn count, and estimated cost in USD and AI credits.

#### Scenario: Two sessions in the database

- **WHEN** the database contains two `invoke_agent` spans
- **THEN** the script SHALL output two session records with token counts and cost

#### Scenario: Session uses a model not in pricing config

- **WHEN** an `invoke_agent` span has a `request_model` not found in `model-pricing.json` aliases
- **THEN** the script SHALL report the raw model ID and cost as "unknown" for that session

### Requirement: Script produces daily aggregation

In `-Daily` mode, the script SHALL group sessions by calendar date, summing token counts and cost, and output one record per date. Token counts SHALL be further broken down by model within each day.

#### Scenario: Multiple sessions on one day

- **WHEN** the database contains sessions spanning multiple hours on the same date
- **THEN** the script SHALL produce a single daily record with aggregated totals

### Requirement: Script produces weekly and monthly aggregation

In `-Weekly` mode, the script SHALL group sessions by ISO week. In `-Monthly` mode, the script SHALL group by calendar month. Both SHALL sum token counts and cost, broken down by model.

#### Scenario: Sessions span two weeks

- **WHEN** the database contains sessions in both the last week of May and first week of June
- **THEN** the script SHALL produce two weekly records with correct ISO week boundaries

### Requirement: Script produces cost breakdown

In `-Cost` mode, the script SHALL output a cost summary across all models, including: model name, pricing tier applied, input tokens, output tokens, cached tokens, total cost in USD, and total cost in AI credits. The summary SHALL include a grand total.

#### Scenario: Cost mode with known model

- **WHEN** the database contains usage of `oswe-vscode-prime` and the pricing config maps it to `raptor-mini` with $0.25/M input and $2.00/M output
- **THEN** the script SHALL compute cost as (input_tokens/1M × $0.25) + (output_tokens/1M × $2.00)

### Requirement: Script loads and applies model pricing

The script SHALL load `model-pricing.json` from the same directory as the script. If the file is missing, the script SHALL still produce reports but mark all costs as "unavailable". If a model in the database has no pricing entry, the script SHALL show the model as "unpriced" in the output.

#### Scenario: Pricing file missing

- **WHEN** `model-pricing.json` does not exist alongside the script
- **THEN** the script SHALL print a warning and produce reports with cost fields set to "N/A"

### Requirement: Script outputs structured JSON

All report modes SHALL output a JSON object to stdout. The JSON SHALL include metadata (report type, generation timestamp, database path) and the report data array. The script SHALL also accept an optional `-OutputFile` parameter to save the JSON to a file.

#### Scenario: Output to file

- **WHEN** the script is run with `-OutputFile "report.json"`
- **THEN** the JSON report SHALL be written to `report.json` in addition to stdout
