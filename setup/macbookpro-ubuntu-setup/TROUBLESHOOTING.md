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
   cmdline to `quiet libata.force=noncq intel_iommu=off` in `/etc/default/grub`,
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

- amdgpu `EDID err … eDP-2`: the gmux never routes the panel to the dGPU.
- `ata1.00: unexpected _GTF length (8)`: Apple ACPI quirk.
- `ata1.00: FORCE: modified (max_sec=)`: the cap being applied.

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
| `snap` commands hang | snapd is off at boot | `don`, or `sudo systemctl start snapd.socket snapd.service` |
| no GUI at the panel | `doff` was run, or `HEADLESS=1` | `don` |
| files in `/tmp` vanished | tmpfs, wiped on boot | use `~/jobs` |
| apt fails on `liberror-perl` | broken `noble/main` index | `sudo rm -rf /var/lib/apt/lists/* && sudo apt-get update` |
| 5 GHz networks missing | regulatory domain is `00` | `iw reg get`; re-run setup with `COUNTRY=` |

### Undo individual changes

```bash
# Bluetooth
sudo systemctl enable --now bluetooth && sudo rfkill unblock bluetooth
# Camera
sudo rm /etc/modprobe.d/disable-camera.conf
# SD reader (the port may differ: lsusb | grep 05ac:8406)
sudo rm /etc/udev/rules.d/70-cardreader-off.rules && echo 1 | sudo tee /sys/bus/usb/devices/2-4/authorized
# CUPS, ModemManager, notifiers
sudo systemctl enable --now cups.socket cups.service cups-browsed ModemManager motd-news.timer
# Wi-Fi power-save back on (battery over latency)
sudo rm /etc/NetworkManager/conf.d/99-wifi-powersave.conf; nmcli connection modify <name> wifi.powersave 3
# zram
sudo rm /etc/systemd/zram-generator.conf
# tmpfs /tmp
sudo systemctl disable tmp.mount && sudo rm /etc/systemd/system/tmp.mount
# noatime: restore from /etc/fstab.bak; sysctls: remove /etc/sysctl.d/60-fleet-perf.conf
```

Reboot after the zram, tmpfs, fstab or modprobe changes.

### Boot to a text console instead of GDM

```bash
sudo systemctl set-default multi-user.target
sudo rm -f /etc/systemd/system/display-manager.service   # `disable gdm` is a no-op: static unit
```

Undo with `sudo systemctl set-default graphical.target && sudo dpkg-reconfigure gdm3`.

## Known trade-offs

- `intel_iommu=off` disables VT-d. That means no PCI passthrough and weaker DMA
  protection. It's needed because Apple's DMAR tables are unreliable.
- CPU mitigations stay on. Agents run fetched code (npm postinstall, scraped
  content).
- Under sustained all-core load, the CPU hits 100 °C and throttles to 800 MHz,
  even with the fans at max. Long parallel builds run at about 2.4 GHz on
  average. Use `-j4` rather than `-j8`.
- The battery is worn (56 %). It's fine on AC, poor unplugged.
- The `gpu-power-prefs` EFI variable doesn't help. Firmware clears it, and it
  only picks the boot GPU.
