# Troubleshooting — saturn (MacBookPro11,5)

Hardware problems on saturn. Generic Linux worker problems (access, PATH,
services, crash dumps, undoing the generic changes) are in
`setup/linux-worker/TROUBLESHOOTING.md`. The commands assume `ssh saturn`
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
   cmdline to `quiet loglevel=3 libata.force=noncq intel_iommu=off consoleblank=60` in `/etc/default/grub`,
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

## Crashes and freezes

### Saturn seems frozen

Before power-cycling it, check whether it is really down or just unreachable over
Tailscale:

```bash
ping saturn-mbp.local           # from a machine on the same LAN
ssh saturn@saturn-mbp.local     # LAN path, skips Tailscale
```

If either answers, saturn is fine and the problem is the network or the laptop's
Tailscale. A real kernel hang now panics and reboots by itself within about 40 s,
so a box that stays down for minutes is more likely off the network than frozen.

### Saturn stopped booting after repeated crashes

NVRAM may be full of crash dumps (`pstore-efi-cleanup.service` normally clears
them). At the keyboard, hold `Option+Cmd+P+R` at power-on until the second chime.

### Crashes, failed builds or wrong results since the undervolt

The CPU runs 65 mV under stock (`undervolt.service`). -75 mV passed 2 hours of
mprime with bit-identical builds, so -65 has a margin, but a chip can drift with age.

- After any crash, the next boot stays at stock once (`journalctl -b -u undervolt`
  says so, and `setup/saturn/scripts/verify.sh` fails `undervolt`). The boot after that undervolts again.
- To test whether it's the cause, run at stock: `sudo undervolt 0` (until reboot),
  or `sudo systemctl disable undervolt` (stays off).
- To back off for good, re-run `hardware.sh` with `UNDERVOLT_MV=-50`, or edit the value in
  `/etc/systemd/system/undervolt.service`, then `sudo systemctl daemon-reload` and reboot.

## Devices

| Symptom | Cause | Fix |
| --- | --- | --- |
| Thunderbolt device not detected | the controller is powered down | undo below, then reboot |
| Bluetooth, camera or SD reader missing | turned off by `hardware.sh` | undo below |

### Undo the hardware changes

```bash
# Bluetooth (the controller comes back on the next boot)
sudo rm /etc/udev/rules.d/70-bluetooth-off.rules
sudo systemctl enable --now bluetooth && sudo rfkill unblock bluetooth
# Camera
sudo rm /etc/modprobe.d/disable-camera.conf
# Thunderbolt and USB autosuspend (reboot after)
sudo rm /etc/modprobe.d/thunderbolt-off.conf /etc/udev/rules.d/71-idle-power.rules && sudo update-initramfs -u
# SD reader (the port may differ: lsusb | grep 05ac:8406)
sudo rm /etc/udev/rules.d/70-cardreader-off.rules && echo 1 | sudo tee /sys/bus/usb/devices/2-4/authorized
# CPU undervolt (sudo undervolt prints the offset)
sudo systemctl disable --now undervolt && sudo undervolt 0
# Battery charge limit (sudo bclm prints the current one)
sudo systemctl disable --now battery-limit && sudo bclm 100
```

Reboot after the modprobe changes.

## Known trade-offs

- `intel_iommu=off` disables VT-d. That means no PCI passthrough and weaker DMA
  protection. It's needed because Apple's DMAR tables are unreliable.
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
- The CPU is undervolted by 65 mV. Every write to its voltage register marks the
  kernel tainted (`/proc/sys/kernel/tainted` is 4), which only matters when
  reporting kernel bugs: reproduce them with `UNDERVOLT_MV=0` first.
- The `gpu-power-prefs` EFI variable doesn't help. Firmware clears it, and it
  only picks the boot GPU.
