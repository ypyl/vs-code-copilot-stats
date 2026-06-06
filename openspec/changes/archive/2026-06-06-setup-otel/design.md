## Context

VS Code Copilot Chat emits OpenTelemetry traces, metrics, and events that can be captured for offline analysis. The SQLite span exporter (`github.copilot.chat.otel.dbSpanExporter.enabled`) persists spans to a local database, which the user exports via the **Chat: Export Agent Traces DB** command. This avoids the JSONL file bloat observed with the file exporter (redundant cumulative metric snapshots written every ~10 seconds, producing 767KB in 15 minutes for just 2 requests).

Only two settings are needed (the `dbSpanExporter` implicitly enables OTel, but `otel.enabled` is set explicitly for clarity). Any stale file-exporter keys from a prior setup must be cleaned up.

The `settings.json` file is JSONC (JSON with comments and trailing commas), so naive JSON parsing will strip comments and may break the file. The script operates safely on the text level.

## Goals / Non-Goals

**Goals:**
- Provide a single-command setup that enables Copilot OTel SQLite span exporter
- Set two keys: `otel.enabled` and `otel.dbSpanExporter.enabled`
- Remove conflicting file-exporter keys if present (`exporterType`, `outfile`)
- Operate safely on VS Code's JSONC settings format (preserve comments, existing formatting)
- Be idempotent for the target keys, aggressive-cleanup for stale keys
- Work on any Windows machine with VS Code installed (stable, Insiders, or custom path)
- Back up settings before modifying
- Report clearly what was changed (added, already-set, removed)

**Non-Goals:**
- Configuring OTLP endpoints or other exporters (SQLite only — simplest path)
- Enabling content capture (opt-in separately for privacy)
- Parsing or analyzing the SQLite DB (future `copilot-stats.ps1` change)
- Supporting macOS/Linux settings paths (Windows-first; cross-platform is future work)
- Modifying workspace-level settings (user-level only)

## Decisions

### Decision 1: Text-based manipulation over JSON parsing

**Chosen**: Read `settings.json` as plain text, use regex to detect existing keys, insert new key-value pairs before the closing `}`.

**Rationale**: VS Code settings.json is JSONC format. `ConvertFrom-Json` strips comments and trailing commas, and `ConvertTo-Json` reformats the entire file. Text manipulation preserves everything else untouched.

### Decision 2: Two settings + cleanup of file-exporter keys

**Chosen**: Always set these two keys:
- `github.copilot.chat.otel.enabled` = `true`
- `github.copilot.chat.otel.dbSpanExporter.enabled` = `true`

And actively remove any existing file-exporter keys:
- `github.copilot.chat.otel.exporterType`
- `github.copilot.chat.otel.outfile`

**Rationale**: The `dbSpanExporter` implicitly enables OTel, but setting both keys is self-documenting. The file exporter produced JSONL bloat (redundant cumulative snapshots) and has a known span serialization bug — removing its settings prevents accidental re-enablement. The cleanup also covers the case where a user previously ran the file-exporter version of this script.

### Decision 3: Cleanup before insertion

**Chosen**: Remove stale file-exporter keys from the text before inserting the new SQLite keys, in the same operation.

**Rationale**: Doing both in one pass avoids an unnecessary intermediate write. The regex-based line deletion is the same technique used for insertion — operate on text, not parsed JSON.

### Decision 4: Idempotent for target keys, not for cleanup

**Chosen**: For the two target keys, skip if already present (idempotent). For file-exporter keys, always remove if found (not idempotent — they're always unwanted).

**Rationale**: The user explicitly chose "override" for stale keys. The target keys should still be idempotent so re-running the script doesn't duplicate them.

### Decision 5: Backup before writing

**Chosen**: Copy `settings.json` to `settings.json.bak` in the same directory before any modifications.

**Rationale**: If something goes wrong, the user can restore. Simple, zero-cost insurance.

### Decision 6: No parameters beyond `-SettingsPath`

**Chosen**: The only parameter is `-SettingsPath` for custom settings.json locations. No `-OutFile` needed.

**Rationale**: The SQLite DB is internal to VS Code; there's no user-configurable path for it. The user exports data via the VS Code command, not a file path.

## Risks / Trade-offs

| Risk | Mitigation |
|------|-----------|
| Regex for key detection might miss keys split across multiple lines | VS Code always formats settings with one key-value per line; this is a safe assumption |
| VS Code process holds a write lock on settings.json | VS Code watches the file and hot-reloads; it does not lock. Script warns if VS Code is running but proceeds |
| Settings.json doesn't exist (fresh VS Code install) | Script creates a minimal valid settings.json with just the OTel keys |
| File-exporter key removal might leave a trailing comma | Regex handles comma cleanup; the insertion logic already accounts for comma-before-brace scenarios |
