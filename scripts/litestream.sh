#!/bin/bash
#
# ZeroClaw Litestream Manager (Integrated Version)
#
# Manages Litestream continuous backup for SQLite databases.
# Litestream now runs inside the agent container (integrated, not sidecar).
#
# Usage:
#   ./scripts/litestream.sh <command> [agent_name] [options]
#
# Commands:
#   status [agent]           Check Litestream status for an agent
#   restore <agent> [time]   Restore agent database from Litestream
#   logs [agent]             Show Litestream logs (from agent container)
#   snapshot <agent>         Create manual snapshot via Litestream
#
# Examples:
#   ./scripts/litestream.sh status handy
#   ./scripts/litestream.sh restore handy "2025-01-15 14:30:00"
#   ./scripts/litestream.sh logs handy -f

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"

compose_project_name() {
    local agent="$1"
    echo "zeroclaw-${agent}"
}

compose_agent() {
    local agent="$1"
    shift
    AGENT_NAME="$agent" \
    SHARED_ENV_FILE="$PROJECT_DIR/.agents/.shared.env" \
    AGENT_ENV_FILE="$PROJECT_DIR/.agents/${agent}/.env" \
    AGENT_CONFIG_DIR_SOURCE="./.agents/${agent}" \
    docker compose -p "$(compose_project_name "$agent")" -f "$COMPOSE_FILE" "$@"
}

list_agents() {
    for agent_dir in "$PROJECT_DIR/.agents"/*/; do
        [[ -f "${agent_dir}/.env" ]] || continue
        local name
        name=$(basename "$agent_dir")
        if [[ "$name" != "templates" && "$name" != "shared" ]]; then
            echo "$name"
        fi
    done
}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Check if agent exists
check_agent() {
    local agent="$1"
    if [[ ! -f "$PROJECT_DIR/.agents/${agent}/.env" ]]; then
        log_error "Agent '$agent' not found"
        exit 1
    fi
}

# Check Litestream status for an agent
status() {
    local agent="${1:-}"
    
    if [[ -z "$agent" ]]; then
        # Show status for all agents
        log_info "Checking Litestream status for all agents..."
        while IFS= read -r a; do
            if compose_agent "$a" ps --status running --services 2>/dev/null | grep -qx "server"; then
                echo ""
                log_info "Agent: $a"
                check_litestream_status "$a"
            fi
        done < <(list_agents)
        return
    fi
    
    check_agent "$agent"
    
    log_info "Litestream status for agent: $agent"
    check_litestream_status "$agent"
}

# Helper function to check Litestream inside container
check_litestream_status() {
    local agent="$1"
    
    # Check if agent container is running
    if ! compose_agent "$agent" ps --status running --services | grep -qx "server"; then
        log_warn "Agent '$agent' is not running"
        return 1
    fi
    
    # Check if Litestream is enabled
    local litestream_enabled
    litestream_enabled=$(compose_agent "$agent" exec -T server \
        printenv ZEROCLAW_LITESTREAM_ENABLED 2>/dev/null || echo "false")
    
    if [[ "$litestream_enabled" != "true" ]]; then
        log_warn "Litestream is not enabled for agent '$agent'"
        log_info "Set ZEROCLAW_LITESTREAM_ENABLED=true in .agents/${agent}/.env"
        return 1
    fi
    
    # Check if Litestream process is running inside container
    if compose_agent "$agent" exec -T server \
        pgrep -x litestream > /dev/null 2>&1; then
        log_success "Litestream process is running inside agent container"
        
        # Show recent logs from Litestream
        log_info "Recent replication activity:"
        compose_agent "$agent" exec -T server \
            tail -20 /tmp/litestream.log 2>/dev/null || \
            log_warn "No Litestream logs available yet"
    else
        log_warn "Litestream process not found inside agent container"
        log_info "Litestream should start automatically with the agent"
        log_info "Check agent logs: ./scripts/agent.sh logs $agent"
    fi
}

# Restore database from Litestream
restore() {
    local agent="$1"
    local restore_time="${2:-latest}"
    
    check_agent "$agent"
    
    log_warn "WARNING: This will restore the database for agent '$agent'"
    log_warn "Current database will be replaced. Ensure agent is stopped first."
    
    # Check if agent is running
    if compose_agent "$agent" ps --status running --services | grep -qx "server"; then
        log_error "Agent '$agent' is still running. Stop it first:"
        log_info "  ./scripts/agent.sh stop $agent"
        exit 1
    fi
    
    # Load MinIO credentials from agent env
    local minio_endpoint
    local minio_bucket
    local minio_access
    local minio_secret
    
    # Source the agent env file
    set -a
    source "$PROJECT_DIR/.agents/${agent}/.env"
    set +a
    
    minio_endpoint="${MINIO_ENDPOINT:-}"
    minio_bucket="${MINIO_BUCKET:-zeroclaw-backups}"
    minio_access="${MINIO_ACCESS_KEY:-}"
    minio_secret="${MINIO_SECRET_KEY:-}"
    
    if [[ -z "$minio_endpoint" || -z "$minio_access" || -z "$minio_secret" ]]; then
        log_error "MinIO credentials not configured for agent '$agent'"
        exit 1
    fi
    
    log_info "Restoring from Litestream..."
    log_info "  Agent: $agent"
    log_info "  Restore point: $restore_time"
    log_info "  Source: $minio_endpoint/$minio_bucket"
    
    read -p "Continue? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Cancelled"
        exit 0
    fi
    
    # Get volume name
    local volume_name="$(compose_project_name "$agent")_data"
    
    # Create temporary restore container with Litestream
    docker run --rm \
        -v "${volume_name}:/restore-data" \
        -e LITESTREAM_ACCESS_KEY_ID="$minio_access" \
        -e LITESTREAM_SECRET_ACCESS_KEY="$minio_secret" \
        litestream/litestream:0.3.13 \
        restore \
        -o /restore-data/.zeroclaw/memory.db \
        -if-db-not-exists \
        -timestamp "$restore_time" \
        "s3://${minio_bucket}/litestream/${agent}/memory.db" \
        -endpoint "$minio_endpoint"
    
    log_success "Database restored successfully"
    log_info "Start the agent: ./scripts/agent.sh start $agent"
}

# Show Litestream logs
logs() {
    local agent="${1:-}"
    shift 2>/dev/null || true
    
    if [[ -n "$agent" ]]; then
        check_agent "$agent"
        # Get logs from inside the agent container
        compose_agent "$agent" exec server \
            tail -f /tmp/litestream.log 2>/dev/null || \
            compose_agent "$agent" logs "$@" server | grep -i litestream || true
    else
        # Show logs for all agents
        while IFS= read -r a; do
            if compose_agent "$a" ps --status running --services 2>/dev/null | grep -qx "server"; then
                echo ""
                log_info "=== Agent: $a ==="
                compose_agent "$a" exec -T server \
                    tail -50 /tmp/litestream.log 2>/dev/null || \
                    log_warn "No Litestream logs for $a"
            fi
        done < <(list_agents)
    fi
}

# Create manual snapshot via Litestream
snapshot() {
    local agent="$1"
    
    check_agent "$agent"
    
    log_info "Creating manual snapshot for agent: $agent"
    
    # Trigger snapshot inside the agent container
    compose_agent "$agent" exec server \
        litestream snapshot \
        -config /tmp/litestream.yml \
        /zeroclaw-data/.zeroclaw/memory.db \
        2>&1 || {
            log_error "Failed to create snapshot. Is Litestream running?"
            exit 1
        }
    
    log_success "Snapshot created successfully"
}

# Main dispatcher
main() {
    local command="${1:-help}"
    
    case "$command" in
        status)
            status "${2:-}"
            ;;
        restore)
            if [[ -z "${2:-}" ]]; then
                log_error "Usage: $0 restore <agent_name> [timestamp]"
                log_info "Examples:"
                log_info "  $0 restore handy          # Restore to latest"
                log_info "  $0 restore handy \"2025-01-15 14:30:00\"  # Restore to specific time"
                exit 1
            fi
            restore "$2" "${3:-latest}"
            ;;
        logs)
            logs "${2:-}" "${@:3}"
            ;;
        snapshot)
            if [[ -z "${2:-}" ]]; then
                log_error "Usage: $0 snapshot <agent_name>"
                exit 1
            fi
            snapshot "$2"
            ;;
        help|--help|-h)
            cat << 'HELP'
ZeroClaw Litestream Manager (Integrated Version)

Manages continuous SQLite backup using Litestream.
Litestream now runs inside the agent container itself.

Usage: ./scripts/litestream.sh <command> [options]

Commands:
  status [agent]            Check Litestream status
  restore <agent> [time]      Restore database from Litestream
                            Time format: "YYYY-MM-DD HH:MM:SS" or "latest"
  logs [agent] [-f]         Show Litestream logs (from inside container)
  snapshot <agent>          Create manual snapshot

Examples:
  ./scripts/litestream.sh status handy
  ./scripts/litestream.sh restore gordon
  ./scripts/litestream.sh restore zoe "2025-01-15 14:30:00"
  ./scripts/litestream.sh logs handy -f

Architecture:
  Litestream is now integrated into the agent container.
  No separate sidecar needed - simpler, more efficient.

Prerequisites:
  1. MinIO service configured at ~/devel/containers/minio
  2. Agent started with ZEROCLAW_LITESTREAM_ENABLED=true
  3. Litestream config in .agents/litestream.yml

For more info: docs/litestream-integration.md
HELP
            ;;
        *)
            log_error "Unknown command: $command"
            log_info "Run '$0 help' for usage information"
            exit 1
            ;;
    esac
}

main "$@"
