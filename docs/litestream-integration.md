# Litestream Integration Guide

This guide explains how to set up **continuous incremental backup** of SQLite databases using **Litestream** integrated directly into the agent container.

## Overview

**Litestream** is a purpose-built tool for streaming SQLite databases to S3-compatible storage (like MinIO). It provides:

- ✅ **Continuous replication** - Backs up in real-time (seconds of lag)
- ✅ **Incremental forever** - Only transfers changed data (WAL segments)
- ✅ **Point-in-time recovery** - Restore to any second in time
- ✅ **Self-hosted** - Works with your MinIO over Tailscale
- ✅ **Space efficient** - No duplicate data, just WAL deltas
- ✅ **Integrated** - Runs inside the agent container (no sidecar)

## Architecture

Litestream is now **integrated into the agent container**, not a separate sidecar:

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Agent Container (Single)                          │
│                                                                      │
│  ┌───────────────────────────────────────────────────────────────┐ │
│  │  ZeroClaw Agent                                               │ │
│  │                                                               │ │
│  │  ┌──────────────┐    ┌─────────────────────────────────────┐ │ │
│  │  │  memory.db   │───▶│  Litestream (integrated)           │ │ │
│  │  │  (SQLite)    │    │                                     │ │ │
│  │  │              │    │  • Uses inotify/fsnotify            │ │ │
│  │  │  PRAGMA      │    │    to detect WAL changes           │ │ │
│  │  │  journal_mode│    │  • Streams to MinIO immediately   │ │ │
│  │  │  = WAL       │    │  • No polling - event-driven       │ │ │
│  │  └──────────────┘    └─────────────────────────────────────┘ │ │
│  │                          │                                     │ │
│  └──────────────────────────┼─────────────────────────────────────┘ │
│                             │                                       │
│                             │ HTTPS/Tailscale                        │
└─────────────────────────────┼─────────────────────────────────────────┘
                              │
                              ▼
          ┌──────────────────────────────────────┐
          │   MinIO Service with Tailscale        │
          │   (standalone, shared service)         │
          │                                       │
          │   ┌─────────────────────────────────┐  │
          │   │  Tailscale Sidecar             │  │
          │   │  - Provides Tailscale IP       │  │
          │   │  - Accessible via:             │  │
          │   │    minio.your-tailnet.ts.net  │  │
          │   └─────────────────────────────────┘  │
          │                   │                  │
          │                   ▼                  │
          │   ┌─────────────────────────────────┐  │
          │   │  MinIO Server                  │  │
          │   │  - zeroclaw-backups bucket     │  │
          │   │  - stts-cache bucket         │  │
          │   └─────────────────────────────────┘  │
          └──────────────────────────────────────┘
```

**Key Change:** Litestream now runs **inside** the agent container, not as a separate sidecar. This means:
- Single container per agent (simpler)
- Direct filesystem access (faster sync)
- Event-driven using inotify (no polling)
- Easier to manage

## Bucket Structure

All ZeroClaw agents share the **same bucket** (`zeroclaw-backups`) but use **separate paths** for isolation:

```
zeroclaw-backups/
└── litestream/
    ├── handy/
    │   └── memory.db/
    │       ├── generations/
    │       │   └── 00000001.wal
    │       └── snapshots/
    │           └── snapshot-2025-01-15T10:00:00.snapshot
    ├── gordon/
    │   └── memory.db/
    │       └── ...
    └── giles/
        └── memory.db/
            └── ...
```

**Why shared bucket?**
- ✅ Simpler management (one bucket policy)
- ✅ Consistent retention across all agents
- ✅ Cost efficient
- ✅ Easy to scale (just add new paths)
- ✅ Litestream's recommended pattern

**Each agent has complete isolation** via unique paths, preventing data collision.

## Architecture

### Architecture

**Two-Tier Design:**

1. **MinIO Service** (`~/devel/containers/minio`):
   - Runs its own Tailscale sidecar
   - Gets a Tailscale hostname: `minio.your-tailnet.ts.net`
   - Shared across all projects

2. **ZeroClaw Agent** (`~/devel/zeroclaw`):
   - Single container runs both ZeroClaw and Litestream
   - Litestream integrated (not a sidecar)
   - Direct filesystem access for WAL monitoring

### Why Tailscale for MinIO?

**Security:**
- ✅ MinIO not exposed to public internet
- ✅ Encrypted WireGuard tunnel
- ✅ Access controlled by Tailscale ACLs
- ✅ Works from anywhere (home, office, cloud)

**Simplicity:**
- No port forwarding needed
- No VPN configuration
- Automatic DNS resolution
- Works across networks

## Setup Instructions

### 1. Start Standalone MinIO with Tailscale

The MinIO service uses the **sidecar pattern** (like chrome-devtools):

```bash
# Navigate to standalone MinIO service
cd ~/devel/containers/minio

# Configure
cp .env.example .env
nano .env
```

**Configure `.env`:**
```bash
# Tailscale (REQUIRED)
TAILSCALE_AUTHKEY=tskey-auth-kXXXXXXXXXXXX-YYYYYYYYYYYYY
TS_HOSTNAME=minio

# MinIO credentials
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=your-strong-password
```

**Get Tailscale auth key:**
1. Go to: https://login.tailscale.com/admin/settings/keys
2. Generate auth key
3. Select: Reusable, Ephemeral
4. Add tags: `tag:minio` (create this tag in Tailscale ACLs)

**Start MinIO:**
```bash
docker compose up -d

# Wait for Tailscale to connect
sleep 10

# Initialize buckets
docker compose --profile setup up mc

# Verify Tailscale connection
docker compose exec tailscale-sidecar tailscale status
```

**Expected output:**
```
# Health check should show "# node found"
# And you should see your tailnet name
```

### 2. Configure ZeroClaw Agents

Edit `.agents/.handy.env` (and `.gordon.env`, `.giles.env`):

```bash
# =============================================================================
# Litestream Configuration
# =============================================================================

# MinIO endpoint via Tailscale
# Format: https://minio.minio.your-tailnet.ts.net:9000
MINIO_ENDPOINT=https://minio.minio.your-tailnet.ts.net:9000
MINIO_ACCESS_KEY=minioadmin
MINIO_SECRET_KEY=your-strong-password
MINIO_BUCKET=zeroclaw-backups

# Enable SQLite WAL mode (required)
ZEROCLAW_SQLITE_WAL_MODE=true
```

**Find your tailnet name:**
```bash
# On your host machine
tailscale status | head -1
# Shows: your-hostname.your-tailnet.ts.net
```

**So the MinIO endpoint would be:**
```
https://minio.minio.your-hostname.your-tailnet.ts.net:9000
```

### 3. Copy Litestream Configuration

```bash
cd ~/devel/zeroclaw
cp .agents/litestream.template.yml .agents/litestream.yml

# The template already has the correct endpoint pattern
# It will be substituted from environment variables
```

### 4. Start Agent with Integrated Litestream

```bash
# Start agent (Litestream runs inside the container)
./scripts/agent.sh start handy

# Or manually:
docker compose -f docker-compose.agents.yml up -d handy
```

This starts **one container** that runs both:
- `zeroclaw-handy` - The agent with Litestream integrated inside

Litestream starts automatically when `ZEROCLAW_LITESTREAM_ENABLED=true`

### 5. Verify Setup

```bash
# Check Litestream is running
./scripts/litestream.sh status handy

# View recent logs
./scripts/litestream.sh logs handy -f

# Verify replication
./scripts/litestream.sh verify handy
```

**Expected output:**
```
[OK] Litestream container is running
[INFO] Last successful: sync complete: generation=xxx
```

## Network Architecture

```
Host Machine
│
├─► ~/devel/containers/minio/ (Standalone MinIO Service)
│   │
│   ├─► tailscale-sidecar (Tailscale sidecar)
│   │   ├─ Gets Tailscale IP
│   │   ├─ Hostname: minio.your-tailnet.ts.net
│   │   └─ DNS: 100.100.100.100
│   │
│   └─► minio (network_mode: service:tailscale-sidecar)
│       ├─ Shares Tailscale network
│       ├─ Accessible at: https://minio.your-tailnet.ts.net:9000
│       └─ Buckets: zeroclaw-backups, stts-cache
│
└─► ~/devel/zeroclaw/ (ZeroClaw with Integrated Litestream)
    │
    └─► zeroclaw-handy (Single Container)
        ├─ ZeroClaw Agent (gateway on port 3000)
        ├─ Litestream (integrated, monitors WAL via inotify)
        │   ├─ Connects to: https://minio.your-tailnet.ts.net:9000
        │   ├─ Uploads to: zeroclaw-backups/litestream/handy/
        │   └─ Event-driven sync (no polling)
        └─ Tailscale state (optional, for SSH access)
```

**Key Improvement:** Single container per agent. Litestream runs inside, directly monitoring the WAL file using inotify/fsnotify for immediate change detection.

## Restore from Litestream

### Point-in-Time Recovery

```bash
# Restore to latest
./scripts/litestream.sh restore handy

# Restore to specific time (down to the second!)
./scripts/litestream.sh restore handy "2025-01-15 14:30:00"

# Restore to specific date
./scripts/litestream.sh restore handy "2025-01-15"
```

### Complete Workflow: Disaster Recovery

**Scenario:** Agent database corrupted at 3 PM, need to restore to 2 PM state.

```bash
# 1. Stop the agent (REQUIRED before restore)
docker compose -f docker-compose.agents.yml stop handy

# 2. Restore to 2 PM state
./scripts/litestream.sh restore handy "2025-01-15 14:00:00"

# 3. Start the agent
./scripts/agent.sh start handy

# 4. Verify data is intact
./scripts/agent.sh logs handy
```

## Storage Comparison

### Space Efficiency

**Scenario:** 500 MB database, 10 MB of changes daily

| Method | After 30 Days | Notes |
|--------|---------------|-------|
| **Full Backups Daily** | 15 GB | 30 × 500 MB |
| **Litestream** | ~800 MB | 500 MB + 30 × 10 MB |
| **Savings** | **94%** | Litestream is 18× more efficient |

## Troubleshooting

### "Connection refused" to MinIO

**Problem:** Litestream can't connect to MinIO

**Check:**
```bash
# 1. Verify MinIO Tailscale sidecar is running
cd ~/devel/containers/minio
docker compose ps

# 2. Check Tailscale status
docker compose exec tailscale-sidecar tailscale status

# 3. Verify DNS resolution
# From any machine on your tailnet:
ping minio.minio.your-tailnet.ts.net

# 4. Check if port 9000 is accessible
curl https://minio.minio.your-tailnet.ts.net:9000/minio/health/live
```

**Solutions:**
1. Ensure `TAILSCALE_AUTHKEY` is valid and not expired
2. Check Tailscale ACLs allow connection
3. Verify DNS is working (100.100.100.100)
4. Ensure both services are on same tailnet

### "WAL mode required" Error

**Problem:** Litestream fails to start, complaining about WAL mode.

**Solution:**
```bash
# 1. Ensure WAL mode is enabled in agent .env
ZEROCLAW_SQLITE_WAL_MODE=true

# 2. If database already exists without WAL, manually convert:
docker compose exec handy sqlite3 /zeroclaw-data/.zeroclaw/memory.db \
    "PRAGMA journal_mode=WAL;"

# 3. Restart litestream
docker compose restart litestream-handy
```

### Authentication Failed

**Problem:** Access denied when connecting to MinIO

**Solution:**
```bash
# Check credentials match between services
# ~/devel/containers/minio/.env
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=your-password

# ~/devel/zeroclaw/.agents/.handy.env
MINIO_ACCESS_KEY=minioadmin  # Must match above
MINIO_SECRET_KEY=your-password # Must match above
```

### Litestream Container Won't Start

**Problem:** Litestream container exits immediately.

**Debug:**
```bash
# Check logs
docker compose logs litestream-handy

# Verify MinIO credentials are set
docker compose exec litestream-handy env | grep LITESTREAM

# Test MinIO connectivity from Litestream container
docker compose exec litestream-handy \
  wget -qO- https://minio.minio.your-tailnet.ts.net:9000/minio/health/live
```

## Security Considerations

### Data in Transit

- ✅ **Tailscale:** All traffic encrypted via WireGuard
- ✅ **HTTPS:** MinIO accessible via HTTPS on Tailscale
- ✅ **Tailscale ACLs:** Control which devices can access MinIO

### Access Control

**Recommended:** Create dedicated service accounts instead of using root:

```bash
# Via MinIO Console (access via Tailscale):
# 1. https://minio.minio.your-tailnet.ts.net:9001
# 2. Login with root credentials
# 3. Identity → Service Accounts
# 4. Create account for each project
```

**Tailscale ACLs:**
```json
// In Tailscale ACLs (https://login.tailscale.com/admin/acls)
{
  "tagOwners": {
    "tag:minio": ["your-email@example.com"]
  },
  "acls": [
    // Only tagged devices can access MinIO port 9000
    {
      "action": "accept",
      "src": ["tag:minio"],
      "dst": ["tag:minio:9000"]
    }
  ]
}
```

## Maintenance

### Update Litestream

```bash
docker compose pull litestream-handy
docker compose up -d litestream-handy
```

### Monitor Replication Lag

```bash
# Check how far behind the backup is
# Should be < 30 seconds
docker compose logs litestream-handy --tail 1
```

### Backup MinIO Data

```bash
# Backup the MinIO data volume
cd ~/devel/containers/minio
docker run --rm \
  -v minio-service_minio-data:/data \
  -v $(pwd)/backups:/backup \
  alpine tar czf /backup/minio-$(date +%Y%m%d).tar.gz -C /data .
```

## Migration from Localhost MinIO

If you were using `localhost:9000` for MinIO:

1. **Stop old MinIO** (if embedded in projects)
2. **Start standalone MinIO with Tailscale** (`~/devel/containers/minio`)
3. **Update all configs** to use `https://minio.minio.ts.net:9000`
4. **Restart agents** - they'll automatically connect via Tailscale

See `docs/minio-migration-guide.md` for detailed steps.

## Summary

You now have:

✅ **MinIO on Tailscale** - Secure, accessible from anywhere on your tailnet  
✅ **Continuous backup** - Litestream streams every 10 seconds  
✅ **Point-in-time recovery** - Restore to any second  
✅ **Shared infrastructure** - One MinIO serves all projects  
✅ **End-to-end encryption** - Tailscale WireGuard + HTTPS  

**Architecture Highlights:**
- **MinIO:** Uses Tailscale sidecar pattern (secure, isolated)
- **ZeroClaw:** Litestream integrated into agent container (simpler, faster)
- **No polling:** Event-driven WAL monitoring via inotify/fsnotify
- **Single container per agent:** Easier to manage and monitor
