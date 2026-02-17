# ZeroClaw TUI

Terminal User Interface for managing ZeroClaw agents.

## Quick Start

```bash
./scripts/tui.sh
```

## Current Status

⚠️ **Simplified CLI Version** - Provides basic agent listing. Full interactive TUI planned.

## Quick Start

```bash
./scripts/tui.sh
```

## Current Status

⚠️ **Simplified CLI Version** - Provides basic agent listing. Full interactive TUI planned.

## Quick Start

```bash
./scripts/tui.sh
```

## Features

- 📋 **Agent Overview**: Per-agent status, config snapshot, env validation
- ⚙️ **Config Editor + Env Modal**: Edit `.agents/<agent>/.env` and manage key/value vars with modal actions
- 📝 **Identity Editor**: Manage markdown identity files (SOUL.md, IDENTITY.md, etc.)
- 🧩 **Skills Manager**: Create, edit, and delete files under `.agents/<agent>/skills/`
- 🔧 **Tools Manager**: Create, edit, and delete files under `.agents/<agent>/tools/`
- 🛟 **Backup Operations View**: Run memory/config backups, MinIO sync, and Litestream controls
- ▶️ **Lifecycle Controls**: Start, stop, restart, create, and safe-remove agents (auto backup + volume prune)
- 📊 **Live Logs**: Tail container logs directly in the TUI

## Keyboard Shortcuts

- `1`..`7`: Switch views
- `Tab`: Cycle focus (agents -> files -> editor)
- `Up/Down` or `j/k`: Move selection
- `Ctrl+s`: Save current file
- `e`: Open env var modal (Config view)
- `s`: Start selected agent
- `t`: Stop selected agent
- `Shift+r`: Restart selected agent
- `a`: Create agent
- `Shift+c`: Duplicate selected agent
- `Shift+d`: Safe-remove selected agent (requires typed confirmation)
- `n`: Create file (Identity/Skills/Tools views)
- `x`: Delete selected file (Identity/Skills/Tools views)
- Skills view: `m` rename selected file, `y` duplicate selected file
- `r`: Refresh agent list/status (or list backups in Backups view)
- Backups view actions: `b/c/r/u/i/o/v/p/g/y`
- `q`: Quit

## Requirements

- Bun >= 1.1
- Docker & Docker Compose (for agent control)

OpenTUI docs: https://opentui.com/docs/getting-started/

## License

Same as ZeroClaw project
