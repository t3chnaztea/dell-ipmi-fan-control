# dell-ipmi-fan-control

Quiet your Dell PowerEdge. A small, dependency-light Bash daemon that reads a
temperature sensor over IPMI and drives the fans on a tiered curve, so an idle
server in a closet runs near-silent instead of at the BMC's noisy default.

Runs on the server itself, or remotely against an iDRAC over the network.

## Why

Dell's stock fan behavior is conservative and loud: many PowerEdge boxes idle
at 30%+ fan speed for no thermal reason, especially with non-Dell PCIe cards
(HBAs, NICs, GPUs) that trip the firmware's "unknown card, spin up" logic. This
script takes manual control, holds the fans low while temps are low, and ramps
them only when the chip actually heats up.

## ⚠️ Read this first

Manual fan control means **you** are responsible for keeping the hardware cool.
A bad curve can let a server overheat. This script mitigates that by:

- restoring Dell's automatic fan control on exit, on `SIGTERM`/`SIGINT`, and if
  a sensor read ever fails (failsafe), and
- ramping to 100% at the top tier.

Test it under load before you trust it, and keep the top tier aggressive.

## Compatibility

- **Works:** PowerEdge 11G–13G: R310, R320, R410, R420, R610, R620, R710,
  R720, R630, R730, T-series equivalents, and similar. These accept the raw
  IPMI fan commands used here.
- **Does not work:** Most 14G and newer (R640, R740, …). Recent iDRAC firmware
  blocks the `raw 0x30 0x30` fan commands. If `list-sensors` works but the fans
  never respond, that's almost certainly why.
- **Requires:** `ipmitool`, and Bash 4+. For remote use, "IPMI Over LAN"
  enabled in iDRAC.

This uses the well-known Dell raw commands:

| Action | Command |
|--------|---------|
| Manual fan mode | `raw 0x30 0x30 0x01 0x00` |
| Automatic fan mode | `raw 0x30 0x30 0x01 0x01` |
| Set fan speed (`NN` = hex %) | `raw 0x30 0x30 0x02 0xff 0xNN` |

## Install

```bash
sudo install -m 0755 fan-control.sh /usr/local/bin/fan-control.sh
sudo cp fan-control.conf.example /etc/dell-ipmi-fan-control.conf
sudo chmod 600 /etc/dell-ipmi-fan-control.conf   # if it holds an iDRAC password
```

Find your temperature sensor's name:

```bash
fan-control.sh list-sensors
```

Pick the right one (commonly `Temp`; dual-socket boxes expose two) and set
`SENSOR_NAME` in the config file.

### Run as a service (systemd)

```bash
sudo cp dell-ipmi-fan-control.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now dell-ipmi-fan-control
journalctl -u dell-ipmi-fan-control -f
```

`systemctl stop` restores Dell's automatic fan control automatically.

### Run on TrueNAS SCALE

TrueNAS has no persistent `/usr/local/bin` and no user systemd units. Drop the
script somewhere persistent (e.g. a dataset), then add a **Post-Init** script
in *System Settings → Advanced → Init/Shutdown Scripts* of type *Command*:

```
/mnt/pool/scripts/fan-control.sh &
```

The internal loop handles scheduling, so no cron entry is needed.

## Configuration

All settings live in `/etc/dell-ipmi-fan-control.conf` (or point
`FAN_CONTROL_CONFIG` elsewhere). See [`fan-control.conf.example`](fan-control.conf.example).

```bash
INTERVAL=30           # seconds between readings
HYSTERESIS=2          # °C buffer before stepping fans down
SENSOR_NAME="Temp"    # from `list-sensors`

CURVE=(
  "40:15"   # temp_up:percent, ascending
  "50:20"
  "60:30"
  "68:50"
  "75:70"
  "80:100"
)
```

At each reading the highest tier whose `temp_up` the sensor meets is applied.
Stepping **down** requires the temperature to fall below `temp_up - HYSTERESIS`,
which stops the fans hunting up and down at a tier boundary.

### Remote iDRAC

To drive a Dell from another machine instead of running on the server itself:

```bash
IPMI_HOST="192.0.2.10"
IPMI_USER="root"
IPMI_PASS="calvin"
```

Leave `IPMI_HOST` empty for local control.

## Operation

```bash
# Status / log
tail -f /var/log/fan-control.log

# Stop (restores auto fan mode)
sudo systemctl stop dell-ipmi-fan-control
# ...or, if started by hand:
kill "$(cat /var/run/fan-control.pid)"
```

## More tiny tools for home labs

Agent skills: [unifi](https://github.com/t3chnaztea/unifi-skills) · [home-assistant](https://github.com/t3chnaztea/home-assistant-skills) · [batocera](https://github.com/t3chnaztea/batocera-skills) · [psn](https://github.com/t3chnaztea/awesome-psn-skills) · [arr-stack](https://github.com/t3chnaztea/arr-stack-skills)  
Retro cabinet: [batocera-toolbox](https://github.com/t3chnaztea/batocera-toolbox) · [batocera-holidays](https://github.com/t3chnaztea/batocera-holidays)  
Home server: [plex-preroll-roulette](https://github.com/t3chnaztea/plex-preroll-roulette)  
PlayStation: [awesome-psnstats](https://github.com/t3chnaztea/awesome-psnstats)  
Desktop: [fastfetch-macos-gradient-hud](https://github.com/t3chnaztea/fastfetch-macos-gradient-hud)

## License

MIT. See [LICENSE](LICENSE).
