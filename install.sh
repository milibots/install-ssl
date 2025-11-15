#!/bin/bash

# Installation script that can be run with: bash <(curl -fsSL https://raw.githubusercontent.com/milibots/panel/main/install.sh)

SCRIPT_URL="https://raw.githubusercontent.com/milibots/panel/main/ssl-setup.sh"
TEMP_SCRIPT="/tmp/ssl-setup-temp.sh"

echo "🔧 SSL Setup Installer for Nginx"
echo "====================================="

# Download and run the main script
if curl -fsSL "$SCRIPT_URL" -o "$TEMP_SCRIPT"; then
    chmod +x "$TEMP_SCRIPT"
    "$TEMP_SCRIPT"
else
    echo "❌ Failed to download the SSL setup script"
    exit 1
fi
