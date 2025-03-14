# UCG-Max Intelligent Fan Control

Advanced temperature management for Ubiquiti UCG-Max devices running UniFi OS 4+

## Features
- 🛠️ **Four Operational States**: OFF/TAPER/LINEAR/EMERGENCY
- 📁 **External Configuration**: Modify settings without editing core script
- 📊 **Adaptive Learning**: Automatically optimizes fan speeds over time
- 🛡️ **Safety Features**: Gradual speed changes, hardware validation, PID locking
- 📈 **Detailed Logging**: Full operational history via systemd journal

## Installation
```bash
curl -sSL https://raw.githubusercontent.com/iceteaSA/ucg-max-fan-control/main/install.sh | sh
```

## Configuration
Edit `/data/fan-control/config`:
```bash
# Temperature Settings
MIN_TEMP=60    # Base threshold (°C)
HYSTERESIS=5   # Activation buffer (°C)
MAX_TEMP=85    # Emergency threshold (°C)

# Fan Behavior
MIN_PWM=55     # Minimum active speed (0-255)
MAX_PWM=255    # Maximum speed (0-255)
TAPER_MINS=90  # Cool-down duration (minutes)
CHECK_INTERVAL=15  # Temperature check frequency (seconds)

# Advanced
MAX_PWM_STEP=25  # Maximum speed change per adjustment
```

Apply changes:
```bash
systemctl restart fan-control.service
```

## Key Operations
| State       | Temperature Range    | Behavior                          |
|-------------|----------------------|-----------------------------------|
| **OFF**     | <65°C (60+5)         | Fan completely disabled           |
| **TAPER**   | Cooling period       | 55 PWM for configured minutes     |
| **LINEAR**  | 65°C - 85°C          | Proportional speed adjustment     |
| **EMERGENCY**| >85°C              | Instant full speed (255 PWM)      |

## Maintenance
```bash
# Live monitoring
journalctl -u fan-control.service -f
# Show last 50 entries
journalctl -u fan-control.service -n 50

# Service management
systemctl status fan-control.service  # Current state
systemctl restart fan-control.service # Apply config changes

# Full removal
/data/fan-control/uninstall.sh
```

## Credits & Acknowledgments
- **Heuristic Control Logic**: [Covert-Agenda](https://www.reddit.com/user/Covert-Agenda/)
- **State Implementation**: fraction995
- **Initial Research**: [UCG-Max Thermal Thread](https://www.reddit.com/r/Ubiquiti/comments/1fr8xyt/)
- **Maintenance Patterns**: SierraSoftworks service templates

[Support Development ☕](https://ko-fi.com/H2H719VB0U)

---

**Disclaimer**: Community project - Not affiliated with Ubiquiti Inc.  
**Compatibility**: Verified on UniFi OS 4.0.0+ (UCG-Max)  
**License**: MIT
