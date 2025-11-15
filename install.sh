#!/bin/bash

# Installation script that can be run with: bash <(curl -fsSL https://raw.githubusercontent.com/milibots/install-ssl/main/install.sh)

SCRIPT_URL="https://raw.githubusercontent.com/milibots/install-ssl/refs/heads/main/ssl-setup.sh"
TEMP_SCRIPT="/tmp/ssl-setup-temp.sh"

echo "🔧 SSL Setup Installer for Nginx"
echo "====================================="
echo "📥 Downloading SSL setup script..."

# Download and run the main script
if curl -fsSL "$SCRIPT_URL" -o "$TEMP_SCRIPT"; then
    chmod +x "$TEMP_SCRIPT"
    echo "✅ Script downloaded successfully"
    echo "🚀 Starting SSL setup..."
    "$TEMP_SCRIPT"
else
    echo "❌ Failed to download the SSL setup script"
    echo "💡 Debug info:"
    echo "   URL attempted: $SCRIPT_URL"
    echo "   Check if the file exists in your repository"
    exit 1
fi
