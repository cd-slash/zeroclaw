#!/bin/bash
# OAuth setup script for vdirsyncer + tailscale serve

WORKSPACE_DIR="${ZEROCLAW_WORKSPACE:-/zeroclaw-data/workspace}"

echo "Starting OAuth setup..."

# Start vdirsyncer discover in background, capture output
# Use the patched version that handles tailscale proxy
LOG_FILE="$WORKSPACE_DIR/vdirsyncer_oauth.log"
touch "$LOG_FILE" 2>/dev/null || true
chmod 600 "$LOG_FILE" 2>/dev/null || true
cd "$WORKSPACE_DIR" && vdirsyncer discover 2>&1 | tee "$LOG_FILE" &
VDIRSYNCER_PID=$!

echo "vdirsyncer PID: $VDIRSYNCER_PID"

# Wait for the OAuth URL to appear
echo "Waiting for OAuth URL..."
TIMEOUT=30
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    if grep -q "Opening https://accounts.google.com/o/oauth2" "$LOG_FILE" 2>/dev/null; then
        break
    fi
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "Timeout: OAuth URL not found"
    kill $VDIRSYNCER_PID 2>/dev/null
    exit 1
fi

# Extract the original OAuth URL and port
ORIGINAL_URL=$(grep "Opening https://accounts.google.com/o/oauth2" "$LOG_FILE" | tail -1 | sed 's/.*Opening //')

# Handle both regular and URL-encoded redirect URIs
if echo "$ORIGINAL_URL" | grep -q "redirect_uri=http%3A%2F%2F"; then
    # URL-encoded
    PORT=$(echo "$ORIGINAL_URL" | grep -oP 'redirect_uri=http%3A%2F%2F127\.0\.0\.1%3A\K\d+')
else
    # Not encoded
    PORT=$(echo "$ORIGINAL_URL" | grep -oP 'redirect_uri=http://127\.0\.0\.1:\K\d+')
fi

if [ -z "$PORT" ]; then
    echo "Could not extract port from OAuth URL"
    kill $VDIRSYNCER_PID 2>/dev/null
    exit 1
fi

echo "vdirsyncer listening on port $PORT"
echo "Original URL: $ORIGINAL_URL"

# Start tailscale serve to proxy the port
echo "Setting up tailscale serve proxy..."
tailscale serve --https=8443 http://127.0.0.1:$PORT > /tmp/tailscale.log 2>&1 &
TAILSCALE_PID=$!

echo "tailscale serve PID: $TAILSCALE_PID"

# Wait a moment for tailscale to start
sleep 2

# Extract the tailscale proxy URL from log
TAILSCALE_URL=$(grep "Available within your tailnet:" /tmp/tailscale.log | tail -1 | grep -oP 'https://[^\s]+')
if [ -z "$TAILSCALE_URL" ]; then
    echo "Could not extract tailscale URL from log"
    kill $TAILSCALE_PID 2>/dev/null
    exit 1
fi

# Remove trailing slash if present
TAILSCALE_URL=$(echo "$TAILSCALE_URL" | sed 's|/$||')

# Save to file for the Python patch to read
echo "$TAILSCALE_URL" > /tmp/tailscale_url.txt
echo "Proxy: $TAILSCALE_URL -> http://127.0.0.1:$PORT"

# Construct the modified OAuth URL with HTTPS redirect URI
# Handle both regular and URL-encoded redirect URIs
# URL-encode the tailscale URL for the OAuth redirect
TAILSCALE_URL_ENCODED=$(echo "$TAILSCALE_URL" | sed 's|:|%3A|g; s|/|%2F|g')

if echo "$ORIGINAL_URL" | grep -q "redirect_uri=http%3A%2F%2F"; then
    # URL-encoded: replace http%3A%2F%2F127.0.0.1%3APORT with encoded tailscale URL
    MODIFIED_URL=$(echo "$ORIGINAL_URL" | \
        sed "s|redirect_uri=http%3A%2F%2F127\.0\.0\.1%3A$PORT|redirect_uri=$TAILSCALE_URL_ENCODED|")
else
    # Not encoded: replace http://127.0.0.1:PORT with encoded tailscale URL
    MODIFIED_URL=$(echo "$ORIGINAL_URL" | \
        sed "s|redirect_uri=http://127\.0\.0\.1:$PORT|redirect_uri=$TAILSCALE_URL_ENCODED|")
fi

echo ""
echo "================================================================"
echo "AUTHORIZE USING THIS URL:"
echo ""
echo "$MODIFIED_URL"
echo ""
echo "================================================================"
echo ""
echo "Processes running and waiting for OAuth callback..."
echo "   vdirsyncer PID: $VDIRSYNCER_PID"
echo "   tailscale serve PID: $TAILSCALE_PID"
echo ""
echo "Next steps:"
echo "   1. Click the URL above"
echo "   2. Sign in and authorize the app"
echo "   3. Script will detect the callback and complete setup"
echo ""

# Monitor for callback completion
echo "Waiting for OAuth callback (Ctrl+C to cancel)..."
while kill -0 $VDIRSYNCER_PID 2>/dev/null; do
    # Check if token file was created
    if [ -f ~/.config/vdirsyncer/google_token ] || [ -f ~/.cache/vdirsyncer/google_token ]; then
        echo "OAuth token saved successfully"
        break
    fi

    # Check if vdirsyncer discovered collections successfully
    if grep -q "henry_calendar_remote:" "$LOG_FILE" 2>/dev/null && \
       ! grep -q "No graphical browser found" "$LOG_FILE" | tail -1; then
        sleep 2
        if ! kill -0 $VDIRSYNCER_PID 2>/dev/null; then
            echo "vdirsyncer completed successfully"
            break
        fi
    fi

    sleep 1
done

# Check exit status
if kill -0 $VDIRSYNCER_PID 2>/dev/null; then
    echo "OAuth flow completed"
else
    EXIT_CODE=$(wait $VDIRSYNCER_PID 2>/dev/null || echo "1")
    if [ "$EXIT_CODE" = "0" ]; then
        echo "OAuth flow completed successfully"
    else
        echo "vdirsyncer exited with code: $EXIT_CODE"
    fi
fi

# Check for token file
echo ""
echo "Checking for OAuth token..."
find ~/.config/vdirsyncer ~/.cache/vdirsyncer -name "*token*" -type f 2>/dev/null

# Cleanup
echo ""
echo "Cleaning up..."
kill $TAILSCALE_PID 2>/dev/null
kill $VDIRSYNCER_PID 2>/dev/null

echo "Setup complete"
