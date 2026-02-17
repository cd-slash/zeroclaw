#!/bin/bash
#
# ZeroClaw Multi-Agent Manager
# 
# Usage:
#   ./scripts/agent.sh <command> [agent_name]
#
# Commands:
#   list              List all available agents
#   start <agent>     Start an agent (e.g., ./agent.sh start handy)
#   stop <agent>      Stop an agent
#   restart <agent>   Restart an agent
#   logs <agent>      Show logs for an agent
#   shell <agent>     Open shell in agent container
#   status            Show status of all agents
#   create <agent>    Create a new agent configuration
#   remove <agent>    Remove an agent (stops and deletes volumes)
#
# Examples:
#   ./scripts/agent.sh start handy          # Start the handy agent
#   ./scripts/agent.sh start gordon         # Start gordon on port 3001
#   ./scripts/agent.sh start zoe          # Start zoe on port 3002
#   ./scripts/agent.sh logs handy -f      # Follow handy logs
#   ./scripts/agent.sh create mybot       # Create new agent config

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
AGENTS_DIR="$PROJECT_DIR/.agents"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.agents.yml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
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

# Check if agent config exists
check_agent_config() {
    local agent="$1"
    if [[ ! -f "$AGENTS_DIR/${agent}/.env" ]]; then
        log_error "Agent '$agent' not found. Config missing: $AGENTS_DIR/${agent}/.env"
        log_info "Use './scripts/agent.sh create $agent' to create a new agent"
        exit 1
    fi
}

# Get the host port for an agent
get_agent_port() {
    local agent="$1"
    # Ports are assigned sequentially: handy=3000, gordon=3001, zoe=3002, etc.
    # This is defined in docker-compose.agents.yml
    case "$agent" in
        handy) echo "3000" ;;
        gordon) echo "3001" ;;
        zoe) echo "3002" ;;
        *) 
            # For custom agents, try to extract from compose file
            local port
            port=$(grep -A 20 "container_name: zeroclaw-${agent}$" "$COMPOSE_FILE" | grep -E '^\s+- "[0-9]+:3000"' | head -1 | sed 's/.*- "\([0-9]*\):3000".*/\1/')
            if [[ -n "$port" ]]; then
                echo "$port"
            else
                echo ""
            fi
            ;;
    esac
}

# List all available agents
list_agents() {
    log_info "Available agents:"
    echo ""
    
    if [[ ! -d "$AGENTS_DIR" ]]; then
        log_warn "Agents directory not found: $AGENTS_DIR"
        return
    fi
    
    # Get all agents from subdirectories containing .env files
    local all_agents=()
    for agent_dir in "$AGENTS_DIR"/*/; do
        if [[ -f "${agent_dir}/.env" ]]; then
            local agent_name
            agent_name=$(basename "$agent_dir")
            # Skip shared and templates directories
            if [[ "$agent_name" != "shared" && "$agent_name" != "templates" ]]; then
                all_agents+=("$agent_name")
            fi
        fi
    done
    
    # Display agents
    printf "%-15s %-10s %-8s %-20s\n" "AGENT" "STATUS" "PORT" "URL"
    printf "%-15s %-10s %-8s %-20s\n" "-----" "------" "----" "---"
    
    for agent in "${all_agents[@]}"; do
        [[ -z "$agent" ]] && continue
        
        local status="stopped"
        local port
        port=$(get_agent_port "$agent")
        
        if docker compose -f "$COMPOSE_FILE" ps "${agent}" 2>/dev/null | grep -q "running"; then
            status="running"
        fi
        
        local url=""
        if [[ -n "$port" ]]; then
            url="http://localhost:${port}"
        fi
        
        printf "%-15s %-10s %-8s %-20s\n" "$agent" "$status" "${port:-auto}" "$url"
    done
    
    echo ""
    log_info "Built-in agents: handy (3000), gordon (3001), zoe (3002)"
    log_info "Custom agents: Create with './scripts/agent.sh create <name>'"
}

# Start an agent
start_agent() {
    local agent="$1"
    check_agent_config "$agent"
    
    local port
    port=$(get_agent_port "$agent")
    
    log_info "Starting agent: $agent"
    if [[ -n "$port" ]]; then
        log_info "Gateway will be available at: http://localhost:${port}"
    fi
    
    # Use the profile-based service
    # Docker Compose automatically isolates volumes and names containers
    docker compose -f "$COMPOSE_FILE" --profile "$agent" up -d
    
    if [[ $? -eq 0 ]]; then
        log_success "Agent '$agent' started successfully"
        log_info "Container name: zeroclaw-${agent}-server-1"
        log_info "View logs: ./scripts/agent.sh logs $agent -f"
    else
        log_error "Failed to start agent '$agent'"
        exit 1
    fi
}

# Stop an agent
stop_agent() {
    local agent="$1"
    
    log_info "Stopping agent: $agent"
    # Use profile to stop the specific agent
    docker compose -f "$COMPOSE_FILE" --profile "$agent" down
    
    if [[ $? -eq 0 ]]; then
        log_success "Agent '$agent' stopped successfully"
    else
        log_warn "Agent '$agent' may not be running or already stopped"
    fi
}

# Restart an agent
restart_agent() {
    local agent="$1"
    stop_agent "$agent"
    sleep 2
    start_agent "$agent"
}

# Show agent logs
show_logs() {
    local agent="$1"
    shift
    # Container is named zeroclaw-<agent>-server-1
    docker compose -f "$COMPOSE_FILE" --profile "$agent" logs "$@" "server"
}

# Open shell in agent container
open_shell() {
    local agent="$1"
    # Container is named zeroclaw-<agent>-server-1
    docker compose -f "$COMPOSE_FILE" --profile "$agent" exec "server" bash
}

# Show status of all agents
show_status() {
    log_info "Agent container status:"
    echo ""
    docker compose -f "$COMPOSE_FILE" ps
}

# Create a new agent
create_agent() {
    local agent="$1"
    local agent_dir="$AGENTS_DIR/${agent}"
    local env_file="${agent_dir}/.env"
    
    if [[ -f "$env_file" ]]; then
        log_error "Agent '$agent' already exists: $env_file"
        exit 1
    fi
    
    # Find next available port
    local port=3000
    while grep -q "\"${port}:3000\"" "$COMPOSE_FILE" 2>/dev/null; do
        ((port++))
    done
    
    # Create agent directory
    mkdir -p "$agent_dir"
    
    # Create agent config
    cat > "$env_file" << EOF
# =============================================================================
# Agent: ${agent}
# Created: $(date)
# =============================================================================

# Agent identity
AGENT_NAME=${agent}
AGENT_ROLE=general

# Model configuration
ZEROCLAW_MODEL=anthropic/claude-sonnet-4-20250514
ZEROCLAW_TEMPERATURE=0.7

# Gateway configuration
ZEROCLAW_GATEWAY_PORT=3000
ZEROCLAW_ALLOW_PUBLIC_BIND=true

# Tool configuration
ZEROCLAW_SHELL_ENABLED=true
ZEROCLAW_FILE_ENABLED=true
ZEROCLAW_BROWSER_ENABLED=true

# Memory configuration
# Options: sqlite (vector-based with semantic search), markdown (file-based), none
ZEROCLAW_MEMORY_BACKEND=sqlite
ZEROCLAW_MEMORY_AUTO_SAVE=true

# Agent config directory (mounted into container)
# The backup_workspace tool includes this directory automatically
AGENT_CONFIG_DIR=/agent-config
EOF
    
    # Create agent subdirectories
    mkdir -p "$agent_dir/skills"
    mkdir -p "$agent_dir/tools"
    
    # Copy template files
    local templates_dir="$AGENTS_DIR/templates"
    if [[ -d "$templates_dir" ]]; then
        # Copy and customize templates
        sed "s/{{AGENT_NAME}}/${agent}/g" "$templates_dir/IDENTITY.md.template" > "$agent_dir/IDENTITY.md"
        sed "s/{{AGENT_NAME}}/${agent}/g" "$templates_dir/SOUL.md.template" > "$agent_dir/SOUL.md"
        sed "s/{{AGENT_NAME}}/${agent}/g" "$templates_dir/AGENTS.md.template" > "$agent_dir/AGENTS.md"
        sed "s/{{AGENT_NAME}}/${agent}/g" "$templates_dir/USER.md.template" > "$agent_dir/USER.md"
        sed "s/{{AGENT_NAME}}/${agent}/g" "$templates_dir/TOOLS.md.template" > "$agent_dir/TOOLS.md"
        cp "$templates_dir/MEMORY.md.template" "$agent_dir/MEMORY.md"
        
        # Set default communication style
        sed -i "s/{{COMMUNICATION_STYLE}}/Be warm, natural, and clear. Use occasional relevant emojis (1-2 max) and avoid robotic phrasing./g" "$agent_dir/SOUL.md"
        sed -i "s/{{USER_NAME}}/(Add your name)/g" "$agent_dir/USER.md"
        sed -i "s/{{TIMEZONE}}/(Add your timezone)/g" "$agent_dir/USER.md"
        sed -i "s/{{COMMUNICATION_STYLE}}/Be warm, natural, and clear. Use occasional relevant emojis (1-2 max) and avoid robotic phrasing./g" "$agent_dir/USER.md"
    fi
    
    log_success "Created agent: $agent"
    log_info "  Config file: $env_file"
    log_info "  Agent directory: $agent_dir/"
    log_info "  - Identity files: $agent_dir/*.md"
    log_info "  - Custom tools: $agent_dir/tools/ (mounted to /usr/local/bin/agent-tools)"
    log_info ""
    log_info "To start this agent:"
    log_info "  ./scripts/agent.sh start ${agent}"
    log_info ""
    log_info "Or with docker compose directly:"
    log_info "  docker compose -f docker-compose.agents.yml --profile ${agent} up -d"
    log_info ""
    log_info "For custom container images per agent:"
    log_info "  1. Create $agent_dir/Dockerfile with your tools"
    log_info "  2. Update docker-compose.agents.yml to use:"
    log_info "     build:"
    log_info "       context: ."
    log_info "       dockerfile: .agents/${agent}/Dockerfile"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Review and customize identity files in $agent_dir/"
    log_info "  2. Add custom tools to $agent_dir/tools/ (optional)"
    log_info "  3. Start with: ./scripts/agent.sh start ${agent}"
}

# Remove an agent (destructive!)
remove_agent() {
    local agent="$1"
    local agent_dir="$AGENTS_DIR/${agent}"
    local env_file="${agent_dir}/.env"
    
    if [[ ! -f "$env_file" ]]; then
        log_error "Agent '$agent' not found"
        exit 1
    fi
    
    log_warn "WARNING: This will stop the agent and DELETE all its data!"
    log_warn "Volumes to be removed:"
    log_warn "  - zeroclaw-data-${agent}"
    log_warn "  - tailscale-data-${agent}"
    echo ""
    read -p "Are you sure? Type 'yes' to confirm: " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        log_info "Cancelled"
        exit 0
    fi
    
    # Stop if running
    docker compose -f "$COMPOSE_FILE" --profile "$agent" down --volumes 2>/dev/null || true
    
    # Remove agent directory (contains .env and all identity files)
    if [[ -d "$agent_dir" ]]; then
        log_warn "Removing agent directory: $agent_dir"
        rm -rf "$agent_dir"
    fi
    
    log_success "Agent '$agent' removed"
    log_info "Note: You may want to remove the service entry from $COMPOSE_FILE"
}

# Main command dispatcher
main() {
    local command="${1:-help}"
    
    case "$command" in
        list)
            list_agents
            ;;
        start)
            if [[ -z "${2:-}" ]]; then
                log_error "Usage: $0 start <agent_name>"
                list_agents
                exit 1
            fi
            start_agent "$2"
            ;;
        stop)
            if [[ -z "${2:-}" ]]; then
                log_error "Usage: $0 stop <agent_name>"
                exit 1
            fi
            stop_agent "$2"
            ;;
        restart)
            if [[ -z "${2:-}" ]]; then
                log_error "Usage: $0 restart <agent_name>"
                exit 1
            fi
            restart_agent "$2"
            ;;
        logs)
            if [[ -z "${2:-}" ]]; then
                log_error "Usage: $0 logs <agent_name> [-f]"
                exit 1
            fi
            local agent="$2"
            shift 2
            show_logs "$agent" "$@"
            ;;
        shell)
            if [[ -z "${2:-}" ]]; then
                log_error "Usage: $0 shell <agent_name>"
                exit 1
            fi
            open_shell "$2"
            ;;
        status)
            show_status
            ;;
        create)
            if [[ -z "${2:-}" ]]; then
                log_error "Usage: $0 create <agent_name>"
                exit 1
            fi
            create_agent "$2"
            ;;
        remove)
            if [[ -z "${2:-}" ]]; then
                log_error "Usage: $0 remove <agent_name>"
                exit 1
            fi
            remove_agent "$2"
            ;;
        help|--help|-h)
            cat << 'HELP'
ZeroClaw Multi-Agent Manager

Usage: ./scripts/agent.sh <command> [agent_name] [options]

Commands:
  list                    List all available agents and their status
  start <agent>           Start an agent (creates container if needed)
  stop <agent>            Stop an agent
  restart <agent>         Restart an agent
  logs <agent> [-f]       Show logs for an agent (-f to follow)
  shell <agent>           Open a bash shell in the agent container
  status                  Show container status for all agents
  create <agent>          Create a new agent configuration
  remove <agent>          Remove an agent (WARNING: deletes all data!)
  help                    Show this help message

Built-in Agents:
  handy                   DevOps specialist (port 3000)
  gordon                  Code review specialist (port 3001)
  zoe                     Creative writing specialist (port 3002)

Examples:
  ./scripts/agent.sh list                    # Show all agents
  ./scripts/agent.sh start handy             # Start the handy agent
  ./scripts/agent.sh logs handy -f           # Follow handy logs
  ./scripts/agent.sh shell handy             # Open shell in handy
  ./scripts/agent.sh create mybot            # Create new agent 'mybot'

Configuration:
  Agent configs are in: .agents/<agent_name>/.env
  Shared config is in:  .agents/shared.env
  Agent directory:      .agents/<agent_name>/ (contains identity files, tools/)
  Compose file:         docker-compose.agents.yml

For more information, see: docs/multi-agent-setup.md
HELP
            ;;
        *)
            log_error "Unknown command: $command"
            log_info "Run '$0 help' for usage information"
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
