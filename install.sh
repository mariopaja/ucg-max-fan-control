#!/bin/bash
set -e

# Create directory for fan control
mkdir -p /data/fan-control

# Install the fan control script
cat > /data/fan-control/fan-control.sh <<'EOF'
#!/bin/bash
###############################################################################
# UCG-Max Intelligent Fan Controller
#
# Operates in three distinct modes to balance cooling performance and fan longevity
###############################################################################

###[ USER-CONFIGURABLE SETTINGS ]##############################################
MIN_PWM=55        # Minimum speed when fan is active (not off)
MAX_PWM=255       # Absolute maximum fan speed
MIN_TEMP=60       # Base temperature threshold (°C)
MAX_TEMP=85       # Critical temperature for full-speed override (°C)
HYSTERESIS=5      # Temperature buffer to prevent rapid state changes (°C)
AVG_WINDOW=120    # Temperature averaging period in seconds (2 minutes)
CHECK_INTERVAL=15 # Time between temperature checks (seconds)
TAPER_DURATION=$((90*60)) # Cool-down period after high temps (1.5 hours)
FAN_PWM_DEVICE="/sys/class/hwmon/hwmon0/pwm1" # Hardware PWM control path
OPTIMAL_PWM_FILE="/data/fan-control/optimal_pwm" # Learned speed storage
###############################################################################

# System state tracking
STATE_OFF=0        # Fan completely disabled
STATE_TAPER=1      # Post-operation cool-down phase
STATE_LINEAR=2     # Active temperature management
CURRENT_STATE=$STATE_OFF
TAPER_START=0      # Timestamp when taper phase began
LAST_PWM=-1        # Current fan speed value
declare -a TEMP_LOG # Temperature history for averaging
FAN_ACTIVATION_TEMP=$((MIN_TEMP + HYSTERESIS)) # Actual turn-on threshold (65°C)

# Initialize PWM learning system
initialize_optimal_pwm() {
    # Create learning file with safe defaults if missing
    if [[ ! -f "$OPTIMAL_PWM_FILE" ]]; then
        echo "$MIN_PWM" > "$OPTIMAL_PWM_FILE"
        chmod 644 "$OPTIMAL_PWM_FILE"
    fi

    # Load historical value with sanity checks
    OPTIMAL_PWM=$(cat "$OPTIMAL_PWM_FILE" 2>/dev/null || echo $MIN_PWM)
    (( OPTIMAL_PWM < MIN_PWM || OPTIMAL_PWM > MAX_PWM )) && OPTIMAL_PWM=$MIN_PWM
}

# Retrieve current CPU temperature
get_current_temp() {
    local temp=$(ubnt-systool cputemp | awk '{print int($1)}' 2>/dev/null)
    echo "${temp:-50}"  # Fallback to safe low temperature on sensor failure
}

# Calculate smoothed temperature average
get_smoothed_temp() {
    local now=$(date +%s)
    local sum=0 count=0
    declare -a valid_entries

    # Process temperature history
    for entry in "${TEMP_LOG[@]}"; do
        IFS=',' read -r ts temp <<< "$entry"
        if (( now - ts <= AVG_WINDOW )); then
            sum=$((sum + temp))
            ((count++))
            valid_entries+=("$entry")
        fi
    done

    # Update log with only relevant entries
    TEMP_LOG=("${valid_entries[@]}")
    (( count > 0 )) && echo $(( sum / count )) || echo 0
}

# Apply new fan speed with safety checks
set_fan_speed() {
    local new_speed=$1
    local current_temp=$(get_current_temp)

    # Emergency override for critical temps
    if (( current_temp >= MAX_TEMP )); then
        new_speed=$MAX_PWM
    fi

    # Only update hardware when necessary
    if [[ "$new_speed" -ne "$LAST_PWM" ]] && [[ -w "$FAN_PWM_DEVICE" ]]; then
        echo "$new_speed" > "$FAN_PWM_DEVICE"
        LAST_PWM=$new_speed
    fi
}

# Execute state machine transitions
update_fan_state() {
    local avg_temp=$(get_smoothed_temp)
    local now=$(date +%s)

    case $CURRENT_STATE in
        $STATE_OFF)
            # Activate when sustained temp reaches 65°C
            if (( avg_temp >= FAN_ACTIVATION_TEMP )); then
                CURRENT_STATE=$STATE_LINEAR
                set_fan_speed $OPTIMAL_PWM
            fi
            ;;

        $STATE_TAPER)
            if (( avg_temp >= FAN_ACTIVATION_TEMP )); then
                # Resume active cooling
                CURRENT_STATE=$STATE_LINEAR
                set_fan_speed $OPTIMAL_PWM
            elif (( now - TAPER_START >= TAPER_DURATION )); then
                # Complete cool-down cycle
                CURRENT_STATE=$STATE_OFF
                set_fan_speed 0
            else
                # Maintain minimum speed during taper
                set_fan_speed $MIN_PWM
            fi
            ;;

        $STATE_LINEAR)
            if (( avg_temp <= MIN_TEMP )); then
                # Begin cool-down phase
                CURRENT_STATE=$STATE_TAPER
                TAPER_START=$now
                set_fan_speed $MIN_PWM
            else
                # Calculate proportional speed (65-85°C range)
                local temp_range=$((MAX_TEMP - FAN_ACTIVATION_TEMP))
                local speed=$(( OPTIMAL_PWM + (avg_temp - FAN_ACTIVATION_TEMP) * (MAX_PWM - OPTIMAL_PWM) / temp_range ))
                speed=$(( speed > MAX_PWM ? MAX_PWM : speed ))
                set_fan_speed $speed

                # Refine optimal speed in 60-67°C range
                if (( avg_temp > MIN_TEMP && avg_temp < FAN_ACTIVATION_TEMP + 2 )); then
                    OPTIMAL_PWM=$(( (OPTIMAL_PWM + speed) / 2 ))  # Moving average
                    echo "$OPTIMAL_PWM" > "${OPTIMAL_PWM_FILE}.tmp"
                    mv "${OPTIMAL_PWM_FILE}.tmp" "$OPTIMAL_PWM_FILE"
                fi
            fi
            ;;
    esac
}

# Main execution flow
initialize_optimal_pwm
initial_temp=$(get_smoothed_temp)

# Cold-start decision
if (( initial_temp >= FAN_ACTIVATION_TEMP )); then
    CURRENT_STATE=$STATE_LINEAR
    set_fan_speed $OPTIMAL_PWM
else
    set_fan_speed 0
fi

# Continuous operation loop
while true; do
    TEMP_LOG+=("$(date +%s),$(get_current_temp)")
    update_fan_state
    sleep $CHECK_INTERVAL
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
Description=UCG-Max Adaptive Fan Controller
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