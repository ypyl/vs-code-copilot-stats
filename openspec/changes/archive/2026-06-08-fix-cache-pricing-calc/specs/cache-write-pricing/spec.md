## ADDED Requirements

### Requirement: Cache write tokens are priced for Anthropic models

The system SHALL read cache write tokens from the `gen_ai.usage.cache_creation.input_tokens` span attribute and apply the `cache_write` per-token rate from `model-pricing.json` for models that define one.

Only Anthropic models (Claude Haiku 4.5, Claude Sonnet 4/4.5/4.6, Claude Opus 4.5/4.6/4.7/4.8) define a `cache_write` rate. For models without a `cache_write` rate, cache write tokens SHALL be ignored (they are zero or meaningless).

#### Scenario: Claude Sonnet 4 session with cache write tokens

- **WHEN** an `invoke_agent` span uses `claude-sonnet-4` and has `gen_ai.usage.cache_creation.input_tokens = 50000`
- **AND** `model-pricing.json` defines `claude-sonnet-4.cache_write = 3.75`
- **THEN** the cost calculation SHALL include `(50000 / 1,000,000) × 3.75 = $0.1875` for cache write

#### Scenario: GPT model session with cache write attribute

- **WHEN** an `invoke_agent` span uses `gpt-5.4-mini` and has `gen_ai.usage.cache_creation.input_tokens = 1000`
- **AND** `model-pricing.json` has no `cache_write` field for `gpt-5.4-mini`
- **THEN** the cache write tokens SHALL NOT affect the cost calculation

#### Scenario: Cache write attribute is absent

- **WHEN** an `invoke_agent` span has no `gen_ai.usage.cache_creation.input_tokens` attribute
- **AND** the model defines a `cache_write` rate
- **THEN** the cache write cost SHALL be $0.00 (no error, no warning)

### Requirement: Cache write tokens appear in all report modes

The system SHALL include cache write token counts and their cost contribution in all report modes: Sessions, Cost, Daily, Weekly, and Monthly.

#### Scenario: Sessions mode includes cache write

- **WHEN** a session has cache write tokens present
- **THEN** the session record SHALL include a `cache_write_tokens` field with the token count
- **AND** the `cost_usd` and `cost_credits` SHALL reflect cache write charges

#### Scenario: Cost mode aggregates cache write

- **WHEN** multiple sessions have cache write tokens
- **THEN** the Cost report SHALL show total `cache_write_tokens` per model
- **AND** the `totals` section SHALL include aggregate cache write counts
