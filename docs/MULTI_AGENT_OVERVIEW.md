# ZeroClaw Multi-Agent System - Complete Overview

This document provides a high-level overview of the ZeroClaw multi-agent container system.

## Architecture Summary

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                           Host Machine                                       │
│                                                                              │
│  ┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐ │
│  │    Agent: handy       │  │   Agent: gordon     │  │    Agent: zoe       │ │
│  │    Port: 3000         │  │   Port: 3001        │  │    Port: 3002       │ │
│  │                       │  │                     │  │                     │ │
│  │  .handy.env (hidden)  │  │ .gordon.env (hidden)│  │  .zoe.env (hidden)  │ │
│  │  .handy/              │  │ .gordon/            │  │  .zoe/              │ │
│  │  ├── IDENTITY.md      │  │ ├── IDENTITY.md     │  │  ├── IDENTITY.md    │ │
│  │  ├── SOUL.md          │  │ ├── SOUL.md         │  │  ├── SOUL.md        │ │
│  │  ├── AGENTS.md        │  │ ├── AGENTS.md       │  │  ├── AGENTS.md      │ │
│  │  ├── USER.md          │  │ ├── USER.md         │  │  ├── USER.md        │ │
│  │  ├── TOOLS.md         │  │ ├── TOOLS.md        │  │  ├── TOOLS.md       │ │
│  │  ├── MEMORY.md        │  │ ├── MEMORY.md       │  │  ├── MEMORY.md      │ │
│  │  └── skills/          │  │ └── skills/         │  │  └── skills/        │ │
│  │                       │  │                     │  │                     │ │
│  │  Docker Volume:       │  │ Docker Volume:      │  │  Docker Volume:     │ │
│  │  zeroclaw-data-handy  │  │ zeroclaw-data-gordon│  │  zeroclaw-data-zoe  │ │
│  │  ├─ memory.db         │  │ ├─ memory.db        │  │  ├─ memory.db       │ │
│  │  ├─ config.toml       │  │ ├─ config.toml      │  │  ├─ config.toml     │ │
│  │  └─ workspace/        │  │ └─ workspace/       │  │  └─ workspace/      │ │
│  │      ├─ MEMORY.md     │  │     ├─ MEMORY.md    │  │      ├─ MEMORY.md   │ │
│  │      └─ memory/       │  │     └─ memory/      │  │      └─ memory/     │ │
│  └─────────────────────┘  └─────────────────────┘  └─────────────────────┘ │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                    Shared Configuration                                  ││
│  │  .agents/.shared.env (API keys, common settings)                        ││
│  │  .agents/.minio.env (MinIO backup credentials - optional)               ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                    Backup Storage (Optional)                             ││
│  │  .backups/ (local)    or    MinIO over Tailscale                       ││
│  │  handy-*.tar.gz             zeroclaw-backups/handy/                      ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└──────────────────────────────────────────────────────────────────────────────┘
```

## Key Components

### 1. Hidden Configuration Files (`.agent.env`)

**Why hidden?** These contain secrets (API keys, tokens) and are in `.gitignore`.

```
.agents/.handy.env      ← Hidden config (never commit this!)
├── AGENT_NAME=handy
├── API_KEY=sk-...       ← Your LLM API key
├── ZEROCLAW_MODEL=...
└── ZEROCLAW_MEMORY_BACKEND=sqlite
```

**3 Agents included:**
- `handy` - DevOps/Infrastructure (port 3000)
- `gordon` - Code Review (port 3001)
- `zoe` - Creative Writing (port 3002)

### 2. Agent Identity Directories (`.agent/`)

**Safe to commit** - these define personality and behavior, no secrets.

```
.agents/.handy/
├── IDENTITY.md    # Who: "I'm Handy, a Rust-forged AI 🦀"
├── SOUL.md        # How: Core truths, communication style
├── AGENTS.md      # What: Operational guidelines
├── USER.md        # Context: Who I'm helping
├── TOOLS.md       # Notes: SSH hosts, environment specifics
├── MEMORY.md      # Long-term memory template
└── skills/        # Custom capabilities
```

**Each agent has unique identity files** tailored to their specialty.

### 3. Isolated Storage (Docker Volumes)

**Why isolated?** Each agent needs separate:
- SQLite database (memory.db)
- Configuration (config.toml)
- Workspace files (MEMORY.md, daily notes, skills)

```
zeroclaw-data-handy      → /zeroclaw-data (in container)
├── .zeroclaw/memory.db              (SQLite vector memory)
├── .zeroclaw/config.toml            (runtime config)
└── .zeroclaw/workspace/
    ├── MEMORY.md                    (curated long-term memory)
    ├── memory/2025-01-15.md         (daily log)
    └── skills/myskill/SKILL.md      (custom skills)
```

**Important:** Agents cannot see each other's data. Complete isolation.

### 4. Memory System

**SQLite Backend (Default):**
- Vector-based with semantic search
- Hybrid search: vector similarity + keyword BM25
- Embeddings for semantic recall
- Automatic hygiene (archive old data, purge ancient)

**Memory Files:**
- `memory.db` - SQLite database (primary store)
- `MEMORY.md` - Curated long-term (auto-injected into prompts)
- `memory/YYYY-MM-DD.md` - Daily logs (on-demand via tools)

**Memory Tools:**
- `memory_store` - Save important info
- `memory_recall` - Search and retrieve
- `memory_forget` - Delete stale data
- `snapshot_memory` - Point-in-time SQLite snapshots with rollback (built-in)
- `backup_workspace` - Full workspace backup and MinIO sync (built-in)

### 5. Backup & Recovery

**Three Ways to Protect Data:**

1. **Database Snapshots (built-in tool) - Fast & Reversible:**
   ```
   # Create point-in-time snapshot (great for experiments)
   snapshot_memory action="create" name="before-experiment"
   # Rollback if needed
   snapshot_memory action="rollback" snapshot="before-experiment-20250115-143022"
   ```

2. **Full Backup (built-in tool) - Complete & Portable:**
   ```
   # Agent can back itself up before risky operations
   backup_workspace action="create"
   backup_workspace action="sync" backup_file="/path/to/backup.tar.gz"
   ```

2. **Host Script (admin initiated):

**Local Backups:**
```bash
./scripts/agent-backup.sh backup handy     # Single agent
./scripts/agent-backup.sh backup-all       # All agents
```

Creates: `.backups/handy-20250115-143022.tar.gz`

**MinIO Remote Storage (Optional):**
```bash
# Configure MinIO (for Tailscale-accessible storage)
cp .agents/minio.env.example .agents/.minio.env
# Edit with your MinIO credentials
source .agents/.minio.env

# Sync to MinIO
./scripts/agent-backup.sh sync-to-minio handy

# Restore from MinIO
./scripts/agent-backup.sh sync-from-minio handy
```

**Why MinIO?**
- Self-hosted S3-compatible storage
- Works over Tailscale (secure, private)
- You control your data
- Perfect for multi-server deployments

## Workflow Examples

### Starting Your First Agent

```bash
# 1. Configure shared settings
nano .agents/.shared.env
# Add: API_KEY=your-key-here

# 2. Customize handy's identity
nano .agents/.handy/IDENTITY.md
# Change name, emoji, vibe

# 3. Start the agent
./scripts/agent.sh start handy

# 4. Access at http://localhost:3000
```

### Creating a Custom Agent

```bash
# Create new agent
./scripts/agent.sh create mybot

# This creates:
# - .agents/.mybot.env (hidden config)
# - .agents/.mybot/ (identity directory with templates)

# Customize identity
nano .agents/.mybot/IDENTITY.md
nano .agents/.mybot/SOUL.md

# Add to docker-compose.agents.yml
# (see template printed by create command)

# Start it
./scripts/agent.sh start mybot
```

### Migrating to New Server

**On source server:**
```bash
# Stop agent
./scripts/agent.sh stop handy

# Backup
./scripts/agent-backup.sh backup handy

# Upload to MinIO
./scripts/agent-backup.sh sync-to-minio handy
```

**On destination server:**
```bash
# Clone repo
git clone <repo> zeroclaw
cd zeroclaw

# Configure MinIO access
source .agents/.minio.env

# Download and restore
./scripts/agent-backup.sh sync-from-minio handy

# Start
./scripts/agent.sh start handy
```

### Multi-Agent Team Workflow

```bash
# Start DevOps agent for infrastructure work
./scripts/agent.sh start handy

# Start code reviewer for PR reviews
./scripts/agent.sh start gordon

# Start creative writer for documentation
./scripts/agent.sh start zoe

# All agents run independently on different ports
# Each has isolated memory and configuration
```

## Configuration Reference

### Priority (highest to lowest)

1. **Runtime env vars** from docker-compose `environment:`
2. **.agents/.agent.env** (hidden agent config)
3. **.agents/.shared.env** (shared settings)
4. **Base image config** (defaults)
5. **Identity files** (`.agent/*.md` - loaded into prompts)

### Common Environment Variables

```bash
# Identity
AGENT_NAME=handy
AGENT_ROLE=devops

# LLM
API_KEY=sk-...
PROVIDER=openrouter
ZEROCLAW_MODEL=anthropic/claude-sonnet-4-20250514
ZEROCLAW_TEMPERATURE=0.7

# Gateway
ZEROCLAW_GATEWAY_PORT=3000
ZEROCLAW_ALLOW_PUBLIC_BIND=true

# Memory
ZEROCLAW_MEMORY_BACKEND=sqlite  # or: markdown, none
ZEROCLAW_MEMORY_AUTO_SAVE=true
ZEROCLAW_SQLITE_WAL_MODE=true  # Required for Litestream

# Litestream (continuous backup)
MINIO_ENDPOINT=https://minio.your-tailnet.ts.net:9000
MINIO_ACCESS_KEY=your-access-key
MINIO_SECRET_KEY=your-secret-key
MINIO_BUCKET=zeroclaw-backups

# Tools
ZEROCLAW_SHELL_ENABLED=true
ZEROCLAW_FILE_ENABLED=true
ZEROCLAW_BROWSER_ENABLED=true
```

## File Structure Summary

```
zeroclaw/
├── .agents/
│   ├── .shared.env             # Shared API keys
│   ├── minio.env.example       # MinIO config template
│   ├── .handy.env              # ← HIDDEN: handy config
│   ├── .gordon.env             # ← HIDDEN: gordon config
│   ├── .zoe.env                # ← HIDDEN: zoe config
│   ├── .handy/                 # handy identity (commit OK)
│   │   ├── IDENTITY.md
│   │   ├── SOUL.md
│   │   ├── AGENTS.md
│   │   ├── USER.md
│   │   ├── TOOLS.md
│   │   ├── MEMORY.md
│   │   └── skills/
│   ├── .gordon/                # gordon identity
│   ├── .zoe/                   # zoe identity
│   └── templates/              # Template files
│       ├── IDENTITY.md.template
│       ├── SOUL.md.template
│       ├── AGENTS.md.template
│       ├── USER.md.template
│       ├── TOOLS.md.template
│       ├── MEMORY.md.template
│       └── SKILL.md.template
├── .backups/                   # Local backups (gitignored)
├── docker-compose.agents.yml   # Multi-agent compose
├── scripts/
│   ├── agent.sh                # Agent management CLI
│   └── agent-backup.sh         # Backup/restore CLI
└── docs/
    ├── multi-agent-setup.md    # Detailed setup guide
    └── backup-and-recovery.md  # Backup documentation
```

## Security Checklist

- ✅ API keys in `.env` files (hidden, gitignored)
- ✅ Agent identity files can be committed (no secrets)
- ✅ Each agent isolated (separate Docker volumes)
- ✅ Backups encrypted at rest (MinIO optional)
- ✅ Tailscale for secure networking (optional)

## Getting Started

1. **Configure API key:**
   ```bash
   nano .agents/.shared.env
   # Add: API_KEY=sk-your-key-here
   ```

2. **Start an agent:**
   ```bash
   ./scripts/agent.sh start handy
   ```

3. **Access the agent:**
   ```bash
   open http://localhost:3000
   ```

4. **Read full docs:**
   - Setup: `docs/multi-agent-setup.md`
   - Backups: `docs/backup-and-recovery.md`

## Quick Reference Card

| Command | Description |
|---------|-------------|
| `./scripts/agent.sh list` | Show all agents |
| `./scripts/agent.sh start handy` | Start agent |
| `./scripts/agent.sh stop handy` | Stop agent |
| `./scripts/agent.sh logs handy -f` | Follow logs |
| `./scripts/agent.sh create mybot` | Create new agent |
| `./scripts/agent-backup.sh backup handy` | Backup agent |
| `./scripts/agent-backup.sh sync-to-minio handy` | Upload to MinIO |
| `./scripts/agent-backup.sh restore handy file.tar.gz` | Restore |

## Need Help?

- **Setup issues:** See `docs/multi-agent-setup.md`
- **Backup questions:** See `docs/backup-and-recovery.md`
- **SQLite details:** Default backend, stored in isolated volumes
- **Memory system:** Uses vector search + daily notes

---

**Summary:** Multiple isolated agents, each with SQLite memory, easy backups to MinIO over Tailscale, portable between servers, secure by default.
