## ADDED Requirements

### Requirement: model-pricing.json supports tiered pricing

The system SHALL support a `tiers` array within a model's pricing entry, where each tier has a `threshold` (maximum input tokens for that tier, exclusive upper bound) and the standard rate fields (`input`, `cache_input`, `cache_write`, `output`).

Models without tiers SHALL retain the existing flat structure for backward compatibility.

#### Scenario: Tiered model pricing lookup

- **WHEN** `model-pricing.json` defines `gpt-5.4` with `tiers` containing two entries: `{ threshold: 272000, input: 2.50, ... }` and `{ threshold: 999999999, input: 5.00, ... }`
- **AND** `Get-PriceInfo` is called with input token count 150000
- **THEN** the first tier SHALL be selected and its rates returned

#### Scenario: Model without tiers uses flat pricing

- **WHEN** `model-pricing.json` defines `gpt-5.4-mini` as `{ "input": 0.75, "cache_input": 0.075, "output": 4.50 }` (flat, no `tiers`)
- **AND** `Get-PriceInfo` is called
- **THEN** the flat rates SHALL be returned directly

### Requirement: Long-context tier applied for GPT-5.4 and GPT-5.5

The system SHALL apply the long-context tier pricing when a model has tiered pricing and the input token count for a request exceeds the default tier's threshold (272,000 tokens for GPT-5.4 and GPT-5.5).

#### Scenario: GPT-5.4 request under threshold

- **WHEN** an `invoke_agent` span uses `gpt-5.4` with 200,000 input tokens
- **THEN** the default tier pricing SHALL be applied (input: $2.50/M, cache_input: $0.25/M, output: $15.00/M)

#### Scenario: GPT-5.4 request exceeds threshold

- **WHEN** an `invoke_agent` span uses `gpt-5.4` with 300,000 input tokens
- **THEN** the long-context tier pricing SHALL be applied (input: $5.00/M, cache_input: $0.50/M, output: $22.50/M)

#### Scenario: GPT-5.5 request under threshold

- **WHEN** an `invoke_agent` span uses `gpt-5.5` with 150,000 input tokens
- **THEN** the default tier pricing SHALL be applied (input: $5.00/M, cache_input: $0.50/M, output: $30.00/M)

#### Scenario: GPT-5.5 request exceeds threshold

- **WHEN** an `invoke_agent` span uses `gpt-5.5` with 500,000 input tokens
- **THEN** the long-context tier pricing SHALL be applied (input: $10.00/M, cache_input: $1.00/M, output: $45.00/M)

### Requirement: Tier selection is per-request for aggregate reports

For aggregate reports (Cost, Daily, Weekly, Monthly), the system SHALL compute cost for each individual span using that span's input token count to select the tier, then sum the per-span costs. It SHALL NOT apply a single tier to the model's aggregate token total.

#### Scenario: Daily report with mixed tiers

- **WHEN** a day has two `gpt-5.4` sessions: one with 200K input (default tier) and one with 500K input (long-context tier)
- **THEN** the total cost for `gpt-5.4` SHALL be the sum of both individually-tiered costs
- **AND** the model entry SHALL still show total aggregated input/output/cache tokens
