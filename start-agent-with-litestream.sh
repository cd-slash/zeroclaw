#!/bin/bash
#
# ZeroClaw Agent Entrypoint with Litestream
#
# Starts both the ZeroClaw agent and Litestream backup service
# in the same container (no sidecar pattern)

set -e

# Function to log with timestamp
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Function to cleanup on exit
cleanup() {
    log "Shutting down..."
    
    # Kill litestream if running
    if [ -n "${LITESTREAM_PID:-}" ]; then
        log "Stopping Litestream (PID: $LITESTREAM_PID)..."
        kill -TERM "$LITESTREAM_PID" 2>/dev/null || true
        wait "$LITESTREAM_PID" 2>/dev/null || true
    fi
    
    # Kill zeroclaw if running  
    if [ -n "${ZEROCLAW_PID:-}" ]; then
        log "Stopping ZeroClaw (PID: $ZEROCLAW_PID)..."
        kill -TERM "$ZEROCLAW_PID" 2>/dev/null || true
        wait "$ZEROCLAW_PID" 2>/dev/null || true
    fi
    
    log "Shutdown complete"
}

trap cleanup EXIT INT TERM

# Check if Litestream is enabled
if [ "${ZEROCLAW_LITESTREAM_ENABLED:-false}" = "true" ]; then
    log "Litestream backup enabled"
    
    # Wait for database to exist (created by zeroclaw on first run)
    DB_PATH="/zeroclaw-data/.zeroclaw/memory.db"
    MAX_WAIT=30
    WAITED=0
    
    log "Waiting for database at $DB_PATH..."
    while [ ! -f "$DB_PATH" ] && [ $WAITED -lt $MAX_WAIT ]; do
        sleep 1
        WAITED=$((WAITED + 1))
        log "Waiting for database... ($WAITED/$MAX_WAIT)"
    done
    
    if [ ! -f "$DB_PATH" ]; then
        log "WARNING: Database not found after ${MAX_WAIT}s, starting without Litestream backup"
        ZEROCLAW_LITESTREAM_ENABLED="false"
    else
        # Ensure WAL mode is enabled
        log "Enabling WAL mode on database..."
        sqlite3 "$DB_PATH" "PRAGMA journal_mode=WAL;" || true
        
        # Prepare Litestream config
        LITESTREAM_CONFIG="/tmp/litestream.yml"
        
        # Substitute environment variables in litestream config
        if [ -f "/etc/litestream/litestream.yml" ]; then
            log "Preparing Litestream configuration..."
            envsubst < /etc/litestream/litestream.yml > "$LITESTREAM_CONFIG"
            
            # Show config (redact secrets)
            log "Litestream configuration:"
            grep -v "secret\|password\|key" "$LITESTREAM_CONFIG" | head -20 || true
            
            # Start Litestream in background
            log "Starting Litestream backup service..."
            litestream replicate -config "$LITESTREAM_CONFIG" "$DB_PATH" &
            LITESTREAM_PID=$!
            
            log "Litestream started with PID: $LITESTREAM_PID"
            
            # Give Litestream a moment to start
            sleep 2
            
            # Check if Litestream is running
            if ! kill -0 "$LITESTREAM_PID" 2>/dev/null; then
                log "ERROR: Litestream failed to start"
                ZEROCLAW_LITESTREAM_ENABLED="false"
            else
                log "Litestream backup active - monitoring WAL for changes"
            fi
        else
            log "WARNING: Litestream config not found at /etc/litestream/litestream.yml"
            ZEROCLAW_LITESTREAM_ENABLED="false"
        fi
    fi
else
    log "Litestream backup disabled (set ZEROCLAW_LITESTREAM_ENABLED=true to enable)"
fi

# Start ZeroClaw agent in background
log "Starting ZeroClaw agent..."
zeroclaw "$@" &
ZEROCLAW_PID=$!

log "ZeroClaw started with PID: $ZEROCLAW_PID"

# Monitor both processes
if [ "${ZEROCLAW_LITESTREAM_ENABLED:-false}" = "true" ] && [ -n "${LITESTREAM_PID:-}" ]; then
    log "Monitoring both ZeroClaw and Litestream..."
    
    while true; do
        # Check if ZeroClaw is still running
        if ! kill -0 "$ZEROCLAW_PID" 2>/dev/null; then
            log "ZeroClaw process exited"
            wait "$ZEROCLAW_PID" || true
            ZEROCLAW_EXIT_CODE=$?
            log "ZeroClaw exit code: $ZEROCLAW_EXIT_CODE"
            exit $ZEROCLAW_EXIT_CODE
        fi
        
        # Check if Litestream is still running
        if ! kill -0 "$LITESTREAM_PID" 2>/dev/null; then
            log "WARNING: Litestream process died, backup stopped"
            wait "$LITESTREAM_PID" || true
            # Don't exit - keep running without backup
            unset LITESTREAM_PID
        fi
        
        sleep 5
    done
else
    # Just wait for ZeroClaw
    log "Waiting for ZeroClaw..."
    wait "$ZEROCLAW_PID" || true
    ZEROCLAW_EXIT_CODE=$?
    exit $ZEROCLAW_EXIT_CODE
fi
