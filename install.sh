#!/bin/bash
set -e

# Create directory for fan control
mkdir -p /data/fan-control

# Install fan control script
cat > /data/fan-control/fan-control.sh <<'EOF'
#!/bin/bash
###############################################################################
# UCG-Max Intelligent Fan Controller
#
# Features:
# - Three operational states (OFF/TAPER/LINEAR)
# - Configurable through /data/fan-control/config
# - Safe speed transitions and error resilience
# - Systemd service integration
###############################################################################

###[ CONFIGURATION ]###########################################################
CONFIG_FILE="/data/fan-control/config"

# Load defaults if config missing
source "$CONFIG_FILE" 2>/dev/null || {
    cat > "$CONFIG_FILE" <<-DEFAULTS
MIN_PWM=55             # Minimum active fan speed (0-255)
MAX_PWM=255            # Maximum fan speed (0-255)
MIN_TEMP=60            # Base threshold (°C)
MAX_TEMP=85            # Critical temperature (°C)
HYSTERESIS=5           # Temperature buffer (°C)
AVG_WINDOW=120         # Rolling average seconds
CHECK_INTERVAL=15      # Base check interval (seconds)
TAPER_MINS=90          # Cool-down duration (minutes)
FAN_PWM_DEVICE="/sys/class/hwmon/hwmon0/pwm1"
OPTIMAL_PWM_FILE="/data/fan-control/optimal_pwm"
MAX_PWM_STEP=25        # Max PWM change per adjustment
DEFAULTS
    source "$CONFIG_FILE"
}

# Derived values
FAN_ACTIVATION_TEMP=$((MIN_TEMP + HYSTERESIS))
TAPER_DURATION=$((TAPER_MINS * 60))

###[ RUNTIME CHECKS ]##########################################################
# Validate hardware access
[[ -w "$FAN_PWM_DEVICE" ]] || {
    logger -t fan-control "FATAL: PWM device $FAN_PWM_DEVICE not writable"
    exit 1
}

# Single instance check
PID_FILE="/var/run/fan-control.pid"
if [[ -f "$PID_FILE" ]]; then
    logger -t fan-control "Service already running (PID $(cat "$PID_FILE"))"
    exit 1
fi
echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT

###[ CORE FUNCTIONALITY ]######################################################
STATE_OFF=0
STATE_TAPER=1
STATE_LINEAR=2
CURRENT_STATE=$STATE_OFF
TAPER_START=0
LAST_PWM=-1
declare -a TEMP_LOG

# Temperature handling
get_current_temp() {
    local temp=$(ubnt-systool cputemp | awk '{print int($1)}' 2>/dev/null)
    echo "${temp:-50}"  # Fallback to safe value
}

get_smoothed_temp() {
    local now=$(date +%s) sum=0 count=0
    declare -a valid_entries

    for entry in "${TEMP_LOG[@]}"; do
        IFS=',' read -r ts temp <<< "$entry"
        if (( now - ts <= AVG_WINDOW )); then
            sum=$((sum + temp))
            ((count++))
            valid_entries+=("$entry")
        fi
    done

    TEMP_LOG=("${valid_entries[@]}")
    echo $(( count > 0 ? sum / count : 0 ))
}

# Speed control with logging
set_fan_speed() {
    local new_speed=$1
    local current_temp=$(get_current_temp)

    # Emergency override
    if (( current_temp >= MAX_TEMP )); then
        new_speed=$MAX_PWM
        logger -t fan-control "EMERGENCY: Temp ${current_temp}℃ ≥ ${MAX_TEMP}℃"
    fi

    # Gradual transitions
    if (( new_speed > LAST_PWM + MAX_PWM_STEP )); then
        new_speed=$(( LAST_PWM + MAX_PWM_STEP ))
    elif (( new_speed < LAST_PWM - MAX_PWM_STEP )); then
        new_speed=$(( LAST_PWM - MAX_PWM_STEP ))
    fi

    if [[ "$new_speed" -ne "$LAST_PWM" ]]; then
        echo "$new_speed" > "$FAN_PWM_DEVICE"
        LAST_PWM=$new_speed
        avg_temp=$(get_smoothed_temp)
        logger -t fan-control "PWM: ${new_speed} | Current: ${current_temp}℃ | Avg: ${avg_temp}℃ | State: ${CURRENT_STATE}"
    fi
}

###[ STATE MANAGEMENT ]########################################################
update_fan_state() {
    local avg_temp=$(get_smoothed_temp)
    local now=$(date +%s)

    case $CURRENT_STATE in
        $STATE_OFF)
            if (( avg_temp >= FAN_ACTIVATION_TEMP )); then
                logger -t fan-control "ACTIVATING: Avg ${avg_temp}℃ ≥ ${FAN_ACTIVATION_TEMP}℃"
                CURRENT_STATE=$STATE_LINEAR
                set_fan_speed $(( $(cat "$OPTIMAL_PWM_FILE") ))
            fi
            ;;

        $STATE_TAPER)
            if (( avg_temp >= FAN_ACTIVATION_TEMP )); then
                logger -t fan-control "REACTIVATING: Avg ${avg_temp}℃"
                CURRENT_STATE=$STATE_LINEAR
                set_fan_speed $(( $(cat "$OPTIMAL_PWM_FILE") ))
            elif (( now - TAPER_START >= TAPER_DURATION )); then
                logger -t fan-control "TAPER COMPLETE: ${TAPER_MINS} minutes elapsed"
                CURRENT_STATE=$STATE_OFF
                set_fan_speed 0
            else
                set_fan_speed $MIN_PWM
            fi
            ;;

        $STATE_LINEAR)
            if (( avg_temp <= MIN_TEMP )); then
                logger -t fan-control "STABILIZED: Starting ${TAPER_MINS}min taper"
                CURRENT_STATE=$STATE_TAPER
                TAPER_START=$now
                set_fan_speed $MIN_PWM
            else
                local temp_range=$((MAX_TEMP - FAN_ACTIVATION_TEMP))
                local speed=$(( (avg_temp - FAN_ACTIVATION_TEMP) * (MAX_PWM - MIN_PWM) / temp_range + MIN_PWM ))
                speed=$(( speed > MAX_PWM ? MAX_PWM : speed ))
                set_fan_speed $speed
            fi
            ;;
    esac
}

###[ MAIN EXECUTION ]##########################################################
# Initialize optimal PWM
[[ -f "$OPTIMAL_PWM_FILE" ]] || echo "$MIN_PWM" > "$OPTIMAL_PWM_FILE"
OPTIMAL_PWM=$(cat "$OPTIMAL_PWM_FILE")

logger -t fan-control "Service starting | Optimal PWM: $OPTIMAL_PWM"

# Initial state
initial_temp=$(get_smoothed_temp)
if (( initial_temp >= FAN_ACTIVATION_TEMP )); then
    CURRENT_STATE=$STATE_LINEAR
    set_fan_speed $OPTIMAL_PWM
else
    set_fan_speed 0
fi

# Main loop
while true; do
    TEMP_LOG+=("$(date +%s),$(get_current_temp)")
    update_fan_state
    sleep $CHECK_INTERVAL
done
EOF

# Create uninstall script
cat > /data/fan-control/uninstall.sh <<'EOF'
#!/bin/sh
set -e

# Stop and disable service
systemctl stop fan-control.service 2>/dev/null || true
systemctl disable fan-control.service 2>/dev/null || true

# Remove system files
rm -f /etc/systemd/system/fan-control.service
rm -f /var/run/fan-control.pid

# Remove data files
rm -rf /data/fan-control

# Reload systemd
systemctl daemon-reload

echo "Uninstallation complete. All components removed."
EOF

# Install systemd service
cat > /etc/systemd/system/fan-control.service <<'EOF'
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

# Set permissions and activate
chmod +x /data/fan-control/fan-control.sh
chmod +x /data/fan-control/uninstall.sh
systemctl daemon-reload
systemctl enable --now fan-control.service

echo "Installation successful!"
echo "Configuration: nano /data/fan-control/config"
echo "Status check: journalctl -u fan-control.service -f"