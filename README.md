# UCG-Max Dynamic Fan Control

Temperature-based fan control solution for Ubiquiti UCG-Max devices running UniFi OS 4+.

## Features
- 🎛️ Dynamic PWM control (0-255 range)
- 🌡️ Temperature-based fan curve (60-85°C range)
- ⚙️ Configurable base speed and polling interval
- 🔄 Automatic service recovery
- 📦 Self-contained installation

## Installation
```bash
curl -sSL https://raw.githubusercontent.com/iceteaSA/ucg-max-fan-control/main/install.sh | sh
```

## Usage
The service starts automatically after installation. It will:
- Maintain base fan speed (PWM 91) below 60°C
- Ramp up linearly from 91-255 PWM between 60-85°C
- Apply maximum cooling (255 PWM) above 85°C
- Check temperature every 15 seconds

## Configuration
Edit `/data/fan-control/fan-control.sh` to modify:
```bash
BASE_PWM=91    # Quiet operation speed (0-255)
MIN_TEMP=60    # Start ramping up from this temp (°C)
MAX_TEMP=85    # Full speed temperature (°C)
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

## Support
If you want to,throw some cents my way:

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/H2H719VB0U)
---

**Note**: Not affiliated with Ubiquiti Inc.  
**Compatibility**: Tested on UniFi OS 4.0.0+  
**License**: MIT
