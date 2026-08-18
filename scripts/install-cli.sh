#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

INSTALL_DIR="${POOLPROBLEM_INSTALL_DIR:-$HOME/.local/bin}"
mkdir -p "$INSTALL_DIR"
cp .build/release/poolproblem "$INSTALL_DIR/poolproblem"
chmod +x "$INSTALL_DIR/poolproblem"

echo "Installed: $INSTALL_DIR/poolproblem"

if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo "Add this directory to your PATH:"
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
fi
