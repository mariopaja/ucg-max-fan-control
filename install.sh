#!/bin/bash
set -e

# Create directory for fan control
mkdir -p /data/fan-control

# Install fan control script with three-state logic
cat > /data/fan-control/fan-control.sh <<'EOF'
#!/bin/bash
###############################################################################
# fancontrol.sh
#
# Comprehensive fan control with minimal PWM toggling and intuitive behaviour:
# 1. Rolling average temperature (last 2 minutes).
# 2. Three states to reduce frequent 0 ↔ nonzero toggles:
#    - OFF: Fan is at 0 PWM.
#    - TAPER: Fan is kept at MIN_PWM for FAN_TAPER_MINS if we have just dropped
#      below MIN_TEMP from above (LINEAR).
#    - LINEAR: Between MIN_TEMP and MAX_TEMP, fan scales linearly from MIN_PWM
#      to MAX_PWM. Above MAX_TEMP, fan is forced to MAX_PWM.
# 3. On initial startup: if avg temp is < MIN_TEMP, remain OFF. If ≥ MIN_TEMP,
#    go straight to LINEAR scaling.
# 4. Logs every PWM change via `logger`, showing the new PWM and the current
#    rolling average temperature.
###############################################################################

############################################
# USER CONFIGURATION
############################################

# Temperature thresholds (°C)
MIN_TEMP=65
MAX_TEMP=85

# Fan PWM values
MIN_PWM=55
MAX_PWM=255

# Minutes to keep fan at MIN_PWM after dropping below MIN_TEMP
FAN_TAPER_MINS=90

# Rolling average window (seconds)
AVG_WINDOW=120

# Interval between checks (seconds)
CHECK_INTERVAL=15

# Path to fan PWM device
FAN_PWM_DEVICE="/sys/class/hwmon/hwmon0/pwm1"

# Command to read CPU/system temperature
GET_TEMP_CMD="ubnt-systool cputemp | awk '{print int(\$1)}'"

############################################
# INTERNAL VARIABLES
############################################

# We store recent temperature readings in an array of "timestamp,temp"
TEMP_LOG=()

# Track the current PWM (to log only on change)
CURRENT_PWM=-1

# Taper tracking
TAPER_START=0   # time we entered TAPER state

# States
STATE_OFF=0
STATE_TAPER=1
STATE_LINEAR=2

# Current state variable
CURRENT_STATE=-1

############################################
# FUNCTIONS
############################################

# Returns current temperature as an integer (fallback: 65)
get_current_temp() {
  t=$(bash -c "$GET_TEMP_CMD" 2>/dev/null)
  echo "${t:-65}"
}

# Updates TEMP_LOG (removing data older than AVG_WINDOW)
# and returns the average of the remaining values.
get_rolling_average_temp() {
  now=$(date +%s)
  sum=0
  count=0

  # Keep only entries within the last AVG_WINDOW seconds
  updated=()
  for entry in "${TEMP_LOG[@]}"; do
    ts=${entry%%,*}
    if (( now - ts <= AVG_WINDOW )); then
      updated+=("$entry")
    fi
  done
  TEMP_LOG=("${updated[@]}")

  # Compute average
  for entry in "${TEMP_LOG[@]}"; do
    val=${entry#*,}
    sum=$(( sum + val ))
    ((count++))
  done

  if (( count == 0 )); then
    echo 0
  else
    echo $(( sum / count ))
  fi
}

# Write new PWM if different from the current setting, and log the change
set_fan_pwm() {
  new_pwm=$1
  if [ "$new_pwm" -ne "$CURRENT_PWM" ]; then
    echo "$new_pwm" > "$FAN_PWM_DEVICE" 2>/dev/null
    CURRENT_PWM=$new_pwm
    avg_temp=$(get_rolling_average_temp)
    logger -t fan-control "Temp=${avg_temp} PWM=${new_pwm}"
  fi
}

# Transitions to a new state and logs it (optionally set an initial PWM)
transition_state() {
  new_state=$1
  CURRENT_STATE=$new_state
}

# Calculates the fan PWM in LINEAR mode for a given avg_temp
calc_linear_pwm() {
  local avg_temp=$1
  local temp_range=$(( MAX_TEMP - MIN_TEMP ))
  local diff=$(( avg_temp - MIN_TEMP ))
  local pwm_range=$(( MAX_PWM - MIN_PWM ))
  local pwm_val=$MIN_PWM

  if (( temp_range > 0 )); then
    pwm_val=$(( MIN_PWM + diff * pwm_range / temp_range ))
  fi

  if (( pwm_val < MIN_PWM )); then
    pwm_val=$MIN_PWM
  elif (( pwm_val > MAX_PWM )); then
    pwm_val=$MAX_PWM
  fi

  echo "$pwm_val"
}

############################################
# MAIN LOGIC
############################################

# 1) First step: read temperature & set initial state
init_temp=$(get_current_temp)
now=$(date +%s)
TEMP_LOG+=( "${now},${init_temp}" )
avg_temp=$(get_rolling_average_temp)

if (( avg_temp < MIN_TEMP )); then
  # Start in OFF state
  transition_state "$STATE_OFF"
  set_fan_pwm 0
else
  # Start in LINEAR state
  transition_state "$STATE_LINEAR"
  pwm_val=$(calc_linear_pwm "$avg_temp")
  set_fan_pwm "$pwm_val"
fi

# 2) Main loop
while true; do
  now=$(date +%s)
  current_temp=$(get_current_temp)
  TEMP_LOG+=( "${now},${current_temp}" )

  avg_temp=$(get_rolling_average_temp)

  case $CURRENT_STATE in
    ########################################
    # OFF STATE
    ########################################
    $STATE_OFF)
      # If the avg_temp is still below MIN_TEMP, remain off
      if (( avg_temp < MIN_TEMP )); then
        set_fan_pwm 0
      else
        # We crossed MIN_TEMP => go LINEAR
        transition_state "$STATE_LINEAR"
        pwm_val=$(calc_linear_pwm "$avg_temp")
        set_fan_pwm "$pwm_val"
      fi
      ;;

    ########################################
    # TAPER STATE
    ########################################
    $STATE_TAPER)
      # If we have risen above MIN_TEMP, go LINEAR
      if (( avg_temp >= MIN_TEMP )); then
        transition_state "$STATE_LINEAR"
        pwm_val=$(calc_linear_pwm "$avg_temp")
        set_fan_pwm "$pwm_val"
      else
        # We are below MIN_TEMP; check if the taper period has ended
        elapsed=$(( now - TAPER_START ))
        needed=$(( FAN_TAPER_MINS * 60 ))
        if (( elapsed >= needed )); then
          # Taper complete, turn fan off
          transition_state "$STATE_OFF"
          set_fan_pwm 0
        else
          # Remain in taper, keep fan at MIN_PWM
          set_fan_pwm "$MIN_PWM"
        fi
      fi
      ;;

    ########################################
    # LINEAR STATE
    ########################################
    $STATE_LINEAR)
      if (( avg_temp < MIN_TEMP )); then
        # Begin taper
        transition_state "$STATE_TAPER"
        TAPER_START=$now
        set_fan_pwm "$MIN_PWM"
      elif (( avg_temp > MAX_TEMP )); then
        # Above maximum => full speed
        set_fan_pwm "$MAX_PWM"
      else
        # Scale linearly
        pwm_val=$(calc_linear_pwm "$avg_temp")
        set_fan_pwm "$pwm_val"
      fi
      ;;

  esac

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