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

- `bash`, `bun`, `cargo`, `cat`, `date`, `echo`, `find`, `git`, `grep`, `head`, `ls`, `node`, `npm`,
  `pwd`, `playwriter`, `gws`, `tail`, `wc`

If a command is missing, add it to `.agents/seldon/config.override.toml` under
`[autonomy].allowed_commands`, then rebuild the agent image.

## Calendar Management (Google Workspace CLI)

Use `gws` for Google Calendar access instead of `vdirsyncer`.

Recommended auth flow:

1. Run `gws auth login` in the container.
2. Complete the browser flow and store credentials under `~/.config/gws`.
3. Use helper commands like `gws calendar +agenda` and `gws calendar +insert`.

If you already have exported credentials, point the shell tool at them with:

- `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE`
- `GOOGLE_WORKSPACE_PROJECT_ID` (optional quota/billing override)

Useful commands:

- `gws calendar +agenda`
- `gws calendar +insert --help`
- `gws calendar events list --help`
- `gws calendar calendars list`

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
