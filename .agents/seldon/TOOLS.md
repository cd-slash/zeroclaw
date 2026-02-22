# TOOLS.md - Local Notes

Skills define HOW tools work. This file is for YOUR setup details.

## What Goes Here

Things like:
- Recurring household checklists and routines
- Appliance/service maintenance intervals
- Vendor contacts and preferred service windows
- Grocery/restock templates and thresholds
- Shared calendar conventions and reminder rules

## Household Operating Notes

(Add your local household system details here)

Example:
- Weekly reset: `Sun planning`, `Mon supplies`, `Fri cleanup`
- Maintenance: `HVAC filter every 90 days`, `smoke alarm check monthly`
- Restock rule: `reorder when pantry item <= 2 units`
- Escalation: `urgent home failures notify immediately`

## Built-in Tools

- **shell** - Execute terminal commands
  - Use when: running helper scripts for schedules or exports
  - Do not use when: file read/write tools are sufficient
- **file_read** - Read file contents
  - Use when: reviewing calendars, notes, and checklists
- **file_write** - Write file contents
  - Use when: storing plans, templates, and status logs
- **memory_store** - Save to memory
  - Use when: preserving stable routines and household preferences
- **memory_recall** - Search memory
  - Use when: checking prior outcomes and recurring issues

## Command Allowlist (Seldon)

The shell tool can only execute allowlisted commands. Current allowlist:

- `bash`, `bun`, `cargo`, `cat`, `date`, `echo`, `find`, `git`, `grep`, `head`, `ls`, `node`,
  `npm`, `pwd`, `playwriter`, `python`, `python3`, `pip`, `pip3`, `tail`,
  `vdirsyncer`, `vdirsyncer-oauth-setup`, `wc`

If a command is missing, add it to `.agents/seldon/config.override.toml` under
`[autonomy].allowed_commands`, then rebuild the agent image.

## Calendar Sync (vdirsyncer + CalDAV)

Template config (place at `~/.config/vdirsyncer/config` inside the container):

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

OAuth flow:

1. Run `vdirsyncer-oauth-setup` (uses `vdirsyncer discover`).
2. Complete auth, token saved at `~/.config/vdirsyncer/google_token`.
3. Run `vdirsyncer sync`.

## Browser Control (Playwriter)

Playwriter CLI is installed. To connect to a Chrome instance with the extension:

```bash
playwriter session new
playwriter -s 1 -e "await page.goto('https://example.com')"
```

Set env vars if needed:

- `PLAYWRITER_HOST` (defaults to `http://127.0.0.1:19988`)
- `PLAYWRITER_TOKEN` (if server uses a token)

---
*Add whatever helps Seldon run your household operations accurately.*
