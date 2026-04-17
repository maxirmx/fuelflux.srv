# SIM800 PPP -> AutoSSH (systemd) bundle

This bundle installs two systemd services to enforce the startup sequence:

`/dev/ttyS5` → `pppd call sim800` → `autossh` tunnel

## What you get

- `sim800.service`  
  Starts and supervises `pppd call sim800`, and waits for `/dev/ttyS5` to exist.

- `autossh-ppp.service`  
  Starts only after `sim800.service` is up, is bound to `sim800.service`, and waits for an IPv4 address on `ppp0`.

- `gsm-watchdog.service` + `gsm-watchdog.timer`  
  Runs every 30 seconds, checks `ppp0` + basic connectivity + modem AT response, and restarts `sim800` after 3 consecutive failures.

- `install.sh`  
  Copies units and watchdog script, applies tunnel settings, enables and starts services.

## Prerequisites

- `pppd` installed
- `autossh` installed
- Installer writes peer file to: `/etc/ppp/peers/sim800`
  - Source template: `ppp/peers/sim800.template`
- Installer writes chat script to: `/etc/chatscripts/sim800`
  - Source template: `ppp/chatscripts/sim800.template`

On Debian/Armbian:

```bash
sudo apt update
sudo apt install -y ppp autossh
```

## Install (recommended)

1) Unpack on the device:

```bash
tar -xzf sim800_ppp_autossh_bundle.tar.gz
cd sim800-ppp-autossh-bundle
```

2) Run installer (edit parameters as needed):

```bash
sudo ./install.sh \
  --server user@example.com \
  --remote-port 2222 \
  --local-port 22
```

Notes:
- The tunnel example uses a reverse tunnel `-R <remote-port>:localhost:<local-port>`.
- If you prefer a local tunnel (`-L`) or dynamic (`-D`), edit the unit after install.

## Status / logs

```bash
systemctl status sim800
systemctl status autossh-ppp
journalctl -u gsm-watchdog -b
journalctl -u gsm-watchdog.timer -b
journalctl -u sim800 -b
journalctl -u autossh-ppp -b
ip addr show ppp0
```

## If you previously used /etc/rc.local

Remove or comment out `pppd call sim800 &` to avoid duplicate `pppd` instances.

## Files

- `systemd/sim800.service`
- `systemd/autossh-ppp.service`
- `systemd/gsm-watchdog.service`
- `systemd/gsm-watchdog.timer`
- `scripts/gsm-watchdog.sh`
- `ppp/peers/sim800.template`
- `ppp/chatscripts/sim800.template`
- `install.sh`
