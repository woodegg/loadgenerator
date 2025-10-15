#!/bin/bash
# install.sh - Installation script for load generator
# Deploys the load generator to the system
#
# Copyright (c) 2025 Jun Zhang
# Licensed under the MIT License. See LICENSE file in the project root.

set -euo pipefail

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Load Generator Installation ==="
echo "Installation directory: $SCRIPT_DIR"
echo ""

# Step 1: Install dependencies
echo "[1/7] Installing dependencies..."
apt-get update -qq
apt-get install -y stress-ng wget bc curl >/dev/null 2>&1
echo "✓ Dependencies installed"

# Step 2: Install binaries
echo "[2/7] Installing binaries..."
cp "$SCRIPT_DIR/bin/loadgen.sh" /usr/local/bin/
cp "$SCRIPT_DIR/bin/loadgen-status" /usr/local/bin/
cp "$SCRIPT_DIR/bin/loadgen-webserver" /usr/local/bin/
chmod +x /usr/local/bin/loadgen.sh
chmod +x /usr/local/bin/loadgen-status
chmod +x /usr/local/bin/loadgen-webserver
echo "✓ Binaries installed to /usr/local/bin/"

# Step 3: Install libraries
echo "[3/7] Installing libraries..."
mkdir -p /usr/local/lib/loadgen
cp "$SCRIPT_DIR/lib/"*.sh /usr/local/lib/loadgen/
echo "✓ Libraries installed to /usr/local/lib/loadgen/"

# Step 4: Install configuration
echo "[4/7] Installing configuration..."
if [ -f /etc/loadgen.conf ]; then
    echo "   Configuration file already exists at /etc/loadgen.conf"
    echo "   Backing up to /etc/loadgen.conf.bak"
    cp /etc/loadgen.conf /etc/loadgen.conf.bak
fi
cp "$SCRIPT_DIR/loadgen.conf.example" /etc/loadgen.conf
echo "✓ Configuration installed to /etc/loadgen.conf"

# Step 5: Create log directories
echo "[5/7] Creating log directories..."
mkdir -p /var/log/loadgen
mkdir -p /var/lib/loadgen
echo "✓ Log directories created"

# Step 6: Install systemd services
echo "[6/7] Installing systemd services..."
cp "$SCRIPT_DIR/systemd/loadgen.service" /etc/systemd/system/
cp "$SCRIPT_DIR/systemd/loadgen-web.service" /etc/systemd/system/
systemctl daemon-reload
echo "✓ Systemd services installed"

# Step 7: Install documentation
echo "[7/7] Installing documentation..."
mkdir -p /usr/local/share/doc/loadgen
cp "$SCRIPT_DIR/README.md" /usr/local/share/doc/loadgen/
echo "✓ Documentation installed to /usr/local/share/doc/loadgen/"

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Next steps:"
echo "1. Edit configuration: vim /etc/loadgen.conf"
echo "2. Set your CPU and bandwidth targets"
echo "3. Enable web dashboard (optional): Set ENABLE_WEB_DASHBOARD=true"
echo "4. Start the services:"
echo "   systemctl start loadgen"
echo "   systemctl start loadgen-web  # If web dashboard enabled"
echo "5. Enable on boot:"
echo "   systemctl enable loadgen"
echo "   systemctl enable loadgen-web  # If web dashboard enabled"
echo "6. Check status: loadgen-status"
echo ""
echo "Quick commands:"
echo "  systemctl start loadgen      # Start load generator"
echo "  systemctl start loadgen-web  # Start web dashboard"
echo "  systemctl stop loadgen       # Stop load generator"
echo "  systemctl status loadgen     # Service status"
echo "  systemctl reload loadgen     # Reload config"
echo "  loadgen-status               # Show current status"
echo "  loadgen-status live          # Live monitoring"
echo "  journalctl -u loadgen -f     # View logs"
echo ""
echo "Web Dashboard:"
echo "  Access at: http://<server-ip>:80/"
echo "  Configure in /etc/loadgen.conf [WEB_DASHBOARD] section"
echo ""
