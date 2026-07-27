#!/bin/sh
set -eu

# Debian's /etc/ppp/ip-up passes the peer's ipparam as argument 6. Ignore
# other PPP connections that also run scripts from /etc/ppp/ip-up.d.
[ "${6:-}" = "sim800" ] || exit 0

PPP_INTERFACE="$1"
# Keep this value in sync with ppp/peers/sim800.template.
PPP_ROUTE_METRIC=700

if ! command -v ip >/dev/null 2>&1; then
  echo "sim800-route: ip command not found" >&2
  exit 1
fi

# pppd 2.4.x refuses to add its default route when another default route
# already exists unless replacedefaultroute is enabled. Add/refresh only the
# SIM800 route here so the existing wlan0 route remains in place.
ip -4 route replace default dev "$PPP_INTERFACE" metric "$PPP_ROUTE_METRIC"
