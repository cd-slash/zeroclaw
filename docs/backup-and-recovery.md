# Multi-Agent Backup & Recovery Guide

ZeroClaw's multi-agent setup uses Docker volumes for isolated storage. This guide covers backup strategies, remote storage with MinIO, and migration between servers.

## Table of Contents

- [Quick Start](#quick-start)
- [Self-Backup Tool](#self-backup-tool)
- [Database Snapshots](#database-snapshots)
- [Understanding Agent Storage](#understanding-agent-storage)
- [Local Backups](#local-backups)
- [MinIO Remote Storage](#minio-remote-storage)
- [Migration Between Servers](#migration-between-servers)
- [Automated Backups](#automated-backups)
- [Disaster Recovery](#disaster-recovery)

## Quick Start

```bash
# Backup a single agent
./scripts/agent-backup.sh backup handy

# Backup all agents
./scripts/agent-backup.sh backup-all

# Upload to MinIO (for offsite storage)
./scripts/agent-backup.sh sync-to-minio handy

# Restore from backup
./scripts/agent-backup.sh restore handy handy-20250115-143022.tar.gz
```

## Self-Backup Tool

Agents can back themselves up using the built-in `backup_workspace` tool. This allows agents to:

- Create backups before major changes
- Sync backups to MinIO for remote storage
- List available backups
- Schedule periodic self-backups

### Using the Tool

The agent can execute these commands:

```
# Create a local backup
backup_workspace action="create" destination="/zeroclaw-data/.zeroclaw/backups"

# List available backups
backup_workspace action="list" location="all"

# Sync a specific backup to MinIO
backup_workspace action="sync" backup_file="/zeroclaw-data/.zeroclaw/backups/self-backup-20250115-143022.tar.gz"
```

### Configuration

For MinIO sync to work from within the container, set these environment variables in your `.agents/.agent.env`:

```bash
# MinIO Configuration (for self-backup tool)
MINIO_ENDPOINT=https://minio.your-tailnet.ts.net:9000
MINIO_ACCESS_KEY=your-access-key
MINIO_SECRET_KEY=your-secret-key
MINIO_BUCKET=zeroclaw-backups
```

**Note:** These are the same credentials used by the host-side backup script. When the agent creates a backup and syncs it, the backup will be available via both the agent's tool and the host script.

### Example: Agent Self-Backup Workflow

An agent might do this before a major refactoring:

```
1. "Let me create a backup before making these changes"
2. backup_workspace action="create"
3. "Backup created. Now syncing to MinIO for safety..."
4. backup_workspace action="sync" backup_file="/path/to/latest.tar.gz"
5. "Now proceeding with the changes..."
```

### Advantages of Self-Backup

1. **Agent-initiated:** Agent decides when backup is needed
2. **Context-aware:** Agent knows when it's about to make risky changes
3. **Always available:** Works even if host script is not accessible
4. **Same format:** Compatible with host-side restore operations

## Database Snapshots

In addition to full workspace backups, agents can create **point-in-time snapshots** of their SQLite memory database. These are faster and more lightweight than full backups, perfect for:

- Testing different memory configurations
- Creating rollback points before risky memory operations
- Experimenting with memory organization
- Quick recovery from mistakes

### Using Database Snapshots

```
# Create a snapshot before a risky operation
snapshot_memory action="create" name="before-cleanup"

# List all available snapshots
snapshot_memory action="list"

# Rollback to a previous snapshot if something goes wrong
snapshot_memory action="rollback" snapshot="before-cleanup-20250115-143022"

# Delete old snapshots to save space
snapshot_memory action="delete" snapshot="old-snapshot-name"
```

### Snapshot vs Full Backup

| Feature | `snapshot_memory` | `backup_workspace` |
|---------|-------------------|---------------------|
| **Scope** | SQLite database only | Entire workspace |
| **Speed** | Fast (file copy) | Slower (archive creation) |
| **Use case** | Point-in-time recovery | Disaster recovery, migration |
| **Frequency** | Multiple per session | Daily/weekly |
| **MinIO sync** | ❌ No | ✅ Yes |
| **Reversible** | ✅ Rollback support | ✅ Full restore |

### When to Use Each

**Use `snapshot_memory` when:**
- Experimenting with memory organization
- Before bulk memory deletions
- Testing different memory strategies
- You need quick rollback capability

**Use `backup_workspace` when:**
- Migrating to a new server
- Major system changes
- Need remote/MinIO storage
- Full disaster recovery required

**Full documentation:** [Database Snapshot Tool](database-snapshot-tool.md)

### Limitations

- Self-backups go to `/zeroclaw-data/.zeroclaw/backups/` by default
- MinIO credentials must be configured in container environment
- Large workspaces may take time to archive (1-2 minutes for 500MB)

## Understanding Agent Storage

### Storage Architecture

Each agent has completely isolated storage:

```
Docker Volume: zeroclaw-data-handy
├── .zeroclaw/
│   ├── memory.db              # SQLite vector memory (primary)
│   ├── config.toml            # Agent configuration
│   └── workspace/
│       ├── MEMORY.md          # Curated long-term memory
│       ├── memory/            # Daily logs (YYYY-MM-DD.md)
│       ├── sessions/          # Session history
│       ├── state/             # Agent state
│       ├── cron/              # Scheduled tasks
│       └── skills/            # Custom skills

Docker Volume: tailscale-data-handy
└── /var/lib/tailscale/        # VPN state (optional)
```

### What Gets Backed Up

The backup captures:
- ✅ SQLite memory database (`memory.db`)
- ✅ All workspace files (MEMORY.md, daily logs, sessions)
- ✅ Agent configuration (`config.toml`)
- ✅ Custom skills
- ✅ Session history and state

## Local Backups

### Creating Backups

```bash
# Backup specific agent
./scripts/agent-backup.sh backup handy
# Output: .backups/handy-20250115-143022.tar.gz

# Backup all agents at once
./scripts/agent-backup.sh backup-all
# Output: .backups/all-agents-20250115-143022.tar.gz
```

### Listing Backups

```bash
# List all backups
./scripts/agent-backup.sh list

# List backups for specific agent
./scripts/agent-backup.sh list handy
```

### Restoring from Local Backup

```bash
# Restore from a specific backup file
./scripts/agent-backup.sh restore handy handy-20250115-143022.tar.gz

# The agent will be stopped, data restored, then ready to start
./scripts/agent.sh start handy
```

**⚠️ Warning:** Restore overwrites ALL existing data for the agent.

## MinIO Remote Storage

### Why MinIO?

MinIO provides:
- S3-compatible object storage
- Works over Tailscale (secure, private network)
- Self-hosted (you control your data)
- Efficient for backups (deduplication, compression)

### Setup

#### 1. Configure MinIO Access

Set environment variables (add to your `.bashrc` or `.zshrc`):

```bash
# MinIO Configuration
export MINIO_ENDPOINT="http://your-minio-server:9000"
export MINIO_ACCESS_KEY="your-access-key"
export MINIO_SECRET_KEY="your-secret-key"
export MINIO_BUCKET="zeroclaw-backups"  # Optional, defaults to 'zeroclaw-backups'
```

Or create `.env` file in project root:

```bash
MINIO_ENDPOINT=http://your-minio-server:9000
MINIO_ACCESS_KEY=your-access-key
MINIO_SECRET_KEY=your-secret-key
MINIO_BUCKET=zeroclaw-backups
```

#### 2. Install MinIO Client (mc)

```bash
# macOS
brew install minio/stable/mc

# Linux
curl https://dl.min.io/client/mc/release/linux-amd64/mc \
  --create-dirs -o ~/minio-binaries/mc
chmod +x ~/minio-binaries/mc
export PATH=$PATH:~/minio-binaries/
```

Or use AWS CLI:

```bash
# AWS CLI works with MinIO's S3-compatible API
pip install awscli
```

#### 3. Test Connection

```bash
mc alias set myminio $MINIO_ENDPOINT $MINIO_ACCESS_KEY $MINIO_SECRET_KEY
mc ls myminio
```

### Backup to MinIO

```bash
# Create local backup and upload to MinIO
./scripts/agent-backup.sh backup handy
./scripts/agent-backup.sh sync-to-minio handy

# Or specify a specific backup file
./scripts/agent-backup.sh sync-to-minio handy handy-20250115-143022.tar.gz
```

### Restore from MinIO

```bash
# Download and restore latest backup
./scripts/agent-backup.sh sync-from-minio handy

# Download specific backup by name
./scripts/agent-backup.sh sync-from-minio handy handy-20250110.tar.gz
```

### MinIO Organization

Backups are organized in MinIO as:

```
zeroclaw-backups/          (bucket)
├── handy/
│   ├── handy-20250115-143022.tar.gz
│   ├── handy-20250114-090015.tar.gz
│   └── handy-20250113-220030.tar.gz
├── gordon/
│   ├── gordon-20250115-143025.tar.gz
│   └── ...
└── zoe/
    └── ...
```

## Migration Between Servers

### Scenario: Moving Agent to New Server

#### On Source Server

```bash
# 1. Stop the agent
./scripts/agent.sh stop handy

# 2. Create backup
./scripts/agent-backup.sh backup handy

# 3. Upload to MinIO
./scripts/agent-backup.sh sync-to-minio handy
```

#### On Destination Server

```bash
# 1. Clone the ZeroClaw repository
git clone <your-repo> zeroclaw
cd zeroclaw

# 2. Ensure agent config exists
# Copy .agents/.handy.env and .agents/.handy/ from source
# Or recreate: ./scripts/agent.sh create handy

# 3. Download and restore from MinIO
./scripts/agent-backup.sh sync-from-minio handy

# 4. Start the agent
./scripts/agent.sh start handy
```

### Scenario: Complete Environment Migration

```bash
# Source server - backup everything
./scripts/agent-backup.sh backup-all
./scripts/agent-backup.sh sync-to-minio all-agents-latest

# Destination server - restore everything
./scripts/agent-backup.sh sync-from-minio all-agents-latest

# Start all agents
./scripts/agent.sh start handy
./scripts/agent.sh start gordon
./scripts/agent.sh start zoe
```

## Automated Backups

### Using Cron

Edit crontab:

```bash
crontab -e
```

Add backup jobs:

```bash
# Daily backup of all agents at 2 AM
0 2 * * * cd /path/to/zeroclaw && ./scripts/agent-backup.sh backup-all >> .backups/backup.log 2>&1

# Weekly sync to MinIO on Sundays at 3 AM
0 3 * * 0 cd /path/to/zeroclaw && ./scripts/agent-backup.sh sync-to-minio handy >> .backups/sync.log 2>&1
```

### Using Systemd Timer (Linux)

Create `/etc/systemd/system/zeroclaw-backup.service`:

```ini
[Unit]
Description=ZeroClaw Agent Backup

[Service]
Type=oneshot
WorkingDirectory=/path/to/zeroclaw
ExecStart=/path/to/zeroclaw/scripts/agent-backup.sh backup-all
Environment=MINIO_ENDPOINT=http://your-minio:9000
Environment=MINIO_ACCESS_KEY=your-key
Environment=MINIO_SECRET_KEY=your-secret
```

Create `/etc/systemd/system/zeroclaw-backup.timer`:

```ini
[Unit]
Description=Run ZeroClaw backup daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
```

Enable:

```bash
sudo systemctl daemon-reload
sudo systemctl enable zeroclaw-backup.timer
sudo systemctl start zeroclaw-backup.timer
```

### Retention Policy

Clean up old backups locally:

```bash
# Keep only last 7 days of backups
find .backups -name "*.tar.gz" -mtime +7 -delete

# Or keep only last 10 backups per agent
ls -t .backups/handy-*.tar.gz | tail -n +11 | xargs rm -f
```

For MinIO, use lifecycle policies:

```bash
# Set 30-day retention on bucket
mc ilm add myminio/zeroclaw-backups --expiry-days 30
```

## Disaster Recovery

### Recovery Scenarios

#### 1. Accidental Data Deletion

```bash
# List available backups
./scripts/agent-backup.sh list handy

# Stop the agent
./scripts/agent.sh stop handy

# Restore from backup
./scripts/agent-backup.sh restore handy handy-20250115-143022.tar.gz

# Start the agent
./scripts/agent.sh start handy
```

#### 2. Server Failure

```bash
# On new server
# 1. Install Docker, Docker Compose
# 2. Clone ZeroClaw repository
# 3. Download all backups from MinIO

for agent in handy gordon zoe; do
    ./scripts/agent-backup.sh sync-from-minio $agent
done

# 4. Start all agents
./scripts/agent.sh start handy
./scripts/agent.sh start gordon
./scripts/agent.sh start zoe
```

#### 3. Database Corruption

```bash
# If memory.db is corrupted, restore from backup
./scripts/agent.sh stop handy
./scripts/agent-backup.sh restore handy handy-latest.tar.gz
./scripts/agent.sh start handy
```

### Testing Backups

Regularly test your backups:

```bash
# Test restore process
./scripts/agent-backup.sh restore handy handy-latest.tar.gz
./scripts/agent.sh start handy
./scripts/agent.sh logs handy -f

# Verify agent works correctly, then
curl http://localhost:3000/health || echo "Agent not healthy!"
```

## Best Practices

### 1. Backup Strategy

- **Daily automated backups** to local storage
- **Weekly sync to MinIO** for offsite storage
- **Before major changes** (upgrades, migrations)
- **Test restores monthly**

### 2. Security

- ✅ Encrypt MinIO at rest if sensitive data
- ✅ Use Tailscale for secure MinIO access
- ✅ Rotate MinIO credentials periodically
- ❌ Never commit backup files to git
- ❌ Don't backup to public cloud without encryption

### 3. Storage Planning

Estimate storage per agent:
- SQLite database: ~50-500MB (depends on conversation history)
- Workspace files: ~10-100MB (MEMORY.md, skills, etc.)
- Daily notes: ~1-5MB per day
- **Total per agent:** ~500MB - 2GB over time

### 4. SQLite-Specific Notes

Since we're using SQLite:

```bash
# Check database size
docker run --rm -v zeroclaw-data-handy:/data alpine \
    ls -lh /data/.zeroclaw/memory.db

# SQLite is self-contained - the .db file is all you need
# The backup script captures this automatically
```

## Troubleshooting

### Backup Fails

```bash
# Check Docker daemon
docker ps

# Check disk space
df -h

# Check volume exists
docker volume ls | grep zeroclaw-data-handy
```

### MinIO Sync Fails

```bash
# Test MinIO connection
mc alias set myminio $MINIO_ENDPOINT $MINIO_ACCESS_KEY $MINIO_SECRET_KEY
mc ls myminio

# Check credentials are set
echo $MINIO_ACCESS_KEY
```

### Restore Fails

```bash
# Verify backup file integrity
tar tzf backup-file.tar.gz > /dev/null && echo "Valid archive"

# Check if agent exists
ls .agents/.handy.env

# Manual restore if needed
docker run --rm \
    -v zeroclaw-data-handy:/target \
    -v $(pwd)/.backups:/backup:ro \
    alpine tar xzf /backup/handy-xxx.tar.gz -C /target
```

## Advanced Topics

### Custom Backup Scripts

Create agent-specific backup logic:

```bash
#!/bin/bash
# backup-handy.sh - Custom backup for handy agent

# Pre-backup: run health check
./scripts/agent.sh logs handy --tail 5 | grep "healthy" || exit 1

# Create backup
./scripts/agent-backup.sh backup handy

# Post-backup: sync to MinIO and notify
./scripts/agent-backup.sh sync-to-minio handy
curl -X POST "https://your-notification-service" \
    -d "Handy backup completed"
```

### Incremental Backups

For large databases, consider:

```bash
# SQLite incremental backup
sqlite3 /path/to/memory.db ".backup '/path/to/memory-backup.db'"

# Or use WAL mode for continuous backup
sqlite3 /path/to/memory.db "PRAGMA journal_mode=WAL;"
```

### Cross-Region Replication

With MinIO, replicate backups across regions:

```bash
# Set up bucket replication
mc replicate add myminio/zeroclaw-backups \
    --remote-bucket http://backup-region:9000/zeroclaw-backups \
    --arn 'arn:minio:replication::xxx:zeroclaw-backups'
```

## Summary

- **SQLite is default** and stored in isolated Docker volumes per agent
- **Backups** are gzipped tar archives of the entire agent volume
- **MinIO integration** provides secure, self-hosted remote storage
- **Migration** is as simple as backup → upload → download → restore
- **Automation** via cron or systemd ensures regular backups
- **Testing** backups regularly prevents surprises during disasters

Your agents' memories and configurations are now fully portable and protected!
