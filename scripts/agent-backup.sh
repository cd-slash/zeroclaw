#!/bin/bash
#
# ZeroClaw Multi-Agent Backup Manager
#
# Usage:
#   ./scripts/agent-backup.sh <command> [options]
#
# Commands:
#   backup <agent>          Backup a specific agent's data
#   backup-all              Backup all agents
#   restore <agent> <file>  Restore agent from backup
#   list <agent>            List available backups for agent
#   sync-to-minio <agent>   Sync agent backups to MinIO
#   sync-from-minio <agent> Restore agent from MinIO backup
#
# Examples:
#   ./scripts/agent-backup.sh backup handy
#   ./scripts/agent-backup.sh backup-all
#   ./scripts/agent-backup.sh restore handy handy-2025-01-15.tar.gz
#   ./scripts/agent-backup.sh sync-to-minio handy
#

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="${PROJECT_DIR}/.backups"
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

# MinIO Configuration (from environment or .env file)
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://localhost:9000}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-}"  
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-}"
MINIO_BUCKET="${MINIO_BUCKET:-zeroclaw-backups}"

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

# Get volume name for agent
get_volume_name() {
    local agent="$1"
    echo "$(compose_project_name "$agent")_data"
}

# Check if agent exists
check_agent() {
    local agent="$1"
    if [[ ! -f "$PROJECT_DIR/.agents/${agent}/.env" ]]; then
        log_error "Agent '$agent' not found"
        exit 1
    fi
}

# Backup a single agent
backup_agent() {
    local agent="$1"
    check_agent "$agent"
    
    local volume
    volume=$(get_volume_name "$agent")
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="${BACKUP_DIR}/${agent}-${timestamp}.tar.gz"
    
    mkdir -p "$BACKUP_DIR"
    
    log_info "Creating backup for agent: $agent"
    log_info "  Source volume: $volume"
    log_info "  Backup file: $backup_file"
    
    # Create backup using docker run with the volume mounted
    docker run --rm \
        -v "${volume}:/source:ro" \
        -v "${BACKUP_DIR}:/backup" \
        alpine:latest \
        tar czf "/backup/$(basename "$backup_file")" -C /source .
    
    if [[ $? -eq 0 ]]; then
        log_success "Backup created: $backup_file"
        
        # Show backup size
        local size
        size=$(du -h "$backup_file" | cut -f1)
        log_info "  Size: $size"
        
        # Create latest symlink
        ln -sf "$backup_file" "${BACKUP_DIR}/${agent}-latest.tar.gz"
        
        # Return the backup file path
        echo "$backup_file"
    else
        log_error "Backup failed"
        exit 1
    fi
}

# Backup all agents
backup_all() {
    log_info "Backing up all agents..."
    
    local agents=()
    for env_file in "$PROJECT_DIR/.agents"/\.[^.]*.env; do
        if [[ -f "$env_file" ]]; then
            local agent
            agent=$(basename "$env_file" .env)
            agent="${agent#.}"
            if [[ "$agent" != "shared" ]]; then
                agents+=("$agent")
            fi
        fi
    done
    
    if [[ ${#agents[@]} -eq 0 ]]; then
        log_warn "No agents found to backup"
        exit 0
    fi
    
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local all_backup="${BACKUP_DIR}/all-agents-${timestamp}.tar.gz"
    local temp_dir
    temp_dir=$(mktemp -d)
    
    for agent in "${agents[@]}"; do
        log_info "Backing up $agent..."
        local volume
        volume=$(get_volume_name "$agent")
        
        # Extract each volume to temp dir
        mkdir -p "${temp_dir}/${agent}"
        docker run --rm \
            -v "${volume}:/source:ro" \
            -v "${temp_dir}/${agent}:/dest" \
            alpine:latest \
            cp -r /source/. /dest/
    done
    
    # Create combined archive
    tar czf "$all_backup" -C "$temp_dir" .
    rm -rf "$temp_dir"
    
    log_success "All agents backed up to: $all_backup"
    
    # Show size
    local size
    size=$(du -h "$all_backup" | cut -f1)
    log_info "  Total size: $size"
    
    # Create latest symlink
    ln -sf "$all_backup" "${BACKUP_DIR}/all-agents-latest.tar.gz"
}

# Restore agent from backup
restore_agent() {
    local agent="$1"
    local backup_file="$2"
    
    check_agent "$agent"
    
    if [[ ! -f "$backup_file" ]]; then
        # Try in backup directory
        if [[ -f "${BACKUP_DIR}/${backup_file}" ]]; then
            backup_file="${BACKUP_DIR}/${backup_file}"
        else
            log_error "Backup file not found: $backup_file"
            exit 1
        fi
    fi
    
    local volume
    volume=$(get_volume_name "$agent")
    
    log_warn "WARNING: This will OVERWRITE all data for agent '$agent'!"
    log_warn "Volume to be restored: $volume"
    log_warn "Backup file: $backup_file"
    read -p "Are you sure? Type 'restore' to confirm: " confirm
    
    if [[ "$confirm" != "restore" ]]; then
        log_info "Restore cancelled"
        exit 0
    fi
    
    # Stop agent if running
    log_info "Stopping agent if running..."
    compose_agent "$agent" down 2>/dev/null || true
    
    # Clear existing volume data
    log_info "Clearing existing data..."
    docker run --rm \
        -v "${volume}:/target" \
        alpine:latest \
        rm -rf /target/* /target/.[!.]* 2>/dev/null || true
    
    # Restore from backup
    log_info "Restoring from backup..."
    docker run --rm \
        -v "${volume}:/target" \
        -v "$(dirname "$backup_file"):/backup:ro" \
        alpine:latest \
        tar xzf "/backup/$(basename "$backup_file")" -C /target
    
    if [[ $? -eq 0 ]]; then
        log_success "Restore completed for agent: $agent"
        log_info "Start the agent with: ./scripts/agent.sh start $agent"
    else
        log_error "Restore failed"
        exit 1
    fi
}

# List backups for agent
list_backups() {
    local agent="${1:-all}"
    
    if [[ ! -d "$BACKUP_DIR" ]]; then
        log_info "No backups directory found"
        exit 0
    fi
    
    log_info "Available backups:"
    echo ""
    
    if [[ "$agent" == "all" ]]; then
        # List all backups
        ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null | while read -r line; do
            echo "  $line"
        done || echo "  No backups found"
    else
        # List backups for specific agent
        ls -lh "${BACKUP_DIR}/${agent}"-*.tar.gz 2>/dev/null | while read -r line; do
            echo "  $line"
        done || echo "  No backups found for $agent"
    fi
}

# Sync backup to MinIO
sync_to_minio() {
    local agent="$1"
    local backup_file="${2:-}"
    
    # Check MinIO configuration
    if [[ -z "$MINIO_ACCESS_KEY" || -z "$MINIO_SECRET_KEY" ]]; then
        log_error "MinIO credentials not configured"
        log_info "Set MINIO_ACCESS_KEY and MINIO_SECRET_KEY environment variables"
        exit 1
    fi
    
    # If no backup file specified, use latest
    if [[ -z "$backup_file" ]]; then
        backup_file="${BACKUP_DIR}/${agent}-latest.tar.gz"
        if [[ ! -f "$backup_file" ]]; then
            log_error "No latest backup found for $agent"
            log_info "Create a backup first: ./scripts/agent-backup.sh backup $agent"
            exit 1
        fi
    fi
    
    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file not found: $backup_file"
        exit 1
    fi
    
    log_info "Syncing backup to MinIO..."
    log_info "  Endpoint: $MINIO_ENDPOINT"
    log_info "  Bucket: $MINIO_BUCKET"
    log_info "  File: $(basename "$backup_file")"
    
    # Use mc (MinIO client) or awscli with S3-compatible endpoint
    if command -v mc &> /dev/null; then
        # Configure mc if needed
        if ! mc alias ls myminio &>/dev/null; then
            mc alias set myminio "$MINIO_ENDPOINT" "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" &>/dev/null
        fi
        
        # Ensure bucket exists
        mc mb "myminio/${MINIO_BUCKET}" &>/dev/null || true
        
        # Upload backup
        mc cp "$backup_file" "myminio/${MINIO_BUCKET}/${agent}/"
        
    elif command -v aws &> /dev/null; then
        # Use AWS CLI with MinIO endpoint
        export AWS_ACCESS_KEY_ID="$MINIO_ACCESS_KEY"
        export AWS_SECRET_ACCESS_KEY="$MINIO_SECRET_KEY"
        
        aws --endpoint-url "$MINIO_ENDPOINT" s3 cp \
            "$backup_file" \
            "s3://${MINIO_BUCKET}/${agent}/$(basename "$backup_file")"
    else
        log_error "Neither 'mc' (MinIO client) nor 'aws' (AWS CLI) found"
        log_info "Install one of them to use MinIO sync"
        exit 1
    fi
    
    if [[ $? -eq 0 ]]; then
        log_success "Backup synced to MinIO: ${agent}/$(basename "$backup_file")"
    else
        log_error "Sync failed"
        exit 1
    fi
}

# Sync backup from MinIO
sync_from_minio() {
    local agent="$1"
    local backup_name="${2:-latest}"
    
    # Check MinIO configuration
    if [[ -z "$MINIO_ACCESS_KEY" || -z "$MINIO_SECRET_KEY" ]]; then
        log_error "MinIO credentials not configured"
        exit 1
    fi
    
    mkdir -p "$BACKUP_DIR"
    
    log_info "Downloading backup from MinIO..."
    log_info "  Endpoint: $MINIO_ENDPOINT"
    log_info "  Bucket: $MINIO_BUCKET"
    log_info "  Agent: $agent"
    
    local backup_file
    if [[ "$backup_name" == "latest" ]]; then
        backup_file="${BACKUP_DIR}/${agent}-latest.tar.gz"
    else
        backup_file="${BACKUP_DIR}/${backup_name}"
    fi
    
    if command -v mc &> /dev/null; then
        # Configure mc if needed
        if ! mc alias ls myminio &>/dev/null; then
            mc alias set myminio "$MINIO_ENDPOINT" "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" &>/dev/null
        fi
        
        if [[ "$backup_name" == "latest" ]]; then
            # Find the latest backup
            local latest
            latest=$(mc ls "myminio/${MINIO_BUCKET}/${agent}/" --json 2>/dev/null | \
                jq -r '.key' | grep "\.tar\.gz$" | sort | tail -1)
            if [[ -z "$latest" ]]; then
                log_error "No backups found in MinIO for agent: $agent"
                exit 1
            fi
            mc cp "myminio/${MINIO_BUCKET}/${agent}/${latest}" "$backup_file"
        else
            mc cp "myminio/${MINIO_BUCKET}/${agent}/${backup_name}" "$backup_file"
        fi
        
    elif command -v aws &> /dev/null; then
        export AWS_ACCESS_KEY_ID="$MINIO_ACCESS_KEY"
        export AWS_SECRET_ACCESS_KEY="$MINIO_SECRET_KEY"
        
        if [[ "$backup_name" == "latest" ]]; then
            # List and find latest
            local latest
            latest=$(aws --endpoint-url "$MINIO_ENDPOINT" s3 ls \
                "s3://${MINIO_BUCKET}/${agent}/" 2>/dev/null | \
                grep "\.tar\.gz$" | sort | tail -1 | awk '{print $4}')
            if [[ -z "$latest" ]]; then
                log_error "No backups found in MinIO for agent: $agent"
                exit 1
            fi
            aws --endpoint-url "$MINIO_ENDPOINT" s3 cp \
                "s3://${MINIO_BUCKET}/${agent}/${latest}" \
                "$backup_file"
        else
            aws --endpoint-url "$MINIO_ENDPOINT" s3 cp \
                "s3://${MINIO_BUCKET}/${agent}/${backup_name}" \
                "$backup_file"
        fi
    else
        log_error "Neither 'mc' nor 'aws' found"
        exit 1
    fi
    
    if [[ $? -eq 0 ]]; then
        log_success "Backup downloaded: $backup_file"
        
        # Ask if user wants to restore
        read -p "Restore this backup to agent '$agent'? (y/N): " restore_confirm
        if [[ "$restore_confirm" =~ ^[Yy]$ ]]; then
            restore_agent "$agent" "$backup_file"
        fi
    else
        log_error "Download failed"
        exit 1
    fi
}

# Main dispatcher
main() {
    local command="${1:-help}"
    
    case "$command" in
        backup)
            if [[ -z "${2:-}" ]]; then
                log_error "Usage: $0 backup <agent_name>"
                exit 1
            fi
            backup_agent "$2"
            ;;
        backup-all)
            backup_all
            ;;
        restore)
            if [[ -z "${2:-}" || -z "${3:-}" ]]; then
                log_error "Usage: $0 restore <agent_name> <backup_file>"
                exit 1
            fi
            restore_agent "$2" "$3"
            ;;
        list)
            list_backups "${2:-all}"
            ;;
        sync-to-minio)
            if [[ -z "${2:-}" ]]; then
                log_error "Usage: $0 sync-to-minio <agent_name> [backup_file]"
                exit 1
            fi
            sync_to_minio "$2" "${3:-}"
            ;;
        sync-from-minio)
            if [[ -z "${2:-}" ]]; then
                log_error "Usage: $0 sync-from-minio <agent_name> [backup_name|latest]"
                exit 1
            fi
            sync_from_minio "$2" "${3:-latest}"
            ;;
        help|--help|-h)
            cat << 'HELP'
ZeroClaw Multi-Agent Backup Manager

Usage: ./scripts/agent-backup.sh <command> [options]

Commands:
  backup <agent>                    Backup a specific agent's data
  backup-all                        Backup all agents
  restore <agent> <file>            Restore agent from backup file
  list [agent|all]                  List available backups
  sync-to-minio <agent> [file]      Upload backup to MinIO
  sync-from-minio <agent> [name]     Download and optionally restore from MinIO

Examples:
  ./scripts/agent-backup.sh backup handy              # Backup handy agent
  ./scripts/agent-backup.sh backup-all                # Backup all agents
  ./scripts/agent-backup.sh list                      # List all backups
  ./scripts/agent-backup.sh restore handy handy-2025-01-15.tar.gz
  ./scripts/agent-backup.sh sync-to-minio handy       # Upload to MinIO
  ./scripts/agent-backup.sh sync-from-minio handy     # Download from MinIO

MinIO Configuration (set via environment):
  MINIO_ENDPOINT      - MinIO server URL (default: http://localhost:9000)
  MINIO_ACCESS_KEY    - MinIO access key
  MINIO_SECRET_KEY    - MinIO secret key
  MINIO_BUCKET        - Bucket name (default: zeroclaw-backups)

Backup Storage:
  Local backups are stored in: .backups/
  Each backup is a gzipped tar archive of the agent's Docker volume

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
