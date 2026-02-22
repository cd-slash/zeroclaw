# Playwriter Browser Control

## Purpose

Use Playwriter CLI to control a Chrome instance with the Playwriter extension.

## Requirements

- Chrome with Playwriter extension installed and connected.
- Playwriter relay server reachable from the agent.

## Environment

Set these in the agent environment or container:

- `PLAYWRITER_HOST` (default is `http://127.0.0.1:19988`)
- `PLAYWRITER_TOKEN` (if you set a token when starting the server)

## Quick Start

```bash
playwriter session new
playwriter -s 1 -e "await page.goto('https://example.com')"
playwriter -s 1 -e "console.log(await page.title())"
```

## Notes

- Sessions keep state between calls. Use `playwriter session list` to inspect.
- Browser tabs are shared across sessions.
