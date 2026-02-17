#!/bin/bash
#
# ZeroClaw Agent Setup Script
#
# This script runs at container startup to verify baked-in agent tools.
# Tool and package installation happens at Docker build time from tools.toml.
#
# Usage: Runs automatically via entrypoint before starting the agent
#

set -e

AGENT_CONFIG_DIR="${AGENT_CONFIG_DIR:-/agent-config}"
TOOLS_DIR="/usr/local/bin/agent-tools"
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

# Verify custom tools baked into image
setup_custom_tools() {
    if [[ ! -d "$TOOLS_DIR" ]]; then
        log "No agent tools directory found at $TOOLS_DIR"
        return 0
    fi
    
    local tools_count
    tools_count=$(find "$TOOLS_DIR" -maxdepth 1 -type f ! -name ".*.tool" 2>/dev/null | wc -l)
    
    if [[ "$tools_count" -eq 0 ]]; then
        log "No baked custom tools found"
        return 0
    fi

    log "Detected $tools_count baked custom tool(s) in $TOOLS_DIR"
    
    # Ensure tools are executable and log metadata
    for tool in "$TOOLS_DIR"/*; do
        if [[ -f "$tool" ]] && [[ "$tool" != *.tool ]]; then
            local tool_name
            tool_name=$(basename "$tool")
            
            # Make executable if needed
            if [[ ! -x "$tool" ]]; then
                log "Making $tool_name executable"
                chmod +x "$tool" 2>/dev/null || true
            fi
            
            local tool_meta="${TOOLS_DIR}/.${tool_name}.tool"
            if [[ -f "$tool_meta" ]]; then
                local desc
                desc=$(grep '^description=' "$tool_meta" | sed 's/^description=//')
                log "  Tool: $tool_name (${desc:-no description})"
            else
                log "  Tool: $tool_name"
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

# Main setup
main() {
    log "======================================="
    log "ZeroClaw Agent Setup"
    log "======================================="
    
    # Run setup steps
    setup_custom_tools
    
    # Mark setup as complete
    touch "$SETUP_MARKER"
    
    log "======================================="
    log "Agent setup complete!"
    log "======================================="
}

# Run main setup
main
