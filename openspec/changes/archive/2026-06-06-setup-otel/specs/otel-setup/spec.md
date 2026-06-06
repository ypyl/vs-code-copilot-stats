## ADDED Requirements

### Requirement: Script locates VS Code settings file

The script SHALL automatically locate the VS Code user `settings.json` file by checking standard installation paths in order: VS Code stable (`%APPDATA%/Code/User/settings.json`), then VS Code Insiders (`%APPDATA%/Code - Insiders/User/settings.json`). The user MAY override with a `-SettingsPath` parameter.

#### Scenario: Stable VS Code is installed

- **WHEN** `%APPDATA%/Code/User/settings.json` exists
- **THEN** the script SHALL use that file as the target

#### Scenario: Only Insiders is installed

- **WHEN** `%APPDATA%/Code/User/settings.json` does not exist AND `%APPDATA%/Code - Insiders/User/settings.json` exists
- **THEN** the script SHALL use the Insiders settings file

#### Scenario: User specifies custom path

- **WHEN** the script is run with `-SettingsPath "D:\custom\settings.json"`
- **THEN** the script SHALL use the specified path regardless of whether standard paths exist

### Requirement: Script adds SQLite span exporter settings

The script SHALL ensure the following two settings are present in `settings.json`:
- `github.copilot.chat.otel.enabled` set to `true`
- `github.copilot.chat.otel.dbSpanExporter.enabled` set to `true`

#### Scenario: No OTel settings exist

- **WHEN** `settings.json` does not contain either of the two OTel keys
- **THEN** the script SHALL add both keys with their correct values

#### Scenario: Some SQLite settings already exist

- **WHEN** `settings.json` already contains `github.copilot.chat.otel.enabled` but not `dbSpanExporter.enabled`
- **THEN** the script SHALL add only the missing key and leave the existing key unchanged

#### Scenario: All SQLite settings already exist

- **WHEN** `settings.json` already contains both SQLite OTel keys
- **THEN** the script SHALL make no modifications to those keys and report they are already configured

### Requirement: Script removes stale file exporter settings

The script SHALL remove any existing file-exporter OTel settings from `settings.json`:
- `github.copilot.chat.otel.exporterType`
- `github.copilot.chat.otel.outfile`

These keys SHALL be removed regardless of their current values, as they conflict with the SQLite exporter and are known to cause JSONL file bloat.

#### Scenario: File exporter settings exist from prior setup

- **WHEN** `settings.json` contains `github.copilot.chat.otel.exporterType` and `github.copilot.chat.otel.outfile`
- **THEN** the script SHALL remove both keys and report them as `[REMOVED]`

#### Scenario: No file exporter settings exist

- **WHEN** `settings.json` does not contain either file-exporter key
- **THEN** the script SHALL proceed without attempting removal and report nothing about file exporter keys

### Requirement: Script preserves existing settings content

The script SHALL modify `settings.json` in a way that preserves all existing content, including JSONC comments, trailing commas, and user formatting. The script MUST NOT strip comments, reorder existing keys, or change formatting of lines it does not touch.

#### Scenario: Settings file contains comments

- **WHEN** `settings.json` contains `// this is a comment` lines
- **THEN** those comment lines SHALL remain unchanged after the script runs

#### Scenario: Settings file has custom formatting

- **WHEN** `settings.json` has non-standard indentation or blank lines between sections
- **THEN** that formatting SHALL be preserved for all lines the script does not modify

### Requirement: Script creates backup before modifying

The script SHALL create a backup copy of `settings.json` before making any modifications. The backup SHALL be named `settings.json.bak` in the same directory as the original file.

#### Scenario: Successful backup before modification

- **WHEN** the script needs to modify `settings.json` (add or remove keys)
- **THEN** it SHALL first copy the file to `settings.json.bak` in the same directory, then proceed with modifications

#### Scenario: No changes needed

- **WHEN** all required settings are already present AND no file-exporter keys exist to remove
- **THEN** the script SHALL NOT create a backup (no file write occurs)

### Requirement: Script reports changes clearly

The script SHALL output a summary of what it did, including which settings were added, which were already present, which were removed, and the backup file path if one was created. It SHALL also instruct the user how to export data.

#### Scenario: Settings were added and stale keys removed

- **WHEN** the script adds SQLite keys and removes file-exporter keys
- **THEN** it SHALL print `[ADDED]`, `[ALREADY SET]`, and `[REMOVED]` labels for each affected key, show the backup path, and print instructions for the "Chat: Export Agent Traces DB" command

#### Scenario: All settings already present, nothing to remove

- **WHEN** no settings needed to be added and no file-exporter keys exist
- **THEN** it SHALL print a message confirming OTel SQLite is already configured and show instructions for exporting data

### Requirement: Script handles missing settings file gracefully

The script SHALL handle the case where no `settings.json` exists (fresh VS Code install with no prior customizations). In this case, it SHALL create a new `settings.json` with the two SQLite OTel settings and a valid JSON structure.

#### Scenario: No settings file exists

- **WHEN** `settings.json` does not exist at the target path
- **THEN** the script SHALL create a new file containing a valid JSON object with the two OTel settings and report the creation
