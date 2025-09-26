#!/bin/bash
set -e
SCRIPT_URL="https://raw.githubusercontent.com/PavelDobre/HAPinstall/main/HAProxySetup.sh"
SCRIPT_NAME="HAProxySetup.sh"
curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_NAME"
chmod +x "$SCRIPT_NAME"
sudo ./"$SCRIPT_NAME"