## Context

The project (`copilot-stats.ps1`) queries VS Code's OTel SQLite export to produce usage and cost reports. It reads token counts from span attributes, looks up per-model pricing from `model-pricing.json`, and computes estimated costs with `Get-Cost`. The current calculation treats cache tokens as additive (added on top of input), inflating costs by 2–5×. Additionally, Anthropic cache write costs and GPT long-context tier pricing exist in the source-of-truth pricing page but are not applied.

The codebase is a single PowerShell script (no modules, no build step). The pricing data is a single JSON file. All database access is via Python's `sqlite3` invoked from PowerShell.

## Goals / Non-Goals

**Goals:**
1. Fix cost formula so cached input tokens are priced at `cache_input` rate and the remainder at the full `input` rate
2. Apply `cache_write` pricing for Anthropic models when cache write tokens appear in telemetry
3. Apply long-context tier pricing for GPT-5.4 and GPT-5.5 when input exceeds 272K tokens per request
4. Use the same cache token data source across all report modes (Sessions, Cost, Daily, Weekly, Monthly)

**Non-Goals:**
- Real-time cost tracking (this is a post-hoc report tool)
- Supporting context tiers for non-GPT models (only GPT-5.4/5.5 have tiers per GitHub docs)
- Changing the PowerShell→Python bridge architecture
- Adding pricing for models not yet in `model-pricing.json`

## Decisions

### D1: Cost formula — subtract cache from input before full-rate charge

**Chosen:** `total = (input - cache) × input_rate + cache × cache_input_rate + output × output_rate + cache_write × cache_write_rate`

**Rationale:** Per GitHub's billing docs, cached tokens are a subset of input tokens that get a discounted rate. The current code adds cache on top of input, effectively double-charging cached tokens at both full and discounted rates. The correct formula subtracts cached tokens from total input before applying the full rate.

**Alternative considered:** Normalize data at ingestion time (track uncached and cached separately). Rejected because it complicates the data model unnecessarily — the formula fix is simpler and the raw telemetry already provides both `input_tokens` (total) and `cache_read.input_tokens` (cached subset).

### D2: Cache data source — use span_attributes consistently

**Chosen:** Always read cache tokens from `span_attributes WHERE key = 'gen_ai.usage.cache_read.input_tokens'`, regardless of mode.

**Rationale:** Currently Sessions mode reads from `span_attributes` but Cost/Daily/Weekly/Monthly modes read from a `cached_tokens` column on the `spans` table. The `spans` table schema may not even have that column (it varies by VS Code version), while `span_attributes` is the standard OTel representation. Consolidating on `span_attributes` removes a brittle assumption and makes cache tracking consistent.

**Alternative considered:** Try `spans.cached_tokens` first, fall back to `span_attributes`. Rejected — adds complexity for no benefit since `span_attributes` is the canonical OTel source.

### D3: Cache write tokens — read from gen_ai.usage.cache_creation.input_tokens

**Chosen:** Read cache write tokens from `span_attributes WHERE key = 'gen_ai.usage.cache_creation.input_tokens'` and apply `cache_write` rate from `model-pricing.json`.

**Rationale:** The OTel semantic conventions for GenAI use `gen_ai.usage.cache_creation.input_tokens` for cache writes. This is the standard attribute name used by the Copilot extension. Only Anthropic models have a `cache_write` price in the rate card, but the code reads the attribute generically and applies the rate if present in the pricing JSON.

**Alternative considered:** Use a single combined cache cost. Rejected because cache writes are separately metered per GitHub's billing page and the rate card already has distinct `cache_write` prices.

### D4: Long-context tier — threshold-based selection in Get-Cost

**Chosen:** Restructure `model-pricing.json` so models with tiers have a `tiers` sub-object. `Get-Cost` selects the appropriate tier by comparing the request's input token count against each tier's threshold.

New JSON shape for tiered models:
```json
"gpt-5.4": {
  "tiers": [
    { "threshold": 272000, "input": 2.50, "cache_input": 0.25, "output": 15.00 },
    { "threshold": 999999999, "input": 5.00, "cache_input": 0.50, "output": 22.50 }
  ]
}
```

Non-tiered models keep their flat structure for backward compatibility.

**Rationale:** GitHub's pricing page shows GPT-5.4 and GPT-5.5 with two explicit tiers based on a 272K input threshold. An array of tier objects with ascending thresholds is the simplest structure that supports the current case and future additional tiers. The `Get-Cost` function iterates tiers and picks the first where `input_tokens ≤ threshold`.

**Alternative considered:** Keep model names flat and use a naming convention (`gpt-5.4-long-context`). Rejected — it would require splitting aggregate data by context length and introduce complexity in the display layer.

### D5: Tier selection for aggregate reports — per-span granularity

**Chosen:** For aggregate reports (Cost/Daily/Weekly/Monthly), compute cost per individual span/session using the correct tier, then sum. Do not apply a single tier to the aggregate total.

**Rationale:** A daily total of 500K input tokens across 10 sessions might include 9 sessions under 272K and 1 session over. Averaging or applying a single tier to the total would be wrong. Per-span cost calculation is correct and aligns with how GitHub bills (per-request).

**Alternative considered:** Apply tier based on average token count. Rejected — would produce incorrect costs.

## Risks / Trade-offs

- **[Risk] Unknown OTel attribute name for cache writes**: `gen_ai.usage.cache_creation.input_tokens` is the expected name but may differ in practice. → **Mitigation**: Log a warning if the attribute is missing but the pricing JSON has `cache_write`; do not fail. Can be tuned after real data validation.
- **[Risk] `model-pricing.json` restructuring breaks external consumers**: If anyone else parses the JSON file, the new `tiers` format for GPT-5.4/5.5 is a breaking change. → **Mitigation**: This is a local-only tool; no known external consumers. The README already documents the file format. Will update README.
- **[Risk] Cost estimates drop significantly**: Fixing the double-count will reduce cost estimates by 2–5× for most users. → **Mitigation**: Not a real risk — the new numbers are correct. Include a note in release/changelog.

## Open Questions

- **What is the exact OTel attribute key for cache write tokens in VS Code Copilot's export?** Needs verification against a real `.db` export. Default assumption: `gen_ai.usage.cache_creation.input_tokens`. If different, update in a follow-up.
- **Does the `spans` table actually have a `cached_tokens` column**, or is it always `NULL`? Needs verification via schema inspection. If the column doesn't exist, the Cost mode's current SQL query silently returns zero cache tokens — confirming the need to switch to `span_attributes`.
