## MODIFIED Requirements

### Requirement: Script produces per-session breakdown

In `-Sessions` mode, the script SHALL output one record per `invoke_agent` span, including: session timestamp, agent name, model name (mapped through pricing aliases), input tokens, output tokens, cached tokens, cache write tokens, turn count, estimated cost in USD and AI credits, and a human-readable session summary derived from the user's request text.

Cached tokens SHALL be read from the `gen_ai.usage.cache_read.input_tokens` span attribute. Cache write tokens SHALL be read from the `gen_ai.usage.cache_creation.input_tokens` span attribute.

Cost SHALL be calculated such that cached input tokens are priced at the `cache_input` rate while the remaining uncached input tokens are priced at the full `input` rate. Cache write tokens SHALL be priced at the `cache_write` rate when the model defines one.

The session summary SHALL be the first line of the `copilot_chat.user_request` attribute from `span_attributes`, truncated to 120 characters with a trailing `…` if the line is longer. If the attribute is missing or empty, the summary SHALL be `"(no summary)"`.

#### Scenario: Two sessions in the database

- **WHEN** the database contains two `invoke_agent` spans
- **THEN** the script SHALL output two session records with token counts, cost, and session summaries

#### Scenario: Session with multi-line user request

- **WHEN** an `invoke_agent` span has `copilot_chat.user_request` containing "Debug auth flow\nContext: the login page..."
- **THEN** the session summary SHALL be "Debug auth flow"

#### Scenario: Session with long first line

- **WHEN** the first line of the user request exceeds 120 characters
- **THEN** the session summary SHALL be truncated to 120 characters followed by `…`

#### Scenario: Session uses a model not in pricing config

- **WHEN** an `invoke_agent` span has a `request_model` not found in `model-pricing.json` aliases
- **THEN** the script SHALL report the raw model ID and cost as "unknown" for that session

#### Scenario: Session without user_request attribute

- **WHEN** an `invoke_agent` span has no `copilot_chat.user_request` attribute
- **THEN** the session summary SHALL be `"(no summary)"`

#### Scenario: Session with cache tokens

- **WHEN** an `invoke_agent` span has 10,000 input tokens and 6,000 cache read tokens
- **AND** the model's `input` rate is $1.00/M and `cache_input` rate is $0.10/M
- **THEN** the input cost SHALL be `(10,000 - 6,000) / 1,000,000 × 1.00 = $0.004` for uncached input
- **AND** the cache cost SHALL be `6,000 / 1,000,000 × 0.10 = $0.0006` for cached input

#### Scenario: Session with cache write tokens

- **WHEN** an `invoke_agent` span has `gen_ai.usage.cache_creation.input_tokens = 20,000`
- **AND** the model defines `cache_write = 3.75`
- **THEN** the session record SHALL include `cache_write_tokens: 20000`
- **AND** the cost SHALL include cache write charges

## ADDED Requirements

### Requirement: Cache token source is consistent across all report modes

In all report modes (Sessions, Cost, Daily, Weekly, Monthly), cache read tokens SHALL be read from the `gen_ai.usage.cache_read.input_tokens` span attribute. No report mode SHALL rely on a `cached_tokens` column on the `spans` table.

#### Scenario: Cost mode reads cache from span_attributes

- **WHEN** generating a Cost report
- **THEN** cache token totals SHALL be aggregated from `span_attributes` entries with key `gen_ai.usage.cache_read.input_tokens`

#### Scenario: Daily mode reads cache from span_attributes

- **WHEN** generating a Daily report
- **THEN** cache token totals SHALL be aggregated from `span_attributes` entries with key `gen_ai.usage.cache_read.input_tokens`
