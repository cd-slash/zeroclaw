#!/bin/bash
#
# Migration script: Move agent configs from old structure to new structure
#
# Old: .agents/.handy.env + .agents/.handy/
# New: .agents/handy/.env + .agents/handy/*
#
# Usage: ./scripts/migrate-agents.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
AGENTS_DIR="$PROJECT_DIR/.agents"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Check if migration is needed
check_migration_needed() {
    local has_old_structure=false
    
    # Check for old .agent.env files
    for env_file in "$AGENTS_DIR"/.[^.]*.env; do
        if [[ -f "$env_file" ]]; then
            has_old_structure=true
            break
        fi
    done
    
    if [[ "$has_old_structure" == "false" ]]; then
        log_success "No old-style agent configs found. Nothing to migrate."
        return 1
    fi
    
    return 0
}

# Show what will be migrated
preview_migration() {
    log_info "The following agents will be migrated:"
    echo ""
    
    for env_file in "$AGENTS_DIR"/.[^.]*.env; do
        if [[ -f "$env_file" ]]; then
            local agent_name
            agent_name=$(basename "$env_file" .env)
            agent_name="${agent_name#.}"
            
            # Skip shared.env
            if [[ "$agent_name" == "shared" ]]; then
                continue
            fi
            
            local old_dir="$AGENTS_DIR/.${agent_name}"
            local new_dir="$AGENTS_DIR/${agent_name}"
            
            echo "  $agent_name:"
            echo "    From: $env_file"
            if [[ -d "$old_dir" ]]; then
                echo "    + $old_dir/"
            fi
            echo "    To:   $new_dir/.env"
            if [[ -d "$old_dir" ]]; then
                echo "    + $new_dir/ (merged with existing)"
            fi
            echo ""
        fi
    done
}

# Perform migration for a single agent
migrate_agent() {
    local agent="$1"
    local old_env="$AGENTS_DIR/.${agent}.env"
    local old_dir="$AGENTS_DIR/.${agent}"
    local new_dir="$AGENTS_DIR/${agent}"
    local new_env="${new_dir}/.env"
    
    log_info "Migrating agent: $agent"
    
    # Create new directory if it doesn't exist
    mkdir -p "$new_dir"
    
    # Move .env file
    if [[ -f "$old_env" ]]; then
        if [[ -f "$new_env" ]]; then
            log_warn "  $new_env already exists, keeping existing"
            log_info "  (Old file at $old_env will not be removed)"
        else
            mv "$old_env" "$new_env"
            log_success "  Moved $old_env -> $new_env"
        fi
    fi
    
    # Move directory contents
    if [[ -d "$old_dir" ]]; then
        if [[ -d "$new_dir" ]]; then
            # Merge contents
            for item in "$old_dir"/* "$old_dir"/.[^.]*; do
                if [[ -e "$item" ]]; then
                    local basename
                    basename=$(basename "$item")
                    local target="$new_dir/$basename"
                    
                    if [[ -e "$target" ]]; then
                        log_warn "  $target already exists, skipping"
                    else
                        mv "$item" "$target"
                        log_success "  Moved $item -> $target"
                    fi
                fi
            done
            
            # Remove old directory if empty
            if [[ -z "$(ls -A "$old_dir" 2>/dev/null)" ]]; then
                rmdir "$old_dir"
                log_success "  Removed empty directory: $old_dir"
            else
                log_warn "  $old_dir not empty, preserved"
            fi
        else
            mv "$old_dir" "$new_dir"
            log_success "  Moved $old_dir -> $new_dir"
        fi
    fi
    
    # Create tools directory if it doesn't exist
    if [[ ! -d "$new_dir/tools" ]]; then
        mkdir -p "$new_dir/tools"
        log_info "  Created tools directory: $new_dir/tools/"
    fi
    
    log_success "Migration complete for $agent"
}

# Main migration
run_migration() {
    log_info "Starting agent configuration migration..."
    echo ""
    
    if ! check_migration_needed; then
        exit 0
    fi
    
    preview_migration
    
    echo ""
    read -p "Proceed with migration? (yes/no): " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        log_info "Migration cancelled"
        exit 0
    fi
    
    echo ""
    log_info "Starting migration..."
    echo ""
    
    # Migrate each agent
    for env_file in "$AGENTS_DIR"/.[^.]*.env; do
        if [[ -f "$env_file" ]]; then
            local agent_name
            agent_name=$(basename "$env_file" .env)
            agent_name="${agent_name#.}"
            
            # Skip shared.env
            if [[ "$agent_name" == "shared" ]]; then
                continue
            fi
            
            migrate_agent "$agent_name"
            echo ""
        fi
    done
    
    log_success "Migration complete!"
    echo ""
    log_info "Next steps:"
    log_info "  1. Review the new structure: ls -la $AGENTS_DIR/"
    log_info "  2. Test your agents: ./scripts/agent.sh start <agent>"
    log_info "  3. Add custom tools to .agents/<agent>/tools/ if needed"
    echo ""
    log_warn "IMPORTANT: Update any external references to the old paths!"
    log_info "  Old: .agents/.handy.env -> New: .agents/handy/.env"
    log_info "  Old: .agents/.handy/     -> New: .agents/handy/"
}

# Show help
show_help() {
    cat << 'EOF'
Agent Configuration Migration Script

This script migrates agent configurations from the old structure to the new:

Old structure:
  .agents/.handy.env      (hidden file)
  .agents/.handy/         (hidden directory)

New structure:
  .agents/handy/.env      (file in agent directory)
  .agents/handy/          (regular directory)
  .agents/handy/tools/   (new: custom tools directory)

Usage:
  ./scripts/migrate-agents.sh     # Run interactive migration
  ./scripts/migrate-agents.sh --help

The script will:
  1. Show what will be migrated
  2. Ask for confirmation
  3. Move .env files into agent directories
  4. Merge identity directories
  5. Create tools/ subdirectories
  6. Clean up old empty directories

Note: Existing files in the new location will be preserved.
EOF
}

# Main
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    show_help
    exit 0
fi

run_migration
