#!/bin/bash
set -e

# Create directory for fan control
mkdir -p /data/fan-control

# Install fan control script
cat > /data/fan-control/fan-control.sh <<'EOF'
#!/bin/bash
#!/bin/bash
###############################################################################
# UCG-Max Intelligent Fan Controller
#
# Features:
# - Three operational states (OFF/TAPER/ACTIVE)
# - Configurable through /data/fan-control/config
# - Safe speed transitions and error resilience
# - Systemd service integration
###############################################################################

###[ CONFIGURATION ]###########################################################
CONFIG_FILE="/data/fan-control/config"

# Load defaults if config missing
source "$CONFIG_FILE" 2>/dev/null || {
    cat > "$CONFIG_FILE" <<-DEFAULTS
MIN_PWM=91             # Minimum active fan speed (0-255)
MAX_PWM=255            # Maximum fan speed (0-255)
MIN_TEMP=60            # Base threshold (°C)
MAX_TEMP=85            # Critical temperature (°C)
HYSTERESIS=5           # Temperature buffer (°C)
CHECK_INTERVAL=15      # Base check interval (seconds)
TAPER_MINS=90          # Cool-down duration (minutes)
FAN_PWM_DEVICE="/sys/class/hwmon/hwmon0/pwm1"
OPTIMAL_PWM_FILE="/data/fan-control/optimal_pwm"
MAX_PWM_STEP=25        # Max PWM change per adjustment
DEADBAND=1             # Temp stability threshold (°C)
ALPHA=40               # Smoothing factor (0-100)
LEARNING_RATE=5        # PWM optimization step size
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
MAX_AGE=60  # Seconds since last PID update

# Check for existing process
if [[ -f "$PID_FILE" ]]; then
    existing_pid=$(cat "$PID_FILE")
    if ps -p "$existing_pid" >/dev/null 2>&1; then
        logger -t fan-control "ALERT: Active service found (PID $existing_pid)"
        exit 1
    else
        logger -t fan-control "CLEANUP: Removing stale PID $existing_pid"
        rm -f "$PID_FILE"
    fi
fi

# Create PID file with atomic lock
(
    flock -x 200
    echo $$ > "$PID_FILE"
    trap 'rm -f "$PID_FILE"; exit' EXIT INT TERM
) 200>"$PID_FILE"

###[ CORE FUNCTIONALITY ]######################################################
STATE_OFF=0
STATE_TAPER=1
STATE_ACTIVE=2
CURRENT_STATE=$STATE_OFF
TAPER_START=0
LAST_PWM=-1
SMOOTHED_TEMP=50
LAST_ADJUSTMENT=0
LAST_AVG_TEMP=0  # Track temperature for deadband calculations

SMOOTHED_TEMP=$(ubnt-systool cputemp | awk '{print int($1)}' || echo 50)
logger -t fan-control "INIT: Raw=${SMOOTHED_TEMP}℃ | Starting smooth_temp=${SMOOTHED_TEMP}℃"

get_smoothed_temp() {
    local raw_temp=$(ubnt-systool cputemp | awk '{print int($1)}' 2>/dev/null)
    raw_temp=${raw_temp:-50}
    local previous=$SMOOTHED_TEMP
    SMOOTHED_TEMP=$(( (ALPHA * SMOOTHED_TEMP + (100 - ALPHA) * raw_temp ) / 100 ))

    logger -t fan-control "TEMP:  RAW=${raw_temp}℃ | SMOOTH=${SMOOTHED_TEMP}℃ | DELTA=$((SMOOTHED_TEMP - previous))℃"
    echo $SMOOTHED_TEMP
}

calculate_speed() {
    local avg_temp=$1
    local temp_range=$((MAX_TEMP - FAN_ACTIVATION_TEMP))
    local temp_diff=$((avg_temp - FAN_ACTIVATION_TEMP))

    (( temp_range > 0 )) || temp_range=1
    local speed=$(( (temp_diff * temp_diff * (MAX_PWM - MIN_PWM) * 20) / (temp_range * temp_range * 10) ))
    speed=$(( speed + MIN_PWM ))
    speed=$(( speed > MAX_PWM ? MAX_PWM : speed ))

    logger -t fan-control "CALC: temp_diff=${temp_diff}℃ | range=${temp_range}℃ | speed=${speed}pwm"
    echo $speed
}

# Speed control with logging
set_fan_speed() {
    local new_speed=$1
    local current_temp=$(get_smoothed_temp)
    local reason="Normal operation"

    # Emergency override
    if (( current_temp >= MAX_TEMP )); then
        new_speed=$MAX_PWM
        reason="EMERGENCY: Temp ${current_temp}℃ ≥ ${MAX_TEMP}℃"
    fi

    # Special handling for OFF state
    if (( CURRENT_STATE == STATE_OFF )); then
        new_speed=0  # Force 0 PWM regardless of other logic
        reason="OFF state override"
    else
        # Apply ramp limits only in non-OFF states
        if (( new_speed > LAST_PWM + MAX_PWM_STEP )); then
            reason="Ramp-up limited: ${LAST_PWM}→$((LAST_PWM + MAX_PWM_STEP))pwm"
            new_speed=$(( LAST_PWM + MAX_PWM_STEP ))
        elif (( new_speed < LAST_PWM - MAX_PWM_STEP )); then
            reason="Ramp-down limited: ${LAST_PWM}→$((LAST_PWM - MAX_PWM_STEP))pwm"
            new_speed=$(( LAST_PWM - MAX_PWM_STEP ))
        fi

        # Enforce MIN/MAX only in active states
        new_speed=$(( new_speed > MAX_PWM ? MAX_PWM : new_speed ))
        new_speed=$(( new_speed < MIN_PWM ? MIN_PWM : new_speed ))
    fi

    if [[ "$new_speed" -ne "$LAST_PWM" ]]; then
        echo "$new_speed" > "$FAN_PWM_DEVICE"
        logger -t fan-control "SET: ${LAST_PWM}→${new_speed}pwm | Reason: ${reason}"
        LAST_PWM=$new_speed
        LAST_AVG_TEMP=$current_temp  # Reset deadband tracking on change

        if (( CURRENT_STATE == STATE_ACTIVE )); then
            local now=$(date +%s)
            if (( now - LAST_ADJUSTMENT > 3600 )); then
                local optimal=$(cat "$OPTIMAL_PWM_FILE")
                local original_optimal=$optimal
                local adjustment=""

                # Only adjust optimal PWM if we're at target speed
                if (( new_speed == optimal )); then
                    (( current_temp > MIN_TEMP )) && {
                        adjustment="+$LEARNING_RATE (optimal at temp ${current_temp}℃)"
                        optimal=$(( optimal + LEARNING_RATE ))
                    }
                    (( current_temp < MIN_TEMP )) && {
                        adjustment="-$LEARNING_RATE (optimal at temp ${current_temp}℃)"
                        optimal=$(( optimal - LEARNING_RATE ))
                    }
                fi

                if [[ -n "$adjustment" ]]; then
                    optimal=$(( optimal > MAX_PWM ? MAX_PWM : optimal ))
                    optimal=$(( optimal < MIN_PWM ? MIN_PWM : optimal ))
                    echo "$optimal" > "$OPTIMAL_PWM_FILE"
                    LAST_ADJUSTMENT=$now
                    logger -t fan-control "LEARNING: ${original_optimal}→${optimal}pwm (${adjustment})"
                fi
            fi
        fi
    fi
}

###[ STATE MANAGEMENT ]########################################################
update_fan_state() {
    local avg_temp=$(get_smoothed_temp)
    local now=$(date +%s)
    local state_transition=""

    case $CURRENT_STATE in
        $STATE_OFF)
            if (( avg_temp >= FAN_ACTIVATION_TEMP )); then
                state_transition="OFF→ACTIVE (${avg_temp}℃ ≥ ${FAN_ACTIVATION_TEMP}℃)"
                CURRENT_STATE=$STATE_ACTIVE
                set_fan_speed $(< "$OPTIMAL_PWM_FILE")
            fi
            ;;

        $STATE_TAPER)
            if (( avg_temp >= FAN_ACTIVATION_TEMP )); then
                state_transition="TAPER→ACTIVE (${avg_temp}℃ ≥ ${FAN_ACTIVATION_TEMP}℃)"
                CURRENT_STATE=$STATE_ACTIVE
                set_fan_speed $(< "$OPTIMAL_PWM_FILE")
            elif (( now - TAPER_START >= TAPER_DURATION )); then
                state_transition="TAPER→OFF (${TAPER_MINS}min elapsed)"
                CURRENT_STATE=$STATE_OFF
                set_fan_speed 0
            else
                local remaining=$(( TAPER_DURATION - (now - TAPER_START) ))
                logger -t fan-control "TAPER: Remaining $((remaining / 60))m | Current: ${avg_temp}℃"
                set_fan_speed $MIN_PWM
            fi
            ;;

        $STATE_ACTIVE)
            if (( avg_temp <= MIN_TEMP )); then
                state_transition="ACTIVE→TAPER (${avg_temp}℃ ≤ ${MIN_TEMP}℃)"
                CURRENT_STATE=$STATE_TAPER
                TAPER_START=$now
                set_fan_speed $MIN_PWM
            else
                local temp_delta=$(( avg_temp - LAST_AVG_TEMP ))
                if (( ${temp_delta#-} > DEADBAND )); then
                    logger -t fan-control "DEADBAND:  DELTA=${temp_delta}℃ | THRESHOLD=${DEADBAND}℃"
                    local speed=$(calculate_speed $avg_temp)
                    set_fan_speed $speed
                else
                    # Force adjustment if we're below target PWM
                    local target_speed=$(calculate_speed $avg_temp)
                    if (( LAST_PWM < target_speed )); then
                        logger -t fan-control "DEADBAND:  Forcing adjustment (current ${LAST_PWM}pwm < target ${target_speed}pwm)"
                        set_fan_speed $target_speed
                    else
                        logger -t fan-control "DEADBAND:  No change | DELTA=${temp_delta}℃"
                    fi
                fi
            fi
            ;;
    esac

    [[ -n "$state_transition" ]] && logger -t fan-control "STATE: ${state_transition}"
}

###[ MAIN EXECUTION ]##########################################################
[[ -f "$OPTIMAL_PWM_FILE" ]] || {
    echo "$MIN_PWM" > "$OPTIMAL_PWM_FILE"
    logger -t fan-control "INIT: Created optimal PWM file with ${MIN_PWM}pwm"
}

OPTIMAL_PWM=$(cat "$OPTIMAL_PWM_FILE")
logger -t fan-control "START: Optimal=${OPTIMAL_PWM}pwm | Config: MIN=${MIN_TEMP}℃, MAX=${MAX_TEMP}℃, HYST=${HYSTERESIS}℃"

initial_temp=$(get_smoothed_temp)
if (( initial_temp >= FAN_ACTIVATION_TEMP )); then
    logger -t fan-control "COLDSTART: Initial temp ${initial_temp}℃ ≥ ${FAN_ACTIVATION_TEMP}℃"
    CURRENT_STATE=$STATE_ACTIVE
    set_fan_speed $OPTIMAL_PWM
else
    logger -t fan-control "COLDSTART: Initial temp ${initial_temp}℃ - Fans off"
    set_fan_speed 0
fi

declare -i loop_counter=0
while true; do
    update_fan_state

    (( loop_counter++ % 10 == 0 )) && {
        logger -t fan-control "STATUS: State=${CURRENT_STATE} | PWM=${LAST_PWM} | Temp=$(get_smoothed_temp)℃"
    }

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
SERVICE_FILE="/etc/systemd/system/fan-control.service"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=UCG-Max Adaptive Fan Controller
After=network.target

[Service]
Type=simple
ExecStart=/data/fan-control/fan-control.sh
Restart=always
RestartSec=5
LogRateLimitIntervalSec=86400  # 24h window
LogRateLimitBurst=10000       # Allow 10k logs/day

[Install]
WantedBy=multi-user.target
EOF

# Set permissions and activate
chmod +x /data/fan-control/fan-control.sh
chmod +x /data/fan-control/uninstall.sh

# Reload systemd configuration
systemctl daemon-reload

# Smart service management
if systemctl is-active --quiet fan-control.service; then
    echo "Service already running - performing hot update"
    systemctl restart fan-control.service
    echo "Service successfully updated and restarted"
else
    echo "Performing fresh installation"
    systemctl enable --now fan-control.service
fi

echo "Installation successful!"
echo "Configuration: nano /data/fan-control/config"
echo "Status check: journalctl -u fan-control.service -f"