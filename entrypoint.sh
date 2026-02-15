#!/bin/bash
set -e

# Authenticate with Tailscale if auth key is provided
if [ -n "$TAILSCALE_AUTHKEY" ] && command -v tailscale &> /dev/null; then
    if ! tailscale status &>/dev/null; then
        echo "[entrypoint] Authenticating with Tailscale..."
        HOSTNAME="${TAILSCALE_HOSTNAME:-${HOSTNAME:-zeroclaw}}"
        tailscale up --ssh --authkey="$TAILSCALE_AUTHKEY" --hostname="$HOSTNAME"
        echo "[entrypoint] Tailscale ready"
    fi
fi

# Run the command passed to the container (or default to zeroclaw gateway)
if [ $# -eq 0 ]; then
    exec zeroclaw gateway
else
    exec "$@"
fi
