# ZeroClaw + MinIO + Tailscale - Complete Setup Guide

This document provides the complete setup instructions for running ZeroClaw agents with continuous SQLite backup to a Tailscale-secured MinIO service.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Your Tailnet                                    │
│                                                                              │
│  ┌─────────────────────────┐                                                 │
│  │  minio-service          │                                                 │
│  │  (~/devel/containers/minio)│                                                 │
│  │                         │                                                 │
│  │  ┌───────────────────┐  │                                                 │
│  │  │ Tailscale Sidecar│  │  Gets Tailscale IP                             │
│  │  │ Hostname: minio  │──┼──▶ minio.minio.your-host.ts.net               │
│  │  └───────────────────┘  │                                                 │
│  │           │             │                                                 │
│  │           ▼             │                                                 │
│  │  ┌───────────────────┐  │                                                 │
│  │  │ MinIO Server     │  │                                                 │
│  │  │ - zeroclaw-      │  │                                                 │
│  │  │   backups        │  │                                                 │
│  │  │ - stts-cache     │  │                                                 │
│  │  │ - litestream     │  │                                                 │
│  │  └───────────────────┘  │                                                 │
│  └─────────────────────────┘                                                 │
│           │                                                                  │
│           │ HTTPS (Tailscale encrypted)                                      │
│           ▼                                                                  │
│  ┌─────────────────────────┐  ┌─────────────────────────┐                     │
│  │  ZeroClaw               │  │  STTS                   │                     │
│  │  (~/devel/zeroclaw)     │  │  (~/devel/stts)          │                     │
│  │                         │  │                         │                     │
│  │  ┌───────────────────┐  │  │  ┌───────────────────┐  │                     │
│  │  │ Agent (handy)     │  │  │  │  App              │  │                     │
│  │  │ - memory.db       │  │  │  │  - Image cache    │  │                     │
│  │  └─────────┬─────────┘  │  │  └───────────────────┘  │                     │
│  │            │             │  └─────────────────────────┘                     │
│  │            │ Mount       │                                                  │
│  │            ▼             │                                                  │
│  │  ┌───────────────────┐  │                                                  │
│  │  │ Litestream        │──┼──▶ Streams to MinIO via Tailscale                │
│  │  │ Sidecar           │  │                                                  │
│  │  └───────────────────┘  │                                                  │
│  └─────────────────────────┘                                                  │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

1. **Tailscale installed** on your host machine
2. **Docker and Docker Compose** installed
3. **Tailscale auth key** (see step 1 below)

## Step-by-Step Setup

### Step 1: Get Tailscale Auth Key

```bash
# Open Tailscale admin console
open https://login.tailscale.com/admin/settings/keys

# Generate a new auth key:
# - Reusable: Yes
# - Ephemeral: Yes  
# - Tags: Create and select "tag:minio"
# 
# Note: You need to add the tag in ACLs first:
# Go to https://login.tailscale.com/admin/acls
# Add: "tagOwners": {"tag:minio": ["your-email@example.com"]}

# Copy the key (looks like: tskey-auth-kXXXXXXXXXXXX-YYYYYYYYYYYYY)
```

### Step 2: Start MinIO Service with Tailscale

```bash
# Navigate to MinIO service
cd ~/devel/containers/minio

# Copy and configure environment
cp .env.example .env
nano .env
```

**Edit `.env`:**
```bash
# Required
TAILSCALE_AUTHKEY=tskey-auth-kXXXXXXXXXXXX-YYYYYYYYYYYYY
TS_HOSTNAME=minio

# MinIO credentials (change the password!)
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=your-strong-password

# Buckets (optional, defaults are fine)
STTS_BUCKET=stts-cache
ZEROCLAW_BUCKET=zeroclaw-backups
LITESTREAM_BUCKET=litestream
```

**Start the service:**
```bash
# Start MinIO with Tailscale
docker compose up -d

# Wait for Tailscale to connect
sleep 10

# Check Tailscale status
docker compose exec tailscale-sidecar tailscale status

# You should see:
# # node found: minio.minio.your-hostname.your-tailnet.ts.net
```

**Initialize buckets:**
```bash
docker compose --profile setup up mc

# Should output:
# Buckets created:
# [2025-01-15 20:00:00 UTC] ... stts-cache
# [2025-01-15 20:00:00 UTC] ... zeroclaw-backups
# [2025-01-15 20:00:00 UTC] ... litestream
```

**Find your hostname:**
```bash
# Get your tailnet name
tailscale status | head -1
# Output: your-hostname.your-tailnet.ts.net

# Your MinIO endpoint will be:
# https://minio.minio.your-hostname.your-tailnet.ts.net:9000
```

**Test the connection:**
```bash
# From your host machine
curl https://minio.minio.your-hostname.your-tailnet.ts.net:9000/minio/health/live

# Should return: OK
```

### Step 3: Configure ZeroClaw

```bash
# Navigate to ZeroClaw
cd ~/devel/zeroclaw

# Copy Litestream config
cp .agents/litestream.template.yml .agents/litestream.yml

# Edit agent environment
nano .agents/.handy.env
```

**Update the Litestream section:**
```bash
# =============================================================================
# Litestream Configuration
# =============================================================================

# MinIO endpoint via Tailscale (use YOUR hostname!)
MINIO_ENDPOINT=https://minio.minio.your-hostname.your-tailnet.ts.net:9000
MINIO_ACCESS_KEY=minioadmin
MINIO_SECRET_KEY=your-strong-password  # Same as minio-service/.env
MINIO_BUCKET=zeroclaw-backups

# Enable SQLite WAL mode (required for Litestream)
ZEROCLAW_SQLITE_WAL_MODE=true
```

**Repeat for other agents:**
```bash
nano .agents/.gordon.env
nano .agents/.zoe.env
# Update the MINIO_ENDPOINT in each
```

### Step 4: Start ZeroClaw Agent

```bash
# Start handy agent (includes Litestream sidecar)
./scripts/agent.sh start handy

# Or manually:
docker compose -f docker-compose.agents.yml up -d handy

# Verify both containers are running
docker compose -f docker-compose.agents.yml ps handy litestream-handy
```

**Check Litestream is working:**
```bash
# View status
./scripts/litestream.sh status handy

# View logs (should show "sync complete" messages)
./scripts/litestream.sh logs handy -f

# Verify replication
./scripts/litestream.sh verify handy
```

### Step 5: Test the Setup

**Create a backup via Litestream:**
```bash
# Trigger manual snapshot
./scripts/litestream.sh snapshot handy
```

**Verify in MinIO:**
```bash
# List litestream bucket
cd ~/devel/containers/minio

# Via mc (from any machine on tailnet)
mc alias set myminio \
  https://minio.minio.your-hostname.your-tailnet.ts.net:9000 \
  minioadmin your-password

mc ls myminio/litestream/handy/

# Should show: memory.db/ with generations/
```

**Test point-in-time restore:**
```bash
# In ZeroClaw directory
cd ~/devel/zeroclaw

# Stop agent first
docker compose -f docker-compose.agents.yml stop handy

# Restore to latest
./scripts/litestream.sh restore handy

# Or restore to specific time
./scripts/litestream.sh restore handy "2025-01-15 20:00:00"

# Start agent
./scripts/agent.sh start handy
```

## Daily Operations

### Check Status

```bash
# MinIO status
cd ~/devel/containers/minio
docker compose ps
docker compose logs tailscale-sidecar --tail 5

# Agent status
cd ~/devel/zeroclaw
./scripts/agent.sh list
./scripts/litestream.sh status handy
```

### View MinIO Console

```bash
# Open in browser
open https://minio.minio.your-hostname.your-tailnet.ts.net:9001

# Login with credentials from minio-service/.env
```

### Backup MinIO Data

```bash
cd ~/devel/containers/minio

# Backup the data volume
docker run --rm \
  -v minio-service_minio-data:/data \
  -v $(pwd)/backups:/backup \
  alpine tar czf /backup/minio-$(date +%Y%m%d).tar.gz -C /data .
```

## Troubleshooting

### "Connection refused" to MinIO

```bash
# 1. Check Tailscale sidecar is healthy
cd ~/devel/containers/minio
docker compose ps

# 2. Verify Tailscale status
docker compose exec tailscale-sidecar tailscale status
# Should show: "# node found" and your tailnet

# 3. Check DNS resolution
ping minio.minio.your-hostname.your-tailnet.ts.net

# 4. Check MinIO health
curl https://minio.minio.your-hostname.your-tailnet.ts.net:9000/minio/health/live
```

### Litestream Can't Connect

```bash
# Check Litestream logs
cd ~/devel/zeroclaw
docker compose -f docker-compose.agents.yml logs litestream-handy

# Verify endpoint is correct
docker compose -f docker-compose.agents.yml exec litestream-handy \
  env | grep LITESTREAM_ENDPOINT

# Test connectivity
docker compose -f docker-compose.agents.yml exec litestream-handy \
  wget -qO- https://minio.minio.your-hostname.your-tailnet.ts.net:9000/minio/health/live
```

### "WAL mode required" Error

```bash
# Ensure WAL mode is enabled
# This should be in .agents/.handy.env:
ZEROCLAW_SQLITE_WAL_MODE=true

# If database exists without WAL:
docker compose -f docker-compose.agents.yml exec handy \
  sqlite3 /zeroclaw-data/.zeroclaw/memory.db "PRAGMA journal_mode=WAL;"

# Restart Litestream
docker compose -f docker-compose.agents.yml restart litestream-handy
```

## Security

### Tailscale ACLs (Recommended)

Restrict access to MinIO:

```json
// Add to your Tailscale ACLs (https://login.tailscale.com/admin/acls)
{
  "tagOwners": {
    "tag:minio": ["your-email@example.com"]
  },
  "acls": [
    // Only allow tagged devices to reach MinIO
    {
      "action": "accept",
      "src": ["tag:member"],
      "dst": ["tag:minio:9000", "tag:minio:9001"]
    }
  ]
}
```

### Service Accounts (Recommended)

Instead of root credentials, create dedicated accounts:

```bash
# Via MinIO Console
cd ~/devel/containers/minio
open https://minio.minio.your-hostname.your-tailnet.ts.net:9001

# Login with root credentials
# Go to: Identity → Service Accounts → Create Service Account
# Create separate accounts for ZeroClaw and STTS
```

## File Locations

```
~/devel/containers/minio/
├── docker-compose.yml      # MinIO + Tailscale sidecar
├── .env                    # Your configuration (not committed)
├── .env.example            # Template
└── README.md               # Documentation

~/devel/zeroclaw/
├── .agents/
│   ├── .handy.env          # Agent config with MinIO endpoint
│   ├── .gordon.env         # Agent config with MinIO endpoint
│   ├── .zoe.env            # Agent config with MinIO endpoint
│   └── litestream.yml      # Litestream config (copied from template)
├── docker-compose.agents.yml  # Agents + Litestream sidecars
└── docs/
    ├── litestream-integration.md
    └── minio-migration-guide.md
```

## Summary

You now have:

✅ **MinIO on Tailscale** - Secure, encrypted, no public exposure  
✅ **Continuous backup** - Litestream streams every 10 seconds  
✅ **Point-in-time recovery** - Restore to any second  
✅ **Multi-project** - ZeroClaw and STTS share same MinIO  
✅ **Remote access** - Works from anywhere on your tailnet  
✅ **End-to-end encryption** - Tailscale WireGuard + HTTPS  

## Next Steps

1. **Configure STTS** to use the same MinIO (update STTS `.env`)
2. **Test restores** - Practice point-in-time recovery
3. **Set up monitoring** - Alert if Litestream falls behind
4. **Create service accounts** - Replace root credentials
5. **Document for team** - Share setup instructions

## Getting Help

- **Litestream docs:** https://litestream.io/
- **MinIO docs:** https://min.io/docs/
- **Tailscale docs:** https://tailscale.com/kb/
- **ZeroClaw docs:** See `~/devel/zeroclaw/docs/`

---

**You're all set!** Your agents now have enterprise-grade continuous backup to a secure, self-hosted MinIO service accessible only via your Tailscale network.
