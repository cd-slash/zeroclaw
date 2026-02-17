# ZeroClaw TUI

Terminal User Interface for managing ZeroClaw agents.

## Current Status

⚠️ **Simplified CLI Version** - Provides basic agent listing. Full interactive TUI planned.

## Quick Start

```bash
./scripts/tui.sh
```

## Current Features

- 📋 **Agent List**: View all agents with their status (running/stopped)
- 📖 **Command Reference**: Shows available agent management commands

## Example Output

```
🦀 ZeroClaw Agent Manager
==========================

Available agents:

  1. gordon          ○ stopped
  2. handy           ● running
  3. zoe             ○ stopped

Commands:
  ./scripts/agent.sh start <name>     - Start an agent
  ./scripts/agent.sh stop <name>      - Stop an agent
  ./scripts/agent.sh logs <name> -f   - View logs
  ./scripts/agent.sh shell <name>     - Open shell
  ./scripts/agent.sh create <name>    - Create new agent
```

## Planned Full TUI Features

- ⚙️ **Configuration Editor**: Edit agent `.env` files
- 📝 **Identity Management**: Edit SOUL.md, IDENTITY.md, etc.
- 🔧 **Tools & Packages**: Configure APT/NPM packages
- ▶️ **Agent Control**: Start/stop with visual feedback
- 📊 **Live Logs**: Stream agent logs in real-time

## Requirements

- Node.js >= 18 (current simplified version)
- Docker & Docker Compose (for agent control)

## Notes

The full OpenTUI-based interactive TUI requires Bun runtime. The official OpenTUI documentation is at https://opentui.com/docs/getting-started/

## License

Same as ZeroClaw project
