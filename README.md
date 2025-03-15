# UCG-Max Intelligent Fan Control

Advanced temperature management for Ubiquiti UCG-Max devices running UniFi OS 4+

## Features
- 🎛️ **Four Operational States**: 
  - **OFF**: Fan disabled (temp < activation threshold)
  - **TAPER**: Post-cooling minimum speed period
  - **ACTIVE**: Quadratic response curve (temp ≥ activation threshold)
  - **EMERGENCY**: Immediate full speed (255 PWM) (critical temps)
- 🚨 **Emergency Override**: Instant full speed at critical temps
- 📈 **Quadratic Response**: Progressive cooling curve for optimal noise/performance
- 🧠 **Adaptive Learning**: Automatic PWM optimization
- 📉 **Exponential Smoothing**: Noise-resistant temperature tracking
- 🛡️ **Safety Systems**: Speed limits, thermal protection, hardware validation

## Installation
```bash
curl -sSL https://raw.githubusercontent.com/iceteaSA/ucg-max-fan-control/main/install.sh | sh
```

## Configuration
Edit `/data/fan-control/config`:
```bash
# Core Thresholds
MIN_TEMP=60            # Base threshold (°C)
MAX_TEMP=85            # Critical temperature (°C)
HYSTERESIS=5           # Temperature buffer (°C)

# Fan Behavior
MIN_PWM=91        # Minimum active speed (0-255)
MAX_PWM=255       # Maximum speed (0-255)
MAX_PWM_STEP=25   # Maximum speed change per adjustment

# Advanced Tuning
ALPHA=40          # Smoothing factor, lower values make the fan curve more aggressive and vice versa (0-100 raw→smooth)
DEADBAND=1        # Temperature stability threshold (°C)
LEARNING_RATE=5   # Hourly PWM optimization step size
TAPER_MINS=90     # Cool-down duration (minutes)
CHECK_INTERVAL=15 # Temperature check frequency (seconds)

# You probably shouldn't touch this
FAN_PWM_DEVICE="/sys/class/hwmon/hwmon0/pwm1"
OPTIMAL_PWM_FILE="/data/fan-control/optimal_pwm"
```

Apply changes:
```bash
systemctl restart fan-control.service
```

## Operational Overview
| State       | Trigger Condition          | Behavior                          |
|-------------|----------------------------|-----------------------------------|
| **OFF**     | <65°C (60+5)               | Fan disabled                      |
| **TAPER**   | Cooling period             | Minimum speed for configured mins |
| **ACTIVE**  | 65°C - 85°C                | Quadratic speed response          |
| **EMERGENCY**| >85°C                     | Immediate full speed (255 PWM)    |

## Monitoring & Logging
Key operational signals:
```log
# Temperature Monitoring
TEMP: raw=68℃ smooth=65℃ delta=-3℃

# Speed Calculations
CALC: temp_diff=5℃ range=20℃ speed=100pwm

# State Transitions
STATE: OFF→ACTIVE (67℃ ≥ 65℃)
STATE: ACTIVE→TAPER (59℃ ≤ 60℃)

# Speed Changes
SET: 55→80pwm | Reason: Ramp-up limited: 55→80pwm

# Learning System
LEARNING: 80→75pwm (-5 current 75pwm < optimal 80pwm)

# System Status
STATUS: State=ACTIVE | PWM=120 | Temp=72℃
```

View logs with:
```bash
journalctl -u fan-control.service -f          # Live monitoring
journalctl -u fan-control.service --since "10 minutes ago"  # Recent history
```

## Technical Implementation
- **Quadratic Response Curve**:
  ```math
  PWM = MIN_PWM + ((temp_diff² × (MAX_PWM - MIN_PWM)) / temp_range²)
  ```
  Where:  
  `temp_diff = current_temp - activation_temp`  
  `temp_range = MAX_TEMP - activation_temp`

- **Exponential Smoothing**:
  ```math
  smoothed_temp = (α × previous_smooth) + ((100 - α) × raw_temp) / 100
  ```
  (α configured via ALPHA parameter)

- **Adaptive Learning**:  
  Hourly adjusts optimal PWM based on thermal performance history

## Maintenance
```bash
# Service Management
systemctl status fan-control.service   # Current state
systemctl restart fan-control.service  # Apply config changes

# Full Removal
/data/fan-control/uninstall.sh
```

## Credits & Acknowledgments
- **Thermal Research**: [UCG-Max Thermal Thread](https://www.reddit.com/r/Ubiquiti/comments/1fr8xyt/)
- **System Integration**: SierraSoftworks service patterns
- **State Implementation**: fraction995
- **Control Logic**: [Covert-Agenda](https://www.reddit.com/user/Covert-Agenda/)

[☕Buy me a coffee](https://ko-fi.com/H2H719VB0U)

---

**Disclaimer**: Community project - Not affiliated with Ubiquiti Inc.  
**Compatibility**: Verified on UniFi OS 4.0.0+ (UCG-Max)  
**License**: MIT
