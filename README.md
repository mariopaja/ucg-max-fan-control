# UCG-Max Dynamic Fan Control

Temperature-based fan control solution for Ubiquiti UCG-Max devices running UniFi OS 4+.

## Features
- 🎛️ Dynamic PWM control (0-255 range)
- 🌡️ Temperature-based fan curve with three-state logic (OFF, TAPER, LINEAR)
- ⏳ Rolling average temperature calculation (2-minute window)
- ⏲️ Configurable taper period to minimize fan toggling
- ⚙️ Configurable base speed, thresholds, and polling interval
- 🔄 Automatic service recovery
- 📦 Self-contained installation

## Installation
```bash
curl -sSL https://raw.githubusercontent.com/iceteaSA/ucg-max-fan-control/main/install.sh | sh
```

## Usage
The service starts automatically after installation. It will:
- **OFF State**: Keep the fan off (0 PWM) when the average temperature is below 65°C.
- **TAPER State**: Maintain minimum fan speed (PWM 55) for 90 minutes after cooling below 65°C.
- **LINEAR State**: Ramp up fan speed linearly from 55-255 PWM between 65-85°C.
- Apply maximum cooling (255 PWM) above 85°C.
- Check temperature every 15 seconds.

## Configuration
Edit `/data/fan-control/fan-control.sh` to modify:
```bash
MIN_TEMP=65    # Start ramping up from this temp (°C)
MAX_TEMP=85    # Full speed temperature (°C)
MIN_PWM=55     # Minimum fan speed (0-255)
MAX_PWM=255    # Maximum fan speed (0-255)
FAN_TAPER_MINS=90  # Minutes to keep fan at MIN_PWM after cooling below MIN_TEMP
CHECK_INTERVAL=15  # Seconds between checks
```

Apply changes:
```bash
systemctl restart fan-control.service
```

## Uninstallation
```bash
# Using included script
/data/fan-control/uninstall.sh
```

## Verification
```bash
# Check service status
systemctl status fan-control.service

# View current PWM value
cat /sys/class/hwmon/hwmon0/pwm1

# Monitor live values
watch -n 0.5 "echo -n 'Temp: '; ubnt-systool cputemp; echo 'PWM: '$(cat /sys/class/hwmon/hwmon0/pwm1)"
```

## Credits
This project builds upon work from:
- [SierraSoftworks/tailscale-udm](https://github.com/SierraSoftworks/tailscale-udm) - Inspiration for persistent service installation methods
- [UCG-Max Temperature Control Reddit Post](https://www.reddit.com/r/Ubiquiti/comments/1fr8xyt/control_the_temperature_of_ucgmax/) - Initial PWM control research and implementation ideas
- **fraction995** - Enhanced three-state logic with rolling average and taper period

## Support
If you want to, throw some cents my way:

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/H2H719VB0U)

---

**Note**: Not affiliated with Ubiquiti Inc.  
**Compatibility**: Tested on UniFi OS 4.0.0+ with a UCG-Max  
**License**: MIT
