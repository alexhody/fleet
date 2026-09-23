# Troubleshooting and fallbacks — MacBook Pro Ubuntu worker

Each entry: what you see, why, and what to do. The commands assume `ssh saturn`
unless an entry says you need the local keyboard.

## Disk

### `host bus error`, `FPDMA` timeouts, ATA resets, or root goes read-only

Check: `journalctl -k | grep -E 'ata1|FPDMA|host bus'`.

1. Confirm the write cap is in place:
   - `/proc/cmdline` must contain `libata.force=max_sec=2560`.
   - `dmesg` must show `maxsec quirk is using value: 2560`.
   - `/sys/block/sda/queue/max_hw_sectors_kb` must be `1280`.

   Kernel 7.0 raised the default I/O size to 4 MiB. This SSD (Samsung `144d:a801`
   controller, firmware `BXW1SA0Q`) fails sustained writes above 1280 KiB.
2. If the cap is right and errors continue, boot once without NCQ:
   `sudo grub-reboot noncq-fallback && sudo reboot`. The next boot goes back to
   the default entry by itself.
3. If `noncq` fixes it, make it permanent and keep the cap through udev. Set the
   cmdline to `quiet loglevel=3 libata.force=noncq intel_iommu=off` in `/etc/default/grub`,
   then `update-grub`. The `60-apple-ssd-max-sectors.rules` rule still caps I/O at
   1280 KiB. Random I/O drops about 15× (150k → 10k read IOPS).

If the root filesystem is already read-only, fsck it at the next boot from the
GRUB recovery entry (local keyboard).

### Never combine `noncq` and `max_sec` in one `libata.force`

libata applies only the **first** matching `force` entry per device. With
`noncq,max_sec=2560`, `max_sec` is silently dropped. The only log line is
`FORCE: modified (noncq)`. Use one entry, or `noncq` plus the udev rule.

### Baseline numbers (fio, O_DIRECT, NCQ on, cap on)

| Test | Expected |
| --- | --- |
| 4k random read, QD32 | ~150k IOPS |
| 4k random write, QD32 | ~100k IOPS |
| 1M sequential read | ~2,100 MB/s |
| 1M sequential write | ~1,480 MB/s |

Much lower than this means NCQ is off: check that
`/sys/block/sda/device/queue_depth` is 32.

## Boot and dGPU

### Boot hangs at a black screen or the GDM logo

GNOME Shell grabbed the AMD dGPU before `dgpu-off` cut its power. Journal
signs: `MESA: error: amdgpu: Failed to allocate a buffer`, `ring sdma0 timeout`.

- **Recover (local keyboard):** power-cycle, press `e` on the GRUB entry, append
  `modprobe.blacklist=amdgpu` to the `linux` line, then press `Ctrl+X`.
- **Check the guards are in place:**
  - `/etc/udev/rules.d/72-dgpu-ignore.rules` exists. It must sort after
    `71-seat.rules`.
  - `systemctl cat dgpu-off` shows `Before=… display-manager.service gdm.service`.
  - `journalctl -b | grep 'selected primary'` names `card1` (i915), not `card2`.
- If the dGPU's PCI address changed, update `KERNELS==` in the 72 rule
  (`lspci | grep -i amd`).

### Give up on the dGPU power-off (stable but ~8 W more at idle)

```bash
sudo systemctl disable dgpu-off
sudo rm /etc/udev/rules.d/72-dgpu-ignore.rules
printf 'blacklist amdgpu\nblacklist radeon\n' | sudo tee /etc/modprobe.d/blacklist-amdgpu.conf
sudo update-initramfs -u && sudo reboot
```

### Need the dGPU on

Switching it back on at runtime fails: amdgpu can't resume and the gfx ring test
fails. Do `sudo systemctl disable dgpu-off && sudo reboot` instead. Re-enable it
the same way.

### `dgpu-off` failed: `vgaswitcheroo switch never appeared`

amdgpu didn't bind. Check `lspci -k -s 01:00.0` shows `Kernel driver in use: amdgpu`,
and that `/etc/modprobe.d/blacklist-amdgpu.conf` has `options amdgpu si_support=1`
and `options radeon si_support=0`. Then run `sudo update-initramfs -u`.

### Boot got slow

Run `systemd-analyze` (normally about 11 s) and `systemd-analyze blame | head`.
If `splash` crept back into the cmdline, remove it: `plymouth-quit-wait` holds
boot until GDM takes over.

### Harmless log noise

None of these reach the text console (`loglevel=3` plus `20-quiet-console.conf`). Read
them with `journalctl -b -k -p err`. To see them on screen again, delete that file.

- amdgpu `EDID err … eDP-2` / `No EDID read`: amdgpu probes the panel for a second before
  `dgpu-off` cuts its power, and the gmux never routes the panel to it.
  `video=eDP-2:d` doesn't stop the probe, so the message can only be hidden.
- `ata1.00: unexpected _GTF length (8)`: Apple ACPI quirk.
- `ata1.00: FORCE: modified (max_sec=)`: the cap being applied.
- brcmfmac `no clm_blob available … limited channels`: Ubuntu ships no channel file
  for this card; the firmware's built-in list is used and 5 GHz works.
- brcmfmac `fail to get arp ip table err:-52`: the 2015 firmware lacks ARP offload.
- `Dependency failed for sssd-*.socket`: SSSD is unconfigured. `setup.sh` masks it.

## Crashes and freezes

### Saturn seems frozen

Before power-cycling it, check whether it is really down or just unreachable over
Tailscale:

```bash
ping <LAN IP>
ssh saturn@<LAN IP>        # LAN path, skips Tailscale
```

If either answers, saturn is fine and the problem is the network or the laptop's
Tailscale. A real kernel hang now panics and reboots by itself within about 40 s,
so a box that stays down for minutes is more likely off the network than frozen.

### Saturn rebooted by itself

A kernel hang, oops or 5-minute I/O stall panicked it (`61-crash-reboot.conf`).
Read the dump:

```bash
ls -t /var/lib/systemd/pstore/ | head -3
sudo cat /var/lib/systemd/pstore/<newest>/*/dmesg.txt | grep -aE 'panic|BUG|RIP|Comm:|hung|lockup' | head
```

`pstore-efi-cleanup.service` then deletes the dump from NVRAM, and only once its
copy is on disk. NVRAM also holds the Mac's boot settings, so it must not fill up.
Check it with `ls /sys/firmware/efi/efivars | grep -c '^dump-'`, which should be 0.

If the Mac ever stops booting after repeated crashes, NVRAM may be full. At the
keyboard, hold `Option+Cmd+P+R` at power-on until the second chime.

To stop the automatic reboots (for example, to read a panic on screen):
`sudo rm /etc/sysctl.d/61-crash-reboot.conf && sudo sysctl kernel.panic=0 kernel.softlockup_panic=0 kernel.hardlockup_panic=0 kernel.hung_task_panic=0`.

Test the whole chain (it crashes saturn on purpose):
`sudo sh -c 'sync; echo c > /proc/sysrq-trigger'`. It should be back over SSH in
about 40 s, with a new dump in `/var/lib/systemd/pstore/` and `verify.sh` all `ok`.

## Access

### Can't SSH in

- `tailscale status` on the laptop. Is `saturn-mbp` online? If not, the box may be
  off, or Tailscale needs a re-login (`sudo tailscale up` at the keyboard).
- The LAN IP is DHCP and changes. Use the Tailscale IP or name.
- Locked out by key-only auth: at the keyboard, change `PasswordAuthentication no`
  to `yes` in `/etc/ssh/sshd_config.d/99-hardening.conf`, then
  `sudo systemctl restart ssh`.
- UFW: `sudo ufw status`. It must allow `tailscale0`, plus `LAN_CIDR` to port 22.
- Back up `~/.ssh/id_ed25519` on the laptop. Losing it means going to the keyboard.

### `command not found` for node/claude over SSH but fine interactively

Ubuntu's `~/.bashrc` returns early for non-interactive shells. Anything below
the `case $- in` guard is invisible to `ssh host cmd` and `bash -lc`, which are
the shells T3 Code and delegated jobs use. The `FLEET_PATH_SET` block must sit
above the guard. `setup.sh` inserts it, and a tool installer appending a PATH
line lower down doesn't matter. Check all three shell kinds:

```bash
ssh saturn 'command -v node claude'             # non-interactive
ssh saturn 'bash -lc "command -v node claude"'  # login (T3 Code)
ssh saturn 'bash -lic "command -v node"'        # interactive: path in fnm_multishells
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
| `saturn-mbp.local` doesn't resolve | avahi (mDNS) is masked | use the Tailscale name, or `sudo systemctl unmask --now avahi-daemon.socket avahi-daemon.service` |
| no GUI at the panel | it boots to a text console | `don` |
| panel is dark | the console blanks after 60 s idle | press a key |
| Thunderbolt device not detected | the controller is powered down | undo below, then reboot |
| `don`/`doff`/`dockeron`/`dockeroff` ask for a password | sudoers rule missing, or the functions differ from the rule (it matches exact commands) | `sudo -l` must list them (`/etc/sudoers.d/desktop-toggles`, `docker-toggles`); re-run setup |
| files in `/tmp` vanished | tmpfs, wiped on boot | use `~/jobs` |
| apt fails on `liberror-perl` | broken `noble/main` index | `sudo rm -rf /var/lib/apt/lists/* && sudo apt-get update` |
| 5 GHz networks missing | regulatory domain is `00` | `iw reg get`; re-run setup with `COUNTRY=` |

### Undo individual changes

```bash
# Bluetooth (the controller comes back on the next boot)
sudo rm /etc/udev/rules.d/70-bluetooth-off.rules
sudo systemctl enable --now bluetooth && sudo rfkill unblock bluetooth
# Camera
sudo rm /etc/modprobe.d/disable-camera.conf
# Thunderbolt and USB autosuspend (reboot after)
sudo rm /etc/modprobe.d/thunderbolt-off.conf /etc/udev/rules.d/71-idle-power.rules && sudo update-initramfs -u
# Console blanking: remove consoleblank=60 from /etc/default/grub, then sudo update-grub
# SD reader (the port may differ: lsusb | grep 05ac:8406)
sudo rm /etc/udev/rules.d/70-cardreader-off.rules && echo 1 | sudo tee /sys/bus/usb/devices/2-4/authorized
# CUPS, ModemManager, notifiers
sudo systemctl enable --now cups.socket cups.service cups-browsed ModemManager motd-news.timer
# Desktop extras (colour profiles, screen sharing, mDNS, light sensor, crash reports, syslog, GPU switching, firmware checks)
sudo systemctl unmask colord gnome-remote-desktop avahi-daemon.socket avahi-daemon iio-sensor-proxy kerneloops rsyslog switcheroo-control fwupd-refresh.timer
# Apport (Ubuntu crash reports)
sudo apt install apport
# Boot waiting for Wi-Fi
sudo systemctl enable NetworkManager-wait-online.service
# SSSD (only if you join a company/LDAP domain)
sudo systemctl unmask sssd.service sssd-{nss,autofs,pac,pam,pam-priv,ssh,sudo}.socket
# Battery charge limit (sudo bclm prints the current one)
sudo systemctl disable --now battery-limit && sudo bclm 100
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

Reboot after the zram, tmpfs, fstab or modprobe changes.

### Boot straight to the desktop instead of the text console

```bash
sudo systemctl set-default graphical.target      # back: sudo systemctl set-default multi-user.target
```

GDM logs `saturn` in automatically either way (`/etc/gdm3/custom.conf`).

## Known trade-offs

- `intel_iommu=off` disables VT-d. That means no PCI passthrough and weaker DMA
  protection. It's needed because Apple's DMAR tables are unreliable.
- CPU mitigations stay on. Agents run fetched code (npm postinstall, scraped
  content).
- Under sustained all-core load, the CPU hits 100 °C and throttles to 800 MHz,
  even with the fans at max. Keep the default 8 build workers anyway: `-j8` still
  beat `-j4` by about 2 % on a sustained build.
- `thermald` is masked. Without a Mac config its defaults halve the power limit and
  inject idle time, so long builds ran ~18 % slower (166–170 s vs 137–140 s for
  3× Redis `-j8`). Under sustained load the CPU now averages 90–93 °C (96 °C before
  the repaste) and throttles itself at 100 °C. Bring it back with
  `sudo systemctl unmask thermald && sudo systemctl enable --now thermald`.
- The battery is worn (56 %). It's fine on AC, poor unplugged. It stops charging
  at 80 % to slow further wear. Above that, it holds its charge on AC rather than
  draining down to 80. An SMC reset (Shift+Ctrl+Option+Power) or a battery unplug
  puts the limit back to 100 until the next boot, when `battery-limit.service` sets
  it again (or run `sudo bclm 80`).
- The `gpu-power-prefs` EFI variable doesn't help. Firmware clears it, and it
  only picks the boot GPU.
