# Migrating to Standalone MinIO Service

This guide helps you migrate from project-embedded MinIO to the new standalone service.

## Background

**Previously:** Each project (STTS, ZeroClaw) had its own MinIO container embedded in their `docker-compose.yml`.

**Now:** A single standalone MinIO service runs independently and serves all projects.

**Benefits:**
- ✅ Single MinIO instance (efficient resource usage)
- ✅ Centralized data management
- ✅ Easier backup/restore
- ✅ Projects just connect (no embedded infrastructure)
- ✅ Consistent configuration across projects

## Architecture

```
Before (Project-Embedded):
┌─────────────────────────────────────────────┐
│ ZeroClaw Project                            │
│ ┌─────────────┐  ┌─────────────┐         │
│ │ Agent       │  │ MinIO       │         │
│ │ Container   │  │ Container   │         │
│ └─────────────┘  └─────────────┘         │
│                                    [Duplicate!]
├─────────────────────────────────────────────┤
│ STTS Project                                │
│ ┌─────────────┐  ┌─────────────┐         │
│ │ App         │  │ MinIO       │         │
│ │ Container   │  │ Container   │         │
│ └─────────────┘  └─────────────┘         │
└─────────────────────────────────────────────┘

After (Standalone):
┌─────────────────────────────────────────────┐
│ Standalone MinIO Service                    │
│ ┌─────────────────────────────────────────┐│
│ │ MinIO Server (shared)                   ││
│ │ • zeroclaw-backups bucket               ││
│ │ • stts-cache bucket                     ││
│ │ • litestream bucket                     ││
│ └─────────────────────────────────────────┘│
└─────────────────────────────────────────────┘
         │                    │
         ▼                    ▼
┌─────────────────┐  ┌─────────────────┐
│ ZeroClaw        │  │ STTS            │
│ (connects via   │  │ (connects via   │
│  localhost:9000) │  │  localhost:9000) │
└─────────────────┘  └─────────────────┘
```

## Migration Steps

### Step 1: Start Standalone MinIO with Tailscale

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
2. Generate auth key (Reusable, Ephemeral)
3. Add tag: `tag:minio` (create in Tailscale ACLs)

**Start MinIO:**
```bash
# Start MinIO with Tailscale sidecar
docker compose up -d

# Wait for Tailscale connection
sleep 10

# Check Tailscale status
docker compose exec tailscale-sidecar tailscale status

# Initialize buckets
docker compose --profile setup up mc

# Verify MinIO is accessible via Tailscale
curl https://minio.minio.your-tailnet.ts.net:9000/minio/health/live
```

```bash
# Start MinIO
docker compose up -d

# Wait a moment for startup
sleep 5

# Initialize buckets
docker compose --profile setup up mc

# Verify it's running
curl http://localhost:9000/minio/health/live
```

### Step 2: Migrate ZeroClaw

#### Option A: Keep Using Old MinIO (Temporary)

If you want to migrate gradually:

1. **Don't change anything yet** - ZeroClaw keeps using old MinIO
2. **Test standalone service** with a test agent first
3. **Migrate production agents** after verification

#### Option B: Migrate ZeroClaw to Standalone (Recommended)

**1. Verify standalone MinIO is working:**

```bash
# Test connection
docker run --rm --network host minio/mc:latest \
  alias set local http://localhost:9000 minioadmin your-password

# List buckets
docker run --rm --network host minio/mc:latest \
  ls local
```

**2. Update ZeroClaw agent configurations:**

Edit `.agents/.handy.env` (and `.gordon.env`, `.giles.env`):

```bash
# Update MinIO endpoint to point to standalone service
# Change from (old):
# MINIO_ENDPOINT=http://minio:9000

# To (new):
MINIO_ENDPOINT=http://localhost:9000

# Keep same credentials if you used them in standalone .env
MINIO_ACCESS_KEY=minioadmin
MINIO_SECRET_KEY=your-password
MINIO_BUCKET=zeroclaw-backups
```

**3. Restart agents:**

```bash
cd /home/cd-slash/devel/zeroclaw

# Stop agents
./scripts/agent.sh stop handy
./scripts/agent.sh stop gordon
./scripts/agent.sh stop giles

# Start agents (will now use standalone MinIO)
./scripts/agent.sh start handy
./scripts/agent.sh start gordon
./scripts/agent.sh start giles
```

**4. Verify Litestream is working:**

```bash
# Check status
./scripts/litestream.sh status handy

# Look for "sync complete" messages
./scripts/litestream.sh logs handy --tail 10
```

### Step 3: Migrate STTS Project

**1. Update STTS environment:**

Edit STTS `.env` file:

```bash
# Change from:
# MINIO_ENDPOINT=http://minio:9000

# To (Tailscale endpoint):
MINIO_ENDPOINT=https://minio.minio.your-tailnet.ts.net:9000
MINIO_ACCESS_KEY=minioadmin
MINIO_SECRET_KEY=your-password
MINIO_BUCKET=stts-cache
```

**Find your tailnet:**
```bash
# On your host machine
tailscale status | head -1
# Shows: your-hostname.your-tailnet.ts.net

# So the endpoint is:
# https://minio.minio.your-hostname.your-tailnet.ts.net:9000
```

**2. Update STTS docker-compose:**

Remove the embedded MinIO service from STTS's `docker-compose.yml`:

```yaml
# REMOVE this section from STTS docker-compose.yml:
#  minio:
#    image: minio/minio:latest
#    ...
```

**3. Restart STTS:**

```bash
cd ~/devel/stts
docker compose stop minio  # If still running
docker compose rm minio    # Remove old container
docker compose up -d     # Restart without MinIO
```

### Step 4: Stop Old MinIO Containers

Once you've verified both projects work with standalone MinIO:

**ZeroClaw:**
```bash
cd /home/cd-slash/devel/zeroclaw
# Remove any embedded minio references from docker-compose files
# (Already done - ZeroClaw never had embedded MinIO)
```

**STTS:**
```bash
cd ~/devel/stts
docker compose stop minio 2>/dev/null || true
docker compose rm -f minio 2>/dev/null || true

# Optional: Remove old MinIO data volume if no longer needed
# docker volume rm stts_minio-data 2>/dev/null || true
```

### Step 5: Verify Everything

**Test ZeroClaw backup:**
```bash
cd /home/cd-slash/devel/zeroclaw
./scripts/agent-backup.sh backup handy
./scripts/agent-backup.sh sync-to-minio handy

# Check it appeared in MinIO
docker run --rm --network host minio/mc:latest \
  ls local/zeroclaw-backups
```

**Test STTS cache:**
```bash
# Use STTS as normal - it should store images in standalone MinIO
# Verify:
docker run --rm --network host minio/mc:latest \
  ls local/stts-cache
```

## Troubleshooting

### Connection Refused

**Problem:** ZeroClaw can't connect to MinIO

**Solution:**
```bash
# Verify MinIO is running
cd /home/cd-slash/devel/minio-service
docker compose ps

# Check endpoint is correct
curl http://localhost:9000/minio/health/live

# If using Tailscale, ensure Tailscale is running
# and update endpoint to Tailscale IP
```

### Authentication Failed

**Problem:** Access denied when connecting

**Solution:**
```bash
# Check credentials match
cat /home/cd-slash/devel/minio-service/.env | grep MINIO_ROOT

# Check agent env has same credentials
cat /home/cd-slash/devel/zeroclaw/.agents/.handy.env | grep MINIO
```

### Data Migration

**Problem:** Need to move existing data from old MinIO

**Solution:**
```bash
# Only if you have critical data in old MinIO

# 1. Start both MinIO instances temporarily
# 2. Use mc mirror to copy data
docker run --rm --network host minio/mc:latest \
  mirror local/old-bucket local/new-bucket

# 3. Or manually copy volumes
docker run --rm \
  -v old-project_minio-data:/old \
  -v minio-service_minio-data:/new \
  alpine cp -r /old/* /new/
```

### Bucket Not Found

**Problem:** ZeroClaw or STTS can't find their bucket

**Solution:**
```bash
# Create buckets manually
cd /home/cd-slash/devel/minio-service
docker compose --profile setup up mc

# Or via MinIO Console (http://localhost:9001)
```

## Configuration Summary

After migration, your setup should look like:

**Standalone MinIO** (`/home/cd-slash/devel/minio-service/.env`):
```bash
# Tailscale (REQUIRED)
TAILSCALE_AUTHKEY=tskey-auth-kXXXXXXXXXXXX-YYYYYYYYYYYYY
TS_HOSTNAME=minio

# MinIO credentials
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=your-strong-password
```

**ZeroClaw** (`.agents/.handy.env`):
```bash
# Tailscale endpoint (NOT localhost!)
MINIO_ENDPOINT=https://minio.minio.your-tailnet.ts.net:9000
MINIO_ACCESS_KEY=minioadmin
MINIO_SECRET_KEY=your-strong-password
MINIO_BUCKET=zeroclaw-backups
```

**STTS** (`.env`):
```bash
# Same Tailscale endpoint
MINIO_ENDPOINT=https://minio.minio.your-tailnet.ts.net:9000
MINIO_ACCESS_KEY=minioadmin
MINIO_SECRET_KEY=your-strong-password
MINIO_BUCKET=stts-cache
```

## Benefits After Migration

✅ **Single point of management** - One MinIO to update, backup, monitor  
✅ **Resource efficiency** - One container instead of multiple  
✅ **Consistent data** - All projects use same storage backend  
✅ **Easier backup** - Backup one volume instead of many  
✅ **Secure networking** - Tailscale encrypted, no public exposure  
✅ **Remote access** - Works from anywhere on your tailnet  
✅ **Shared infrastructure** - Future projects just connect, no setup needed  

## Rollback Plan

If something goes wrong:

1. Stop standalone MinIO: `cd minio-service && docker compose down`
2. Restore old embedded MinIO in each project
3. Update configs back to embedded endpoints
4. Restart projects

## Questions?

- **Q:** Can I run multiple MinIO instances for isolation?  
  **A:** Yes, but defeats the purpose. Use bucket policies instead.

- **Q:** What about security between projects?  
  **A:** Create separate service accounts per project in MinIO Console.

- **Q:** Can I access MinIO remotely?  
  **A:** Yes, via Tailscale. See `minio-service/README.md` for network options.

- **Q:** What if standalone MinIO goes down?  
  **A:** All projects lose storage access. Mitigate with good monitoring and backups.

## Next Steps

1. **Set up monitoring** for standalone MinIO
2. **Configure backups** of the `minio-data` volume
3. **Create service accounts** instead of using root credentials
4. **Document the setup** for your team

See `/home/cd-slash/devel/minio-service/README.md` for full documentation.
