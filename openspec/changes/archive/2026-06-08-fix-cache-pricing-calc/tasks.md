## 1. Fix cost calculation formula (core bug)

- [x] 1.1 Rewrite `Get-Cost` to subtract cache tokens from input before applying full `input` rate: `(input - cache) × input_rate + cache × cache_input_rate + output × output_rate`
- [x] 1.2 Handle edge case where cache tokens exceed input tokens (clamp cache ≤ input to avoid negative uncached cost)

## 2. Add cache write token support

- [x] 2.1 Update `Get-Cost` to accept `CacheWriteTokens` parameter
- [x] 2.2 Apply `cache_write` rate from pricing JSON when model defines it and cache write tokens > 0
- [x] 2.3 Add `gen_ai.usage.cache_creation.input_tokens` to the attribute list read in Sessions mode
- [x] 2.4 Add `cache_write_tokens` field to session output records
- [x] 2.5 Add `cache_write_tokens` aggregation to Cost, Daily, Weekly, and Monthly modes

## 3. Consolidate cache token data source across all modes

- [x] 3.1 Fix Cost mode SQL query to read cache tokens from `span_attributes` (key `gen_ai.usage.cache_read.input_tokens`) instead of `spans.cached_tokens` column
- [x] 3.2 Fix Daily/Weekly/Monthly mode SQL queries to use same `span_attributes` source (currently they read from `span_attributes` via subquery — verify consistency with Sessions mode)
- [x] 3.3 Remove any reference to `cached_tokens` column on `spans` table

## 4. Support long-context tier pricing for GPT-5.4 and GPT-5.5

- [x] 4.1 Restructure `model-pricing.json`: convert `gpt-5.4` and `gpt-5.5` to use `tiers` array with thresholds at 272,000
- [x] 4.2 Update `Get-PriceInfo` to accept input token count and select the correct tier
- [x] 4.3 For tiered models, iterate tiers in ascending threshold order; select first tier where `input_tokens ≤ threshold`
- [x] 4.4 For non-tiered models, return the flat rates unchanged (backward compatible)
- [x] 4.5 Pass per-span input token count to `Get-PriceInfo` in all report modes (Sessions, Cost, Daily, Weekly, Monthly)
- [x] 4.6 For aggregate reports, compute per-span cost with correct tier, then sum (do not apply tier to aggregate totals)
- [x] 4.7 Add long-context tier entries for GPT-5.4 and GPT-5.5 in `model-pricing.json` per GitHub billing docs (input: $5.00/$10.00, cache_input: $0.50/$1.00, output: $22.50/$45.00)

## 5. Update documentation

- [x] 5.1 Update README cost calculation section to document the corrected formula
- [x] 5.2 Update README pricing model section to document tiered pricing structure
- [x] 5.3 Add `cache_write_tokens` to the "What gets tracked" table in README
- [x] 5.4 Update example outputs in README to reflect new fields (cache_write_tokens)

## 6. Validation

- [x] 6.1 Review `Get-Cost` output against hand-calculated examples for each model family (OpenAI, Anthropic, Google)
- [x] 6.2 Verify no regression: non-cached sessions produce same cost as before
- [x] 6.3 Verify tier selection: input at 200K, 272K exactly, and 300K returns correct tier
- [x] 6.4 Verify all report modes (Sessions, Cost, Daily, Weekly, Monthly) run without errors
