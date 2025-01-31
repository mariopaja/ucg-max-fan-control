#!/bin/sh
set -e

# Create directory for fan control
mkdir -p /data/fan-control

# Install fan control script
cat > /data/fan-control/fan-control.sh <<'EOF'
#!/bin/sh
# Fan Control Configuration
BASE_PWM=91
MIN_TEMP=60
MAX_TEMP=85
CHECK_INTERVAL=15
MIN_PWM=0
MAX_PWM=255

while true; do
    temp=$(ubnt-systool cputemp | awk '{print int($1)}')

    if [ "$temp" -lt "$MIN_TEMP" ]; then
        pwm="$BASE_PWM"
    elif [ "$temp" -ge "$MIN_TEMP" ] && [ "$temp" -le "$MAX_TEMP" ]; then
        delta_temp=$((temp - MIN_TEMP))
        pwm=$((BASE_PWM + (delta_temp * (MAX_PWM - BASE_PWM)) / (MAX_TEMP - MIN_TEMP)))
    else
        pwm="$MAX_PWM"
    fi

    [ "$pwm" -lt "$MIN_PWM" ] && pwm="$MIN_PWM"
    [ "$pwm" -gt "$MAX_PWM" ] && pwm="$MAX_PWM"

    echo "$pwm" > /sys/class/hwmon/hwmon0/pwm1
    sleep "$CHECK_INTERVAL"
done
EOF

# Create uninstall script in same directory
cat > /data/fan-control/uninstall.sh <<'EOF'
#!/bin/sh
set -e

systemctl stop fan-control.service 2>/dev/null || true
systemctl disable fan-control.service 2>/dev/null || true
rm -f /etc/systemd/system/fan-control.service
rm -rf /data/fan-control
systemctl daemon-reload

echo "Uninstallation complete. Fan control removed."
EOF

# Set execute permissions
chmod +x /data/fan-control/fan-control.sh
chmod +x /data/fan-control/uninstall.sh

# Install systemd service
cat > /etc/systemd/system/fan-control.service <<EOF
[Unit]
Description=Dynamic Fan Speed Control
After=network.target

[Service]
Type=simple
ExecStart=/data/fan-control/fan-control.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now fan-control.service

echo "Installation complete. Fan control service is now active."
echo "Uninstall script: /data/fan-control/uninstall.sh"