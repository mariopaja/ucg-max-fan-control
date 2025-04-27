#!/bin/bash
set -e

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root (sudo)"
    exit 1
fi

# Check for systemd availability
if ! command -v systemctl >/dev/null 2>&1; then
    echo "Error: systemd is required but not found"
    exit 1
fi

# Stop and disable service
systemctl stop fan-control.service 2>/dev/null || true
systemctl disable fan-control.service 2>/dev/null || true

# Remove system files
echo "Removing system files..."
rm -f /etc/systemd/system/fan-control.service || echo "Warning: Could not remove service file"
rm -f /var/run/fan-control.pid || echo "Warning: Could not remove PID file"

# Remove data files
echo "Removing data files..."
if [ -d "/data/fan-control" ]; then
    rm -rf /data/fan-control || {
        echo "Warning: Could not remove data directory"
        echo "You may need to manually remove /data/fan-control"
    }
else
    echo "Data directory not found, skipping"
fi

# Reload systemd
systemctl daemon-reload

echo "Uninstallation complete. All components removed."
