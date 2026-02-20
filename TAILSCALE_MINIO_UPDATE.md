# Update Summary: Tailscale-Enabled MinIO Service

## What Changed

The standalone MinIO service has been updated to use the **Tailscale sidecar pattern** (like chrome-devtools), making it accessible only via Tailscale (not localhost).

## New Architecture

### Before (localhost)
```
MinIO exposed on: http://localhost:9000
ZeroClaw connects: http://localhost:9000
```

### After (Tailscale)
```
MinIO Service:
  ├─► Tailscale sidecar (gets Tailscale IP)
  │   └─ Hostname: minio.minio.your-tailnet.ts.net
  └─► MinIO (uses tailscale-sidecar's network)
      └─ Accessible at: https://minio.minio.your-tailnet.ts.net:9000

ZeroClaw connects to: https://minio.minio.your-tailnet.ts.net:9000
```

## Files Updated

### 1. minio-service/docker-compose.yml
**Added:**
- `tailscale-sidecar` service (Tailscale sidecar)
- MinIO uses `network_mode: service:tailscale-sidecar`
- `mc` (setup) also uses Tailscale network
- Removed port mappings from MinIO (now accessed via Tailscale)

**Pattern:** Same as `~/devel/containers/chrome-devtools`

### 2. minio-service/.env.example
**Added:**
- `TAILSCALE_AUTHKEY` (required)
- `TS_HOSTNAME=minio`
- Removed `MINIO_API_PORT` and `MINIO_CONSOLE_PORT` (no longer needed)

### 3. minio-service/README.md
**Updated:**
- Added Tailscale setup instructions
- Updated connection examples to use Tailscale hostname
- Removed localhost references
- Added security benefits section

### 4. zeroclaw/.agents/.handy.env (and .gordon.env, .giles.env)
**Changed:**
```bash
# From:
MINIO_ENDPOINT=http://localhost:9000

# To:
MINIO_ENDPOINT=https://minio.minio.your-tailnet.ts.net:9000
```

### 5. zeroclaw/.agents/litestream.template.yml
**Changed:**
```yaml
# From:
endpoint: ${LITESTREAM_ENDPOINT:-http://localhost:9000}

# To:
endpoint: ${LITESTREAM_ENDPOINT:-https://minio.minio.your-tailnet.ts.net:9000}
```

### 6. zeroclaw/docs/litestream-integration.md
**Updated:**
- Added Tailscale sidecar architecture diagram
- Updated setup instructions for Tailscale
- Added troubleshooting for Tailscale connection
- Updated all endpoint examples

### 7. zeroclaw/docs/minio-migration-guide.md
**Updated:**
- Added Tailscale setup to migration steps
- Updated all configuration examples
- Changed troubleshooting to use Tailscale hostname

## Setup Instructions

### 1. Get Tailscale Auth Key

```bash
# Go to Tailscale admin console
open https://login.tailscale.com/admin/settings/keys

# Generate:
# - Reusable: Yes
# - Ephemeral: Yes
# - Tags: tag:minio (create this tag in ACLs first)

# Copy the key: tskey-auth-kXXXXXXXXXXXX-YYYYYYYYYYYYY
```

### 2. Configure MinIO Service

```bash
cd ~/devel/containers/minio
cp .env.example .env

# Edit .env
nano .env
```

```bash
# Required
TAILSCALE_AUTHKEY=tskey-auth-kXXXXXXXXXXXX-YYYYYYYYYYYYY
TS_HOSTNAME=minio

# MinIO credentials
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=your-strong-password
```

### 3. Start MinIO with Tailscale

```bash
docker compose up -d

# Wait for Tailscale
sleep 10

# Check status
docker compose exec tailscale-sidecar tailscale status

# Should show:
# # node found: minio.minio.your-hostname.your-tailnet.ts.net
```

### 4. Initialize Buckets

```bash
docker compose --profile setup up mc
```

### 5. Find Your Tailscale Hostname

```bash
# On your host machine
tailscale status | head -1
# Shows: your-hostname.your-tailnet.ts.net

# So MinIO is at:
# https://minio.minio.your-hostname.your-tailnet.ts.net:9000
```

### 6. Configure ZeroClaw

Edit `.agents/.handy.env`:

```bash
MINIO_ENDPOINT=https://minio.minio.your-hostname.your-tailnet.ts.net:9000
MINIO_ACCESS_KEY=minioadmin
MINIO_SECRET_KEY=your-password
MINIO_BUCKET=zeroclaw-backups

ZEROCLAW_SQLITE_WAL_MODE=true
```

### 7. Start ZeroClaw Agent

```bash
cd ~/devel/zeroclaw
cp .agents/litestream.template.yml .agents/litestream.yml
./scripts/agent.sh start handy

# Verify
curl https://minio.minio.your-hostname.your-tailnet.ts.net:9000/minio/health/live
```

## Benefits

✅ **Security:** Not exposed to public internet  
✅ **Encryption:** Tailscale WireGuard encryption  
✅ **Access Control:** Tailscale ACLs control who can access  
✅ **Remote Access:** Works from anywhere on your tailnet  
✅ **No Port Forwarding:** No need to open ports  
✅ **Automatic DNS:** Tailscale provides magic DNS  

## Testing

```bash
# From any machine on your tailnet:
curl https://minio.minio.your-hostname.your-tailnet.ts.net:9000/minio/health/live

# Or use mc:
mc alias set myminio https://minio.minio.your-hostname.your-tailnet.ts.net:9000 minioadmin your-password
mc ls myminio
```

## Next Steps

1. **Update STTS** to use the Tailscale endpoint
2. **Create Tailscale ACLs** to restrict access (optional)
3. **Test Litestream** replication
4. **Set up monitoring** for the MinIO service

## Troubleshooting

**"Connection refused" to MinIO:**
```bash
# Check Tailscale sidecar is running
docker compose ps

# Check Tailscale status
docker compose exec tailscale-sidecar tailscale status

# Verify hostname resolves
ping minio.minio.your-tailnet.ts.net
```

**"Authentication failed":**
```bash
# Ensure credentials match between:
# - minio-service/.env
# - zeroclaw/.agents/.handy.env
```

## Summary

MinIO now runs securely on your Tailscale network, accessible only to devices on your tailnet. This provides encryption, access control, and remote accessibility without exposing anything to the public internet.
