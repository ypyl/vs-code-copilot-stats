## Why

Enabling Copilot OpenTelemetry monitoring currently requires manually opening VS Code Settings UI, searching for specific keys, and setting them correctly. This is friction — especially for users who just want to start collecting usage data with the simplest approach (SQLite span exporter). A one-command setup script eliminates that friction and ensures consistent configuration. The SQLite exporter is preferred over the file exporter because it avoids JSONL file bloat (redundant cumulative metric snapshots every ~10 seconds) and correctly serializes span data.

## What Changes

- **Rewrite** `setup-otel.ps1` to enable the SQLite span exporter instead of the file exporter
- Script sets two keys: `otel.enabled` and `otel.dbSpanExporter.enabled`
- Script actively removes stale file-exporter keys (`exporterType`, `outfile`) if present from a prior setup
- All existing behavior preserved: JSONC-safe text manipulation, idempotency for new keys, backup before modify, VS Code running detection
- Reports which keys were added, which were already set, and which were removed

## Capabilities

### New Capabilities

- `otel-setup`: Automated VS Code settings configuration that enables the Copilot OTel SQLite span exporter. The script locates the user's `settings.json`, ensures the two required keys are present, removes any conflicting file-exporter settings, preserves all existing content (including JSONC comments), and confirms the result.

### Modified Capabilities

None — this is a new tool with no existing capabilities to modify.

## Impact

- Existing `setup-otel.ps1` replaced (simpler: ~160 lines vs ~220)
- No external dependencies beyond PowerShell 5.1+ (built into Windows)
- Touches `%APPDATA%/Code/User/settings.json` (VS Code stable) and checks for Insiders variant
- Related to a future `copilot-stats.ps1` change that will query the exported SQLite `.db` file
- **Breaking**: `-OutFile` parameter removed (no longer applicable with SQLite exporter)
