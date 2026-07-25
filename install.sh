#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  sudo ./install.sh --server user@host --remote-port 2222 --local-port 22 [options]

Required:
  --server        SSH user@host (e.g. root@example.com or user@example.com)
  --remote-port   Remote port for reverse tunnel (e.g. 2222)
  --local-port    Local port to expose on the device (usually 22)

Options:
  --unit-dir      systemd unit dir (default: /etc/systemd/system)
  --no-start      Only install + enable, do not start services now
  --help          Show help

Example:
  sudo ./install.sh --server user@example.com --remote-port 2222 --local-port 22

Notes:
- If you previously used /etc/rc.local to start pppd, disable/remove that line to avoid duplicates.
- This script installs ppp/peers/sim800.template to /etc/ppp/peers/sim800.
- This script installs ppp/chatscripts/sim800.template to /etc/chatscripts/sim800.
EOF
}

UNIT_DIR="/etc/systemd/system"
NO_START="0"
SSH_USERHOST=""
REMOTE_PORT=""
LOCAL_PORT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --unit-dir) UNIT_DIR="$2"; shift 2;;
    --server) SSH_USERHOST="$2"; shift 2;;
    --remote-port) REMOTE_PORT="$2"; shift 2;;
    --local-port) LOCAL_PORT="$2"; shift 2;;
    --no-start) NO_START="1"; shift 1;;
    --help|-h) usage; exit 0;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2;;
  esac
done

if [[ -z "$SSH_USERHOST" || -z "$REMOTE_PORT" || -z "$LOCAL_PORT" ]]; then
  echo "ERROR: --server, --remote-port, and --local-port are required." >&2
  usage
  exit 2
fi

if [[ ! "$REMOTE_PORT" =~ ^[0-9]+$ || ! "$LOCAL_PORT" =~ ^[0-9]+$ ]]; then
  echo "ERROR: ports must be integers." >&2
  exit 2
fi

if [[ ! -e "/dev/ttyS5" ]]; then
  echo "WARNING: /dev/ttyS5 does not exist right now. That's OK at install time, but sim800.service will wait for it at boot." >&2
fi

MISSING_PACKAGES=()
[[ -x /usr/sbin/pppd ]] || MISSING_PACKAGES+=("ppp")
[[ -x /usr/bin/autossh ]] || MISSING_PACKAGES+=("autossh")

if (( ${#MISSING_PACKAGES[@]} > 0 )); then
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "ERROR: Missing dependencies: ${MISSING_PACKAGES[*]}. Install them manually; apt-get is not available." >&2
    exit 1
  fi

  echo "[1/10] Installing dependencies: ${MISSING_PACKAGES[*]}"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${MISSING_PACKAGES[@]}"
else
  echo "[1/10] Dependencies already installed (ppp, autossh)"
fi

echo "[2/10] Installing systemd units into: $UNIT_DIR"
install -d "$UNIT_DIR"

# sim800.service
SIM800_SRC="systemd/sim800.service"
SIM800_DST="$UNIT_DIR/sim800.service"
install -m 0644 "$SIM800_SRC" "$SIM800_DST"

# autossh-ppp.service
AUTOSSH_SRC="systemd/autossh-ppp.service"
AUTOSSH_DST="$UNIT_DIR/autossh-ppp.service"
sed \
  -e "s|@SSH_USERHOST@|${SSH_USERHOST}|g" \
  -e "s|@REMOTE_PORT@|${REMOTE_PORT}|g" \
  -e "s|@LOCAL_PORT@|${LOCAL_PORT}|g" \
  "$AUTOSSH_SRC" > "$AUTOSSH_DST"

GSM_WATCHDOG_SERVICE_SRC="systemd/gsm-watchdog.service"
GSM_WATCHDOG_SERVICE_DST="$UNIT_DIR/gsm-watchdog.service"
install -m 0644 "$GSM_WATCHDOG_SERVICE_SRC" "$GSM_WATCHDOG_SERVICE_DST"

GSM_WATCHDOG_TIMER_SRC="systemd/gsm-watchdog.timer"
GSM_WATCHDOG_TIMER_DST="$UNIT_DIR/gsm-watchdog.timer"
install -m 0644 "$GSM_WATCHDOG_TIMER_SRC" "$GSM_WATCHDOG_TIMER_DST"

chmod 0644 "$SIM800_DST" "$AUTOSSH_DST" "$GSM_WATCHDOG_SERVICE_DST" "$GSM_WATCHDOG_TIMER_DST"

echo "[3/10] Installing GSM watchdog script"
install -d "/usr/local/bin"
install -m 0755 "scripts/gsm-watchdog.sh" "/usr/local/bin/gsm-watchdog.sh"

echo "[4/10] Installing PPP peer file"
install -d "/etc/ppp/peers"
install -m 0644 "ppp/peers/sim800.template" "/etc/ppp/peers/sim800"

echo "[5/10] Installing chat script"
install -d "/etc/chatscripts"
install -m 0644 "ppp/chatscripts/sim800.template" "/etc/chatscripts/sim800"

echo "[6/10] Reloading systemd"
systemctl daemon-reload

echo "[7/10] Enabling services"
systemctl enable sim800.service
systemctl enable autossh-ppp.service
systemctl enable gsm-watchdog.timer

echo "[8/10] Showing unit summary"
systemctl cat sim800.service | sed -n '1,120p' || true
echo "----"
systemctl cat autossh-ppp.service | sed -n '1,160p' || true
echo "----"
systemctl cat gsm-watchdog.service | sed -n '1,120p' || true
echo "----"
systemctl cat gsm-watchdog.timer | sed -n '1,120p' || true

if [[ "$NO_START" == "1" ]]; then
  echo "[9/10] Skipping start (--no-start)."
  echo "Done. Reboot or start manually:"
  echo "  systemctl start sim800"
  echo "  systemctl start autossh-ppp"
  echo "  systemctl start gsm-watchdog.timer"
  exit 0
fi

echo "[9/10] Starting services"
systemctl restart sim800.service
systemctl restart autossh-ppp.service
systemctl restart gsm-watchdog.timer

echo "[10/10] Completed installation"
echo
echo "Done."
echo "Check status:"
echo "  systemctl status sim800"
echo "  systemctl status autossh-ppp"
echo "  systemctl status gsm-watchdog.timer"
echo "  journalctl -u gsm-watchdog -b"
echo "  journalctl -u sim800 -b"
echo "  journalctl -u autossh-ppp -b"
