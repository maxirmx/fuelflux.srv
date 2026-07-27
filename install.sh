#!/usr/bin/env bash
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: Please run as root (e.g. sudo ./install.sh --server user@host --remote-port 2222 --local-port 22)." >&2
  exit 1
fi

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
- This script installs SIM800 route hooks under /etc/ppp/ip-{up,down}.d.
- This script installs ppp/chatscripts/sim800.template to /etc/chatscripts/sim800.
- This script installs and enables rtc-i2c.service for a DS1307 on I2C bus 3.
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

if [[ ! -e "/dev/i2c-3" ]]; then
  echo "WARNING: /dev/i2c-3 does not exist right now. rtc-i2c.service requires it to initialize the DS1307." >&2
fi

MISSING_PACKAGES=()
[[ -x /usr/sbin/pppd ]] || MISSING_PACKAGES+=("ppp")
[[ -x /usr/bin/autossh ]] || MISSING_PACKAGES+=("autossh")
[[ -x /usr/sbin/resolvconf || -x /sbin/resolvconf ]] || MISSING_PACKAGES+=("resolvconf")
command -v ip >/dev/null 2>&1 || MISSING_PACKAGES+=("iproute2")
command -v hwclock >/dev/null 2>&1 || MISSING_PACKAGES+=("util-linux")
if ! command -v i2cget >/dev/null 2>&1 || ! command -v i2cset >/dev/null 2>&1; then
  MISSING_PACKAGES+=("i2c-tools")
fi

if (( ${#MISSING_PACKAGES[@]} > 0 )); then
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "ERROR: Missing dependencies: ${MISSING_PACKAGES[*]}. Install them manually; apt-get is not available." >&2
    exit 1
  fi

  echo "[1/11] Installing dependencies: ${MISSING_PACKAGES[*]}"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${MISSING_PACKAGES[@]}"
else
  echo "[1/11] Dependencies already installed (ppp, autossh, resolvconf, iproute2, util-linux, i2c-tools)"
fi

echo "[2/11] Configuring NetworkManager to use resolvconf"
NETWORKMANAGER_CONFIG="/etc/NetworkManager/NetworkManager.conf"

install -d -m 0755 "$(dirname "$NETWORKMANAGER_CONFIG")"
NETWORKMANAGER_CONFIG_TMP="$(mktemp "${NETWORKMANAGER_CONFIG}.XXXXXX")"

if [[ -f "$NETWORKMANAGER_CONFIG" ]]; then
  awk '
    BEGIN {
      in_main = 0
      main_seen = 0
      setting_written = 0
    }

    function write_setting() {
      if (in_main && !setting_written) {
        print "rc-manager=resolvconf"
        setting_written = 1
      }
    }

    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      write_setting()
      in_main = ($0 ~ /^[[:space:]]*\[main\][[:space:]]*$/)
      if (in_main) {
        main_seen = 1
      }
      print
      next
    }

    in_main && /^[[:space:]]*[#;]?[[:space:]]*rc-manager[[:space:]]*=/ {
      if (!setting_written) {
        print "rc-manager=resolvconf"
        setting_written = 1
      }
      next
    }

    { print }

    END {
      write_setting()
      if (!main_seen) {
        if (NR > 0) {
          print ""
        }
        print "[main]"
        print "rc-manager=resolvconf"
      }
    }
  ' "$NETWORKMANAGER_CONFIG" > "$NETWORKMANAGER_CONFIG_TMP"
else
  printf '[main]\nrc-manager=resolvconf\n' > "$NETWORKMANAGER_CONFIG_TMP"
fi

install -m 0644 "$NETWORKMANAGER_CONFIG_TMP" "$NETWORKMANAGER_CONFIG"
rm -f "$NETWORKMANAGER_CONFIG_TMP"

# Ensure resolvconf has created its runtime resolver before switching /etc/resolv.conf.
if command -v resolvconf >/dev/null 2>&1; then
  resolvconf -u
fi
if [[ ! -e "/run/resolvconf/resolv.conf" ]]; then
  echo "ERROR: /run/resolvconf/resolv.conf not found after resolvconf -u; refusing to replace /etc/resolv.conf." >&2
  exit 1
fi
ln -sfn "/run/resolvconf/resolv.conf" "/etc/resolv.conf"

if systemctl is-active --quiet NetworkManager.service; then
  if ! systemctl reload NetworkManager.service; then
    systemctl kill --kill-who=main --signal=HUP NetworkManager.service
  fi
fi

echo "[3/11] Installing systemd units into: $UNIT_DIR"
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

RTC_I2C_SRC="systemd/rtc-i2c.service"
RTC_I2C_DST="$UNIT_DIR/rtc-i2c.service"
install -m 0644 "$RTC_I2C_SRC" "$RTC_I2C_DST"

chmod 0644 "$SIM800_DST" "$AUTOSSH_DST" "$GSM_WATCHDOG_SERVICE_DST" "$GSM_WATCHDOG_TIMER_DST" "$RTC_I2C_DST"

echo "[4/11] Installing helper scripts"
install -d "/usr/local/bin"
install -m 0755 "scripts/gsm-watchdog.sh" "/usr/local/bin/gsm-watchdog.sh"
install -m 0755 "scripts/rtc-i2c-setup.sh" "/usr/local/bin/rtc-i2c-setup.sh"

echo "[5/11] Installing PPP configuration"
install -d "/etc/ppp/peers" "/etc/ppp/ip-up.d" "/etc/ppp/ip-down.d"
install -m 0644 "ppp/peers/sim800.template" "/etc/ppp/peers/sim800"
install -m 0755 "scripts/sim800-route-up.sh" "/etc/ppp/ip-up.d/90-sim800-route"
install -m 0755 "scripts/sim800-route-down.sh" "/etc/ppp/ip-down.d/90-sim800-route"

echo "[6/11] Installing chat script"
install -d "/etc/chatscripts"
install -m 0644 "ppp/chatscripts/sim800.template" "/etc/chatscripts/sim800"

echo "[7/11] Reloading systemd"
systemctl daemon-reload

echo "[8/11] Enabling services"
systemctl enable sim800.service
systemctl enable autossh-ppp.service
systemctl enable gsm-watchdog.timer
systemctl enable rtc-i2c.service

echo "[9/11] Showing unit summary"
systemctl cat sim800.service | sed -n '1,120p' || true
echo "----"
systemctl cat autossh-ppp.service | sed -n '1,160p' || true
echo "----"
systemctl cat gsm-watchdog.service | sed -n '1,120p' || true
echo "----"
systemctl cat gsm-watchdog.timer | sed -n '1,120p' || true
echo "----"
systemctl cat rtc-i2c.service | sed -n '1,120p' || true

if [[ "$NO_START" == "1" ]]; then
  echo "[10/11] Skipping start (--no-start)."
  echo "Done. Reboot or start manually:"
  echo "  systemctl start sim800"
  echo "  systemctl start autossh-ppp"
  echo "  systemctl start gsm-watchdog.timer"
  echo "  systemctl start rtc-i2c"
  exit 0
fi

echo "[10/11] Starting services"
systemctl restart rtc-i2c.service
systemctl restart sim800.service
systemctl restart autossh-ppp.service
systemctl restart gsm-watchdog.timer

echo "[11/11] Completed installation"
echo
echo "Done."
echo "Check status:"
echo "  systemctl status sim800"
echo "  systemctl status autossh-ppp"
echo "  systemctl status gsm-watchdog.timer"
echo "  systemctl status rtc-i2c"
echo "  journalctl -u gsm-watchdog -b"
echo "  journalctl -u sim800 -b"
echo "  journalctl -u autossh-ppp -b"
echo "  journalctl -u rtc-i2c -b"
