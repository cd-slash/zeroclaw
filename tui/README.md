# ZeroClaw TUI

Terminal User Interface for managing ZeroClaw agents using OpenTUI.

## Features

- 📋 **Agent List**: View all agents with their status (running/stopped)
- ⚙️ **Configuration Editor**: Edit agent `.env` files
- 📝 **Identity Management**: View/edit SOUL.md, IDENTITY.md, etc.
- 🔧 **Tools Management**: Configure APT/NPM packages and custom tools
- ▶️ **Agent Control**: Start/stop agents directly from the UI
- 📊 **Live Logs**: View agent logs in real-time

## Installation

```bash
cd tui
npm install
npm run build
```

## Usage

From the project root:

```bash
./tui/dist/index.js
```

Or install globally:

```bash
cd tui
npm link
zeroclaw-tui
```

## Controls

- **↑/↓ or k/j**: Navigate lists
- **Enter**: Select
- **Tab**: Switch between tabs (in editor)
- **q**: Quit (from main list)
- **Back**: Return to agent list (from editor)

## Screenshots

### Agent List
```
┌──────────────────────────────────────────────┐
│           ZeroClaw Agent Manager             │
│ Use ↑/↓ to navigate, Enter to select, q to quit│
├──────────────────────────────────────────────┤
│ ● handy                                      │
│ ○ gordon                                     │
│ ○ zoe                                        │
│ + Create New Agent                           │
└──────────────────────────────────────────────┘
```

### Agent Editor
```
┌────────────────────────────────────────────────────────────────┐
│ Agent: handy ● running                                           │
│ [CONFIG] [SOUL] [IDENTITY] [TOOLS] [BACK]                      │
├────────────────────────────────────────────────────────────────┤
│ Configuration (.env)                                             │
│ AGENT_NAME: handy_____________________________________________│
│ ZEROCLAW_MODEL: anthropic/claude-sonnet-4-20250514_____________│
│ AGENT_APT_PACKAGES: kubectl helm________________________________│
│ [STOP] [SAVE] [VIEW LOGS]                                      │
└────────────────────────────────────────────────────────────────┘
```

## Architecture

The TUI is built with OpenTUI Core and provides:

1. **Agent Discovery**: Automatically finds all agents in `.agents/`
2. **Real-time Status**: Checks Docker container status
3. **Safe Editing**: Modifies `.env` and markdown files
4. **External Editor Integration**: Opens files in $EDITOR for complex edits

## Development

```bash
npm run dev    # Watch mode
npm run build  # Compile
npm run lint   # Check code
```

## Requirements

- Node.js >= 18
- Docker & Docker Compose (for agent control)
- Access to ZeroClaw project directory

## License

Same as ZeroClaw project
