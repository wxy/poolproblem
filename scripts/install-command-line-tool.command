#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$SCRIPT_DIR/PoolProblem.app"
CLI="$APP/Contents/Resources/poolproblem"
INSTALL_DIR="${POOLPROBLEM_INSTALL_DIR:-$HOME/.local/bin}"

if [ ! -x "$CLI" ]; then
    echo "CLI not found at $CLI" >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR"
cp "$CLI" "$INSTALL_DIR/poolproblem"
chmod +x "$INSTALL_DIR/poolproblem"

echo "Installed: $INSTALL_DIR/poolproblem"

if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo
    echo "Add this directory to your PATH:"
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
fi
