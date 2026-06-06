## 1. Script skeleton and parameters

- [x] 1.1 Rewrite `setup-otel.ps1` param block: `[string]$SettingsPath` only (remove `-OutFile`)
- [x] 1.2 Update script-level help comment for SQLite exporter, update examples
- [x] 1.3 Define target settings: `otel.enabled` and `otel.dbSpanExporter.enabled` as ordered dict
- [x] 1.4 Define stale keys list: `otel.exporterType` and `otel.outfile`

## 2. Settings file location

- [x] 2.1 Implement path resolution: check `-SettingsPath` parameter first, then stable, then Insiders
- [x] 2.2 Handle case where no settings file is found — create a new one at the stable path
- [x] 2.3 Warn if VS Code process is detected running

## 3. Read and validate

- [x] 3.1 Read `settings.json` content as a single string (or default to `{}`)
- [x] 3.2 Validate closing brace exists; abort with clear error if malformed
- [x] 3.3 Attempt strict JSON parse; warn if fails (likely JSONC, proceeding with text approach)

## 4. Key detection and cleanup

- [x] 4.1 Check which target keys (SQLite) are already present using regex
- [x] 4.2 Check which stale keys (file exporter) are present using regex
- [x] 4.3 Remove stale key lines from content text, handling trailing commas
- [x] 4.4 Build list of target keys that need to be added (skip already-present)

## 5. Safe insertion into JSONC

- [x] 5.1 If any changes are needed (adds or removals), create backup: `Copy-Item settings.json settings.json.bak`
- [x] 5.2 Construct JSON snippet for missing target keys with proper quoting
- [x] 5.3 Insert new keys before the final `}` — handle empty `{}`, comma-before-brace, trailing whitespace
- [x] 5.4 Write modified content back to `settings.json` with UTF8 encoding and error handling

## 6. Reporting

- [x] 6.1 Output summary header: "Copilot OTel Setup (SQLite)"
- [x] 6.2 For each target key, report `[ADDED]` or `[ALREADY SET]`
- [x] 6.3 For each stale key removed, report `[REMOVED]`
- [x] 6.4 Print backup file path (if backup was created)
- [x] 6.5 Print instructions: "Use Chat: Export Agent Traces DB command to export data"
- [x] 6.6 Print restart reminder if VS Code is running

## 7. Error handling and edge cases

- [x] 7.1 If `settings.json` is malformed (no closing brace), warn and abort
- [x] 7.2 If the file is read-only or write fails, report a clear error message
- [x] 7.3 Handle the edge case where settings.json contains only `{}` (empty object)
- [x] 7.4 Handle comma cleanup after stale key removal (no double commas or trailing comma before `}`)
