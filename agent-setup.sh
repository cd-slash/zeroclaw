#!/bin/bash
#
# ZeroClaw Agent Setup Script
#
# This script runs at container startup to set up agent-specific tools and packages.
# It reads configuration from environment variables and installs:
#   - APT packages (system tools)
#   - NPM packages (global Node.js tools)
#   - Custom tools from /agent-config/tools/
#
# Usage: Runs automatically via entrypoint before starting the agent
#

set -e

AGENT_CONFIG_DIR="${AGENT_CONFIG_DIR:-/agent-config}"
TOOLS_DIR="${AGENT_CONFIG_DIR}/tools"
SETUP_MARKER="/tmp/.zeroclaw-agent-setup-done"

log() {
    echo "[agent-setup] $(date +'%Y-%m-%d %H:%M:%S') $1"
}

# Check if setup already completed (skip on container restart)
if [[ -f "$SETUP_MARKER" ]]; then
    log "Agent setup already completed (container restart detected)"
    exit 0
fi

log "Starting agent setup..."
log "Config directory: $AGENT_CONFIG_DIR"

# Install APT packages if specified
install_apt_packages() {
    local packages="${AGENT_APT_PACKAGES:-}"
    
    if [[ -z "$packages" ]]; then
        log "No APT packages to install (AGENT_APT_PACKAGES not set)"
        return 0
    fi
    
    log "Installing APT packages: $packages"
    
    # Check if we can install packages (need root or sudo)
    if [[ "$EUID" -ne 0 ]] && ! command -v sudo &>/dev/null; then
        log "WARNING: Cannot install APT packages - not running as root and no sudo available"
        return 1
    fi
    
    local apt_cmd="apt-get"
    if [[ "$EUID" -ne 0 ]]; then
        apt_cmd="sudo apt-get"
    fi
    
    # Update package list and install
    $apt_cmd update -qq || true
    
    # Install packages (space-separated list)
    for pkg in $packages; do
        log "Installing: $pkg"
        $apt_cmd install -y --no-install-recommends "$pkg" 2>/dev/null || {
            log "WARNING: Failed to install $pkg"
        }
    done
    
    # Clean up
    $apt_cmd clean || true
    rm -rf /var/lib/apt/lists/* 2>/dev/null || true
    
    log "APT package installation complete"
}

# Install NPM packages if specified
install_npm_packages() {
    local packages="${AGENT_NPM_PACKAGES:-}"
    
    if [[ -z "$packages" ]]; then
        log "No NPM packages to install (AGENT_NPM_PACKAGES not set)"
        return 0
    fi
    
    # Check if npm is available
    if ! command -v npm &>/dev/null; then
        log "WARNING: npm not available in this container image"
        return 1
    fi
    
    log "Installing NPM packages globally: $packages"
    
    # Install packages (space-separated list)
    for pkg in $packages; do
        log "Installing: $pkg"
        npm install -g "$pkg" 2>/dev/null || {
            log "WARNING: Failed to install $pkg"
        }
    done
    
    # Clean up npm cache
    npm cache clean --force 2>/dev/null || true
    
    log "NPM package installation complete"
}

# Setup custom tools from agent directory
setup_custom_tools() {
    if [[ ! -d "$TOOLS_DIR" ]]; then
        log "No custom tools directory found at $TOOLS_DIR"
        return 0
    fi
    
    local tools_count
    tools_count=$(find "$TOOLS_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l)
    
    if [[ "$tools_count" -eq 0 ]]; then
        log "Custom tools directory is empty"
        return 0
    fi
    
    log "Setting up $tools_count custom tool(s) from $TOOLS_DIR"
    
    # Ensure tools are executable
    for tool in "$TOOLS_DIR"/*; do
        if [[ -f "$tool" ]]; then
            local tool_name
            tool_name=$(basename "$tool")
            
            # Make executable if needed
            if [[ ! -x "$tool" ]]; then
                log "Making $tool_name executable"
                chmod +x "$tool" 2>/dev/null || true
            fi
            
            # Log tool type
            if file "$tool" 2>/dev/null | grep -q "text"; then
                local shebang
                shebang=$(head -1 "$tool")
                log "  Tool: $tool_name ($shebang)"
            else
                log "  Tool: $tool_name (binary)"
            fi
        fi
    done
    
    # Ensure PATH includes agent-tools
    if [[ ":$PATH:" != *":/usr/local/bin/agent-tools:"* ]]; then
        export PATH="/usr/local/bin/agent-tools:$PATH"
        log "Added /usr/local/bin/agent-tools to PATH"
    fi
    
    log "Custom tools are available via: agent-tools/<tool-name>"
}

# Install tools from AGENT_TOOLS env var (simple URLs or package names)
install_remote_tools() {
    local tools="${AGENT_TOOLS:-}"
    
    if [[ -z "$tools" ]]; then
        log "No remote tools to install (AGENT_TOOLS not set)"
        return 0
    fi
    
    log "Installing remote tools: $tools"
    
    # Create tools directory if needed
    mkdir -p /usr/local/bin/agent-tools
    
    for tool in $tools; do
        # Check if it's a URL
        if [[ "$tool" =~ ^https?:// ]]; then
            local tool_name
            tool_name=$(basename "$tool")
            
            log "Downloading: $tool_name from $tool"
            if curl -fsSL "$tool" -o "/usr/local/bin/agent-tools/$tool_name" 2>/dev/null; then
                chmod +x "/usr/local/bin/agent-tools/$tool_name"
                log "Installed: $tool_name"
            else
                log "WARNING: Failed to download $tool"
            fi
        else
            log "WARNING: Unknown tool format: $tool (expected URL)"
        fi
    done
}

# Main setup
main() {
    log "======================================="
    log "ZeroClaw Agent Setup"
    log "======================================="
    
    # Run setup steps
    install_apt_packages
    install_npm_packages
    setup_custom_tools
    install_remote_tools
    
    # Mark setup as complete
    touch "$SETUP_MARKER"
    
    log "======================================="
    log "Agent setup complete!"
    log "======================================="
}

# Run main setup
main
