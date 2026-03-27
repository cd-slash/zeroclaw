# Google Calendar Management (gws)

## Purpose

Use Google Workspace CLI (`gws`) to read calendar state, review agendas, and create or update events when appropriate.

## Prerequisites

- `gws` installed in the image
- Google Workspace CLI auth completed with `gws auth login`, or
- a credentials file exposed through `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE`

## Authentication

Recommended interactive flow:

1. Run `gws auth login`
2. Complete browser consent
3. Credentials persist under `~/.config/gws`

Optional environment-based auth:

- `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE`
- `GOOGLE_WORKSPACE_CLI_TOKEN`
- `GOOGLE_WORKSPACE_PROJECT_ID`

## Core Commands

Show upcoming schedule:

```bash
gws calendar +agenda
```

Insert an event:

```bash
gws calendar +insert --help
```

List calendars:

```bash
gws calendar calendars list
```

Inspect event APIs:

```bash
gws calendar events list --help
gws schema calendar.events.insert
```

## Notes

- Prefer `+agenda` for review and `+insert` for new events.
- Use `--dry-run` when you want to inspect a request before creating or updating events.
- `gws` returns structured JSON, which makes it a better fit for agent workflows than older sync-based approaches.
