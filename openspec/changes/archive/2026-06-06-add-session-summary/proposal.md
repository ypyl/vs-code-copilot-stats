## Why

The `-Sessions` report currently identifies sessions only by a UUID (`conversation_id`), making it impossible to tell which session is which at a glance. The user's actual request text is already stored in `copilot_chat.user_request` in `span_attributes` — we can extract its first line as a human-readable summary, giving each session recognizable context without needing content capture enabled.

## What Changes

- Add a `session_summary` field to the `-Sessions` report output
- Extract `copilot_chat.user_request` from `span_attributes` for each `invoke_agent` span
- Take the first line (up to first newline), truncate to ~120 characters
- Fall back to `"(no summary)"` if the attribute is missing

## Capabilities

### Modified Capabilities

- `copilot-stats`: The `-Sessions` report now includes a `session_summary` field containing a truncated first line of the user's request text, extracted from the `copilot_chat.user_request` span attribute.

## Impact

- Minor change to `copilot-stats.ps1` — add one extra attribute query per session
- No new files, no schema changes, no external dependencies
