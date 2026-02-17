#!/bin/bash
#
# ZeroClaw TUI Launcher
# 
# Wrapper script to run the TUI from project root
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TUI_DIR="$PROJECT_DIR/tui"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check if TUI is built
if [[ ! -d "$TUI_DIR/dist" ]] || [[ ! -f "$TUI_DIR/dist/index.js" ]]; then
    echo -e "${BLUE}[INFO]${NC} Building TUI for the first time..."
    cd "$TUI_DIR"
    
    # Check if node_modules exists
    if [[ ! -d "$TUI_DIR/node_modules" ]]; then
        echo -e "${BLUE}[INFO]${NC} Installing dependencies..."
        npm install
    fi
    
    npm run build
    
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}[ERROR]${NC} Failed to build TUI"
        exit 1
    fi
    
    echo -e "${GREEN}[OK]${NC} TUI built successfully"
fi

# Run the TUI
cd "$PROJECT_DIR"
node "$TUI_DIR/dist/index.js" "$@"
