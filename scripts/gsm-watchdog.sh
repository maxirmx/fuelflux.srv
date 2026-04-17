#!/bin/bash

DEV=/dev/ttyS5
IF=ppp0

# Use Yandex DNS (stable + reachable in your region)
TARGET=77.88.8.8

STATE_FILE=/run/gsm-watchdog.state
MAX_FAILS=3

log() {
    logger -t gsm-watchdog "$1"
}

# --- load state ---
FAILS=0
if [ -f "$STATE_FILE" ]; then
    FAILS=$(cat "$STATE_FILE")
fi

FAILS=$((FAILS + 1))

# --- 1. PPP interface exists ---
if ! ip link show "$IF" > /dev/null 2>&1; then
    log "PPP missing (fail $FAILS/$MAX_FAILS)"
    echo "$FAILS" > "$STATE_FILE"
    [ "$FAILS" -ge "$MAX_FAILS" ] && systemctl restart sim800
    exit 1
fi

# --- 2. PPP has IP ---
IP=$(ip -4 addr show "$IF" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
if [ -z "$IP" ]; then
    log "PPP no IP (fail $FAILS/$MAX_FAILS)"
    echo "$FAILS" > "$STATE_FILE"
    [ "$FAILS" -ge "$MAX_FAILS" ] && systemctl restart sim800
    exit 1
fi

# --- 3. Connectivity test ---
ping -I "$IF" -c 2 -W 3 "$TARGET" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    log "PPP no connectivity via $TARGET (fail $FAILS/$MAX_FAILS)"
    echo "$FAILS" > "$STATE_FILE"
    [ "$FAILS" -ge "$MAX_FAILS" ] && systemctl restart sim800
    exit 1
fi

# --- 4. Optional modem check (non-invasive) ---
# Only check if everything else is OK
echo -e "AT\r" > "$DEV"
REPLY=$(timeout 2 cat "$DEV" | head -n 1)

if [[ "$REPLY" != *"OK"* ]]; then
    log "SIM800 not responding (fail $FAILS/$MAX_FAILS)"
    echo "$FAILS" > "$STATE_FILE"
    [ "$FAILS" -ge "$MAX_FAILS" ] && systemctl restart sim800
    exit 1
fi

# --- SUCCESS ---
echo 0 > "$STATE_FILE"
log "OK (IP=$IP)"

exit 0
