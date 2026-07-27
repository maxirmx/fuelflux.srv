#!/bin/sh
set -eu

# Debian's /etc/ppp/ip-down passes the peer's ipparam as argument 6. Ignore
# other PPP connections that also run scripts from /etc/ppp/ip-down.d.
[ "${6:-}" = "sim800" ] || exit 0

PPP_INTERFACE="$1"
# Keep this value in sync with ppp/peers/sim800.template.
PPP_ROUTE_METRIC=700

if ! command -v ip >/dev/null 2>&1; then
  echo "sim800-route: ip command not found" >&2
  exit 1
fi

# The route might already have been removed as the interface went down.
ip -4 route del default dev "$PPP_INTERFACE" metric "$PPP_ROUTE_METRIC" \
  2>/dev/null || true
