#!/bin/sh
set -eu

# Debian's /etc/ppp/ip-down passes the peer's ipparam as argument 6. Ignore
# other PPP connections that also run scripts from /etc/ppp/ip-down.d.
[ "${6:-}" = "sim800" ] || exit 0

PPP_INTERFACE="$1"

ip -4 route del 77.88.8.88 dev "$PPP_INTERFACE" 2>/dev/null || true
ip -4 route del 77.88.8.2 dev "$PPP_INTERFACE" 2>/dev/null || true
