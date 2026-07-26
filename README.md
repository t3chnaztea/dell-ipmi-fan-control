# dell-ipmi-fan-control

Take manual control of the fans on a Dell PowerEdge over IPMI and run them on
your own temperature curve, so a server that lives in a home or an office is
near-silent at idle instead of sitting at the BMC's noisy default.

## Will this work on your server?

Answer this first. It decides whether the rest of the page is worth your time.

| Generation | Models | Works |
|---|---|---|
| 11G | R310, R410, R510, R610, R710, T310, T410 | Yes |
| 12G | R320, R420, R520, R620, R720, T320, T420 | Yes |
| 13G | R430, R530, R630, R730, T430, T630 | Yes |
| 14G and newer | R440, R640, R740, R650, R750 | **No** |

14G and newer iDRAC firmware blocks the raw fan commands this depends on.
There is no workaround in this repo. If you are on 14G+, your options are
iDRAC's own thermal profiles under **Configuration > System Settings >
Hardware Settings > Fans**, which is coarse, but it is what you have.

Check in ten seconds on hardware you already own:

```bash
ipmitool raw 0x30 0x30 0x01 0x00 && echo "manual mode accepted"
ipmitool raw 0x30 0x30 0x01 0x01   # and straight back to automatic
```

If the first command errors, your firmware has blocked it and nothing here
will help.

## Is a fan curve actually your problem?

A PowerEdge runs loud for three different reasons. This project fixes one of
them. Working out which one you have first will save you an afternoon.

**1. The BMC is simply conservative.** It idles around 30% for no thermal
reason, and it has done that since the day you got it. This is the case this
project is for: take manual control, run a lower curve.

**2. A non-Dell PCIe card is forcing a ramp.** Fit a third-party HBA, NIC, or
GPU and the firmware cannot read its thermals, so it applies a blanket cooling
response and holds the fans at a floor **regardless of temperature**. The tell
is fans pinned at a fixed speed while every sensor reads cool, starting the day
you added the card.

This script does not fix that one. There is a separate, widely circulated raw
iDRAC command that disables the third-party PCIe cooling response on some 13G
firmware. **I have not tested it and it is deliberately not wired into this
script**, so treat it as a lead rather than a recipe: search for "disable
third-party PCIe card default cooling response". If a manual curve does not
drop your noise, this is the most likely reason.

**3. Something is genuinely wrong.** A failing fan whining at full tilt, a heat
sink packed with dust, a hot room. Overriding the curve on a box that is hot
for a real reason is how hardware dies. Look at `ipmitool sdr type fan` and
your inlet temperature before reaching for software.

## What it does

A small Bash daemon: read one temperature sensor every 30 seconds, set a fan
percentage from a tiered curve you define. Runs on the server itself, or across
the network against a remote iDRAC.

The parts that are easy to get wrong, and are handled:

- **Hysteresis.** Stepping down requires the temperature to fall a couple of
  degrees *below* the tier boundary, so the fans do not hunt when you idle
  right on a threshold.
- **Failsafe.** Dell's automatic control is restored on exit, on
  `SIGTERM`/`SIGINT`, and if a sensor read fails. A dead sensor hands the fans
  back to the BMC and leaves them there until it reads again, rather than
  flapping between modes once per interval.
- **Preflight.** A missing `ipmitool`, an unreadable sensor name, or a
  malformed curve fails *before* the BMC is taken out of automatic mode, so a
  typo cannot leave your fans owned by a script that already died.

Requires `ipmitool` and Bash 4+. Nothing else.

## Read this first

Manual fan control means **you** are responsible for keeping the hardware cool.
A bad curve can cook a server. The failsafes above shrink the blast radius;
they do not transfer the responsibility. Test under sustained load before you
trust it, and keep the top tier aggressive.

## Install

```bash
sudo install -m 0755 fan-control.sh /usr/local/bin/fan-control.sh
sudo cp fan-control.conf.example /etc/dell-ipmi-fan-control.conf
sudo chmod 600 /etc/dell-ipmi-fan-control.conf   # if it holds an iDRAC password
```

Find your temperature sensor:

```bash
fan-control.sh list-sensors
```

Pick one (commonly `Temp`) and set `SENSOR_NAME` in the config file. Dual-socket
boxes expose two sensors under that same name; the hottest reading is the one
the curve is applied to.

### Run as a service (systemd)

```bash
sudo cp dell-ipmi-fan-control.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now dell-ipmi-fan-control
journalctl -u dell-ipmi-fan-control -f
```

`systemctl stop` restores Dell's automatic fan control.

### Run on TrueNAS SCALE

TrueNAS has no persistent `/usr/local/bin` and no user systemd units. Put the
script on a dataset, then add a **Post-Init** script under *System Settings >
Advanced > Init/Shutdown Scripts*, type *Command*:

```
/mnt/pool/scripts/fan-control.sh &
```

The loop schedules itself, so no cron entry is needed.

## Configuration

Everything lives in `/etc/dell-ipmi-fan-control.conf` (or point
`FAN_CONTROL_CONFIG` elsewhere). See
[`fan-control.conf.example`](fan-control.conf.example).

```bash
INTERVAL=30           # seconds between readings
HYSTERESIS=2          # degrees C buffer before stepping fans down
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

**That curve is tuned for a single-socket 12G box and is a starting point, not
a recommendation.** Dual sockets or high-TDP chips will sit a tier or two
higher at idle. Watch your own logs for a day and adjust rather than copying it
verbatim.

### Remote iDRAC

To drive a Dell from another machine instead of running on the server itself:

```bash
IPMI_HOST="192.0.2.10"
IPMI_USER="root"
IPMI_PASS="calvin"
```

Leave `IPMI_HOST` empty for local control. Needs "IPMI Over LAN" enabled in
iDRAC. The password reaches `ipmitool` through the environment, so it does not
show up in `ps` while the loop is running.

## Operation

```bash
tail -f /var/log/fan-control.log            # what it is doing
sudo systemctl stop dell-ipmi-fan-control   # stop (restores auto)
kill "$(cat /var/run/fan-control.pid)"      # ...if you started it by hand
```

## The raw commands

For anyone who would rather understand this than run it. These are the
well-known Dell raw IPMI commands, and there is nothing proprietary here:

| Action | Command |
|--------|---------|
| Manual fan mode | `raw 0x30 0x30 0x01 0x00` |
| Automatic fan mode | `raw 0x30 0x30 0x01 0x01` |
| Set fan speed (`NN` = hex %) | `raw 0x30 0x30 0x02 0xff 0xNN` |

The daemon is a loop around those three plus a sensor read. If the commands
were all you wanted, take them and skip the rest. What you would be
reimplementing is the hysteresis, the failsafe, and the preflight.

## More tiny tools for home labs

Agent skills: [unifi](https://github.com/t3chnaztea/unifi-skills) · [home-assistant](https://github.com/t3chnaztea/home-assistant-skills) · [batocera](https://github.com/t3chnaztea/batocera-skills) · [psn](https://github.com/t3chnaztea/awesome-psn-skills) · [arr-stack](https://github.com/t3chnaztea/arr-stack-skills)  
Retro cabinet: [batocera-toolbox](https://github.com/t3chnaztea/batocera-toolbox) · [batocera-holidays](https://github.com/t3chnaztea/batocera-holidays)  
Home server: [plex-preroll-roulette](https://github.com/t3chnaztea/plex-preroll-roulette)  
PlayStation: [awesome-psnstats](https://github.com/t3chnaztea/awesome-psnstats)  
Desktop: [fastfetch-macos-gradient-hud](https://github.com/t3chnaztea/fastfetch-macos-gradient-hud)

## License

MIT. See [LICENSE](LICENSE).

> Not affiliated with Dell. "PowerEdge" and "iDRAC" are used descriptively.
