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
    
    local effective_api_key="${ZEROCLAW_API_KEY:-${API_KEY:-}}"
    if [ -n "$effective_api_key" ]; then
        local escaped=$(escape_sed "$effective_api_key")
        if grep -q "^api_key = " "$CONFIG_FILE"; then
            sed -i "s#^api_key = .*#api_key = \"$escaped\"#" "$CONFIG_FILE"
        else
            printf '\napi_key = "%s"\n' "$effective_api_key" >> "$CONFIG_FILE"
        fi
        echo "[entrypoint]   api_key: updated from env"
    else
        if grep -q "^api_key = " "$CONFIG_FILE"; then
            sed -i '/^api_key = /d' "$CONFIG_FILE"
            echo "[entrypoint]   api_key: removed (not set in env)"
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

# Build JSON array from comma-separated usernames/IDs.
build_json_array_from_csv() {
    local csv="$1"
    if [ -z "$csv" ]; then
        printf '[]'
        return 0
    fi

    printf '%s' "$csv" \
        | tr ',' '\n' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | sed '/^$/d' \
        | jq -R . \
        | jq -s .
}

# Build TOML array from comma-separated usernames/IDs.
build_toml_array_from_csv() {
    local csv="$1"
    if [ -z "$csv" ]; then
        printf '[]'
        return 0
    fi

    local out=""
    local item
    while IFS= read -r item; do
        item="$(printf '%s' "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "$item" ] && continue
        item="${item//\\/\\\\}"
        item="${item//\"/\\\"}"
        if [ -z "$out" ]; then
            out="\"$item\""
        else
            out="$out, \"$item\""
        fi
    done < <(printf '%s\n' "$csv" | tr ',' '\n')

    if [ -z "$out" ]; then
        printf '[]'
    else
        printf '[%s]' "$out"
    fi
}

remove_toml_section() {
    local section="$1"
    local tmp_file
    tmp_file="$(mktemp)"
    awk -v section="$section" '
        BEGIN { skip = 0 }
        {
            if ($0 == section) {
                skip = 1
                next
            }
            if (skip && $0 ~ /^\[/) {
                skip = 0
            }
            if (!skip) {
                print
            }
        }
    ' "$CONFIG_FILE" > "$tmp_file"
    mv "$tmp_file" "$CONFIG_FILE"
}

ensure_config_permissions() {
    if [ -f "$CONFIG_FILE" ]; then
        chown zeroclaw:zeroclaw "$CONFIG_FILE" 2>/dev/null || true
        chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    fi
}

# Auto-bootstrap Telegram channel from env when configured.
bootstrap_telegram_channel() {
    local bot_token="${ZEROCLAW_TELEGRAM_BOT_TOKEN:-${TELEGRAM_BOT_TOKEN:-}}"
    local channel_name="${ZEROCLAW_TELEGRAM_CHANNEL_NAME:-${TELEGRAM_CHANNEL_NAME:-telegram}}"
    local allowed_users_csv="${ZEROCLAW_TELEGRAM_ALLOWED_USERS:-${TELEGRAM_ALLOWED_USERS:-}}"
    local allow_all="${ZEROCLAW_TELEGRAM_ALLOW_ALL:-${TELEGRAM_ALLOW_ALL:-false}}"

    if [ -z "$bot_token" ]; then
        return 0
    fi

    # Ensure [channels_config] exists and has cli=true.
    if ! grep -q "^\[channels_config\]" "$CONFIG_FILE"; then
        printf '\n[channels_config]\ncli = true\n' >> "$CONFIG_FILE"
    elif ! sed -n '/^\[channels_config\]/,/^\[/p' "$CONFIG_FILE" | grep -q '^cli = '; then
        sed -i '/^\[channels_config\]$/a cli = true' "$CONFIG_FILE"
    fi

    # Re-sync Telegram section from env on every boot to avoid stale allowlists.
    if grep -q "^\[channels_config\.telegram\]" "$CONFIG_FILE"; then
        remove_toml_section "[channels_config.telegram]"
    fi

    local allowed_users_json='[]'
    local allowed_users_toml='[]'
    if [ -n "$allowed_users_csv" ]; then
        allowed_users_json="$(build_json_array_from_csv "$allowed_users_csv")"
        allowed_users_toml="$(build_toml_array_from_csv "$allowed_users_csv")"
    elif [ "$allow_all" = "true" ] || [ "$allow_all" = "1" ] || [ "$allow_all" = "yes" ] || [ "$allow_all" = "on" ]; then
        allowed_users_json='["*"]'
        allowed_users_toml='["*"]'
    fi

    local escaped_token
    escaped_token="${bot_token//\\/\\\\}"
    escaped_token="${escaped_token//\"/\\\"}"

    {
        printf '\n[channels_config.telegram]\n'
        printf 'bot_token = "%s"\n' "$escaped_token"
        printf 'allowed_users = %s\n' "$allowed_users_toml"
        printf 'stream_mode = "off"\n'
        printf 'draft_update_interval_ms = 1000\n'
        printf 'interrupt_on_new_message = false\n'
        printf 'mention_only = false\n'
    } >> "$CONFIG_FILE"

    if [ "$allowed_users_json" = '[]' ]; then
        echo "[entrypoint] Telegram channel configured from env (warning: allowed_users is empty; bot will deny all until allowlist is configured)"
    else
        echo "[entrypoint] Telegram channel configured from env"
    fi
}

# Run config update
update_config
bootstrap_telegram_channel
ensure_config_permissions

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

# Start docsd (managed-docs daemon) as separate user for strong write boundary
DOCSD_SOCKET="${DOCSD_SOCKET:-/zeroclaw-data/workspace/.managed-docs/docsd.sock}"
DOCSD_DIR="$(dirname "$DOCSD_SOCKET")"
# docsd materialization may replace/create markdown files under workspace root.
# Keep workspace group-writable for zeroclaw/docs boundary users.
chown zeroclaw:zeroclawdocs /zeroclaw-data/workspace 2>/dev/null || true
chmod 0775 /zeroclaw-data/workspace 2>/dev/null || true
mkdir -p "$DOCSD_DIR"
chown -R docsd:zeroclawdocs "$DOCSD_DIR"
chmod 0770 "$DOCSD_DIR"

# Materialize identity markdown files from mounted agent config when missing.
# This keeps workspace bootstrap files available for prompt injection even before
# managed-docs materialization runs.
if [ -n "$AGENT_CONFIG_DIR" ] && [ -d "$AGENT_CONFIG_DIR" ]; then
    for doc in AGENTS.md SOUL.md TOOLS.md IDENTITY.md USER.md HEARTBEAT.md BOOTSTRAP.md MEMORY.md; do
        src_path="$AGENT_CONFIG_DIR/$doc"
        dst_path="/zeroclaw-data/workspace/$doc"
        if [ -f "$src_path" ] && [ ! -f "$dst_path" ]; then
            cp "$src_path" "$dst_path"
            chown docsd:zeroclawdocs "$dst_path" 2>/dev/null || true
            chmod 0644 "$dst_path" 2>/dev/null || true
        fi
    done

    if [ -d "$AGENT_CONFIG_DIR/skills" ]; then
        while IFS= read -r -d '' skill_file; do
            rel_path="${skill_file#${AGENT_CONFIG_DIR}/}"
            dst_path="/zeroclaw-data/workspace/${rel_path}"
            dst_dir="$(dirname "$dst_path")"
            mkdir -p "$dst_dir"
            if [ ! -f "$dst_path" ]; then
                cp "$skill_file" "$dst_path"
                chown docsd:zeroclawdocs "$dst_path" 2>/dev/null || true
                chmod 0644 "$dst_path" 2>/dev/null || true
            fi
        done < <(find "$AGENT_CONFIG_DIR/skills" -mindepth 2 -maxdepth 2 -name "SKILL.md" -type f -print0)
    fi
fi

for doc in AGENTS.md SOUL.md TOOLS.md IDENTITY.md USER.md HEARTBEAT.md BOOTSTRAP.md MEMORY.md; do
    if [ -f "/zeroclaw-data/workspace/$doc" ]; then
        chown docsd:zeroclawdocs "/zeroclaw-data/workspace/$doc" 2>/dev/null || true
        chmod 0644 "/zeroclaw-data/workspace/$doc" 2>/dev/null || true
    fi
done
if [ -d "/zeroclaw-data/workspace/skills" ]; then
    find "/zeroclaw-data/workspace/skills" -mindepth 2 -maxdepth 2 -name "SKILL.md" -type f \
        -exec chown docsd:zeroclawdocs {} \; -exec chmod 0644 {} \; 2>/dev/null || true
fi

if ! pgrep -u docsd -f "zeroclaw docsd" >/dev/null 2>&1; then
    echo "[entrypoint] Starting docsd at $DOCSD_SOCKET"
    DOCSD_CMD="exec zeroclaw docsd --socket '$DOCSD_SOCKET'"
    if [ -n "$AGENT_CONFIG_DIR" ] && [ -d "$AGENT_CONFIG_DIR" ]; then
        DOCSD_CMD="$DOCSD_CMD --scaffold-dir '$AGENT_CONFIG_DIR'"
    fi
    su -m docsd -s /bin/bash -c "$DOCSD_CMD" &
fi

# Wait for docsd socket before launching agent runtime
for i in $(seq 1 50); do
    if [ -S "$DOCSD_SOCKET" ]; then
        chmod 0660 "$DOCSD_SOCKET" 2>/dev/null || true
        chown docsd:zeroclawdocs "$DOCSD_SOCKET" 2>/dev/null || true
        break
    fi
    sleep 0.1
done

export DOCSD_SOCKET

# Drop to zeroclaw user and run zeroclaw
# Use 'su -m' to preserve environment variables (API keys, config)
if [ $# -eq 0 ]; then
    exec su -m zeroclaw -c "exec zeroclaw gateway"
else
    # Properly quote all arguments for the su command
    exec su -m zeroclaw -c "exec $*"
fi
