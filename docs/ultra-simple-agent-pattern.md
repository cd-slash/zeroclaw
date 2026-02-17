# Ultra-Simple Multi-Agent Pattern

## The Insight

**You were absolutely right!** Docker Compose already handles naming automatically:
- Service name `server` + profile `handy` = container `zeroclaw-handy-server-1`
- Anonymous volumes + profile = automatically isolated per agent
- No variable substitution needed!

## How Simple It Is Now

### docker-compose.agents.yml
```yaml
name: zeroclaw  # Project name

services:
  server:  # Just "server" - Docker adds the profile
    env_file:
      - .agents/.shared.env
      - .agents/.handy.env  # Agent-specific config
    ports:
      - "3000:3000"
    volumes:
      - data:/zeroclaw-data      # Anonymous - isolated per profile
      - tailscale:/var/lib/tailscale
      - ./.agents/.handy:/agent-config:ro  # Config for backup
    profiles: [handy]  # Profile name used for isolation
```

### Usage

```bash
# Start handy
# Docker creates: zeroclaw-handy-server-1
# Volumes: zeroclaw_handy_data, zeroclaw_handy_tailscale
docker compose -f docker-compose.agents.yml --profile handy up -d

# Start gordon  
docker compose -f docker-compose.agents.yml --profile gordon up -d

# Start zoe
docker compose -f docker-compose.agents.yml --profile zoe up -d
```

That's it! No environment variables. No container_name. No variable substitution.

## What Docker Handles Automatically

| Resource | Pattern | Example (profile=handy) |
|----------|---------|---------------------------|
| **Container** | `{project}-{profile}-{service}-{n}` | `zeroclaw-handy-server-1` |
| **Data Volume** | `{project}_{profile}_data` | `zeroclaw_handy_data` |
| **Tailscale Volume** | `{project}_{profile}_tailscale` | `zeroclaw_handy_tailscale` |
| **Network** | `{project}_{profile}` | `zeroclaw_handy` |

All isolation is automatic based on profile name!

## Creating New Agents

```bash
# 1. Create agent config
./scripts/agent.sh create mybot

# 2. Start it (Docker handles everything)
docker compose -f docker-compose.agents.yml --profile mybot up -d
```

Or add to docker-compose for persistence:
```yaml
  mybot:
    <<: *agent-base
    profiles: [mybot]
    env_file:
      - .agents/.shared.env
      - .agents/.mybot.env
    ports:
      - "3003:3000"
    volumes:
      - data:/zeroclaw-data
      - tailscale:/var/lib/tailscale
      - ./.agents/.mybot:/agent-config:ro
```

## Config Backup Still Works

The `backup_workspace` tool automatically includes configs:

1. Each agent's `.env` sets: `AGENT_CONFIG_DIR=/agent-config`
2. Docker Compose mounts: `./.agents/.{agent}:/agent-config:ro`
3. Backup tool reads `AGENT_CONFIG_DIR` and includes it

```bash
# Inside any agent container
zeroclaw tools backup_workspace '{"action": "create"}'
```

## Benefits

✅ **Zero variable substitution** - Docker handles all naming  
✅ **Anonymous volumes** - Isolated automatically by profile  
✅ **Simple service definition** - Just add a profile  
✅ **No environment variables needed** - Just use `--profile`  
✅ **Scales infinitely** - Same pattern for 3 or 300 agents  

## Complete Example

```bash
# Build once
docker compose -f docker-compose.agents.yml build

# Start multiple agents
docker compose -f docker-compose.agents.yml --profile handy up -d
docker compose -f docker-compose.agents.yml --profile gordon up -d
docker compose -f docker-compose.agents.yml --profile zoe up -d

# Check containers
docker ps | grep zeroclaw
# zeroclaw-handy-server-1
# zeroclaw-gordon-server-1  
# zeroclaw-zoe-server-1

# Check volumes
docker volume ls | grep zeroclaw
# zeroclaw_handy_data
# zeroclaw_gordon_data
# zeroclaw_zoe_data

# Logs
docker compose -f docker-compose.agents.yml --profile handy logs -f

# Shell
docker compose -f docker-compose.agents.yml --profile handy exec server bash
```

## Status

**This is the ultimate simple pattern!**

- No hardcoded service names per agent
- No variable substitution complexity  
- No explicit container naming
- Just: profile name → automatic isolation

Docker Compose does the work. We just add profiles. 🎉
