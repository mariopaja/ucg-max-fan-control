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
        logger -t fan-control "Created new optimal PWM file with initial value $MIN_PWM"
    fi

    # Load historical value with sanity checks
    OPTIMAL_PWM=$(cat "$OPTIMAL_PWM_FILE" 2>/dev/null || echo $MIN_PWM)
    if (( OPTIMAL_PWM < MIN_PWM )) || (( OPTIMAL_PWM > MAX_PWM )); then
        OPTIMAL_PWM=$MIN_PWM
        logger -t fan-control "Reset invalid optimal PWM to safe minimum $MIN_PWM"
    fi
    logger -t fan-control "Loaded optimal PWM: $OPTIMAL_PWM"
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
    local avg=$(( count > 0 ? sum / count : 0 ))
    logger -t fan-control "Calculated rolling average: ${avg}℃ (${count} samples)"
    echo $avg
}

# Apply new fan speed with safety checks
set_fan_speed() {
    local new_speed=$1
    local current_temp=$(get_current_temp)

    # Emergency override for critical temps
    if (( current_temp >= MAX_TEMP )); then
        new_speed=$MAX_PWM
        logger -t fan-control "EMERGENCY OVERRIDE: Current temp ${current_temp}℃ ≥ ${MAX_TEMP}℃"
    fi

    # Only update hardware when necessary
    if [[ "$new_speed" -ne "$LAST_PWM" ]] && [[ -w "$FAN_PWM_DEVICE" ]]; then
        echo "$new_speed" > "$FAN_PWM_DEVICE"
        LAST_PWM=$new_speed
        local avg_temp=$(get_smoothed_temp)
        logger -t fan-control "Set PWM: $new_speed | State: $CURRENT_STATE | Avg Temp: ${avg_temp}℃"
    fi
}

# Execute state machine transitions
update_fan_state() {
    local avg_temp=$(get_smoothed_temp)
    local now=$(date +%s)

    case $CURRENT_STATE in
        $STATE_OFF)
            if (( avg_temp >= FAN_ACTIVATION_TEMP )); then
                logger -t fan-control "ACTIVATING: Avg temp ${avg_temp}℃ ≥ activation threshold ${FAN_ACTIVATION_TEMP}℃"
                CURRENT_STATE=$STATE_LINEAR
                set_fan_speed $OPTIMAL_PWM
            else
                logger -t fan-control "Remaining OFF: Avg temp ${avg_temp}℃ < threshold"
            fi
            ;;

        $STATE_TAPER)
            if (( avg_temp >= FAN_ACTIVATION_TEMP )); then
                logger -t fan-control "EARLY REACTIVATION: Avg temp ${avg_temp}℃ ≥ threshold during taper"
                CURRENT_STATE=$STATE_LINEAR
                set_fan_speed $OPTIMAL_PWM
            elif (( now - TAPER_START >= TAPER_DURATION )); then
                logger -t fan-control "TAPER COMPLETE: Returning to OFF state after 90 minutes"
                CURRENT_STATE=$STATE_OFF
                set_fan_speed 0
            else
                local remaining=$(( (TAPER_DURATION - (now - TAPER_START)) / 60 ))
                logger -t fan-control "TAPER ACTIVE: ${remaining} minutes remaining"
                set_fan_speed $MIN_PWM
            fi
            ;;

        $STATE_LINEAR)
            if (( avg_temp <= MIN_TEMP )); then
                logger -t fan-control "STABILIZED: Avg temp ${avg_temp}℃ ≤ min threshold ${MIN_TEMP}℃"
                CURRENT_STATE=$STATE_TAPER
                TAPER_START=$now
                set_fan_speed $MIN_PWM
            else
                local temp_range=$((MAX_TEMP - FAN_ACTIVATION_TEMP))
                local speed=$(( OPTIMAL_PWM + (avg_temp - FAN_ACTIVATION_TEMP) * (MAX_PWM - OPTIMAL_PWM) / temp_range ))
                speed=$(( speed > MAX_PWM ? MAX_PWM : speed ))

                logger -t fan-control "LINEAR MODE: Temp ${avg_temp}℃ → PWM ${speed}"
                set_fan_speed $speed

                if (( avg_temp > MIN_TEMP && avg_temp < FAN_ACTIVATION_TEMP + 2 )); then
                    OPTIMAL_PWM=$(( (OPTIMAL_PWM + speed) / 2 ))
                    echo "$OPTIMAL_PWM" > "${OPTIMAL_PWM_FILE}.tmp"
                    mv "${OPTIMAL_PWM_FILE}.tmp" "$OPTIMAL_PWM_FILE"
                    logger -t fan-control "ADJUSTED OPTIMAL PWM: ${OPTIMAL_PWM} (previous: $(( (OPTIMAL_PWM*2 - speed) )) )"
                fi
            fi
            ;;
    esac
}

# Main execution flow
initialize_optimal_pwm
initial_temp=$(get_smoothed_temp)
logger -t fan-control "Service starting | Initial temp: ${initial_temp}℃ | Optimal PWM: ${OPTIMAL_PWM}"

if (( initial_temp >= FAN_ACTIVATION_TEMP )); then
    logger -t fan-control "HOT START: Beginning in LINEAR state"
    CURRENT_STATE=$STATE_LINEAR
    set_fan_speed $OPTIMAL_PWM
else
    logger -t fan-control "COLD START: Beginning in OFF state"
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