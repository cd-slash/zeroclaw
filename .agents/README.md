# ZeroClaw Multi-Agent Configuration

This directory contains environment configurations and identity templates for individual ZeroClaw agents.

## Quick Start

```bash
# List all agents and their status
../scripts/agent.sh list

# Start an agent
../scripts/agent.sh start handy

# View logs
../scripts/agent.sh logs handy -f

# Create a new agent
../scripts/agent.sh create mybot
```

## File Structure

```
.agents/
├── .shared.env             # Common configuration (API keys, defaults, ignored)
├── .shared.env.example     # Safe template (tracked)
├── handy/                  # DevOps agent directory
│   ├── .env                # Agent config (HIDDEN FILE - contains secrets)
│   ├── IDENTITY.md         # Who the agent is
│   ├── SOUL.md             # Personality and behavior
│   ├── AGENTS.md           # Operational guidelines
│   ├── USER.md             # User context
│   ├── TOOLS.md            # Tool notes
│   ├── MEMORY.md           # Long-term memory template
│   ├── skills/             # Agent-specific skills
│   └── tools.toml          # Tool declarations for image build
├── gordon/                 # Code agent directory
│   ├── .env
│   └── ...
├── zoe/                    # Creative agent directory
│   ├── .env
│   └── ...
└── templates/              # Template files for new agents
    ├── IDENTITY.md.template
    ├── SOUL.md.template
    ├── MEMORY.md.template
    └── ...
```

## Configuration Inheritance

Settings are loaded in this order (later overrides earlier):

1. **Base config** from Docker image
2. **.shared.env** - Common settings for all agents
3. **`<agent>/.env`** - Agent-specific settings (HIDDEN FILE)
4. **Runtime environment** from docker-compose
5. **Identity files** in `.agents/<agent>/` directory

## Adding a New Agent

### Method 1: Using the CLI (Recommended)

```bash
# Create a new agent
../scripts/agent.sh create mybot

# This creates:
# - .agents/mybot/.env (hidden env file)
# - .agents/mybot/*.md (identity templates)
# - .agents/mybot/skills/ (skills directory)
# - .agents/mybot/tools.toml (tool declarations)
```

### Method 2: Manual Setup

1. Create agent directory and copy templates:
   ```bash
   mkdir -p .agents/mybot
   cp .agents/handy/.env .agents/mybot/.env
   cp .agents/handy/*.md .agents/mybot/
   ```

2. Edit `.agents/mybot/.env` with your settings

3. Customize identity files in `.agents/mybot/`:
   - `IDENTITY.md` - Agent name, vibe, emoji
   - `SOUL.md` - Personality and behavior
   - `USER.md` - Who you're helping
   - `TOOLS.md` - Tool-specific notes
   - `AGENTS.md` - Operational guidelines

4. (Optional) Add tool entries to `.agents/mybot/tools.toml`

5. Add the service to `docker-compose.agents.yml`

6. Start with `../scripts/agent.sh start mybot`

## Built-in Agents

| Agent  | Purpose              | Port | Config Directory |
|--------|---------------------|------|-----------------|
| handy  | DevOps/Infrastructure | 3000 | `handy/`        |
| gordon | Code Review         | 3001 | `gordon/`       |
| zoe    | Creative Writing    | 3002 | `zoe/`          |

## Identity Files

Each agent has a `.agents/<agent>/` directory containing:

### IDENTITY.md
Who the agent is:
- **Name** - Agent's name
- **Creature** - What kind of AI (e.g., "Rust-forged AI")
- **Vibe** - General attitude (e.g., "Sharp, direct, resourceful")
- **Emoji** - Visual identifier (e.g., 🦀)

### SOUL.md
Personality and behavior guidelines:
- Communication style
- Core truths and boundaries
- Identity affirmation (never claim to be ChatGPT/Claude/etc.)
- How to introduce itself

### AGENTS.md
Operational guidelines:
- Session startup checklist
- Memory system usage
- Safety rules
- Tool usage guidelines
- Sub-task scoping

### USER.md
Who the agent is helping:
- User name and timezone
- Communication preferences
- Work context
- Technical stack

### TOOLS.md
Local tool notes:
- SSH hosts and aliases
- Device nicknames
- Preferred configurations
- Environment-specific details

### skills/
Agent-specific capabilities:
- Each skill is a subdirectory with `SKILL.md` or `SKILL.toml`
- Defines custom tools and behaviors
- Can include shell scripts, HTTP calls, etc.

### tools.toml
Custom CLI tool declarations for this agent image:
- Each `[[tool]]` entry resolves one binary during build
- Resolved binaries are copied to `/usr/local/bin/agent-tools`
- Supports local paths and remote URLs
- Supports optional `sha256` verification per tool

## Per-Agent Tool Customization

Each agent can have different CLI tools without needing separate Dockerfiles:

### Method 1: Tool Manifest (Recommended)

Declare tools in `.agents/<agent>/tools.toml`:

```toml
[[tool]]
name = "my-kubectl-wrapper"
source = "path"
path = ".agents/handy/tools/my-kubectl-wrapper"
binary = "my-kubectl-wrapper"
description = "Custom kubectl helper"
sha256 = ""
```

On `../scripts/agent.sh start <agent>` these are automatically:
- Resolved into `.agents/<agent>/.build-tools/`
- Copied into the Docker image at `/usr/local/bin/agent-tools/`
- Made executable and available as `agent-tools/<tool-name>`

### Method 2: Build-Time APT + Bun Packages (Preferred)

Declare package routes in `.agents/<agent>/tools.toml`:

```toml
[apt]
packages = ["jq", "ripgrep"]

[bun]
packages = ["typescript", "tsx"]
```

**How it works:**
- `../scripts/agent.sh start <agent>` resolves `tools.toml` into `.build-tools/`
- Docker build installs `[apt].packages` directly into the image
- Docker build installs Bun and `[bun].packages` globally into the image
- Result is immutable and portable to remote hosts

**Example DevOps agent `.env`:**

```bash
# Agent identity
AGENT_NAME=handy
AGENT_ROLE=devops

# DevOps tools
AGENT_APT_PACKAGES="kubectl helm jq git curl"
AGENT_NPM_PACKAGES="@kubernetes/client-node"

# Model and gateway
ZEROCLAW_MODEL=anthropic/claude-sonnet-4-20250514
ZEROCLAW_GATEWAY_PORT=3000
```

**Example Code agent `.env`:**

```bash
# Agent identity
AGENT_NAME=gordon
AGENT_ROLE=code-reviewer

# Development tools
AGENT_APT_PACKAGES="nodejs npm git"
AGENT_NPM_PACKAGES="typescript ts-node @types/node eslint"

# Model and gateway
ZEROCLAW_MODEL=anthropic/claude-sonnet-4-20250514
ZEROCLAW_GATEWAY_PORT=3000
```

### Method 3: Advanced - Custom Dockerfile (Rarely Needed)

Only needed if you require:
- Complex multi-step builds
- Specific library versions not available in apt
- Custom compiled binaries

See docker-compose.agents.yml comments for the custom Dockerfile approach if needed.

## Important Files

- **.shared.env** - Put your API key here (ignored by git)
- **handy/.env**, **gordon/.env**, **zoe/.env** - Agent configurations (HIDDEN)
- **handy/**, **gordon/**, **zoe/** - Agent directories (config + identity + tools)
- **docker-compose.agents.yml** - Service definitions
- **../scripts/agent.sh** - Management CLI
- **../docs/multi-agent-setup.md** - Full documentation

## Environment Variables

Common variables you can set per agent:

```bash
# Identity
AGENT_NAME=handy
AGENT_ROLE=devops

# LLM Settings
ZEROCLAW_MODEL=anthropic/claude-sonnet-4-20250514
ZEROCLAW_TEMPERATURE=0.7
PROVIDER=openrouter

# Gateway
ZEROCLAW_GATEWAY_PORT=3000
ZEROCLAW_ALLOW_PUBLIC_BIND=true

# Tools
ZEROCLAW_SHELL_ENABLED=true
ZEROCLAW_FILE_ENABLED=true
ZEROCLAW_BROWSER_ENABLED=true

# Identity files directory (optional, defaults to .agents/<agent>)
AGENT_IDENTITY_DIR=.agents/handy
```

## Storage Isolation

Each agent has isolated Docker volumes:
- `zeroclaw-data-<agent>` - Workspace and config
- `tailscale-data-<agent>` - VPN state (if enabled)

No data is shared between agents. Each agent's workspace contains its own:
- Identity files (IDENTITY.md, SOUL.md, etc.)
- Memory and daily notes
- Skills directory
- Configuration files

## Security Notes

- **Env files** (`.env`) are in `.gitignore` and should never be committed
- **Never commit API keys** - keep them in `.shared.env` or agent `.env` files
- **Agent directories** (`handy/`, `gordon/`, etc.) can be committed if they don't contain secrets
- **Each agent is isolated** - no cross-contamination of data
- **Agent-specific tools** in `tools/` subdirectory are isolated to that agent

## Backup & Recovery

### Option 1: Litestream (Recommended for Production)

**Litestream** provides continuous real-time backup of SQLite databases to MinIO:

```bash
# Setup (one-time per agent)
cp litestream.template.yml litestream.yml
# Add MinIO credentials to .agents/<agent>/.env

# Start agent with Litestream sidecar
../scripts/agent.sh start handy

# Check status
../scripts/litestream.sh status handy

# Restore to any point in time
../scripts/litestream.sh restore handy "2025-01-15 14:30:00"
```

**Benefits:**
- Real-time streaming (10s intervals)
- Incremental forever (95% space savings)
- Point-in-time recovery (to the second)
- Automatic, no agent action needed

**Docs:** [docs/litestream-integration.md](../docs/litestream-integration.md)

### Option 2: Manual Backups

For ad-hoc or migration backups:

```bash
# Quick backup commands
../scripts/agent-backup.sh backup handy              # Backup single agent
../scripts/agent-backup.sh backup-all                # Backup all agents
../scripts/agent-backup.sh restore handy backup-file.tar.gz  # Restore agent

# MinIO integration for remote backups
../scripts/agent-backup.sh sync-to-minio handy       # Upload to MinIO
../scripts/agent-backup.sh sync-from-minio handy     # Download from MinIO
```

### Setup MinIO Backup (Optional)

1. Copy the example config:
   ```bash
   cp minio.env.example .minio.env
   ```

2. Edit `.minio.env` with your MinIO credentials

3. Source the config:
   ```bash
   source .minio.env
   ```

4. Start backing up to remote storage

**Full backup documentation:** [docs/backup-and-recovery.md](../docs/backup-and-recovery.md)

## Documentation

- **Setup Guide:** [docs/multi-agent-setup.md](../docs/multi-agent-setup.md)
- **Backup & Recovery:** [docs/backup-and-recovery.md](../docs/backup-and-recovery.md)
