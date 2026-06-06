## Context

The `copilot-stats.ps1` Sessions mode queries `invoke_agent` spans and enriches them with token counts from `span_attributes`. The `span_attributes` table also contains `copilot_chat.user_request` — the raw text of the user's message that started the session. This is always populated (it's metadata, not captured content), so no privacy tradeoff.

## Goals / Non-Goals

**Goals:**
- Add a `session_summary` field to session records in `-Sessions` mode
- Extract first line of `copilot_chat.user_request` from `span_attributes`
- Truncate to ~120 characters with ellipsis if longer
- Fall back to `"(no summary)"` if attribute is missing

**Non-Goals:**
- Changing any other report mode (Daily/Weekly/Monthly/Cost unaffected)
- Enabling content capture (stays off by default)
- Changing the data model or JSON structure beyond the new field

## Decisions

### Decision 1: Query alongside existing attribute fetch

**Chosen**: Add `copilot_chat.user_request` to the existing attribute query (which already fetches token counts) rather than making a separate query.

**Rationale**: The attribute query already fetches three keys for each session span. Adding a fourth key adds negligible overhead and avoids a second round-trip to the DB.

### Decision 2: First-line truncation

**Chosen**: Split on newline, take the first line, truncate to 120 characters with `…` appended.

**Rationale**: User requests often span multiple lines (the full message including context). The first line is usually the core ask. 120 characters is enough to identify the session without overwhelming the output.

## Risks / Trade-offs

| Risk | Mitigation |
|------|-----------|
| User request text might be very long (multi-paragraph) | Only first line used, truncated to 120 chars |
| Attribute might be missing (older VS Code versions) | Falls back to `"(no summary)"` |
