# Generic Multi-Agent Pattern

## Overview

**Problem Solved:** No more editing docker-compose for every new agent!

**The New Pattern:** Set `AGENT_NAME` and `AGENT_PORT`, run the generic `agent` service. That's it.

## How It Works

Docker Compose variable substitution (`${AGENT_NAME}`, `${AGENT_PORT}`) makes this work:

```yaml
# docker-compose.agents.yml
services:
  agent:  # Generic service works with ANY agent
    container_name: zeroclaw-${AGENT_NAME:-agent}
    volumes:
      - zeroclaw-data-${AGENT_NAME:-agent}:/zeroclaw-data
      - ./.agents/.${AGENT_NAME:-agent}:/agent-config:ro
    ports:
      - "${AGENT_PORT:-3000}:3000"
```

## Usage

### Option 1: Using agent.sh (Easiest)
```bash
# Create agent (auto-assigns next available port)
./scripts/agent.sh create mybot

# Start it (agent.sh sets AGENT_NAME and AGENT_PORT automatically)
./scripts/agent.sh start mybot
```

### Option 2: Using docker compose directly
```bash
# Start any agent by setting environment variables
AGENT_NAME=mybot AGENT_PORT=3003 docker compose -f docker-compose.agents.yml up -d agent
```

### Option 3: Using the agent's .env file
```bash
# The .env file already contains AGENT_NAME and AGENT_PORT
docker compose -f docker-compose.agents.yml --env-file .agents/.mybot.env up -d agent
```

## What Gets Created Automatically

When you run with `AGENT_NAME=mybot`:

| Resource | Name Pattern | Example |
|----------|---------------|---------|
| Container | zeroclaw-${AGENT_NAME} | zeroclaw-mybot |
| Hostname | ${AGENT_NAME} | mybot |
| Data Volume | zeroclaw-data-${AGENT_NAME} | zeroclaw-data-mybot |
| Config Mount | ./.agents/.${AGENT_NAME}:/agent-config | ./.agents/.mybot:/agent-config |
| Tailscale Volume | tailscale-data-${AGENT_NAME} | tailscale-data-mybot |
| Port | ${AGENT_PORT}:3000 | 3003:3000 |

## For Production / Persistent Agents

If you want agents to always be available via profile names (handy, gordon, zoe, etc.),
just add them as pre-configured services in docker-compose.agents.yml:

```yaml
  mybot:
    <<: *agent-base
    container_name: zeroclaw-mybot
    hostname: mybot
    env_file:
      - .agents/shared.env
      - .agents/.mybot.env
    environment:
      - AGENT_NAME=mybot
      - ZEROCLAW_LITESTREAM_ENABLED=true
      - AGENT_CONFIG_DIR=/agent-config
    ports:
      - "3003:3000"
    volumes:
      - zeroclaw-data-mybot:/zeroclaw-data
      - tailscale-data-mybot:/var/lib/tailscale
      - ./.agents/.mybot:/agent-config:ro
    profiles: [mybot]
    command: ["start-agent-with-litestream.sh", "gateway", "--port", "3000", "--host", "[::]"]
```

Then start with:
```bash
docker compose -f docker-compose.agents.yml --profile mybot up -d
```

## Benefits

✅ **No compose editing** for temporary/ephemeral agents  
✅ **Environment-driven** - Just set AGENT_NAME and AGENT_PORT  
✅ **Automatic volume creation** - Docker creates named volumes dynamically  
✅ **Config backup** - AGENT_CONFIG_DIR env var enables automatic config backup  
✅ **Works for 1 or 1000 agents** - Same pattern scales infinitely  

## Config Backup Still Works!

The `backup_workspace` tool automatically includes config because:
1. Each agent's `.env` sets: `AGENT_CONFIG_DIR=/agent-config`
2. Docker Compose mounts: `./.agents/.${AGENT_NAME}:/agent-config:ro`
3. Backup tool reads `AGENT_CONFIG_DIR` and includes it

```bash
# Inside any agent:
zeroclaw tools backup_workspace '{"action": "create"}'
# → Backs up workspace + config from /agent-config
```

## Migration from Old Pattern

Already have agents running? Just update the compose file:

**Old way (hardcoded):**
```yaml
  handy:
    container_name: zeroclaw-handy
    volumes:
      - zeroclaw-data-handy:/zeroclaw-data
```

**New way (variable-based, optional for pre-configured agents):**
```yaml
  handy:
    <<: *agent-base  # Uses generic base
    container_name: zeroclaw-handy
    env_file: .agents/.handy.env  # AGENT_NAME and AGENT_PORT here
    volumes:
      - zeroclaw-data-handy:/zeroclaw-data
      - ./.agents/.handy:/agent-config:ro  # Config backup
```

## Summary

| Task | Old Way | New Way |
|------|---------|---------|
| Create agent | Edit compose, add service | `./agent.sh create mybot` |
| Start agent | `docker compose --profile mybot up` | `./agent.sh start mybot` OR set env vars |
| Config backup | Not included | Automatic via AGENT_CONFIG_DIR |
| Scale | Limited by compose complexity | Unlimited - same pattern |

**Status: Truly scalable multi-agent system!** 🚀
