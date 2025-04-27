# UCG-Max/Fibre Intelligent Fan Control

Advanced temperature management for Ubiquiti UCG-Max/Fibre devices running UniFi OS 4+

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
curl -sSL https://raw.githubusercontent.com/iceteaSA/ucg-max-fan-control/main/install.sh | sudo bash
```

### Using a Different Branch
If you want to install from a specific branch (e.g., for testing new features):

**Method 1: Direct URL**
```bash
# Replace 'dev' with your desired branch name
curl -sSL https://raw.githubusercontent.com/iceteaSA/ucg-max-fan-control/dev/install.sh | sudo bash
```

**Method 2: Environment Variable**
```bash
# Set the branch name via environment variable
FAN_CONTROL_BRANCH=dev curl -sSL https://raw.githubusercontent.com/iceteaSA/ucg-max-fan-control/main/install.sh | sudo bash
```

### Manual Installation
If you prefer to inspect the code before installation:
```bash
# Clone the repository
git clone https://github.com/iceteaSA/ucg-max-fan-control.git
cd ucg-max-fan-control

# Optionally checkout a specific branch
# git checkout dev

# Run the installer (you can also use FAN_CONTROL_BRANCH to override the branch)
sudo ./install.sh
# Or with a specific branch:
# sudo FAN_CONTROL_BRANCH=dev ./install.sh
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
                  # Note: Due to hardware limitations, actual PWM values may vary slightly from requested values

# Advanced Tuning
ALPHA=20          # Smoothing factor, lower values make the smoothed temp follow raw temp more closely (0-100 raw→smooth)
DEADBAND=1        # Temperature stability threshold (°C)
LEARNING_RATE=5   # Hourly PWM optimization step size
TAPER_MINS=90     # Cool-down duration (minutes)
CHECK_INTERVAL=15 # Temperature check frequency (seconds)

# You probably shouldn't touch this
FAN_PWM_DEVICE="/sys/class/hwmon/hwmon0/pwm1"
OPTIMAL_PWM_FILE="/data/fan-control/optimal_pwm"
```

> **Note**: The script automatically checks for missing configuration parameters and adds them with default values if they're not present in the config file. This ensures that all required parameters are always available, even if you've edited the config file manually.

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

# Configuration Management
CONFIG: Missing parameter detected: CHECK_INTERVAL
CONFIG: Updating configuration file with 1 missing parameters
CONFIG: Configuration file updated successfully

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
  $$PWM = MIN\_PWM + ((temp\_diff^2 \times (MAX\_PWM - MIN\_PWM)) / temp\_range^2)$$
  Where:  
  `temp_diff = current_temp - activation_temp`  
  `temp_range = MAX_TEMP - activation_temp`

- **Exponential Smoothing**:
  $$smoothed\_temp = (\alpha \times previous\_smooth) + ((100 - \alpha) \times raw\_temp) / 100$$
  (α configured via ALPHA parameter)

- **Adaptive Learning**:  
  Hourly adjusts optimal PWM based on thermal performance history

- **Hardware PWM Limitations**:  
  Due to device hardware limitations, the actual PWM values applied may differ from the requested values
  (e.g., setting 50 might result in ~48, or 100 might result in ~92)

## Maintenance
```bash
# Service Management
systemctl status fan-control.service   # Current state
systemctl restart fan-control.service  # Apply config changes

# Full Removal
/data/fan-control/uninstall.sh
```

## Project Structure
- **fan-control.sh**: The main script that monitors temperature and controls fan speed
- **install.sh**: Installation script that copies files and sets up the systemd service
  - Supports installation from different branches via the `FAN_CONTROL_BRANCH` environment variable
  - Automatically downloads required files if not found locally
- **uninstall.sh**: Script to remove the fan control system
- **fan-control.service**: Systemd service configuration

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
