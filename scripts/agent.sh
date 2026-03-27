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
#   rebuild-all       Resolve tools, rebuild image, and start all agents
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
#   ./scripts/agent.sh start giles            # Start the giles agent
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
SHARED_GWS_DIR="$AGENTS_DIR/.shared.gws"
SHARED_GWS_CONFIG_FILE="$SHARED_GWS_DIR/base.env"
SHARED_GWS_CLIENT_SECRET_FILE="$SHARED_GWS_DIR/client_secret.json"
GWS_EXPORTED_CREDENTIALS_PATH="/zeroclaw-data/.config/gws/credentials.json"
GWS_CLIENT_SECRET_PATH="/zeroclaw-data/.config/gws/client_secret.json"
GWS_TUNNEL_PORT_FILE="/tmp/gws-callback-port"
GWS_HOST_TEMP_DIR_BASE="${XDG_RUNTIME_DIR:-/tmp}/zeroclaw-gws-auth"

compose_project_name() {
    local agent="$1"
    echo "zeroclaw-${agent}"
}

agent_container_name() {
    local agent="$1"
    echo "zeroclaw-${agent}"
}

compose_agent() {
    local agent="$1"
    shift
    AGENT_NAME="$agent" \
    CONTAINER_NAME="zeroclaw-${agent}" \
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

get_all_agents() {
    if [[ ! -d "$AGENTS_DIR" ]]; then
        return 0
    fi

    local agent_dir
    for agent_dir in "$AGENTS_DIR"/*/; do
        if [[ -f "${agent_dir}/.env" ]]; then
            local agent_name
            agent_name=$(basename "$agent_dir")
            if [[ "$agent_name" != "shared" && "$agent_name" != "templates" ]]; then
                echo "$agent_name"
            fi
        fi
    done
}

is_agent_running() {
    local agent="$1"
    docker ps --format '{{.Names}}' | grep -qx "$(agent_container_name "$agent")"
}

agent_container_exists() {
    local agent="$1"
    docker ps -a --format '{{.Names}}' | grep -qx "$(agent_container_name "$agent")"
}

agent_is_local() {
    local agent="$1"
    agent_container_exists "$agent"
}

ensure_agent_reachable() {
    local agent="$1"
    check_agent_config "$agent"

    if agent_is_local "$agent"; then
        if ! is_agent_running "$agent"; then
            log_info "Agent '$agent' is not running locally; starting it first"
            start_agent "$agent"
        fi
        return 0
    fi

    local host
    host=$(get_agent_hostname "$agent")
    if ! tailscale ping -c 1 "$host" >/dev/null 2>&1; then
        log_error "Agent '$agent' is not running locally and Tailscale host '$host' is unreachable"
        exit 1
    fi
}

ensure_agent_running() {
    local agent="$1"
    ensure_agent_reachable "$agent"
}

require_tty() {
    local command_name="$1"
    if [[ ! -t 0 || ! -t 1 ]]; then
        log_error "$command_name requires an interactive terminal"
        log_info "Run this command directly in your shell"
        exit 1
    fi
}

resolve_agent_or_prompt() {
    local provided_agent="${1:-}"
    local prompt_text="$2"

    if [[ -n "$provided_agent" ]]; then
        printf '%s\n' "$provided_agent"
        return 0
    fi

    require_tty "$prompt_text"
    prompt_for_agent "$prompt_text"
}

run_gws_in_agent() {
    local agent="$1"
    local interactive="$2"
    shift 2

    local quoted_args=""
    if [[ $# -gt 0 ]]; then
        printf -v quoted_args '%q ' "$@"
    fi

    local docker_args=()
    if [[ "$interactive" == "true" ]]; then
        docker_args=(-it)
    fi

    docker exec "${docker_args[@]}" "$(agent_container_name "$agent")" sh -lc \
        "export HOME=/zeroclaw-data GOOGLE_WORKSPACE_CLI_CONFIG_DIR=/zeroclaw-data/.config/gws; \
         mkdir -p /zeroclaw-data/.config/gws; \
         ${quoted_args}"
}

run_gws_shell_in_agent() {
    local agent="$1"
    local interactive="$2"
    shift 2

    ensure_agent_reachable "$agent"

    local quoted_args=""
    if [[ $# -gt 0 ]]; then
        printf -v quoted_args '%q ' "$@"
    fi

    local prefix="export HOME=/zeroclaw-data GOOGLE_WORKSPACE_CLI_CONFIG_DIR=/zeroclaw-data/.config/gws; mkdir -p /zeroclaw-data/.config/gws;"

    if agent_is_local "$agent"; then
        local docker_args=()
        if [[ "$interactive" == "true" ]]; then
            docker_args=(-it)
        fi
        docker exec "${docker_args[@]}" "$(agent_container_name "$agent")" sh -lc "$prefix ${quoted_args}"
    else
        if [[ "$interactive" == "true" ]]; then
            tailscale ssh "zeroclaw@$(get_agent_hostname "$agent")" "sh -lc $(printf '%q' "$prefix ${quoted_args}")"
        else
            tailscale ssh "zeroclaw@$(get_agent_hostname "$agent")" "sh -lc $(printf '%q' "$prefix ${quoted_args}")"
        fi
    fi
}

stream_file_to_agent() {
    local agent="$1"
    local source_file="$2"
    local remote_path="$3"

    ensure_agent_reachable "$agent"

    if agent_is_local "$agent"; then
        docker exec -i "$(agent_container_name "$agent")" sh -lc \
            "mkdir -p \"$(dirname "$remote_path")\" && cat > '$remote_path' && chmod 600 '$remote_path'" \
            < "$source_file"
    else
        tailscale ssh "zeroclaw@$(get_agent_hostname "$agent")" \
            "sh -lc $(printf '%q' "mkdir -p \"$(dirname "$remote_path")\" && cat > '$remote_path' && chmod 600 '$remote_path'")" \
            < "$source_file"
    fi
}

copy_file_from_agent() {
    local agent="$1"
    local remote_path="$2"
    local target_file="$3"

    ensure_agent_reachable "$agent"

    if agent_is_local "$agent"; then
        docker exec "$(agent_container_name "$agent")" sh -lc "cat '$remote_path'" > "$target_file"
    else
        tailscale ssh "zeroclaw@$(get_agent_hostname "$agent")" \
            "sh -lc $(printf '%q' "cat '$remote_path'")" > "$target_file"
    fi
}

gws_agent_config_file() {
    local agent="$1"
    echo "$AGENTS_DIR/${agent}/gws.env"
}

load_gws_auth_config() {
    local agent="$1"
    GWS_SCOPE_PRESET=""
    GWS_PROJECT_ID_PRESET=""

    local config_file
    config_file=$(gws_agent_config_file "$agent")
    if [[ -f "$config_file" ]]; then
        # shellcheck disable=SC1090
        source "$config_file"
    fi
}

save_gws_auth_config() {
    local agent="$1"
    local scope_preset="$2"
    local project_id_preset="$3"
    local config_file
    config_file=$(gws_agent_config_file "$agent")

    cat > "$config_file" <<EOF
GWS_SCOPE_PRESET=${scope_preset}
GWS_PROJECT_ID_PRESET=${project_id_preset}
EOF
}

gws_auth_has_scope_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            -s|--services|--scope|--scopes|--scope-preset|--full|--readonly)
                return 0
                ;;
            -s=*|--services=*|--scope=*|--scopes=*|--scope-preset=*|--full=*|--readonly=*)
                return 0
                ;;
        esac
    done
    return 1
}

build_gws_login_command() {
    local agent="$1"
    shift
    load_gws_auth_config "$agent"

    local cmd=(gws auth login)
    if [[ -n "$GWS_SCOPE_PRESET" ]] && ! gws_auth_has_scope_args "$@"; then
        cmd+=(-s "$GWS_SCOPE_PRESET")
    fi
    cmd+=("$@")

    printf '%q ' "${cmd[@]}"
}

run_gws_configured_in_agent() {
    local agent="$1"
    local interactive="$2"
    shift 2

    load_gws_auth_config "$agent"
    local prefix="export HOME=/zeroclaw-data GOOGLE_WORKSPACE_CLI_CONFIG_DIR=/zeroclaw-data/.config/gws; mkdir -p /zeroclaw-data/.config/gws;"
    if [[ -n "$GWS_PROJECT_ID_PRESET" ]]; then
        prefix+=" export GOOGLE_WORKSPACE_PROJECT_ID=$(printf '%q' "$GWS_PROJECT_ID_PRESET");"
    fi

    local quoted_args=""
    if [[ $# -gt 0 ]]; then
        printf -v quoted_args '%q ' "$@"
    fi

    local docker_args=()
    if [[ "$interactive" == "true" ]]; then
        docker_args=(-it)
    fi

    docker exec "${docker_args[@]}" "$(agent_container_name "$agent")" sh -lc "$prefix ${quoted_args}"
}

start_tailscale_ssh_tunnel() {
    local agent="$1"
    local local_port="$2"
    local remote_port="$3"
    local pid_file
    pid_file=$(mktemp)

    tailscale ssh -N -L "${local_port}:127.0.0.1:${remote_port}" "zeroclaw@$(get_agent_hostname "$agent")" >/dev/null 2>&1 &
    local tunnel_pid=$!
    echo "$tunnel_pid" > "$pid_file"

    local i
    for i in $(seq 1 20); do
        if ss -ltn 2>/dev/null | grep -q ":${local_port} "; then
            rm -f "$pid_file"
            printf '%s\n' "$tunnel_pid"
            return 0
        fi
        if ! kill -0 "$tunnel_pid" 2>/dev/null; then
            break
        fi
        sleep 0.25
    done

    kill "$tunnel_pid" 2>/dev/null || true
    rm -f "$pid_file"
    return 1
}

find_free_local_port() {
    python3 - <<'PY'
import socket
s=socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
PY
}

gws_auth_login_via_tunnel() {
    local agent="$1"
    shift
    require_tty "gws-login"
    ensure_agent_running "$agent"
    ensure_gws_client_configured "$agent"

    local remote_port local_port tunnel_pid login_cmd

    login_cmd=$(build_gws_login_command "$agent" "$@")

    log_info "Starting tunneled Google Workspace login for '$agent'"
    log_info "A localhost callback on your machine will be forwarded into the container"

    run_gws_configured_in_agent "$agent" false sh -lc "rm -f '$GWS_TUNNEL_PORT_FILE'; nohup sh -lc '$login_cmd' >/tmp/gws-auth-login.log 2>&1 & echo \$! >/tmp/gws-auth-login.pid" >/dev/null

    local i
    for i in $(seq 1 80); do
        remote_port=$(docker exec "$(agent_container_name "$agent")" sh -lc "test -f '$GWS_TUNNEL_PORT_FILE' && cat '$GWS_TUNNEL_PORT_FILE'" 2>/dev/null || true)
        if [[ "$remote_port" =~ ^[0-9]+$ ]]; then
            break
        fi
        sleep 0.25
    done

    if [[ ! "$remote_port" =~ ^[0-9]+$ ]]; then
        log_error "Failed to detect container callback port for '$agent'"
        log_info "Check log: docker exec $(agent_container_name "$agent") sh -lc 'cat /tmp/gws-auth-login.log'"
        return 1
    fi

    local_port=$(find_free_local_port)
    tunnel_pid=$(start_tailscale_ssh_tunnel "$agent" "$local_port" "$remote_port") || {
        log_error "Failed to start localhost callback tunnel"
        return 1
    }

    trap 'kill "$tunnel_pid" 2>/dev/null || true' EXIT INT TERM

    log_info "Callback tunnel ready: http://localhost:${local_port} -> ${agent}:${remote_port}"
    log_info "Open the Google auth URL from the container log if it does not open automatically"
    log_info "Watch login progress with: docker exec $(agent_container_name "$agent") sh -lc "tail -f /tmp/gws-auth-login.log""

    local login_pid
    login_pid=$(docker exec "$(agent_container_name "$agent")" sh -lc "cat /tmp/gws-auth-login.pid" 2>/dev/null || true)
    while [[ -n "$login_pid" ]] && docker exec "$(agent_container_name "$agent")" sh -lc "kill -0 '$login_pid'" >/dev/null 2>&1; do
        sleep 1
    done

    kill "$tunnel_pid" 2>/dev/null || true
    trap - EXIT INT TERM

    local status_output
    status_output=$(docker exec "$(agent_container_name "$agent")" sh -lc "cat /tmp/gws-auth-login.log" 2>/dev/null || true)
    if printf '%s' "$status_output" | grep -qi 'error\|failed'; then
        printf '%s\n' "$status_output"
        return 1
    fi

    run_gws_configured_in_agent "$agent" false sh -lc 'gws auth export --unmasked > /zeroclaw-data/.config/gws/credentials.json && chmod 600 /zeroclaw-data/.config/gws/credentials.json'
    log_success "Google Workspace auth exported for '$agent'"
}

gws_client_is_configured() {
    local agent="$1"
    ensure_agent_running "$agent"
    run_gws_configured_in_agent "$agent" false sh -lc "test -f '$GWS_CLIENT_SECRET_PATH' || { test -n \"\$GOOGLE_WORKSPACE_CLI_CLIENT_ID\" && test -n \"\$GOOGLE_WORKSPACE_CLI_CLIENT_SECRET\"; }" >/dev/null 2>&1
}

gws_client_file_present() {
    local agent="$1"
    ensure_agent_running "$agent"
    run_gws_configured_in_agent "$agent" false test -f "$GWS_CLIENT_SECRET_PATH" >/dev/null 2>&1
}

gws_client_install() {
    local agent="$1"
    local source_file="$2"
    check_agent_config "$agent"

    if [[ ! -f "$source_file" ]]; then
        log_error "Client secret file not found: $source_file"
        exit 1
    fi

    stream_file_to_agent "$agent" "$source_file" "$GWS_CLIENT_SECRET_PATH"
    log_success "Installed Google Workspace client secret for '$agent'"
}

gws_creds_install() {
    local agent="$1"
    local source_file="$2"
    check_agent_config "$agent"

    if [[ ! -f "$source_file" ]]; then
        log_error "Credentials file not found: $source_file"
        exit 1
    fi

    stream_file_to_agent "$agent" "$source_file" "$GWS_EXPORTED_CREDENTIALS_PATH"
    log_success "Installed Google Workspace credentials for '$agent'"
}

secure_delete_file() {
    local path="$1"
    [[ -e "$path" ]] || return 0

    if command -v shred >/dev/null 2>&1; then
        shred -u "$path" 2>/dev/null || rm -f "$path"
    else
        rm -f "$path"
    fi
}

gws_host_login_temp() {
    local agent="$1"
    shift
    require_tty "gws-host-login"
    ensure_agent_running "$agent"
    ensure_gws_client_configured "$agent"

    if ! command -v gws >/dev/null 2>&1; then
        log_error "Host gws CLI not found"
        log_info "Install it on your machine first so the browser callback lands on your host"
        exit 1
    fi

    local temp_dir export_file client_secret_file login_cmd
    temp_dir="${GWS_HOST_TEMP_DIR_BASE}-${agent}-$$"
    export_file="$temp_dir/credentials.json"
    client_secret_file="$temp_dir/client_secret.json"
    mkdir -p "$temp_dir"
    chmod 700 "$temp_dir"

    local cleanup_cmd="secure_delete_file '$export_file'; secure_delete_file '$client_secret_file'; rm -rf '$temp_dir'"
    trap "$cleanup_cmd" EXIT INT TERM

    copy_file_from_agent "$agent" "$GWS_CLIENT_SECRET_PATH" "$client_secret_file"
    chmod 600 "$client_secret_file"

    load_gws_auth_config "$agent"
    local cmd=(gws auth login)
    if [[ -n "$GWS_SCOPE_PRESET" ]] && ! gws_auth_has_scope_args "$@"; then
        cmd+=(-s "$GWS_SCOPE_PRESET")
    fi
    cmd+=("$@")

    log_info "Running host-side Google Workspace login for '$agent' in an isolated temp config"
    log_info "Your normal host gws auth will not be touched"

    GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$temp_dir" "${cmd[@]}"
    GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$temp_dir" gws auth export --unmasked > "$export_file"
    chmod 600 "$export_file"

    gws_creds_install "$agent" "$export_file"

    secure_delete_file "$export_file"
    secure_delete_file "$client_secret_file"
    rm -rf "$temp_dir"
    trap - EXIT INT TERM

    log_success "Host login imported into '$agent' and removed from host temp storage"
}

gws_client_base_install() {
    local source_file="$1"

    if [[ ! -f "$source_file" ]]; then
        log_error "Client secret file not found: $source_file"
        exit 1
    fi

    mkdir -p "$SHARED_GWS_DIR"
    cp "$source_file" "$SHARED_GWS_CLIENT_SECRET_FILE"
    chmod 600 "$SHARED_GWS_CLIENT_SECRET_FILE"
    log_success "Saved shared base Google Workspace client secret"
    log_info "Base file: $SHARED_GWS_CLIENT_SECRET_FILE"
}

gws_client_base_save() {
    local source_agent="$1"
    check_agent_config "$source_agent"

    if ! gws_client_file_present "$source_agent"; then
        log_error "Source agent '$source_agent' has no client_secret.json in its container"
        log_info "Install one with './scripts/agent.sh gws-client-install $source_agent /path/to/client_secret.json'"
        exit 1
    fi

    mkdir -p "$SHARED_GWS_DIR"
    docker exec "$(agent_container_name "$source_agent")" sh -lc \
        "cat '$GWS_CLIENT_SECRET_PATH'" > "$SHARED_GWS_CLIENT_SECRET_FILE"
    chmod 600 "$SHARED_GWS_CLIENT_SECRET_FILE"
    log_success "Saved shared base Google Workspace client secret from '$source_agent'"
    log_info "Base file: $SHARED_GWS_CLIENT_SECRET_FILE"
}

gws_client_base_apply() {
    local targets=("$@")

    if [[ ! -f "$SHARED_GWS_CLIENT_SECRET_FILE" ]]; then
        log_error "No shared base client secret found at $SHARED_GWS_CLIENT_SECRET_FILE"
        log_info "Create one with './scripts/agent.sh gws-client-base-install /path/to/client_secret.json'"
        exit 1
    fi

    if [[ ${#targets[@]} -eq 0 || "${targets[0]}" == "--all" ]]; then
        mapfile -t targets < <(get_all_agents)
    fi

    local target_agent
    for target_agent in "${targets[@]}"; do
        [[ -z "$target_agent" ]] && continue
        gws_client_install "$target_agent" "$SHARED_GWS_CLIENT_SECRET_FILE"
    done
}

gws_client_show() {
    local selected_agent="${1:-}"
    local agents=()

    if [[ -n "$selected_agent" ]]; then
        check_agent_config "$selected_agent"
        agents=("$selected_agent")
    else
        mapfile -t agents < <(get_all_agents)
    fi

    printf "%-15s %-12s\n" "AGENT" "CLIENT"
    printf "%-15s %-12s\n" "-----" "------"

    local agent status
    for agent in "${agents[@]}"; do
        [[ -z "$agent" ]] && continue
        status="stopped"
        if is_agent_running "$agent"; then
            if gws_client_is_configured "$agent"; then
                status="configured"
            else
                status="missing"
            fi
        fi
        printf "%-15s %-12s\n" "$agent" "$status"
    done
}

ensure_gws_client_configured() {
    local agent="$1"

    if gws_client_is_configured "$agent"; then
        return 0
    fi

    log_error "Google Workspace OAuth client is not configured for '$agent'"
    log_info "Options:"
    log_info "  1. Install a desktop OAuth client JSON: ./scripts/agent.sh gws-client-install $agent /path/to/client_secret.json"
    log_info "  2. Save/apply a shared base client: ./scripts/agent.sh gws-client-base-install /path/to/client_secret.json"
    log_info "  3. Use env vars in .agents/$agent/.env: GOOGLE_WORKSPACE_CLI_CLIENT_ID and GOOGLE_WORKSPACE_CLI_CLIENT_SECRET"
    log_info "  4. Run './scripts/agent.sh gws-setup $agent' to create/configure the OAuth client with gcloud"
    exit 1
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
    mapfile -t all_agents < <(get_all_agents)

    # Display agents
    printf "%-15s %-10s %-28s\n" "AGENT" "STATUS" "ACCESS"
    printf "%-15s %-10s %-28s\n" "-----" "------" "------"

    for agent in "${all_agents[@]}"; do
        [[ -z "$agent" ]] && continue

        local status="stopped"
        local hostname
        hostname=$(get_agent_hostname "$agent")

        if is_agent_running "$agent"; then
            status="running"
        fi

        local access="${hostname} (Tailscale)"
        printf "%-15s %-10s %-28s\n" "$agent" "$status" "$access"
    done

    echo ""
    log_info "Built-in agents: handy, gordon, giles, dwayne"
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
        log_info "Container name: zeroclaw-${agent}"
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
    compose_agent "$agent" build zeroclaw

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
    compose_agent "$agent" logs "$@" zeroclaw
}

# Open shell in agent container
open_shell() {
    local agent="$1"
    compose_agent "$agent" exec zeroclaw bash
}

show_auth_status() {
    local selected_agent="${1:-}"
    local agents=()

    if [[ -n "$selected_agent" ]]; then
        check_agent_config "$selected_agent"
        agents=("$selected_agent")
    else
        mapfile -t agents < <(get_all_agents)
    fi

    printf "%-15s %-10s %-12s %-12s %-14s\n" "AGENT" "RUNTIME" "CLIENT" "CREDS" "CALENDAR"
    printf "%-15s %-10s %-12s %-12s %-14s\n" "-----" "-------" "------" "-----" "--------"

    local agent
    for agent in "${agents[@]}"; do
        [[ -z "$agent" ]] && continue
        local runtime="stopped"
        local client="unknown"
        local creds="unknown"
        local calendar="n/a"

        if is_agent_running "$agent"; then
            runtime="running"

            if gws_client_is_configured "$agent"; then
                client="configured"
            else
                client="missing"
            fi

            if run_gws_configured_in_agent "$agent" false test -f /zeroclaw-data/.config/gws/credentials.json >/dev/null 2>&1; then
                creds="exported"
            else
                creds="missing"
            fi

            local calendar_output calendar_cmd_status
            set +e
            calendar_output=$(run_gws_configured_in_agent "$agent" false gws calendar +agenda 2>&1)
            calendar_cmd_status=$?
            set -e

            if [[ $calendar_cmd_status -eq 0 ]]; then
                calendar="ok"
            elif printf '%s' "$calendar_output" | grep -qi 'No OAuth client configured'; then
                calendar="client-missing"
            elif printf '%s' "$calendar_output" | grep -qi 'auth'; then
                calendar="auth-missing"
            elif printf '%s' "$calendar_output" | grep -qi '403\|insufficient\|permission\|scope'; then
                calendar="scope-mismatch"
            else
                calendar="error"
            fi
        fi

        printf "%-15s %-10s %-12s %-12s %-14s\n" "$agent" "$runtime" "$client" "$creds" "$calendar"
    done
}

gws_auth_setup() {
    local agent="$1"
    shift
    require_tty "gws-setup"
    ensure_agent_running "$agent"

    log_info "Running interactive Google Workspace setup for '$agent'"
    log_info "This uses the container's gws + gcloud setup flow"

    if ! run_gws_configured_in_agent "$agent" false command -v gcloud >/dev/null 2>&1; then
        log_error "gcloud is not available in '$agent'"
        log_info "Rebuild the agent image first: ./scripts/agent.sh up $agent"
        exit 1
    fi

    run_gws_configured_in_agent "$agent" true gws auth setup "$@"

    log_info "Exporting credentials to /zeroclaw-data/.config/gws/credentials.json"
    run_gws_configured_in_agent "$agent" false sh -lc 'gws auth export --unmasked > /zeroclaw-data/.config/gws/credentials.json && chmod 600 /zeroclaw-data/.config/gws/credentials.json'
}

gws_auth_login() {
    local agent="$1"
    shift
    require_tty "gws-login"
    ensure_agent_running "$agent"
    ensure_gws_client_configured "$agent"

    gws_host_login_temp "$agent" "$@"
}

gws_rebuild_all() {
    local agent
    while IFS= read -r agent; do
        [[ -z "$agent" ]] && continue
        up_agent "$agent"
    done < <(get_all_agents)
}

gws_auth_test() {
    local agent="$1"
    ensure_agent_running "$agent"
    run_gws_configured_in_agent "$agent" false gws calendar +agenda
}

gws_auth_export() {
    local agent="$1"
    ensure_agent_running "$agent"
    run_gws_configured_in_agent "$agent" false sh -lc 'if [ -f /zeroclaw-data/.config/gws/credentials.json ]; then cat /zeroclaw-data/.config/gws/credentials.json; else gws auth export --unmasked; fi'
}

gws_auth_clear() {
    local agent="$1"
    ensure_agent_running "$agent"
    run_gws_configured_in_agent "$agent" false sh -lc "rm -f '$GWS_EXPORTED_CREDENTIALS_PATH'"
    log_success "Removed exported Google Workspace credentials for '$agent'"
}

gws_config_show() {
    local selected_agent="${1:-}"
    local agents=()

    if [[ -n "$selected_agent" ]]; then
        check_agent_config "$selected_agent"
        agents=("$selected_agent")
    else
        mapfile -t agents < <(get_all_agents)
    fi

    printf "%-15s %-24s %-18s\n" "AGENT" "SCOPES" "PROJECT_ID"
    printf "%-15s %-24s %-18s\n" "-----" "------" "----------"

    local agent
    for agent in "${agents[@]}"; do
        [[ -z "$agent" ]] && continue
        load_gws_auth_config "$agent"
        printf "%-15s %-24s %-18s\n" "$agent" "${GWS_SCOPE_PRESET:--}" "${GWS_PROJECT_ID_PRESET:--}"
    done
}

gws_config_set() {
    local agent="$1"
    shift
    check_agent_config "$agent"
    load_gws_auth_config "$agent"

    local scopes="$GWS_SCOPE_PRESET"
    local project_id="$GWS_PROJECT_ID_PRESET"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --scopes)
                scopes="${2:-}"
                shift 2
                ;;
            --project-id)
                project_id="${2:-}"
                shift 2
                ;;
            --clear-scopes)
                scopes=""
                shift
                ;;
            --clear-project-id)
                project_id=""
                shift
                ;;
            *)
                log_error "Unknown gws-config-set option: $1"
                exit 1
                ;;
        esac
    done

    save_gws_auth_config "$agent" "$scopes" "$project_id"
    log_success "Updated Google Workspace auth config for '$agent'"
}

gws_config_copy() {
    local source_agent="$1"
    shift
    check_agent_config "$source_agent"

    local source_file
    source_file=$(gws_agent_config_file "$source_agent")
    if [[ ! -f "$source_file" ]]; then
        log_error "Source agent '$source_agent' has no gws config preset"
        log_info "Create one with './scripts/agent.sh gws-config-set $source_agent --scopes calendar'"
        exit 1
    fi

    local target_agent target_file
    for target_agent in "$@"; do
        check_agent_config "$target_agent"
        target_file=$(gws_agent_config_file "$target_agent")
        cp "$source_file" "$target_file"
        log_success "Copied Google Workspace auth config from '$source_agent' to '$target_agent'"
    done
}

gws_config_base_save() {
    local source_agent="$1"
    check_agent_config "$source_agent"
    local source_file
    source_file=$(gws_agent_config_file "$source_agent")

    if [[ ! -f "$source_file" ]]; then
        log_error "Source agent '$source_agent' has no gws config preset"
        log_info "Create one with './scripts/agent.sh gws-config-set $source_agent --scopes calendar'"
        exit 1
    fi

    mkdir -p "$SHARED_GWS_DIR"
    cp "$source_file" "$SHARED_GWS_CONFIG_FILE"
    log_success "Saved shared base Google Workspace auth config from '$source_agent'"
    log_info "Base file: $SHARED_GWS_CONFIG_FILE"
}

gws_config_base_apply() {
    local targets=("$@")

    if [[ ! -f "$SHARED_GWS_CONFIG_FILE" ]]; then
        log_error "No shared base config found at $SHARED_GWS_CONFIG_FILE"
        log_info "Create one with './scripts/agent.sh gws-config-base-save <source_agent>'"
        exit 1
    fi

    if [[ ${#targets[@]} -eq 0 || "${targets[0]}" == "--all" ]]; then
        mapfile -t targets < <(get_all_agents)
    fi

    local target_agent target_file
    for target_agent in "${targets[@]}"; do
        [[ -z "$target_agent" ]] && continue
        check_agent_config "$target_agent"
        target_file=$(gws_agent_config_file "$target_agent")
        cp "$SHARED_GWS_CONFIG_FILE" "$target_file"
        log_success "Applied shared base Google Workspace auth config to '$target_agent'"
    done
}

prompt_for_agent() {
    local prompt_text="$1"
    local agents=()
    mapfile -t agents < <(get_all_agents)

    if [[ ${#agents[@]} -eq 0 ]]; then
        log_error "No agents found"
        exit 1
    fi

    echo "$prompt_text"
    select agent in "${agents[@]}" "Quit"; do
        case "$agent" in
            "")
                echo "Invalid selection"
                ;;
            Quit)
                return 1
                ;;
            *)
                printf '%s\n' "$agent"
                return 0
                ;;
        esac
    done
}

auth_menu() {
    require_tty "gws-menu"

    while true; do
        echo ""
        echo "Google Workspace Menu"
        select action in "Show status" "Show client status" "Show config" "Login" "Setup" "Test calendar" "Set config" "Copy config" "Install client secret" "Save shared base client" "Apply shared base client" "Save shared base config" "Apply shared base config" "Export credentials" "Clear credentials" "Open agent shell" "Quit"; do
            case "$action" in
                "Show status")
                    show_auth_status
                    break
                    ;;
                "Show client status")
                    gws_client_show
                    break
                    ;;
                "Show config")
                    gws_config_show
                    break
                    ;;
                Login)
                    local agent
                    agent=$(prompt_for_agent "Select an agent to authenticate:") || return 0
                    gws_auth_login "$agent"
                    break
                    ;;
                Setup)
                    local agent
                    agent=$(prompt_for_agent "Select an agent for gws auth setup:") || return 0
                    gws_auth_setup "$agent"
                    break
                    ;;
                "Test calendar")
                    local agent
                    agent=$(prompt_for_agent "Select an agent to test:") || return 0
                    gws_auth_test "$agent"
                    break
                    ;;
                "Set config")
                    local agent scopes
                    agent=$(prompt_for_agent "Select an agent to configure:") || return 0
                    read -r -p "Enter scope preset (example: calendar,drive), or blank to keep current: " scopes
                    if [[ -n "$scopes" ]]; then
                        gws_config_set "$agent" --scopes "$scopes"
                    else
                        gws_config_show "$agent"
                    fi
                    break
                    ;;
                "Copy config")
                    local source_agent
                    source_agent=$(prompt_for_agent "Select the source agent:") || return 0
                    local target_agent
                    target_agent=$(prompt_for_agent "Select one target agent:") || return 0
                    gws_config_copy "$source_agent" "$target_agent"
                    break
                    ;;
                "Install client secret")
                    local agent path
                    agent=$(prompt_for_agent "Select an agent to receive client_secret.json:") || return 0
                    read -r -p "Path to client_secret.json: " path
                    [[ -n "$path" ]] && gws_client_install "$agent" "$path"
                    break
                    ;;
                "Save shared base client")
                    local path
                    read -r -p "Path to client_secret.json to save as shared base: " path
                    [[ -n "$path" ]] && gws_client_base_install "$path"
                    break
                    ;;
                "Apply shared base client")
                    local agent
                    agent=$(prompt_for_agent "Select an agent to receive shared base client_secret.json:") || return 0
                    gws_client_base_apply "$agent"
                    break
                    ;;
                "Save shared base config")
                    local agent
                    agent=$(prompt_for_agent "Select the source agent for shared base config:") || return 0
                    gws_config_base_save "$agent"
                    break
                    ;;
                "Apply shared base config")
                    local agent
                    agent=$(prompt_for_agent "Select an agent to receive shared base config:") || return 0
                    gws_config_base_apply "$agent"
                    break
                    ;;
                "Export credentials")
                    local agent
                    agent=$(prompt_for_agent "Select an agent to export:") || return 0
                    gws_auth_export "$agent"
                    break
                    ;;
                "Clear credentials")
                    local agent
                    agent=$(prompt_for_agent "Select an agent to clear:") || return 0
                    gws_auth_clear "$agent"
                    break
                    ;;
                "Open agent shell")
                    local agent
                    agent=$(prompt_for_agent "Select an agent shell to open:") || return 0
                    open_shell "$agent"
                    break
                    ;;
                Quit)
                    return 0
                    ;;
                *)
                    echo "Invalid selection"
                    ;;
            esac
        done
    done
}

# Show status of all agents
show_status() {
    log_info "Agent container status:"
    echo ""
    if [[ ! -d "$AGENTS_DIR" ]]; then
        log_warn "Agents directory not found: $AGENTS_DIR"
        return
    fi

    local agent_name
    while IFS= read -r agent_name; do
        [[ -z "$agent_name" ]] && continue
        echo "[$(compose_project_name "$agent_name")]"
        compose_agent "$agent_name" ps || true
        echo ""
    done < <(get_all_agents)
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
    log_info "  AGENT_NAME=${agent} CONTAINER_NAME=zeroclaw-${agent} docker compose -p zeroclaw-${agent} -f docker-compose.yml up -d"
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
        rebuild-all)
            gws_rebuild_all
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
        gws-status)
            if [[ -n "${2:-}" ]]; then
                show_auth_status "$2"
            else
                show_auth_status
            fi
            ;;
        gws-login)
            local agent
            agent=$(resolve_agent_or_prompt "${2:-}" "Select an agent for Google Workspace login:") || exit 1
            if [[ -n "${2:-}" ]]; then
                shift 2
            else
                shift 1
            fi
            gws_auth_login "$agent" "$@"
            ;;
        gws-setup)
            local agent
            agent=$(resolve_agent_or_prompt "${2:-}" "Select an agent for Google Workspace setup:") || exit 1
            if [[ -n "${2:-}" ]]; then
                shift 2
            else
                shift 1
            fi
            gws_auth_setup "$agent" "$@"
            ;;
        gws-test)
            local agent
            agent=$(resolve_agent_or_prompt "${2:-}" "Select an agent to test Google Workspace access:") || exit 1
            gws_auth_test "$agent"
            ;;
        gws-export)
            local agent
            agent=$(resolve_agent_or_prompt "${2:-}" "Select an agent to export Google Workspace credentials:") || exit 1
            gws_auth_export "$agent"
            ;;
        gws-clear)
            local agent
            agent=$(resolve_agent_or_prompt "${2:-}" "Select an agent to clear Google Workspace credentials:") || exit 1
            gws_auth_clear "$agent"
            ;;
        gws-client-show)
            if [[ -n "${2:-}" ]]; then
                gws_client_show "$2"
            else
                gws_client_show
            fi
            ;;
        gws-client-install)
            if [[ -z "${2:-}" || -z "${3:-}" ]]; then
                log_error "Usage: $0 gws-client-install <agent_name> <path/to/client_secret.json>"
                exit 1
            fi
            gws_client_install "$2" "$3"
            ;;
        gws-creds-install)
            if [[ -z "${2:-}" || -z "${3:-}" ]]; then
                log_error "Usage: $0 gws-creds-install <agent_name> <path/to/credentials.json>"
                exit 1
            fi
            gws_creds_install "$2" "$3"
            ;;
        gws-client-base-install)
            if [[ -z "${2:-}" ]]; then
                log_error "Usage: $0 gws-client-base-install <path/to/client_secret.json>"
                exit 1
            fi
            gws_client_base_install "$2"
            ;;
        gws-client-base-save)
            if [[ -z "${2:-}" ]]; then
                log_error "Usage: $0 gws-client-base-save <source_agent>"
                exit 1
            fi
            gws_client_base_save "$2"
            ;;
        gws-client-base-apply)
            shift
            gws_client_base_apply "$@"
            ;;
        gws-config-show)
            if [[ -n "${2:-}" ]]; then
                gws_config_show "$2"
            else
                gws_config_show
            fi
            ;;
        gws-config-set)
            if [[ -z "${2:-}" ]]; then
                log_error "Usage: $0 gws-config-set <agent_name> [--scopes value] [--project-id value] [--clear-scopes] [--clear-project-id]"
                exit 1
            fi
            local agent="$2"
            shift 2
            gws_config_set "$agent" "$@"
            ;;
        gws-config-copy)
            if [[ -z "${2:-}" || -z "${3:-}" ]]; then
                log_error "Usage: $0 gws-config-copy <source_agent> <target_agent> [more_target_agents...]"
                exit 1
            fi
            local source_agent="$2"
            shift 2
            gws_config_copy "$source_agent" "$@"
            ;;
        gws-config-base-save)
            if [[ -z "${2:-}" ]]; then
                log_error "Usage: $0 gws-config-base-save <source_agent>"
                exit 1
            fi
            gws_config_base_save "$2"
            ;;
        gws-config-base-apply)
            shift
            gws_config_base_apply "$@"
            ;;
        gws-menu)
            auth_menu
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
  rebuild-all             Resolve tools, rebuild image, and start all agents
  resolve <agent>         Resolve tools.toml into .build-tools only
  stop <agent>            Stop an agent
  restart <agent>         Restart an agent
  logs <agent> [-f]       Show logs for an agent (-f to follow)
  shell <agent>           Open a bash shell in the agent container
  gws-status [agent]      Show Google Workspace auth status for one/all agents
  gws-login [agent]       Run host-side temp gws login, import creds to agent
  gws-setup [agent]       Run interactive gws auth setup, then export creds
  gws-test [agent]        Test Google Calendar access for an agent
  gws-client-show [...]   Show per-agent Google OAuth client availability
  gws-client-install ...  Install client_secret.json into one agent container
  gws-creds-install ...   Install exported credentials.json into one agent
  gws-client-base-install Save shared base client_secret.json from local file
  gws-client-base-save    Save shared base client_secret.json from one agent
  gws-client-base-apply   Apply shared base client_secret.json to agents
  gws-config-show [...]   Show stored per-agent scope/project gws presets
  gws-config-set <agent>  Set per-agent non-secret gws defaults
  gws-config-copy ...     Copy scope/project gws presets between agents
  gws-config-base-save    Save shared base scope/project gws config
  gws-config-base-apply   Apply shared base scope/project gws config
  gws-export [agent]      Print exported gws credentials for an agent
  gws-clear [agent]       Remove exported gws credentials for an agent
  gws-menu                Open an interactive Google Workspace menu
  status                  Show container status for all agents
  create <agent>          Create a new agent configuration
  remove <agent>          Remove an agent (WARNING: deletes all data!)
  help                    Show this help message

Built-in Agents:
  handy                   DevOps specialist (Tailscale access)
  gordon                  Code review specialist (Tailscale access)
  giles                     Creative writing specialist (Tailscale access)
  dwayne                  CCTV security specialist (Tailscale access)

Examples:
  ./scripts/agent.sh list                    # Show all agents
  ./scripts/agent.sh start handy             # Start the handy agent
  ./scripts/agent.sh up handy                # Rebuild and start handy
  ./scripts/agent.sh rebuild handy           # Rebuild handy image
  ./scripts/agent.sh rebuild-all             # Rebuild all agent images
  ./scripts/agent.sh logs handy -f           # Follow handy logs
  ./scripts/agent.sh shell handy             # Open shell in handy
  ./scripts/agent.sh gws-status              # Show gws auth status for all agents
  ./scripts/agent.sh gws-client-base-install ./client_secret.json
  ./scripts/agent.sh gws-client-base-apply --all
  ./scripts/agent.sh gws-login handy         # Authenticate handy with gws
  ./scripts/agent.sh gws-creds-install handy ./handy-credentials.json
  ./scripts/agent.sh gws-setup               # Prompt for agent, then run setup
  ./scripts/agent.sh gws-test handy          # Test handy calendar access
  ./scripts/agent.sh gws-config-set handy --scopes calendar
  ./scripts/agent.sh gws-config-copy handy gordon giles
  ./scripts/agent.sh gws-config-base-apply --all
  ./scripts/agent.sh gws-menu                # Open interactive Google Workspace menu
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
