## 1. Add session summary to attribute query

- [x] 1.1 Add `copilot_chat.user_request` to the list of keys in the existing attribute fetch for invoke_agent spans
- [x] 1.2 Extract the value from the query result

## 2. Format and include in output

- [x] 2.1 Take first line (split on `\n`), truncate to 120 characters with `…` if needed
- [x] 2.2 Fall back to `"(no summary)"` if attribute is missing or empty
- [x] 2.3 Add `session_summary` field to the session record in the output

## 3. Verify

- [x] 3.1 Test with real database to confirm summaries appear
- [x] 3.2 Test with a session that has a multi-line request
