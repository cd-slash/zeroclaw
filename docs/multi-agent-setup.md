# Multi-Agent Setup Guide

ZeroClaw supports running multiple isolated agents, each with their own configuration, storage, and identity. This is useful for:

- **Specialized agents**: Different agents for different tasks (DevOps, coding, writing)
- **Team collaboration**: Each team member gets their own agent
- **Environment isolation**: Separate agents for dev/staging/prod
- **Skill separation**: Agents with different capabilities and permissions

## Quick Start

```bash
# 1. Set your API key in shared config
nano .agents/.shared.env

# 2. Start an agent
./scripts/agent.sh start handy

# 3. Access the agent through its Tailscale hostname/domain
# (no unique host port mapping required)

# 4. Start another agent
./scripts/agent.sh start gordon

# 5. Start the CCTV security agent
./scripts/agent.sh start dwayne
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Host Machine                                 │
│  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐       │
│  │     handy      │  │     gordon     │  │      giles       │       │
│  │  tailscale     │  │  tailscale     │  │   tailscale    │       │
│  │                │  │                │  │                │       │
│  │ .handy.env     │  │ .gordon.env    │  │  .giles.env      │       │
│  │ .handy/        │  │ .gordon/       │  │  .giles/         │       │
│  │ ├── IDENTITY.md│  │ ├── IDENTITY.md│  │  ├── IDENTITY.md│      │
│  │ ├── SOUL.md    │  │ ├── SOUL.md    │  │  ├── SOUL.md    │      │
│  │ ├── AGENTS.md  │  │ ├── AGENTS.md  │  │  ├── AGENTS.md  │      │
│  │ └── skills/    │  │ └── skills/    │  │  └── skills/    │      │
│  └─────┬──────────┘  └─────┬──────────┘  └─────┬──────────┘       │
│        │                   │                   │                   │
│  ┌─────┴───────────────────┴───────────────────┴──────┐           │
│  │              .agents/.shared.env                    │           │
│  │         (API keys, common settings)                 │           │
│  └─────────────────────────────────────────────────────┘           │
└─────────────────────────────────────────────────────────────────────┘
```

Each agent has:
- **Isolated storage**: Separate Docker volumes (no data conflicts)
- **Unique identity**: Distinct hostname and container identity on Tailscale
- **Shared base config**: Common settings from `.shared.env`
- **Agent-specific config**: Hidden `.env` file (e.g., `.handy.env`)
- **Agent identity files**: Markdown files defining personality, behavior, and skills

## Directory Structure

```
.agents/
├── .shared.env             # Common configuration (API keys, defaults)
├── .handy.env              # DevOps agent config (HIDDEN FILE)
├── .handy/                 # DevOps agent identity
│   ├── IDENTITY.md         # Who the agent is
│   ├── SOUL.md             # Personality and behavior
│   ├── AGENTS.md           # Operational guidelines
│   ├── USER.md             # User context
│   ├── TOOLS.md            # Tool notes
│   └── skills/             # Agent-specific skills
├── .gordon.env             # Code agent config (HIDDEN FILE)
├── .gordon/                # Code agent identity
│   └── ...
├── .giles.env                # Creative agent config (HIDDEN FILE)
├── .giles/                   # Creative agent identity
│   └── ...
├── .dwayne.env             # Security agent config (HIDDEN FILE)
├── .dwayne/                # Security agent identity
│   └── ...
└── templates/              # Template files for new agents
    ├── IDENTITY.md.template
    ├── SOUL.md.template
    └── ...

docker-compose.agents.yml    # Multi-agent compose configuration
scripts/agent.sh             # Management CLI
```

**Security Note:** Agent `.env` files are hidden (prefixed with `.`) and in `.gitignore` to prevent accidental commits of secrets. Identity markdown files (`.handy/`, `.gordon/`, etc.) can be committed to version control as they don't contain sensitive data.

## Available Agents

### Built-in Agents

| Agent  | Role      | Access        | Config File       | Description                    |
|--------|-----------|---------------|-------------------|--------------------------------|
| handy  | DevOps    | Tailscale     | `.handy.env`      | Infrastructure, CI/CD, shell   |
| gordon | Code      | Tailscale     | `.gordon.env`     | Code review, refactoring       |
| giles    | Creative  | Tailscale     | `.giles.env`        | Writing, documentation         |
| dwayne | Security  | Tailscale     | `.dwayne.env`     | CCTV monitoring and alert triage |

### Agent Configuration Files

Each agent has a **hidden** `.env` file in `.agents/`:

```bash
# .agents/.handy.env (HIDDEN FILE - contains secrets)
AGENT_NAME=handy
AGENT_ROLE=devops
ZEROCLAW_MODEL=anthropic/claude-sonnet-4-20250514
ZEROCLAW_TEMPERATURE=0.5
ZEROCLAW_GATEWAY_PORT=3000
ZEROCLAW_ALLOW_PUBLIC_BIND=true
```

And an identity directory with markdown files:

```
.agents/.handy/
├── IDENTITY.md       # Who the agent is (name, vibe, emoji)
├── SOUL.md           # Personality and behavior guidelines
├── AGENTS.md         # Operational guidelines
├── USER.md           # Who you're helping
├── TOOLS.md          # Tool-specific notes
└── skills/           # Custom capabilities
    └── example/
        └── SKILL.md
```

**Identity Files:**

- **IDENTITY.md** — Name, creature type, vibe, emoji
- **SOUL.md** — Core truths, communication style, boundaries, continuity
- **AGENTS.md** — Session checklist, memory system, safety rules, tools
- **USER.md** — User name, timezone, preferences, work context
- **TOOLS.md** — Local notes, SSH hosts, device names, environment specifics

## Management Commands

### List All Agents

```bash
./scripts/agent.sh list
```

Shows:
- Agent names
- Running/stopped status
- Tailscale access hostnames

### Start an Agent

```bash
./scripts/agent.sh start handy
```

- Creates container if needed
- Uses isolated storage volume
- Loads shared + agent-specific config
- Exposes gateway on internal `:3000` and is accessed via Tailscale

### Stop an Agent

```bash
./scripts/agent.sh stop handy
```

Preserves data in the agent's volume for restart.

### View Logs

```bash
# Show logs
./scripts/agent.sh logs handy

# Follow logs in real-time
./scripts/agent.sh logs handy -f

# Show last 50 lines
./scripts/agent.sh logs handy --tail 50
```

### Open Shell

```bash
./scripts/agent.sh shell handy
```

Opens a bash shell inside the agent container for debugging.

### Google Workspace Auth

Use the centralized auth helpers when an agent needs its own Google Workspace login.
Each agent authenticates individually inside its own container and stores exported
credentials in its own persistent volume at `/zeroclaw-data/.config/gws/credentials.json`.
Each agent image also includes `gcloud`, so `gws auth setup` can run inside the container.

By default, `gws-login` now runs on your host machine in a temporary isolated `gws`
config directory, exports credentials, copies them into the selected agent container,
and then removes the temporary host credentials. This avoids the localhost callback
problem and does not overwrite your normal host `gws` auth state. If the selected
agent is not running on this machine, the credentials/client files are copied over
Tailscale SSH instead of local Docker exec.

If you already ran `gws-setup` for an agent, `gws-login` will automatically pull that
agent's `client_secret.json` into the temporary host config before starting login.

```bash
# Show auth state for all agents
./scripts/agent.sh gws-status

# Show whether each agent has an OAuth client configured
./scripts/agent.sh gws-client-show

# Install one desktop OAuth client JSON as the shared base
./scripts/agent.sh gws-client-base-install ./client_secret.json

# Apply that same client config to all agents
./scripts/agent.sh gws-client-base-apply --all

# Run the normal interactive gws login flow for one agent
./scripts/agent.sh gws-login handy

# Override the saved preset and request the full scope set
./scripts/agent.sh gws-login handy --full

# Or choose a custom service set for this login only
./scripts/agent.sh gws-login handy -s drive,gmail,sheets,calendar

# Or install an already-exported credentials file manually
./scripts/agent.sh gws-creds-install handy ./handy-credentials.json

# If you want the one-time setup flow instead
./scripts/agent.sh gws-setup handy

# Optionally set a non-secret scope preset for future logins
./scripts/agent.sh gws-config-set handy --scopes drive,gmail,sheets,calendar

# Test that calendar access works
./scripts/agent.sh gws-test handy

# Open a simple interactive menu
./scripts/agent.sh gws-menu
```

Notes:
- These commands build on top of the existing `gws auth setup` / `gws auth login` flow.
- `gws-setup` uses `gcloud` inside the container to create/configure the Google OAuth client.
- `gws-login` uses a host-side temporary config dir so your normal host `gws` auth is untouched.
- The helper exports credentials after login, imports them into the container, and deletes the temporary host copy.
- No scope preset is applied by default.
- Saved presets in `.agents/<agent>/gws.env` are only optional defaults; passing `--full`, `--readonly`, or `-s ...` overrides them for that login.
- Auth is isolated per agent; logging in `handy` does not grant access to `gordon`.
- Auth credentials are never copied between agents.
- If an agent is stopped, the helper starts it automatically before auth.

Typical first-time flow:

```bash
# 1. Save one downloaded desktop OAuth client JSON as the shared base
./scripts/agent.sh gws-client-base-install ./client_secret.json

# 2. Apply that client config everywhere
./scripts/agent.sh gws-client-base-apply --all

# 3. Optionally apply shared scope/project defaults
./scripts/agent.sh gws-config-base-apply --all

# 4. Authenticate each agent independently
./scripts/agent.sh gws-login handy
./scripts/agent.sh gws-login gordon
```

### Reusing Scope and Project Defaults

If you want a consistent starting point without sharing credentials, store a reusable
auth config preset. This copies only non-secret settings like scope presets and optional
project IDs. Each agent still runs its own `gws auth login` afterward.

```bash
# Set a base config on one source agent only if you want explicit defaults
./scripts/agent.sh gws-config-set handy --scopes drive,gmail,sheets,calendar --project-id my-project-id

# Copy handy's auth config directly to specific agents
./scripts/agent.sh gws-config-copy handy gordon giles prime

# Save handy's config as the shared base profile
./scripts/agent.sh gws-config-base-save handy

# Apply that shared base later to one agent
./scripts/agent.sh gws-config-base-apply gordon

# Or apply it to all agents
./scripts/agent.sh gws-config-base-apply --all

# Then authenticate each agent independently
./scripts/agent.sh gws-login gordon
```

How to think about it:
- Use `gws-config-copy` when you want one agent's scope/project defaults to seed other agents.
- Use `gws-config-base-save` + `gws-config-base-apply` when you want a reusable baseline you can apply later.
- Agents can still diverge afterward by changing config or running `gws-login` with explicit flags.
- Config presets influence future login/setup behavior; they do not move auth state, tokens, or credentials between agents.

### Check Status

```bash
./scripts/agent.sh status
```

Shows all agent containers and their states.

## Creating a New Agent

### 1. Create Agent Configuration

```bash
./scripts/agent.sh create mybot
```

This creates:
- **`.agents/.mybot.env`** — Hidden configuration file with secrets
- **`.agents/.mybot/`** — Identity directory with markdown templates:
  - `IDENTITY.md` — Agent name, vibe, emoji
  - `SOUL.md` — Personality and behavior
  - `AGENTS.md` — Operational guidelines
  - `USER.md` — User context
  - `TOOLS.md` — Tool notes
  - `skills/` — Custom capabilities directory

### 2. Add to Docker Compose

Edit `docker-compose.agents.yml` and add the service:

```yaml
  mybot:
    <<: *agent-base
    container_name: zeroclaw-mybot
    hostname: mybot
    env_file:
      - .agents/.shared.env
      - .agents/.mybot.env
    environment:
      - AGENT_NAME=mybot
      - ZEROCLAW_GATEWAY_PORT=3000
    volumes:
      - zeroclaw-data-mybot:/zeroclaw-data
      - tailscale-data-mybot:/var/lib/tailscale
      - .agents/.mybot:/zeroclaw-data/.zeroclaw/workspace/.agent:ro
    profiles: [mybot]

volumes:
  zeroclaw-data-mybot:
  tailscale-data-mybot:
```

### 3. Customize Configuration

**Edit `.agents/.mybot.env`** (hidden file with secrets):

```bash
# Agent identity
AGENT_NAME=mybot
AGENT_ROLE=assistant

# Model settings
ZEROCLAW_MODEL=anthropic/claude-sonnet-4-20250514
ZEROCLAW_TEMPERATURE=0.7

# Capabilities
ZEROCLAW_SHELL_ENABLED=true
ZEROCLAW_FILE_ENABLED=true
ZEROCLAW_BROWSER_ENABLED=true
```

**Edit `.agents/.mybot/IDENTITY.md`** (agent identity):

```markdown
# IDENTITY.md — Who Am I?

- **Name:** MyBot
- **Creature:** A Rust-forged AI — fast, lean, and relentless
- **Vibe:** Helpful, efficient, reliable
- **Specialty:** General Assistance
- **Emoji:** 🤖
```

**Edit `.agents/.mybot/SOUL.md`** (personality):

```markdown
# SOUL.md — Who You Are

## Core Truths
**Be genuinely helpful.** Skip the fluff — just help.

## Identity
You are **MyBot**. Built in Rust. 3MB binary. Zero bloat.
You are NOT ChatGPT, Claude, or any other product. You are MyBot.

## Communication
Be clear, concise, and helpful. Use occasional emojis when appropriate.
```

### 4. Start the Agent

```bash
./scripts/agent.sh start mybot
```

The agent will load both the `.env` configuration and the identity files from `.agents/.mybot/`.

## Configuration Inheritance

Configuration is loaded in order (later overrides earlier):

1. **Base config** (`dev/config.template.toml` in image)
2. **Environment variables** from `.shared.env` (common settings)
3. **Environment variables** from `.agent.env` (hidden agent-specific settings)
4. **Runtime overrides** from `environment:` section
5. **Identity files** from `.agents/.agent/` directory (personality and behavior)

### Shared Configuration (.shared.env)

Put common settings here (API keys, defaults):

```bash
# Required: API key for all agents
API_KEY=your-api-key-here

# Default provider
PROVIDER=openrouter

# Default model
ZEROCLAW_MODEL=anthropic/claude-sonnet-4-20250514

# Common tunnel settings
TUNNEL_PROVIDER=none
```

### Agent-Specific Configuration (.agent.env)

Override shared settings per agent in the hidden `.env` file:

```bash
# .agents/.handy.env (HIDDEN FILE)
AGENT_NAME=handy
AGENT_ROLE=devops

# Specialized model
ZEROCLAW_MODEL=anthropic/claude-sonnet-4-20250514

# Lower temperature for consistent technical responses
ZEROCLAW_TEMPERATURE=0.5

# Enable specific tools
ZEROCLAW_SHELL_ENABLED=true
```

### Agent Identity Files (.agents/.agent/)

Personality and behavior are defined in markdown files (safe to commit):

```
.agents/.handy/
├── IDENTITY.md    # Name: Handy, Vibe: Sharp/resourceful, Emoji: 🦀
├── SOUL.md        # Core truths: "Be genuinely helpful", Communication style
├── AGENTS.md      # Session checklist, memory system, safety rules
├── USER.md        # User preferences, work context
└── TOOLS.md       # SSH hosts, environment notes
```

These files are mounted into the container at `/zeroclaw-data/.zeroclaw/workspace/.agent/` and loaded into the agent's system prompt.

## Storage Isolation

Each agent gets completely isolated storage:

```
Docker Volumes:
├── zeroclaw-data-handy       → /zeroclaw-data (container)
├── zeroclaw-data-gordon      → /zeroclaw-data (container)
├── zeroclaw-data-giles         → /zeroclaw-data (container)
├── tailscale-data-handy      → /var/lib/tailscale (container)
├── tailscale-data-gordon     → /var/lib/tailscale (container)
└── tailscale-data-giles        → /var/lib/tailscale (container)
```

This prevents:
- File conflicts between agents
- Memory/database collisions
- Config corruption
- Cross-agent data leaks

## Memory System

Each agent has its own isolated memory storage. ZeroClaw supports two memory backends:

### SQLite Backend (Recommended)

Vector-based memory with semantic search:
- **Location:** `/zeroclaw-data/.zeroclaw/memory.db`
- **Features:** Embeddings, hybrid search (vector + keyword), automatic hygiene
- **Daily notes:** Stored as rows with timestamps
- **Config:** `ZEROCLAW_MEMORY_BACKEND=sqlite`

### Markdown Backend

File-based memory for transparency:
- **Core memory:** `/zeroclaw-data/.zeroclaw/workspace/MEMORY.md` (curated long-term)
- **Daily notes:** `/zeroclaw-data/.zeroclaw/workspace/memory/YYYY-MM-DD.md`
- **Features:** Plain text, version control friendly, human-readable
- **Config:** `ZEROCLAW_MEMORY_BACKEND=markdown`

### Memory Isolation

Because each agent has isolated volumes:

```
Agent: handy
├── zeroclaw-data-handy/.zeroclaw/memory.db        (SQLite)
├── zeroclaw-data-handy/.zeroclaw/workspace/MEMORY.md  (Markdown core)
└── zeroclaw-data-handy/.zeroclaw/workspace/memory/    (Daily logs)

Agent: gordon
├── zeroclaw-data-gordon/.zeroclaw/memory.db       (SQLite)
├── zeroclaw-data-gordon/.zeroclaw/workspace/MEMORY.md (Markdown core)
└── zeroclaw-data-gordon/.zeroclaw/workspace/memory/   (Daily logs)
```

**Key Point:** Agents cannot see each other's memories. Each has a completely separate memory store.

### Memory Tools

Agents use three memory tools:

- **`memory_store`** — Save important information to long-term memory
- **`memory_recall`** — Search and retrieve from memory
- **`memory_forget`** — Delete incorrect or stale memories

### Best Practices for Multi-Agent Memory

1. **Agent-specific memories:** Each agent should only store what it needs
   - Handy: Infrastructure decisions, deployment notes
   - Gordon: Code patterns, review conventions
   - Giles: Writing style, content preferences

2. **Cross-agent coordination:** If agents need shared context:
   - Use shared files in the project workspace (not in .zeroclaw dir)
   - Document conventions in `.agents/.agent/AGENTS.md`
   - Use the `delegate` tool to hand off work between agents

3. **Memory hygiene:** SQLite backend includes automatic cleanup:
   - Archives old conversations after 7 days
   - Purges archived data after 30 days
   - Each agent's hygiene runs independently

### Memory Configuration per Agent

Set memory backend in `.agents/.agent.env`:

```bash
# SQLite (default) - with vector search
ZEROCLAW_MEMORY_BACKEND=sqlite
ZEROCLAW_MEMORY_AUTO_SAVE=true

# Markdown - file-based, human-readable
ZEROCLAW_MEMORY_BACKEND=markdown
ZEROCLAW_MEMORY_AUTO_SAVE=true

# None - disable persistent memory
ZEROCLAW_MEMORY_BACKEND=none
```

## Access Model

All agents run gateway on internal container port `3000`.

- No per-agent host port mapping is required.
- Reach each agent through its own Tailscale hostname/domain.
- Distinct hostnames come from each agent's Tailscale identity, not port numbers.

## Use Cases

### DevOps Pipeline

```bash
# Start DevOps agent for infrastructure work
./scripts/agent.sh start handy

# Use for:
# - Docker deployments
# - CI/CD configuration
# - Infrastructure as code
```

### Code Review Team

```bash
# Start code review agents for different languages
./scripts/agent.sh start gordon    # General review
./scripts/agent.sh create rust-reviewer
./scripts/agent.sh create python-reviewer
```

### Multi-Environment Setup

```bash
# Development agent
./scripts/agent.sh create dev-agent
# Edit .agents/dev-agent.env for dev settings

# Staging agent
./scripts/agent.sh create staging-agent
# Edit .agents/staging-agent.env for staging settings

# Production agent
./scripts/agent.sh create prod-agent
# Edit .agents/prod-agent.env with restricted permissions
```

## Troubleshooting

### Agent Won't Start

```bash
# Check logs
./scripts/agent.sh logs handy

# Restart with clean slate
./scripts/agent.sh stop handy
./scripts/agent.sh start handy
```

### Access Issues

```bash
# Verify the agent is running
./scripts/agent.sh list

# Confirm Tailscale identity inside the agent
./scripts/agent.sh logs handy --tail 100
```

### Storage Issues

```bash
# Check volume usage
docker volume ls | grep zeroclaw

# Inspect specific agent data
docker volume inspect zeroclaw-data-handy
```

### Config Not Loading

```bash
# Verify env file exists
ls -la .agents/handy.env

# Check env file syntax
cat .agents/handy.env | grep -v "^#" | grep -v "^$"

# Restart to reload config
./scripts/agent.sh restart handy
```

## Advanced Topics

### Tailscale per Agent

Each agent can have its own Tailscale identity:

```bash
# .agents/handy.env
TAILSCALE_AUTHKEY=tskey-auth-handy

# .agents/gordon.env  
TAILSCALE_AUTHKEY=tskey-auth-gordon
```

Each agent appears as a separate machine in your Tailscale network.

### Resource Limits

Set per-agent resource constraints in compose file:

```yaml
  handy:
    <<: *agent-base
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 512M
        reservations:
          cpus: '0.5'
          memory: 256M
```

### Custom Networks

Create isolated networks per team/project:

```yaml
networks:
  team-a:
    driver: bridge
  team-b:
    driver: bridge

services:
  handy:
    <<: *agent-base
    networks:
      - team-a
  
  gordon:
    <<: *agent-base
    networks:
      - team-b
```

## Migration from Single Agent

If you're currently running a single ZeroClaw container:

```bash
# 1. Stop current container
docker compose down

# 2. Copy data to first agent volume
docker volume create zeroclaw-data-handy
docker run --rm -v zeroclaw-data:/source -v zeroclaw-data-handy:/dest alpine cp -r /source/* /dest/

# 3. Update .agents/.shared.env with your API key

# 4. Start agent
./scripts/agent.sh start handy
```

## Security Considerations

- Each agent has isolated storage (no cross-contamination)
- Agents share only the `.shared.env` (keep secrets there)
- Container names are prefixed (`zeroclaw-*`)
- Profiles prevent accidental multi-agent startup
- Each agent can have different autonomy levels

## See Also

- [Configuration Reference](config-reference.md)
- [Docker Compose Documentation](https://docs.docker.com/compose/)
- [ZeroClaw Gateway API](gateway-api.md)
