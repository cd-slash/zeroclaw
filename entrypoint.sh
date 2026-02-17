#!/bin/bash
set -e

CONFIG_FILE="/zeroclaw-data/.zeroclaw/config.toml"

# Check if value is numeric (integer or float)
is_numeric() {
    [[ "$1" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]
}

# Check if value is a boolean
is_boolean() {
    [[ "$1" =~ ^(true|false)$ ]]
}

# Escape special characters for sed
escape_sed() {
    printf '%s\n' "$1" | sed -e 's/[]\/"$*.^[]/\\&/g'
}

# Convert env var name to config key
env_to_key() {
    local var="$1"
    echo "$var" | sed 's/^ZEROCLAW_//' | tr '[:upper:]' '[:lower:]'
}

# Update config key (handles numbers and booleans without quotes, strings with quotes)
update_config_key() {
    local key="$1"
    local value="$2"
    local section="${3:-}"
    
    local formatted_value
    if is_numeric "$value"; then
        formatted_value="$value"
    elif is_boolean "$value"; then
        formatted_value="$value"
    else
        local escaped_value=$(escape_sed "$value")
        formatted_value="\"$escaped_value\""
    fi
    
    if [ -n "$section" ]; then
        if grep -q "^\[$section\]" "$CONFIG_FILE"; then
            if sed -n "/^\[$section\]/,/^\[/p" "$CONFIG_FILE" | grep -q "^$key = "; then
                sed -i "/^\[$section\]/,/^\[/ s#^$key = .*#$key = $formatted_value#" "$CONFIG_FILE"
                return 0
            fi
        fi
        return 1
    else
        if grep -q "^$key = " "$CONFIG_FILE"; then
            sed -i "s#^$key = .*#$key = $formatted_value#" "$CONFIG_FILE"
            return 0
        fi
        if grep -q "^default_$key = " "$CONFIG_FILE"; then
            sed -i "s#^default_$key = .*#default_$key = $formatted_value#" "$CONFIG_FILE"
            return 0
        fi
        return 1
    fi
}

# Auto-sync ZEROCLAW_ environment variables
auto_sync_env_vars() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "[entrypoint] Warning: config.toml not found"
        return 1
    fi
    
    echo "[entrypoint] Scanning ZEROCLAW_* variables..."
    local synced_count=0
    
    for var in $(env | grep "^ZEROCLAW_" | cut -d= -f1); do
        local value="${!var}"
        [ -z "$value" ] && continue
        
        local key=$(env_to_key "$var")
        local section=""
        local config_key="$key"
        
        case "$key" in
            gateway_*)
                section="gateway"
                config_key="${key#gateway_}"
                ;;
            tunnel_*)
                section="tunnel"
                config_key="${key#tunnel_}"
                ;;
        esac
        
        if update_config_key "$config_key" "$value" "$section"; then
            if [ -n "$section" ]; then
                echo "[entrypoint]   [$section] $config_key = $value"
            else
                echo "[entrypoint]   $config_key = $value"
            fi
            synced_count=$((synced_count + 1))
        fi
    done
    
    echo "[entrypoint] Synced $synced_count variable(s)"
}

# Explicit sync for critical variables
explicit_sync() {
    echo "[entrypoint] Applying explicit config updates..."
    
    if [ -n "$PROVIDER" ]; then
        local escaped=$(escape_sed "$PROVIDER")
        sed -i "s#^default_provider = .*#default_provider = \"$escaped\"#" "$CONFIG_FILE"
        echo "[entrypoint]   provider: $PROVIDER"
    fi
    
    if [ -n "$API_KEY" ]; then
        local current=$(grep "^api_key = " "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2 || echo "")
        if [ -n "$current" ] && [[ "$current" == http* ]]; then
            echo "[entrypoint]   api_key: keeping ollama URL"
        else
            local escaped=$(escape_sed "$API_KEY")
            sed -i "s#^api_key = .*#api_key = \"$escaped\"#" "$CONFIG_FILE"
            echo "[entrypoint]   api_key: updated"
        fi
    fi
    
    local public_bind="${ZEROCLAW_ALLOW_PUBLIC_BIND:-${ALLOW_PUBLIC_BIND:-}}"
    if [ -n "$public_bind" ]; then
        # Remove any surrounding quotes from the value
        public_bind=${public_bind//\"}
        public_bind=${public_bind//\'}
        sed -i "s#^allow_public_bind = .*#allow_public_bind = $public_bind#" "$CONFIG_FILE"
        echo "[entrypoint]   allow_public_bind: $public_bind"
    fi
    
    if [ -n "$TUNNEL_PROVIDER" ]; then
        local escaped=$(escape_sed "$TUNNEL_PROVIDER")
        if ! grep -q "^\[tunnel\]" "$CONFIG_FILE"; then
            echo "" >> "$CONFIG_FILE"
            echo "[tunnel]" >> "$CONFIG_FILE"
            echo "provider = \"$escaped\"" >> "$CONFIG_FILE"
        else
            sed -i "/^\[tunnel\]/,/^\[/ s#^provider = .*#provider = \"$escaped\"#" "$CONFIG_FILE"
        fi
        echo "[entrypoint]   tunnel: $TUNNEL_PROVIDER"
    fi
}

# Main config sync
update_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "[entrypoint] Warning: config.toml not found"
        return 1
    fi
    
    echo "[entrypoint] Syncing config.toml from environment..."
    explicit_sync
    auto_sync_env_vars
    echo "[entrypoint] Config sync complete"
}

# Run config update
update_config

# Run agent-specific setup (packages, tools, etc.)
# This happens once per container start, then is cached
if [[ -f "/usr/local/bin/agent-setup.sh" ]]; then
    /usr/local/bin/agent-setup.sh
fi

# Start Tailscale if configured
if [ -n "$TAILSCALE_AUTHKEY" ] && command -v tailscale &> /dev/null; then
    if ! pgrep -x "tailscaled" > /dev/null; then
        echo "[entrypoint] Starting tailscaled..."
        mkdir -p /var/run/tailscale
        chmod 755 /var/run/tailscale
        tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock &
        sleep 3
    fi
    
    if ! tailscale --socket=/var/run/tailscale/tailscaled.sock status &>/dev/null; then
        echo "[entrypoint] Authenticating with Tailscale..."
        HOSTNAME="${TAILSCALE_HOSTNAME:-${HOSTNAME:-zeroclaw}}"
        tailscale --socket=/var/run/tailscale/tailscaled.sock up --ssh --operator=zeroclaw --authkey="$TAILSCALE_AUTHKEY" --hostname="$HOSTNAME"
        echo "[entrypoint] Tailscale ready"
    fi
    
    chown zeroclaw:zeroclaw /var/run/tailscale/tailscaled.sock 2>/dev/null || true
fi

# Drop to zeroclaw user and run zeroclaw
# Use 'su -m' to preserve environment variables (API keys, config)
if [ $# -eq 0 ]; then
    exec su -m zeroclaw -c "exec zeroclaw gateway"
else
    # Properly quote all arguments for the su command
    exec su -m zeroclaw -c "exec $*"
fi
