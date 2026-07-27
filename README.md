# SIM800 PPP -> AutoSSH (systemd) bundle

This bundle installs systemd services for the following startup sequence:

`/dev/ttyS5` → `pppd call sim800` → `autossh` tunnel

## What you get

- `sim800.service`  
  Starts and supervises `pppd call sim800`, and waits for `/dev/ttyS5` to exist.

- `autossh-ppp.service`  
  Starts only after `sim800.service` is up, is bound to `sim800.service`, and waits for an IPv4 address on `ppp0`.

- `gsm-watchdog.service` + `gsm-watchdog.timer`  
  Runs every 30 seconds, checks `ppp0` + basic connectivity + modem AT response, and restarts `sim800` after 3 consecutive failures.

- `rtc-i2c.service`
  Binds a DS1307 at address `0x68` on I2C bus 3 and exposes `/dev/rtc1`
  as `/dev/rtc`.

- `chrony.service`
  Synchronizes system time from stable NTP sources, tolerates GSM latency,
  and periodically copies synchronized system time back to the RTC.

- `install.sh`  
  Installs dependencies, configures DNS resolution, copies units and the
  helper scripts, applies tunnel settings, and enables and starts services.

## Network routing

The SIM800 peer uses `replacedefaultroute`, so `ppp0` replaces the existing
IPv4 default route while the PPP connection is active.

## RTC initialization and boot behavior

The installer enables `rtc-i2c.service` and installs `i2c-tools` when needed.
The setup script first waits up to 10 seconds for `/dev/i2c-3`, which handles
adapters that appear late during boot without requiring a systemd device unit.
On the first service start, it then:

1. Binds the `ds1307` driver to I2C bus 3 at address `0x68`.
2. Waits for `/dev/rtc1`.
3. Reads register `0x00` and checks the clock-halt bit.
4. If the oscillator is stopped, clears the bit and initializes the RTC from
   the current system time with `hwclock -w`.
5. Otherwise, restores system time from the RTC with `hwclock -s`.
6. Links `/dev/rtc` to `/dev/rtc1`.

This makes initialization safe on the first run: an RTC whose oscillator is
stopped cannot overwrite the current system time. Later boots restore time
from the running RTC.

## Chrony and RTC startup order

RTC setup runs before Chrony. This gives the system a plausible clock while
offline; Chrony then corrects it when an NTP source becomes reachable. The
Chrony dependency on `rtc-i2c.service` is soft, so an RTC failure does not
prevent network time synchronization.

The installed `/etc/chrony/chrony.conf` uses the VNIIFTRI, Russian NTP pool,
and Ubuntu NTP pool sources from issue #8. It enables fast correction during
the first three updates, permits higher GSM jitter, enables `rtcsync`, and
writes logs under `/var/log/chrony`.

After dependency installation, the installer verifies that both `chronyd` and
`chronyc` are executable. On Debian/Ubuntu it also verifies that `dpkg`
reports the `chrony` package as fully installed. Installation stops before
configuration changes if any of these checks fail.

The SIM800 PPP hooks add host routes for `77.88.8.88` and `77.88.8.2` through
the active PPP interface. Chrony is restarted after those routes are installed
and the routes are removed when that SIM800 connection goes down. The hooks
are scoped by `ipparam sim800`, so they ignore unrelated PPP connections.

## Prerequisites

- Installer writes peer file to: `/etc/ppp/peers/sim800`
  - Source template: `ppp/peers/sim800.template`
- Installer writes chat script to: `/etc/chatscripts/sim800`
  - Source template: `ppp/chatscripts/sim800.template`

On Debian/Armbian, `install.sh` automatically installs the `ppp`, `autossh`,
and `resolvconf` packages when they are missing. To install them manually
instead:

```bash
sudo apt update
sudo apt install -y ppp autossh resolvconf
```

The installer also enforces this NetworkManager DNS configuration:

```ini
# /etc/NetworkManager/NetworkManager.conf
[main]
rc-manager=resolvconf
```

It preserves other NetworkManager settings and ensures the resolver file uses
the output managed by `resolvconf`:

```text
/etc/resolv.conf -> /run/resolvconf/resolv.conf
```

If NetworkManager is already running, the installer reloads it so the DNS
configuration takes effect immediately.

## Configure unattended SSH authentication

`autossh-ppp.service` runs as `root`, so it uses SSH credentials from
`/root/.ssh`. Password authentication is not suitable for a systemd service;
configure public-key authentication before starting `autossh-ppp`.

1) On the device, create a dedicated key:

```bash
sudo install -d -m 0700 /root/.ssh
sudo ssh-keygen \
  -t ed25519 \
  -f /root/.ssh/id_ed25519 \
  -N '' \
  -C 'sim800-autossh'
```

The private key has no passphrase because the service cannot answer an
interactive passphrase prompt. Keep `/root/.ssh/id_ed25519` readable only by
root.

2) Authorize the key for the tunnel user on the remote server:

```bash
sudo ssh-copy-id \
  -i /root/.ssh/id_ed25519.pub \
  user@example.com
```

This asks for the remote user's password once. If password authentication is
disabled, ask the remote administrator to add the contents of
`/root/.ssh/id_ed25519.pub` to the remote user's `~/.ssh/authorized_keys`.

For a tunnel-only key, restrict its line in the remote `authorized_keys` file.
Replace `2222` if you use another remote port:

```text
restrict,port-forwarding,permitlisten="localhost:2222" ssh-ed25519 AAAA... sim800-autossh
```

3) Verify that the remote SSH server permits public-key authentication and
remote forwarding. These settings belong in `/etc/ssh/sshd_config` on the
remote server:

```text
PubkeyAuthentication yes
AllowTcpForwarding remote
```

Validate and reload the remote SSH server after changing its configuration:

```bash
sudo sshd -t
sudo systemctl reload sshd
```

The service may be named `ssh` instead of `sshd` on Debian/Ubuntu.

4) Once `ppp0` is connected, test authentication non-interactively with the
same interface and host-key policy used by the service:

```bash
sudo ssh \
  -i /root/.ssh/id_ed25519 \
  -o IdentitiesOnly=yes \
  -o BatchMode=yes \
  -o BindInterface=ppp0 \
  -o StrictHostKeyChecking=accept-new \
  user@example.com true
```

The command must finish without asking for a password. If the remote server is
reachable only through PPP, run the installer with `--no-start`, start
`sim800.service`, provision and test the key, and then start
`autossh-ppp.service`.

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
- With the default loopback binding, connect from the remote server using
  `ssh -p <remote-port> <device-user>@localhost`.
- Exposing the reverse port to other hosts requires an explicit non-loopback
  bind address, `GatewayPorts` on the remote SSH server, and appropriate
  firewall restrictions.
- If you prefer a local tunnel (`-L`) or dynamic (`-D`), edit the unit after
  install.

## Status / logs

```bash
systemctl status sim800
systemctl status autossh-ppp
systemctl status rtc-i2c
systemctl status chrony
journalctl -u gsm-watchdog -b
journalctl -u gsm-watchdog.timer -b
journalctl -u sim800 -b
journalctl -u autossh-ppp -b
journalctl -u rtc-i2c -b
journalctl -u chrony -b
ip addr show ppp0
ip -4 route show default
hwclock -r -f /dev/rtc1
chronyc tracking
chronyc sources -v
```

## If you previously used /etc/rc.local

Remove or comment out `pppd call sim800 &` to avoid duplicate `pppd` instances.

## Files

- `systemd/sim800.service`
- `systemd/autossh-ppp.service`
- `systemd/gsm-watchdog.service`
- `systemd/gsm-watchdog.timer`
- `systemd/rtc-i2c.service`
- `systemd/chrony.service.d/10-rtc-i2c.conf`
- `chrony/chrony.conf`
- `scripts/chrony-ppp-down.sh`
- `scripts/chrony-ppp-up.sh`
- `scripts/gsm-watchdog.sh`
- `scripts/rtc-i2c-setup.sh`
- `ppp/peers/sim800.template`
- `ppp/chatscripts/sim800.template`
- `install.sh`
