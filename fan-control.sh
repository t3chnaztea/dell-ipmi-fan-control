#!/usr/bin/env bash
# dell-ipmi-fan-control
# Temperature-based fan speed control for Dell PowerEdge servers via IPMI.
#
# Reads a temperature sensor every INTERVAL seconds and sets fan speed
# according to a tiered curve. Works locally or against a remote iDRAC
# (IPMI over LAN).
#
# Safety: switches the BMC back to Dell automatic fan control on exit,
# on signal, or if a sensor read fails. You are responsible for choosing
# a curve that keeps your hardware cool.
#
# Usage:
#   fan-control.sh                 Run the control loop (default)
#   fan-control.sh list-sensors    Print all IPMI sensors and exit
#   fan-control.sh -h | --help     Show help
#
# Compatibility: PowerEdge 11G-13G (R310/R320/R420/R610/R620/R710/R720/
# R630/R730 and similar). iDRAC firmware on 14G+ (R640/R740) generally
# blocks the raw fan-control commands this script relies on.

set -euo pipefail

# --- Defaults (override via the config file or environment) -----------------
INTERVAL="${INTERVAL:-30}"            # seconds between readings
HYSTERESIS="${HYSTERESIS:-2}"         # degrees C buffer before stepping down
SENSOR_NAME="${SENSOR_NAME:-Temp}"    # IPMI sensor to read (see: list-sensors)
LOGFILE="${LOGFILE:-/var/log/fan-control.log}"
PIDFILE="${PIDFILE:-/var/run/fan-control.pid}"

# Remote iDRAC (IPMI over LAN). Leave IPMI_HOST empty to talk to the local BMC.
IPMI_HOST="${IPMI_HOST:-}"
IPMI_USER="${IPMI_USER:-root}"
IPMI_PASS="${IPMI_PASS:-}"

# Config file is sourced as Bash, so it can set scalars above, the CURVE
# array below, and the IPMI_* connection variables.
CONFIG_FILE="${FAN_CONTROL_CONFIG:-/etc/dell-ipmi-fan-control.conf}"
# shellcheck source=/dev/null
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# Fan speed curve: "temp_up:percent", ascending by temperature.
# At each reading the highest tier whose temp_up the sensor meets is used.
# Stepping DOWN requires the temp to fall below (temp_up - HYSTERESIS).
if [[ -z "${CURVE+x}" ]]; then
  CURVE=(
    "40:15"
    "50:20"
    "60:30"
    "68:50"
    "75:70"
    "80:100"
  )
fi

CURRENT_PERCENT=""

# --- Helpers ----------------------------------------------------------------
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOGFILE"
}

# ipmitool wrapper: local BMC, or remote iDRAC when IPMI_HOST is set.
ipmi() {
  if [[ -n "$IPMI_HOST" ]]; then
    # Hand the password to ipmitool via the IPMI_PASSWORD env var (-E) rather
    # than -P, so the BMC credential never appears in `ps`/argv while the
    # control loop is running.
    IPMI_PASSWORD="$IPMI_PASS" ipmitool -I lanplus -H "$IPMI_HOST" -U "$IPMI_USER" -E "$@"
  else
    ipmitool "$@"
  fi
}

set_fan_auto() {
  ipmi raw 0x30 0x30 0x01 0x01 > /dev/null 2>&1
  log "Restored Dell automatic fan control"
}

set_fan_manual() {
  ipmi raw 0x30 0x30 0x01 0x00 > /dev/null 2>&1
}

set_fan_speed() {
  local percent=$1 hex
  hex=$(printf '0x%02x' "$percent")
  ipmi raw 0x30 0x30 0x02 0xff "$hex" > /dev/null 2>&1
}

get_temp() {
  local raw
  raw=$(ipmi sensor reading "$SENSOR_NAME" 2>/dev/null | awk -F'|' '{print $2}' | tr -d ' ')
  # Reject empty / "na" / non-numeric readings; truncate any decimal portion.
  if [[ ! "$raw" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    return 1
  fi
  echo "${raw%.*}"
}

temp_to_percent() {
  local temp=$1
  local entry threshold percent result

  # Below the lowest tier -> lowest tier's percent.
  result="${CURVE[0]##*:}"

  # Highest tier whose threshold the temp meets wins.
  for (( i=${#CURVE[@]}-1; i>=0; i-- )); do
    entry="${CURVE[$i]}"
    threshold="${entry%%:*}"
    percent="${entry##*:}"
    if (( temp >= threshold )); then
      result=$percent
      break
    fi
  done

  # Hysteresis: don't step down until temp falls below (threshold - HYSTERESIS).
  if [[ -n "$CURRENT_PERCENT" ]] && (( result < CURRENT_PERCENT )); then
    for entry in "${CURVE[@]}"; do
      threshold="${entry%%:*}"
      percent="${entry##*:}"
      if (( percent == CURRENT_PERCENT )); then
        if (( temp >= threshold - HYSTERESIS )); then
          echo "$CURRENT_PERCENT"
          return
        fi
        break
      fi
    done
  fi

  echo "$result"
}

cleanup() {
  log "Shutting down, restoring auto fan control"
  set_fan_auto
  rm -f "$PIDFILE"
  exit 0
}

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

# --- Subcommands ------------------------------------------------------------
case "${1:-run}" in
  -h|--help)
    usage
    exit 0
    ;;
  list-sensors)
    ipmi sensor
    exit 0
    ;;
  run)
    ;;
  *)
    echo "Unknown command: $1" >&2
    usage >&2
    exit 1
    ;;
esac

# --- Main loop --------------------------------------------------------------
# Prevent duplicate instances.
if [[ -f "$PIDFILE" ]]; then
  old_pid=$(cat "$PIDFILE")
  if kill -0 "$old_pid" 2>/dev/null; then
    echo "Already running (PID $old_pid). Exiting."
    exit 1
  fi
  rm -f "$PIDFILE"
fi

echo $$ > "$PIDFILE"
trap cleanup SIGTERM SIGINT SIGHUP EXIT

log "Starting fan control (PID $$, sensor '$SENSOR_NAME', ${IPMI_HOST:-local})"

set_fan_manual
log "Manual fan control enabled"

while true; do
  temp=$(get_temp) || {
    log "FAILSAFE: cannot read sensor '$SENSOR_NAME', restoring auto mode"
    set_fan_auto
    CURRENT_PERCENT=""
    sleep "$INTERVAL"
    set_fan_manual 2>/dev/null || true
    continue
  }

  target=$(temp_to_percent "$temp")

  if [[ "$target" != "$CURRENT_PERCENT" ]]; then
    set_fan_speed "$target"
    log "${temp}C -> fan ${target}% (was ${CURRENT_PERCENT:-auto})"
    CURRENT_PERCENT=$target
  fi

  sleep "$INTERVAL"
done
