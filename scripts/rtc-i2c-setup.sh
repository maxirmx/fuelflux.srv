#!/usr/bin/env bash
set -euo pipefail

readonly I2C_BUS="3"
readonly I2C_ADDRESS="0x68"
readonly I2C_DEVICE_PATH="/sys/bus/i2c/devices/${I2C_BUS}-0068"
readonly I2C_NEW_DEVICE_PATH="/sys/class/i2c-adapter/i2c-${I2C_BUS}/new_device"
readonly RTC_DEVICE="/dev/rtc1"
readonly RTC_LINK="/dev/rtc"

require_command() {
  local command_name="$1"
  local command_path

  command_path="$(command -v "$command_name" || true)"
  if [[ -z "$command_path" ]]; then
    echo "ERROR: Required command not found: $command_name" >&2
    exit 1
  fi

  printf '%s\n' "$command_path"
}

I2CGET="$(require_command i2cget)"
I2CSET="$(require_command i2cset)"
HWCLOCK="$(require_command hwclock)"
LN="$(require_command ln)"
readonly I2CGET I2CSET HWCLOCK LN

i2c_force_args=()
if [[ -e "$I2C_DEVICE_PATH" ]]; then
  # A bound kernel driver owns the address, so i2c-tools requires --force.
  i2c_force_args=(-f)
fi

rtc_seconds="$("$I2CGET" "${i2c_force_args[@]}" -y "$I2C_BUS" "$I2C_ADDRESS" 0x00)"
if [[ ! "$rtc_seconds" =~ ^0x[[:xdigit:]]{2}$ ]]; then
  echo "ERROR: Unexpected DS1307 seconds register value: $rtc_seconds" >&2
  exit 1
fi

rtc_seconds_value=$((rtc_seconds))
initialize_rtc="0"
if (( (rtc_seconds_value & 0x80) != 0 )); then
  echo "DS1307 oscillator is stopped; clearing the clock-halt bit"
  "$I2CSET" "${i2c_force_args[@]}" -y "$I2C_BUS" "$I2C_ADDRESS" 0x00 0x00
  initialize_rtc="1"
fi

if [[ ! -e "$I2C_DEVICE_PATH" ]]; then
  if [[ ! -w "$I2C_NEW_DEVICE_PATH" ]]; then
    echo "ERROR: I2C adapter ${I2C_BUS} is unavailable: $I2C_NEW_DEVICE_PATH" >&2
    exit 1
  fi

  printf '%s\n' "ds1307 $I2C_ADDRESS" > "$I2C_NEW_DEVICE_PATH"
fi

for (( attempt = 1; attempt <= 10; attempt++ )); do
  [[ -e "$RTC_DEVICE" ]] && break
  sleep 0.2
done

if [[ ! -e "$RTC_DEVICE" ]]; then
  echo "ERROR: DS1307 did not create $RTC_DEVICE" >&2
  exit 1
fi

if [[ "$initialize_rtc" == "1" ]]; then
  echo "Initializing RTC from system time"
  "$HWCLOCK" -w -f "$RTC_DEVICE"
else
  echo "Restoring system time from RTC"
  "$HWCLOCK" -s -f "$RTC_DEVICE"
fi

"$LN" -sfn "$RTC_DEVICE" "$RTC_LINK"
