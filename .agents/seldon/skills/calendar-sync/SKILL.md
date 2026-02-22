# Calendar Sync (vdirsyncer + CalDAV)

## Purpose

Set up bidirectional sync between Google Calendar and a CalDAV endpoint using vdirsyncer.

## Prerequisites

- `vdirsyncer` installed in the image
- OAuth client ID/secret for Google Calendar API
- A CalDAV server endpoint with credentials

## Config Template

Create `~/.config/vdirsyncer/config` with:

```ini
[general]
status_path = "~/.config/vdirsyncer/status"

[pair google_calendar]
a = "google"
b = "google_local"
collections = null
metadata = ["color", "displayname"]
conflict_resolution = "b wins"

[storage google]
type = "google_calendar"
token_file = "~/.config/vdirsyncer/google_token"
client_id = "<google_oauth_client_id>"
client_secret = "<google_oauth_client_secret>"

[storage google_local]
type = "caldav"
url = "http://127.0.0.1:5232/"
username = "zeroclaw"
password = "<local_caldav_password>"
```

## OAuth Flow

1. Run `vdirsyncer-oauth-setup` (uses `vdirsyncer discover`).
2. Complete the browser auth; the token is written to `~/.config/vdirsyncer/google_token`.
3. Run `vdirsyncer sync`.

## Notes

- `collections = null` lets vdirsyncer discover all collections.
- `conflict_resolution = "b wins"` favors the CalDAV side on conflict.
- Adjust the CalDAV URL to your server.
