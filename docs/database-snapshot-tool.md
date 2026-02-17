# Database Snapshot Tool

The `snapshot_memory` tool allows agents to create point-in-time snapshots of their SQLite memory database and rollback to previous states when needed.

## Overview

This tool provides database-level snapshots that are:
- **Fast:** Creates a copy of the database file (not a full backup)
- **Lightweight:** Can be done frequently (before risky operations)
- **Reversible:** Can rollback to any previous snapshot
- **Safe:** Automatically creates a backup of current state before rollback

## Comparison: Snapshot vs Full Backup

| Feature | `snapshot_memory` | `backup_workspace` |
|---------|-------------------|---------------------|
| **Scope** | SQLite database only | Entire workspace |
| **Speed** | Fast (copy file) | Slower (tar.gz archive) |
| **Size** | ~50-500MB | ~50-500MB + workspace files |
| **Use case** | Point-in-time recovery | Disaster recovery, migration |
| **Frequency** | Multiple times per session | Daily/weekly |
| **MinIO sync** | ❌ No | ✅ Yes |

## Tool Specification

```json
{
  "name": "snapshot_memory",
  "description": "Create, manage, and rollback point-in-time snapshots of the SQLite memory database.",
  "parameters": {
    "action": {
      "type": "string",
      "enum": ["create", "list", "rollback", "delete"],
      "required": true
    },
    "name": {
      "type": "string",
      "description": "Optional name for the snapshot (will be prefixed with timestamp)"
    },
    "snapshot": {
      "type": "string",
      "description": "Name of snapshot for rollback or delete actions"
    }
  }
}
```

## Usage Examples

### Create a Snapshot

```
snapshot_memory action="create"
```

**Result:**
```
Snapshot created: snapshot-20250115-143022 (45.67 MB)
```

### Create Named Snapshot

```
snapshot_memory action="create" name="before-major-cleanup"
```

**Result:**
```
Snapshot created: before-major-cleanup-20250115-143022 (45.67 MB)
```

### List All Snapshots

```
snapshot_memory action="list"
```

**Result:**
```
Available snapshots:
  • before-major-cleanup-20250115-143022 (created: 2025-01-15T14:30:22, 45.67 MB)
  • snapshot-20250114-090015 (created: 2025-01-14T09:00:15, 43.21 MB)
  • baseline-20250113-220030 (created: 2025-01-13T22:00:30, 41.89 MB)
```

### Rollback to a Snapshot

```
snapshot_memory action="rollback" snapshot="baseline-20250113-220030"
```

**Result:**
```
Rollback successful. Database restored to snapshot: baseline-20250113-220030
Pre-rollback backup created: pre-rollback-baseline-20250113-220030-20250115-143500
```

**⚠️ Important:** Rollback automatically creates a backup of the current state before replacing it, so you can undo the rollback if needed.

### Delete a Snapshot

```
snapshot_memory action="delete" snapshot="old-snapshot-20250110"
```

**Result:**
```
Snapshot 'old-snapshot-20250110' deleted.
```

## Best Practices

### When to Create Snapshots

Create snapshots before:
- **Bulk memory operations:** Deleting many memories at once
- **Memory experiments:** Testing different memory configurations
- **Risky changes:** Operations that might corrupt or lose data
- **Important milestones:** After achieving a significant state

### Snapshot Naming Convention

Use descriptive names:
- `before-cleanup` - Before deleting old memories
- `baseline` - Known good state
- `pre-experiment` - Before trying something new
- `post-import` - After importing large data

### Workflow Example

```
User: "I want to experiment with a completely different memory organization."

Agent:
1. "This will significantly change how memories are stored. Let me create a snapshot first."
2. snapshot_memory action="create" name="pre-reorganization"
3. "Snapshot created. Now I'll reorganize the memories..."
4. [performs reorganization]
5. "Reorganization complete. If this doesn't work well, I can rollback to 'pre-reorganization'."

User: [tests new organization, decides it was better before]

Agent:
1. "I'll rollback to the previous organization."
2. snapshot_memory action="rollback" snapshot="pre-reorganization-20250115-143022"
3. "Rollback complete. Memory organization restored to previous state."
```

## Storage Location

Snapshots are stored in:
```
/zeroclaw-data/.zeroclaw/snapshots/
├── snapshot-20250115-143022.db
├── snapshot-20250115-143022.json (metadata)
├── before-cleanup-20250115-150000.db
└── before-cleanup-20250115-150000.json
```

## Safety Features

1. **Automatic pre-rollback backup:** Before rolling back, current state is saved
2. **WAL checkpoint:** Ensures database is consistent before snapshot
3. **SQLite validation:** Verifies snapshots are valid databases before rollback
4. **WAL file cleanup:** Removes WAL/SHM files during rollback to ensure clean state

## Comparison with Memory Tools

| Tool | Purpose | Reversible |
|------|---------|------------|
| `memory_store` | Add single memory | ❌ Manual deletion |
| `memory_forget` | Remove single memory | ❌ Permanent |
| `memory_recall` | Search memories | N/A (read-only) |
| `snapshot_memory` | Entire database state | ✅ Full rollback |

## Troubleshooting

### "SQLite database not found" Error

The snapshot tool requires the SQLite memory backend. Check your configuration:

```bash
# In .agents/.agent.env
ZEROCLAW_MEMORY_BACKEND=sqlite
```

### "Snapshot does not appear to be valid SQLite"

The snapshot file may be corrupted. Try:
1. Create a new snapshot
2. Delete the corrupted one: `snapshot_memory action="delete" snapshot="bad-snapshot"`
3. Verify database health manually if needed

### Rollback Fails

If rollback fails:
1. Check if the snapshot exists: `snapshot_memory action="list"`
2. Try the pre-rollback backup (automatically created)
3. Use `backup_workspace` to restore from a full backup if needed

## Integration with AGENTS.md

Update your agent's `AGENTS.md` to reference snapshots:

```markdown
## Risky Operations Protocol

Before making significant changes to memory:
1. Create snapshot: snapshot_memory action="create" name="before-change"
2. Make the changes
3. If issues arise, rollback: snapshot_memory action="rollback" snapshot="<name>"

## Memory Experiments

When experimenting with memory organization:
1. Always snapshot first: snapshot_memory action="create" name="pre-experiment"
2. Document what you're testing
3. After experiment, decide: keep changes or rollback
```

## Limitations

- **Local only:** Snapshots are not synced to MinIO (use `backup_workspace` for remote)
- **SQLite only:** Only works with SQLite memory backend
- **Space usage:** Each snapshot is a full copy (consider deleting old snapshots)
- **No automatic cleanup:** You must manually delete old snapshots

## Storage Management

### Check snapshot storage usage

```bash
# From within container
shell command="du -sh /zeroclaw-data/.zeroclaw/snapshots/"
```

### Clean up old snapshots

```
# List all snapshots
snapshot_memory action="list"

# Delete old snapshots you don't need
snapshot_memory action="delete" snapshot="old-snapshot-name"
```

## See Also

- [Agent Self-Backup Tool](agent-self-backup-tool.md) - Full workspace backups
- [Multi-Agent Setup](multi-agent-setup.md) - General multi-agent documentation
- [Memory System Overview](multi-agent-setup.md#memory-system) - How memory works
