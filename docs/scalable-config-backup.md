# Scalable Agent Config Backup

## The Problem (Solved)

**Issue:** Agent-specific mounts in docker-compose are unmanageable with many agents.

**Solution:** Generic pattern using `AGENT_CONFIG_DIR` environment variable.

## How It Works

### 1. Per-Agent Mount Pattern

Each agent gets ONE additional mount line in docker-compose:

```yaml
services:
  handy:
    volumes:
      - zeroclaw-data-handy:/zeroclaw-data
      - tailscale-data-handy:/var/lib/tailscale
      - ./.agents/.handy:/agent-config:ro  # ← Config files mounted here
```

### 2. Environment Variable

Each agent's `.env` file sets:

```bash
AGENT_CONFIG_DIR=/agent-config
```

### 3. Automatic Backup Inclusion

The `backup_workspace` tool automatically detects `AGENT_CONFIG_DIR` and includes it in backups:

```rust
// In backup.rs - automatically includes config if env var is set
let config_dir = self.get_config_dir();  // Checks AGENT_CONFIG_DIR
if let Some(ref config) = config_dir {
    // Include both workspace AND config in backup
    tar czf backup.tar.gz -C /zeroclaw-data . -C /agent-config .
}
```

## Creating New Agents (Scalable)

Use the agent creation script - it outputs a complete, ready-to-use service template:

```bash
./scripts/agent.sh create mynewagent
```

Output includes:
```yaml
  mynewagent:
    <<: *agent-base
    container_name: zeroclaw-mynewagent
    hostname: mynewagent
    env_file:
      - .agents/shared.env
      - .agents/.mynewagent.env
    environment:
      - AGENT_NAME=mynewagent
      - ZEROCLAW_GATEWAY_PORT=3000
      - ZEROCLAW_LITESTREAM_ENABLED=true
    ports:
      - "3003:3000"  # Auto-assigned next available port
    volumes:
      - zeroclaw-data-mynewagent:/zeroclaw-data
      - tailscale-data-mynewagent:/var/lib/tailscale
      - ./.agents/.mynewagent:/agent-config:ro  # ← Config mount
    profiles: [mynewagent]
    command: ["start-agent-with-litestream.sh", "gateway", "--port", "3000", "--host", "[::]"]

volumes:
  zeroclaw-data-mynewagent:
  tailscale-data-mynewagent:
```

Just copy-paste into `docker-compose.agents.yml` and you're done!

## What's Backed Up

When you run `backup_workspace action="create"`:

### Included Automatically:
- ✅ **Workspace files** (`/zeroclaw-data/workspace/*`)
- ✅ **SQLite database** (`memory.db` with embeddings)
- ✅ **Agent config files** (via `AGENT_CONFIG_DIR`)
  - `IDENTITY.md`, `SOUL.md`, `AGENTS.md`
  - `USER.md`, `TOOLS.md`, `MEMORY.md`
  - Custom skills in `skills/` subdirectory
- ✅ **State files** (model cache, preferences)

### NOT Included (by design):
- ❌ `.env` files with secrets → Keep local/secure
- ❌ Tailscale state → Can re-authenticate easily

## No Per-Agent Bucket Configuration! 🎉

All agents share the same MinIO bucket:

```
zeroclaw-backups (shared bucket)
├── litestream/
│   ├── handy/          # Continuous DB streaming
│   ├── gordon/         # (WAL files, ~95% space savings)
│   └── zoe/
└── self-backups/
    ├── self-backup-20250115-143022.tar.gz  # From handy
    ├── self-backup-20250116-091530.tar.gz  # From gordon
    └── ...
```

Each agent uses the same `MINIO_BUCKET=zeroclaw-backups` env var.
The backup tool automatically extracts the agent name from `AGENT_NAME` for organization.

## Testing the Backup

```bash
# 1. Create an agent
./scripts/agent.sh create testagent
# (Copy the service template to docker-compose.agents.yml)

# 2. Start the agent
./scripts/agent.sh start testagent

# 3. Verify config is mounted
docker exec -it zeroclaw-testagent ls -la /agent-config/

# 4. Create backup from inside the agent
docker exec -it zeroclaw-testagent bash
zeroclaw tools backup_workspace '{"action": "create"}'

# 5. Check backup includes config
tar tzf /zeroclaw-data/.zeroclaw/backups/self-backup-*.tar.gz | grep -E "(IDENTITY|SOUL|AGENTS)"

# 6. Sync to MinIO
zeroclaw tools backup_workspace '{"action": "sync", "backup_file": "/path/to/backup.tar.gz"}'
```

## Migration for Existing Agents

Already have agents running? Add the config mount:

1. **Edit `docker-compose.agents.yml`** and add to each agent:
   ```yaml
   volumes:
     - ./.agents/.AGENTNAME:/agent-config:ro
   ```

2. **Edit each agent's `.env` file** and add:
   ```bash
   AGENT_CONFIG_DIR=/agent-config
   ```

3. **Restart agents**:
   ```bash
   ./scripts/agent.sh restart handy
   ./scripts/agent.sh restart gordon
   ./scripts/agent.sh restart zoe
   ```

4. **Test backup**:
   ```bash
   ./scripts/agent.sh shell handy
   # Inside container:
   zeroclaw tools backup_workspace '{"action": "create"}'
   ```

## Architecture Benefits

| Aspect | Before | After |
|--------|--------|-------|
| **Docker Compose** | Hardcoded agent-specific mounts | Generic pattern, one line per agent |
| **New Agents** | Manual compose editing | Auto-generated service template |
| **Config Backup** | Not included | Automatic via `AGENT_CONFIG_DIR` |
| **Bucket Config** | Per-agent complexity | Shared bucket, no extra config |
| **Scalability** | Limited | Unlimited agents, same pattern |

## Summary

✅ **Scalable:** Generic pattern works for 3 or 300 agents  
✅ **Automatic:** Config files backed up without per-agent setup  
✅ **Simple:** One env var + one mount line per agent  
✅ **No duplication:** Shared bucket, no config sprawl  
✅ **Easy creation:** `agent.sh create` outputs ready-to-use template  

**Status: Production-ready scalable solution!** 🚀
