# UCG-Max Dynamic Fan Control

Temperature-based fan control solution for Ubiquiti UCG-Max devices running UniFi OS 4+.

## Features
- 🎛️ Four-state PWM control (OFF/TAPER/LINEAR/EMERGENCY)
- 🌡️ 2-minute rolling temperature average
- ⏲️ 90-minute cool-down period
- 🔄 Self-learning optimal speeds
- 🚨 Instant full-speed emergency override

## Installation
```bash
curl -sSL https://raw.githubusercontent.com/iceteaSA/ucg-max-fan-control/main/install.sh | sh
```

## Usage
The service auto-starts and handles:
- **OFF** (<65°C avg): Fan completely off
- **TAPER** (90min): Minimum speed after cooling
- **LINEAR** (65-85°C): Smart speed scaling
- **EMERGENCY** (>85°C): Full blast instantly

## Configuration
Edit `/data/fan-control/fan-control.sh`:
```bash
# Temperature logic
MIN_TEMP=60    # Base threshold (°C)
HYSTERESIS=5   # Buffer zone (°C) -> fan activates at 65°C (60+5)
MAX_TEMP=85    # Emergency threshold (°C)

# Fan behavior
MIN_PWM=55     # Minimum active speed
MAX_PWM=255    # Maximum speed
TAPER_DURATION=$((90*60))  # Cool-down period (seconds)
CHECK_INTERVAL=15          # Check every X seconds
```

Apply changes:
```bash
systemctl restart fan-control.service
```

## Uninstall
```bash
/data/fan-control/uninstall.sh
```

## Verify
```bash
# Check service
systemctl status fan-control.service
```

## Credits
- [Covert-Agenda](https://www.reddit.com/user/Covert-Agenda/) for heuristic control logic
- fraction995 for three-state implementation
- Initial research from [UCG-Max Reddit thread](https://www.reddit.com/r/Ubiquiti/comments/1fr8xyt/control_the_temperature_of_ucgmax/)

[☕ Buy me a coffee](https://ko-fi.com/H2H719VB0U)

---

**Note**: Unofficial project - Not affiliated with Ubiquiti  
**Compatibility**: UniFi OS 4.0.0+ on UCG-Max  
**License**: MIT
