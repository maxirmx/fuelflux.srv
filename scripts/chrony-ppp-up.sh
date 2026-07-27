#!/bin/sh
set -eu

# Debian's /etc/ppp/ip-up passes the peer's ipparam as argument 6. Ignore
# other PPP connections that also run scripts from /etc/ppp/ip-up.d.
[ "${6:-}" = "sim800" ] || exit 0

PPP_INTERFACE="$1"

if ! command -v ip >/dev/null 2>&1; then
  echo "chrony-ppp: ip command not found" >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "chrony-ppp: systemctl command not found" >&2
  exit 1
fi

# Keep these endpoints reachable through SIM800 and restart Chrony after the
# PPP-specific routes are available.
ip -4 route replace 77.88.8.88 dev "$PPP_INTERFACE"
ip -4 route replace 77.88.8.2 dev "$PPP_INTERFACE"
systemctl restart chrony.service
