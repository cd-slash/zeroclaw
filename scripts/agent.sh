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
#   up <agent>        Resolve tools, rebuild image, and start agent
#   rebuild <agent>   Resolve tools and rebuild image only
#   resolve <agent>   Resolve tools.toml into .build-tools only
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
#   ./scripts/agent.sh up handy             # Rebuild and start handy
#   ./scripts/agent.sh rebuild handy        # Rebuild handy image only
#   ./scripts/agent.sh start gordon         # Start the gordon agent
#   ./scripts/agent.sh start zoe            # Start the zoe agent
#   ./scripts/agent.sh start dwayne         # Start the dwayne agent
#   ./scripts/agent.sh logs handy -f      # Follow handy logs
#   ./scripts/agent.sh create mybot       # Create new agent config

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
AGENTS_DIR="$PROJECT_DIR/.agents"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
RESOLVE_TOOLS_SCRIPT="$SCRIPT_DIR/resolve-agent-tools.sh"

compose_project_name() {
    local agent="$1"
    echo "zeroclaw-${agent}"
}

compose_agent() {
    local agent="$1"
    shift
    AGENT_NAME="$agent" \
    SHARED_ENV_FILE="$AGENTS_DIR/.shared.env" \
    AGENT_ENV_FILE="$AGENTS_DIR/${agent}/.env" \
    AGENT_CONFIG_DIR_SOURCE="./.agents/${agent}" \
    docker compose \
        -p "$(compose_project_name "$agent")" \
        --env-file "$AGENTS_DIR/.shared.env" \
        --env-file "$AGENTS_DIR/${agent}/.env" \
        -f "$COMPOSE_FILE" "$@"
}

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

resolve_agent_tools() {
    local agent="$1"
    if [[ -x "$RESOLVE_TOOLS_SCRIPT" ]]; then
        log_info "Resolving toolset from .agents/${agent}/tools.toml"
        "$RESOLVE_TOOLS_SCRIPT" "$agent"
    fi
}

# Resolve advertised Tailscale hostname for an agent.
# Falls back to agent directory name if TAILSCALE_HOSTNAME is unset.
get_agent_hostname() {
    local agent="$1"
    local env_file="$AGENTS_DIR/${agent}/.env"
    if [[ -f "$env_file" ]]; then
        local ts_host
        ts_host=$(awk -F'=' '/^TAILSCALE_HOSTNAME=/{print $2}' "$env_file" | tail -n 1 | tr -d '"' || true)
        if [[ -n "$ts_host" ]]; then
            echo "$ts_host"
            return
        fi
    fi
    echo "$agent"
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
    printf "%-15s %-10s %-28s\n" "AGENT" "STATUS" "ACCESS"
    printf "%-15s %-10s %-28s\n" "-----" "------" "------"
    
    for agent in "${all_agents[@]}"; do
        [[ -z "$agent" ]] && continue
        
        local status="stopped"
        local hostname
        hostname=$(get_agent_hostname "$agent")
        
        if compose_agent "$agent" ps --status running --services 2>/dev/null | grep -qx "server"; then
            status="running"
        fi
        
        local access="${hostname} (Tailscale)"
        printf "%-15s %-10s %-28s\n" "$agent" "$status" "$access"
    done
    
    echo ""
    log_info "Built-in agents: handy, gordon, zoe, dwayne"
    log_info "Custom agents: Create with './scripts/agent.sh create <name>'"
}

# Start an agent
start_agent() {
    local agent="$1"
    check_agent_config "$agent"
    
    local hostname
    hostname=$(get_agent_hostname "$agent")
    
    log_info "Starting agent: $agent"
    log_info "Access via Tailscale hostname: ${hostname}"
    
    compose_agent "$agent" up -d
    
    if [[ $? -eq 0 ]]; then
        log_success "Agent '$agent' started successfully"
        log_info "Container name: $(compose_project_name "$agent")-server-1"
        log_info "View logs: ./scripts/agent.sh logs $agent -f"
    else
        log_error "Failed to start agent '$agent'"
        exit 1
    fi
}

up_agent() {
    local agent="$1"
    check_agent_config "$agent"
    local hostname
    hostname=$(get_agent_hostname "$agent")

    log_info "Rebuilding and starting agent: $agent"
    log_info "Access via Tailscale hostname: ${hostname}"

    resolve_agent_tools "$agent"
    compose_agent "$agent" up -d --build

    if [[ $? -eq 0 ]]; then
        log_success "Agent '$agent' rebuilt and started successfully"
    else
        log_error "Failed to rebuild/start agent '$agent'"
        exit 1
    fi
}

rebuild_agent() {
    local agent="$1"
    check_agent_config "$agent"

    log_info "Rebuilding agent image: $agent"
    resolve_agent_tools "$agent"
    compose_agent "$agent" build server

    if [[ $? -eq 0 ]]; then
        log_success "Agent '$agent' image rebuilt successfully"
    else
        log_error "Failed to rebuild agent '$agent'"
        exit 1
    fi
}

# Stop an agent
stop_agent() {
    local agent="$1"
    
    log_info "Stopping agent: $agent"
    # Use profile to stop the specific agent
    compose_agent "$agent" down
    
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
    compose_agent "$agent" logs "$@" server
}

# Open shell in agent container
open_shell() {
    local agent="$1"
    compose_agent "$agent" exec server bash
}

# Show status of all agents
show_status() {
    log_info "Agent container status:"
    echo ""
    if [[ ! -d "$AGENTS_DIR" ]]; then
        log_warn "Agents directory not found: $AGENTS_DIR"
        return
    fi

    for agent_dir in "$AGENTS_DIR"/*/; do
        if [[ -f "${agent_dir}/.env" ]]; then
            local agent_name
            agent_name=$(basename "$agent_dir")
            if [[ "$agent_name" != "shared" && "$agent_name" != "templates" ]]; then
                echo "[$(compose_project_name "$agent_name")]"
                compose_agent "$agent_name" ps || true
                echo ""
            fi
        fi
    done
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
    
    # Create agent directory
    mkdir -p "$agent_dir"
    
    # Create agent config
    cat > "$env_file" << EOF
AGENT_NAME=${agent}
AGENT_ROLE=general

# Override .shared.env defaults only when needed.
ZEROCLAW_MODEL=anthropic/claude-sonnet-4-20250514
ZEROCLAW_TEMPERATURE=0.7

# Optional: override Tailscale device hostname.
# TAILSCALE_HOSTNAME=${agent}
EOF
    
    # Create agent subdirectories
    mkdir -p "$agent_dir/skills"
    mkdir -p "$agent_dir/tools"
    mkdir -p "$agent_dir/.build-tools"
    touch "$agent_dir/.build-tools/.gitkeep"

    cat > "${agent_dir}/tools.toml" << EOF
# Tool declarations for ${agent} image builds.
# Each [[tool]] entry is copied into /usr/local/bin/agent-tools at build time.
# Supported sources:
#   - source = "path" with local file path (absolute or project-relative)
#   - source = "url" with remote binary URL

# [[tool]]
# name = "example-cli"
# source = "path"
# path = ".agents/${agent}/tools/example-cli"
# binary = "example-cli"
# description = "Example CLI description"
# sha256 = ""

# [apt]
# packages = ["jq", "ripgrep"]

# [bun]
# packages = ["typescript", "tsx"]

# [[tool]]
# name = "remote-example"
# source = "url"
# url = "https://example.com/releases/example-cli-linux-amd64"
# binary = "example-cli"
# description = "Remote example binary"
# sha256 = ""
EOF
    
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
    log_info "  - Tool manifest: $agent_dir/tools.toml"
    log_info "  - Local tool sources: $agent_dir/tools/"
    log_info ""
    log_info "To start this agent:"
    log_info "  ./scripts/agent.sh start ${agent}"
    log_info ""
    log_info "Or with docker compose directly:"
    log_info "  AGENT_NAME=${agent} docker compose -p zeroclaw-${agent} -f docker-compose.yml up -d"
    log_info ""
    log_info "For custom container images per agent:"
    log_info "  1. Create $agent_dir/Dockerfile with your tools"
    log_info "  2. The generic docker-compose.yml already uses AGENT_NAME for image build"
    log_info "     build:"
    log_info "       context: ."
    log_info "       dockerfile: .agents/${agent}/Dockerfile"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Review and customize identity files in $agent_dir/"
    log_info "  2. Add tool entries to $agent_dir/tools.toml (optional)"
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
    log_warn "  - $(compose_project_name "$agent")_data"
    log_warn "  - $(compose_project_name "$agent")_tailscale"
    echo ""
    read -p "Are you sure? Type 'yes' to confirm: " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        log_info "Cancelled"
        exit 0
    fi
    
    # Stop if running
    compose_agent "$agent" down --volumes 2>/dev/null || true
    
    # Remove agent directory (contains .env and all identity files)
    if [[ -d "$agent_dir" ]]; then
        log_warn "Removing agent directory: $agent_dir"
        rm -rf "$agent_dir"
    fi
    
    log_success "Agent '$agent' removed"
    log_info "Note: Agent service is generic in $COMPOSE_FILE (no per-agent entry needed)"
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
        up)
            if [[ -z "${2:-}" ]]; then
                log_error "Usage: $0 up <agent_name>"
                exit 1
            fi
            up_agent "$2"
            ;;
        rebuild)
            if [[ -z "${2:-}" ]]; then
                log_error "Usage: $0 rebuild <agent_name>"
                exit 1
            fi
            rebuild_agent "$2"
            ;;
        resolve)
            if [[ -z "${2:-}" ]]; then
                log_error "Usage: $0 resolve <agent_name>"
                exit 1
            fi
            check_agent_config "$2"
            resolve_agent_tools "$2"
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
  up <agent>              Resolve tools, rebuild image, and start
  rebuild <agent>         Resolve tools and rebuild image only
  resolve <agent>         Resolve tools.toml into .build-tools only
  stop <agent>            Stop an agent
  restart <agent>         Restart an agent
  logs <agent> [-f]       Show logs for an agent (-f to follow)
  shell <agent>           Open a bash shell in the agent container
  status                  Show container status for all agents
  create <agent>          Create a new agent configuration
  remove <agent>          Remove an agent (WARNING: deletes all data!)
  help                    Show this help message

Built-in Agents:
  handy                   DevOps specialist (Tailscale access)
  gordon                  Code review specialist (Tailscale access)
  zoe                     Creative writing specialist (Tailscale access)
  dwayne                  CCTV security specialist (Tailscale access)

Examples:
  ./scripts/agent.sh list                    # Show all agents
  ./scripts/agent.sh start handy             # Start the handy agent
  ./scripts/agent.sh up handy                # Rebuild and start handy
  ./scripts/agent.sh rebuild handy           # Rebuild handy image
  ./scripts/agent.sh logs handy -f           # Follow handy logs
  ./scripts/agent.sh shell handy             # Open shell in handy
  ./scripts/agent.sh create mybot            # Create new agent 'mybot'

Configuration:
  Agent configs are in: .agents/<agent_name>/.env
  Shared config is in:  .agents/.shared.env
  Agent directory:      .agents/<agent_name>/ (contains identity files, tools.toml)
  Compose file:         docker-compose.yml

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
