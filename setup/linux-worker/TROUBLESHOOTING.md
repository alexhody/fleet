# Troubleshooting and fallbacks — Linux worker

Each entry: what you see, why, and what to do. The commands assume `ssh <host>`
unless an entry says you need the local keyboard. Hardware-specific problems are
in the machine's folder (`setup/saturn/TROUBLESHOOTING.md`).

## Boot

### Boot got slow

Run `systemd-analyze` (normally about 11 s) and `systemd-analyze blame | head`.
If `splash` crept back into the cmdline, remove it: `plymouth-quit-wait` holds
boot until GDM takes over.

### Harmless log noise

None of these reach the text console (`loglevel=3` plus `20-quiet-console.conf`). Read
them with `journalctl -b -k -p err`. To see them on screen again, delete that file.

- `Dependency failed for sssd-*.socket`: SSSD is unconfigured. `setup.sh` masks it.

Machine folders list their own (`setup/saturn/TROUBLESHOOTING.md`).

## Crashes and freezes

### The worker seems frozen

Before power-cycling it, check whether it is really down or just unreachable over
Tailscale:

```bash
ping <name>.local           # from a machine on the same LAN
ssh <user>@<name>.local     # LAN path, skips Tailscale
```

If either answers, the worker is fine and the problem is the network or the
laptop's Tailscale. T3 Connect doesn't use Tailscale either, so a working T3
terminal points the same way. A real kernel hang panics and reboots by itself
within about 40 s, so a box that stays down for minutes is more likely off the
network than frozen.

### The worker rebooted by itself

A kernel hang, oops or 5-minute I/O stall panicked it (`61-crash-reboot.conf`).
Read the dump:

```bash
ls -t /var/lib/systemd/pstore/ | head -3
sudo cat /var/lib/systemd/pstore/<newest>/*/dmesg.txt | grep -aE 'panic|BUG|RIP|Comm:|hung|lockup' | head
```

`pstore-efi-cleanup.service` then deletes the dump from NVRAM, and only once its
copy is on disk. NVRAM also holds boot settings, so it must not fill up.
Check it with `ls /sys/firmware/efi/efivars | grep -c '^dump-'`, which should be 0.

To stop the automatic reboots (for example, to read a panic on screen):
`sudo rm /etc/sysctl.d/61-crash-reboot.conf && sudo sysctl kernel.panic=0 kernel.softlockup_panic=0 kernel.hardlockup_panic=0 kernel.hung_task_panic=0`.

Test the whole chain (it crashes the worker on purpose):
`sudo sh -c 'sync; echo c > /proc/sysrq-trigger'`. It should be back over SSH in
about 40 s, with a new dump in `/var/lib/systemd/pstore/`.

## Access

### Can't SSH in

- `tailscale status` on the laptop. Is the node online? If not, the box may be
  off, or Tailscale needs a re-login (`sudo tailscale up` at the keyboard).
- On the LAN, use `<name>.local` rather than an IP; the IP changes with the network.
- Locked out by key-only auth: at the keyboard, change `PasswordAuthentication no`
  to `yes` in `/etc/ssh/sshd_config.d/99-hardening.conf`, then
  `sudo systemctl restart ssh`.
- UFW: `sudo ufw status`. It must allow `tailscale0`, plus ports 22/tcp and
  5353/udp from `10.0.0.0/8`, `172.16.0.0/12` and `192.168.0.0/16`.
- Back up `~/.ssh/id_ed25519` on the laptop. Losing it means going to the keyboard.

### `command not found` for node/claude over SSH but fine interactively

Ubuntu's `~/.bashrc` returns early for non-interactive shells. Anything below
the `case $- in` guard is invisible to `ssh host cmd` and `bash -lc`, which are
the shells T3 Code and delegated jobs use. The `FLEET_PATH_SET` block must sit
above the guard. `setup.sh` inserts it, and a tool installer appending a PATH
line lower down doesn't matter. Check all three shell kinds:

```bash
ssh <host> 'command -v node claude'             # non-interactive
ssh <host> 'bash -lc "command -v node claude"'  # login (T3 Code)
ssh <host> 'bash -lic "command -v node"'        # interactive: path in fnm_multishells
```

### Agent jobs stall or stop making progress

- The login expired. Check with `claude auth status`, `codex login status` and
  `opencode auth list`, then log in again (SKILL.md step 5).
- A `claude -p` run without `--permission-mode auto --permission-prompts none`
  sits on a prompt nobody answers.
- Don't use `--bare` on a subscription login. It ignores OAuth.

## Services and devices

### Something expected is not running

| Symptom | Cause | Fix |
| --- | --- | --- |
| containers gone after reboot | Docker is off at boot | `dockeron`, or re-run setup with `DOCKER_ON=1` |
| need a snap app (e.g. Chromium) | snapd is removed and pinned out | `sudo rm /etc/apt/preferences.d/no-snapd && sudo apt install snapd` |
| `<name>.local` doesn't resolve | the client is on another network, or avahi stopped | use the Tailscale name; `systemctl status avahi-daemon`, re-run setup |
| no GUI at the panel | it boots to a text console | `don` |
| panel is dark | the console blanks after 60 s idle | press a key |
| `don`/`doff`/`dockeron`/`dockeroff` ask for a password | sudoers rule missing, or the functions differ from the rule (it matches exact commands) | `sudo -l` must list them (`/etc/sudoers.d/desktop-toggles`, `docker-toggles`); re-run setup |
| `sudo` asks for a password | `zz-<user>-nopasswd` missing or invalid | `sudo visudo -cf /etc/sudoers.d/zz-<user>-nopasswd`; re-run setup |
| files in `/tmp` vanished | tmpfs, wiped on boot | use `~/jobs` |
| apt fails on `liberror-perl` | broken `noble/main` index | `sudo rm -rf /var/lib/apt/lists/* && sudo apt-get update` |
| 5 GHz networks missing | regulatory domain is `00` | `iw reg get`; re-run setup with `COUNTRY=` |

### Undo individual changes

```bash
# Console blanking: remove consoleblank=60 from /etc/default/grub, then sudo update-grub
# CUPS, ModemManager, notifiers
sudo systemctl enable --now cups.socket cups.service cups-browsed ModemManager motd-news.timer
# Desktop extras (colour profiles, screen sharing, light sensor, crash reports, syslog, GPU switching, firmware checks)
sudo systemctl unmask colord gnome-remote-desktop iio-sensor-proxy kerneloops rsyslog switcheroo-control fwupd-refresh.timer
# Apport (Ubuntu crash reports)
sudo apt install apport
# Boot waiting for Wi-Fi
sudo systemctl enable NetworkManager-wait-online.service
# SSSD (only if you join a company/LDAP domain)
sudo systemctl unmask sssd.service sssd-{nss,autofs,pac,pam,pam-priv,ssh,sudo}.socket
# Passwordless sudo (don/doff/dockeron/dockeroff keep their narrow rules)
sudo rm /etc/sudoers.d/zz-<user>-nopasswd
# Wi-Fi power-save back on (battery over latency)
sudo rm /etc/NetworkManager/conf.d/99-wifi-powersave.conf; nmcli connection modify <name> wifi.powersave 3
# zram
sudo rm /etc/systemd/zram-generator.conf
# tmpfs /tmp
sudo systemctl disable tmp.mount && sudo rm /etc/systemd/system/tmp.mount
# noatime: restore from /etc/fstab.bak; sysctls: remove /etc/sysctl.d/60-fleet-perf.conf
# BBR only: delete its two lines from 60-fleet-perf.conf, then
sudo sysctl -w net.ipv4.tcp_congestion_control=cubic net.core.default_qdisc=fq_codel
```

Reboot after the zram, tmpfs or fstab changes.

### Boot straight to the desktop instead of the text console

```bash
sudo systemctl set-default graphical.target      # back: sudo systemctl set-default multi-user.target
```

To log the user in without a password when GDM starts, set `AutomaticLoginEnable`
in `/etc/gdm3/custom.conf`.

## Known trade-offs

- CPU mitigations stay on. Agents run fetched code (npm postinstall, scraped
  content).
