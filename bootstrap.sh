#!/bin/bash
set -e

# URL of the main script
SCRIPT_URL="https://raw.githubusercontent.com/PavelDobre/HAPinstall/main/HAProxySetup.sh"
SCRIPT_NAME="HAProxySetup.sh"

# Download the main script
curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_NAME"

# Make it executable
chmod +x "$SCRIPT_NAME"

# Run it with sudo
sudo ./"$SCRIPT_NAME"