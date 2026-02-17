# Agent Self-Backup Tool

The `backup_workspace` tool allows agents to create backups of their own workspace and sync them to MinIO for remote storage.

## Overview

This tool is built into ZeroClaw and available to all agents. It provides:

- **Self-initiated backups:** Agents can create backups before risky operations
- **MinIO integration:** Sync backups to remote storage for disaster recovery
- **Backup management:** List available backups (local and remote)
- **Safety first:** Protect agent state before major changes

## Tool Specification

```json
{
  "name": "backup_workspace",
  "description": "Create a backup of the agent's workspace and optionally sync to MinIO remote storage.",
  "parameters": {
    "action": {
      "type": "string",
      "enum": ["create", "list", "sync"],
      "required": true
    },
    "destination": {
      "type": "string",
      "description": "Directory path for new backup (default: /zeroclaw-data/.zeroclaw/backups)"
    },
    "backup_file": {
      "type": "string",
      "description": "Path to backup file for sync action"
    },
    "location": {
      "type": "string",
      "enum": ["local", "minio", "all"],
      "default": "all"
    }
  }
}
```

## Usage Examples

### Create a Backup

```
backup_workspace action="create"
```

**Result:**
```
Backup created successfully: /zeroclaw-data/.zeroclaw/backups/self-backup-20250115-143022.tar.gz (45.67 MB)
```

### Create Backup in Custom Location

```
backup_workspace action="create" destination="/tmp/my-backup"
```

### List All Backups

```
backup_workspace action="list" location="all"
```

**Result:**
```
Local backups:
  - self-backup-20250115-143022.tar.gz (45.67 MB)
  - self-backup-20250114-090015.tar.gz (43.21 MB)

MinIO backups:
  - self-backup-20250115-143022.tar.gz
  - self-backup-20250114-090015.tar.gz
```

### Sync Backup to MinIO

```
backup_workspace action="sync" backup_file="/zeroclaw-data/.zeroclaw/backups/self-backup-20250115-143022.tar.gz"
```

**Result:**
```
Backup synced to MinIO: zeroclaw-backups/self-backups/self-backup-20250115-143022.tar.gz
```

## Configuration

For MinIO sync to work, configure these environment variables in your agent's `.env` file:

```bash
# .agents/.handy.env
MINIO_ENDPOINT=https://minio.your-tailnet.ts.net:9000
MINIO_ACCESS_KEY=your-access-key
MINIO_SECRET_KEY=your-secret-key
MINIO_BUCKET=zeroclaw-backups
```

**Note:** These are the same credentials used by the host-side backup script. Both tools can access the same MinIO bucket.

## Best Practices

### When to Create Backups

Create a backup before:
- Major refactoring or restructuring
- Destructive operations (deleting files, wiping data)
- Complex multi-step operations that could fail
- Important milestones

### Example Workflow

```
User: "I want to reorganize this entire project structure."

Agent:
1. "This is a significant change. Let me create a backup first."
2. backup_workspace action="create"
3. "Backup created at 45.67 MB. Now proceeding with reorganization..."
4. [Perform restructuring]
5. "Restructuring complete. Would you like me to sync this backup to MinIO for extra safety?"
```

### Integrating with Memory

After creating a backup, store metadata in memory:

```
memory_store key="backup-before-refactor" value="Created backup self-backup-20250115-143022.tar.gz (45.67 MB) before project restructure"
```

## Backup Contents

The backup captures:
- ✅ SQLite memory database (`memory.db`)
- ✅ Configuration files (`config.toml`)
- ✅ Workspace files (`MEMORY.md`, `skills/`, etc.)
- ✅ Session history and state
- ✅ Daily notes (`memory/YYYY-MM-DD.md`)

## Security Considerations

1. **Path validation:** Only absolute paths are allowed (prevents directory traversal)
2. **No secrets in backups:** API keys are in env files, not in the backup
3. **Workspace-only:** Backs up `/zeroclaw-data`, not system files
4. **Optional MinIO:** Remote sync only happens if explicitly configured

## Comparison: Self-Backup vs Host Script

| Feature | Self-Backup Tool | Host Script (`agent-backup.sh`) |
|---------|------------------|----------------------------------|
| **Initiated by** | Agent | Human operator |
| **Context** | Agent knows when backup needed | Scheduled or manual |
| **MinIO sync** | ✅ Yes (if configured) | ✅ Yes |
| **Restore** | ❌ No (backup only) | ✅ Yes (full restore) |
| **Scheduling** | Via agent logic | Via cron/systemd |
| **Access** | Always available | Requires host access |

## Troubleshooting

### "MinIO not configured" Error

The MinIO environment variables are not set. Add them to `.agents/.agent.env`:

```bash
MINIO_ENDPOINT=https://minio.your-tailnet.ts.net:9000
MINIO_ACCESS_KEY=your-key
MINIO_SECRET_KEY=your-secret
```

### Backup File Not Found

When syncing, provide the full absolute path:

```
backup_workspace action="sync" backup_file="/zeroclaw-data/.zeroclaw/backups/self-backup-20250115-143022.tar.gz"
```

### Permission Denied

Ensure the agent has write access to the destination directory:

```
# Check permissions
shell command="ls -la /zeroclaw-data/.zeroclaw/"
```

## Integration with AGENTS.md

Your agent's `AGENTS.md` should reference the backup tool:

```markdown
## Safety Guidelines

Before major changes:
1. Create a backup: backup_workspace action="create"
2. If MinIO configured, also sync to remote
3. Proceed with changes

## Crash Recovery

- If operation fails, data can be restored from backup
- Check backup_workspace action="list" for available backups
- Host admin can restore using: ./scripts/agent-backup.sh restore agent backup-file.tar.gz
```

## Migration Workflow

**Scenario:** Agent wants to move to a new server

1. **On source server:**
   ```
   backup_workspace action="create"
   backup_workspace action="sync" backup_file="/path/to/latest.tar.gz"
   ```

2. **On destination server:**
   ```bash
   # Admin runs on host
   ./scripts/agent-backup.sh sync-from-minio handy
   ./scripts/agent.sh start handy
   ```

## See Also

- [Backup and Recovery Guide](backup-and-recovery.md) - Full backup documentation
- [Multi-Agent Setup](multi-agent-setup.md) - General multi-agent information
- `agent-backup.sh` - Host-side backup management script
