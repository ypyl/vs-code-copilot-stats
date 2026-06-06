## MODIFIED Requirements

### Requirement: Script produces per-session breakdown

In `-Sessions` mode, the script SHALL output one record per `invoke_agent` span, including: session timestamp, agent name, model name (mapped through pricing aliases), input tokens, output tokens, cached tokens, turn count, estimated cost in USD and AI credits, and a human-readable session summary derived from the user's request text.

The session summary SHALL be the first line of the `copilot_chat.user_request` attribute from `span_attributes`, truncated to 120 characters with a trailing `…` if the line is longer. If the attribute is missing or empty, the summary SHALL be `"(no summary)"`.

#### Scenario: Two sessions in the database

- **WHEN** the database contains two `invoke_agent` spans
- **THEN** the script SHALL output two session records with token counts, cost, and session summaries

#### Scenario: Session with multi-line user request

- **WHEN** an `invoke_agent` span has `copilot_chat.user_request` containing "Debug auth flow\nContext: the login page..."
- **THEN** the session summary SHALL be "Debug auth flow"

#### Scenario: Session with long first line

- **WHEN** the first line of the user request exceeds 120 characters
- **THEN** the session summary SHALL be truncated to 120 characters followed by `…`

#### Scenario: Session uses a model not in pricing config

- **WHEN** an `invoke_agent` span has a `request_model` not found in `model-pricing.json` aliases
- **THEN** the script SHALL report the raw model ID and cost as "unknown" for that session

#### Scenario: Session without user_request attribute

- **WHEN** an `invoke_agent` span has no `copilot_chat.user_request` attribute
- **THEN** the session summary SHALL be `"(no summary)"`
