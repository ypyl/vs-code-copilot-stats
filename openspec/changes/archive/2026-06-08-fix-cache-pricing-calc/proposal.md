## Why

The cost calculator in `copilot-stats.ps1` double-counts cached input tokens — it charges both the full `input` rate on all input tokens AND the `cache_input` rate on cached tokens, treating them as additive rather than a subset. GitHub's billing model treats cache tokens as a portion of input that gets a discounted rate, not an additional charge. This overestimates costs by 2–5× for sessions with high cache hit rates (which is the normal case). Additionally, Anthropic cache write costs and GPT long-context tier pricing are not applied at all, producing inaccurate cost estimates for those models.

## What Changes

- **BREAKING**: Fix cost formula to subtract cached tokens from input before applying the full `input` rate (cached tokens are a subset, not additive). Reported costs will decrease — this is a correction, not a reduction.
- Apply `cache_write` pricing for Anthropic models (Claude Haiku/Sonnet/Opus) when cache write tokens are present in the telemetry data.
- Support GPT-5.4 and GPT-5.5 dual-tier pricing (default vs. long context) based on the input token count per request.
- Align cache token data sources between modes: use the same attribute/column consistently across Sessions, Cost, and aggregate reports.

## Capabilities

### New Capabilities
- `cache-write-pricing`: Apply `cache_write` token costs for Anthropic models (Claude family)
- `long-context-tier`: Apply higher per-token rates for GPT-5.4 and GPT-5.5 when input exceeds the 272K threshold

### Modified Capabilities
- `copilot-stats`: Cost calculation formula changed to treat cache tokens as a subset of input rather than additive; cache token source made consistent across all report modes

## Impact

- `copilot-stats.ps1`: `Get-Cost` function rewritten; SQL queries for Cost/Daily/Weekly/Monthly modes updated for consistent cache column; new helper for tier selection
- `model-pricing.json`: Possibly restructured to support tiered pricing (e.g., `gpt-5.4` with `default` and `long_context` sub-keys)
- No external dependencies, no API changes, no database schema changes
