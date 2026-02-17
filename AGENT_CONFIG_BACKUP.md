# Agent Config Backup Solution

## Summary

✅ **The .md config files are now backed up automatically** using a **scalable, generic pattern**!

## The Solution: Generic Pattern

Instead of hardcoded agent-specific mounts, we use a **simple, scalable approach**:

### 1. Per-Agent Config Mount

Each agent adds **one line** to their service in docker-compose:

```yaml
volumes:
  - ./.agents/.handy:/agent-config:ro  # Config files mounted here
```

### 2. Environment Variable

Each agent's `.env` file sets:

```bash
AGENT_CONFIG_DIR=/agent-config  # Tells backup tool where to find config
```

### 3. Automatic Backup Inclusion

The `backup_workspace` tool reads `AGENT_CONFIG_DIR` and automatically includes it:

```rust
fn get_config_dir(&self) -> Option<PathBuf> {
    std::env::var("AGENT_CONFIG_DIR")
        .ok()
        .map(PathBuf::from)
        .filter(|p| p.exists())
}
```

## What's Backed Up

When you run `backup_workspace action="create"`:

### ✅ **Agent Config Files** (via AGENT_CONFIG_DIR)
- `IDENTITY.md` - Who the agent is
- `SOUL.md` - Core personality and values
- `AGENTS.md` - Session behavior rules
- `USER.md` - User preferences and context
- `TOOLS.md` - Local tool notes
- `MEMORY.md` - Curated long-term memory
- Custom skills in `skills/` subdirectory

### ✅ **Workspace Files**
- Project files and code
- Documentation
- Files created during agent sessions

### ✅ **SQLite Memory Database**
- All memories and embeddings
- Conversation history
- Learned facts

### ✅ **State Files**
- Model cache
- User preferences

## Creating New Agents (Scalable!)

```bash
./scripts/agent.sh create mynewagent
```

This outputs a **complete, ready-to-use service template** including the config mount. Just copy-paste into `docker-compose.agents.yml`:

```yaml
  mynewagent:
    <<: *agent-base
    container_name: zeroclaw-mynewagent
    hostname: mynewagent
    env_file:
      - .agents/.shared.env
      - .agents/.mynewagent.env
    environment:
      - AGENT_NAME=mynewagent
      - ZEROCLAW_GATEWAY_PORT=3000
      - ZEROCLAW_LITESTREAM_ENABLED=true
    ports:
      - "3003:3000"
    volumes:
      - zeroclaw-data-mynewagent:/zeroclaw-data
      - tailscale-data-mynewagent:/var/lib/tailscale
      - ./.agents/.mynewagent:/agent-config:ro  # ← Config backup mount
    profiles: [mynewagent]
    command: ["start-agent-with-litestream.sh", "gateway", "--port", "3000", "--host", "[::]"]
```

## No Per-Agent Bucket Configuration! 🎉

All agents use the **shared bucket**:

```
MinIO Bucket: zeroclaw-backups
├── litestream/           # Continuous DB streaming (~95% space savings)
│   ├── handy/
│   ├── gordon/
│   └── zoe/
└── self-backups/         # Full workspace backups from backup_workspace
    ├── self-backup-20250115-143022.tar.gz
    ├── self-backup-20250116-091530.tar.gz
    └── ...
```

Just set `MINIO_BUCKET=zeroclaw-backups` in `.agents/.shared.env` and all agents use it!

## What's NOT Backed Up (by design)

- ❌ `.env` files with secrets → Keep these secure/local
- ❌ Tailscale state → Can re-authenticate easily

## Testing

```bash
# 1. Restart agents with new mounts
./scripts/agent.sh restart handy

# 2. Verify config is mounted
docker exec zeroclaw-handy ls -la /agent-config/

# 3. Create backup
docker exec -it zeroclaw-handy bash
zeroclaw tools backup_workspace '{"action": "create"}'

# 4. Check backup includes config
tar tzf /zeroclaw-data/.zeroclaw/backups/self-backup-*.tar.gz | grep "agent-config"
# Should show:
# agent-config/
# agent-config/IDENTITY.md
# agent-config/SOUL.md
# etc.
```

## Migration for Existing Agents

If you have existing agents without config backup:

1. **Add config mount** to `docker-compose.agents.yml`:
   ```yaml
   volumes:
     - ./.agents/.handy:/agent-config:ro
   ```

2. **Add env var** to each agent's `.env`:
   ```bash
   AGENT_CONFIG_DIR=/agent-config
   ```

3. **Restart**:
   ```bash
   ./scripts/agent.sh restart handy
   ```

## Three-Tier Backup Strategy

| Tier | Tool | What | Frequency | Recovery |
|------|------|------|-----------|----------|
| **1. Continuous** | Litestream | SQLite DB | Real-time | Point-in-time to any second |
| **2. Self-Service** | backup_workspace | Full workspace + config | On-demand/weekly | Full restore from any backup |
| **3. Snapshots** | snapshot_memory | SQLite only | Before risky ops | Quick local rollback |

## Architecture Benefits

| Aspect | Before | After |
|--------|--------|-------|
| **Docker Compose** | Hardcoded mounts | Generic pattern, scalable |
| **New Agents** | Manual editing | Auto-generated template |
| **Config Backup** | Not included | Automatic via env var |
| **Bucket Config** | Per-agent complexity | Shared bucket |
| **Scalability** | Limited | Works for 3 or 300 agents |

## Status

✅ **Config files backed up automatically**  
✅ **Scalable generic pattern** (no hardcoded mounts)  
✅ **Agent creation script outputs ready-to-use templates**  
✅ **No per-agent bucket configuration**  
✅ **Three-tier backup strategy**  

**Status: Production-ready!** 🚀

---

For detailed documentation, see: `docs/scalable-config-backup.md`
