#!/usr/bin/env bash
# hardware.sh - MacBookPro11,5 quirks for the saturn worker. Run it after
# setup/linux-worker/scripts/setup.sh and before the first reboot.
#
#   Boot  : SSD write-size cap and IOMMU off on the kernel cmdline, udev cap,
#           NCQ on, noncq fallback GRUB entry
#   Power : dGPU off through the gmux, fans (mbpfan), thermald off, battery
#           charge limit, CPU undervolt
#   Off   : Bluetooth, camera, SD reader, Thunderbolt; USB autosuspend
#
# Usage:
#   sudo bash hardware.sh
#
# Options (env):
#   CHARGE_LIMIT  stop charging the battery at this % (default 80; 100 = no limit)
#   UNDERVOLT_MV  CPU voltage offset in mV (default -65; 0 = stock)
#   SKIP_GRUB=1   do not touch the GRUB cmdline or add the fallback entry
#   SKIP_DGPU=1   do not set up the AMD dGPU power-off
#   SKIP_DEVICES=1 do not turn off Bluetooth/camera/SD reader/Thunderbolt
#
set -euo pipefail

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

# grub_add <param>...: add kernel params to GRUB_CMDLINE_LINUX_DEFAULT unless present.
grub_add() {
  local line t
  line="$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/p' /etc/default/grub)"
  for t in "$@"; do
    case " $line " in *" $t "*) ;; *) line="${line:+$line }$t" ;; esac
  done
  sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$line\"|" /etc/default/grub
}

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi
if ! grep -q 'MacBookPro11' /sys/class/dmi/id/product_name 2>/dev/null; then
  echo "Not a MacBookPro11,x: $(cat /sys/class/dmi/id/product_name 2>/dev/null)" >&2
  exit 1
fi

CHARGE_LIMIT="${CHARGE_LIMIT:-80}"
UNDERVOLT_MV="${UNDERVOLT_MV:--65}"
SKIP_GRUB="${SKIP_GRUB:-0}"
SKIP_DGPU="${SKIP_DGPU:-0}"
SKIP_DEVICES="${SKIP_DEVICES:-0}"

# ============================================================== BOOT
log "Boot - SSD cap, IOMMU, fallback entry"
if [ "$SKIP_GRUB" != "1" ]; then
  cp -n /etc/default/grub /etc/default/grub.bak 2>/dev/null || true
  grub_add libata.force=max_sec=2560 intel_iommu=off
  # One-boot escape if NCQ ever misbehaves: `grub-reboot noncq-fallback && reboot`
  if ! grep -q noncq-fallback /etc/grub.d/40_custom; then
    BOOT_UUID=$(findmnt -no UUID /boot 2>/dev/null || findmnt -no UUID /)
    KP=$(mountpoint -q /boot && echo "" || echo /boot)
    cat >> /etc/grub.d/40_custom <<EOF

  menuentry 'Ubuntu (noncq fallback)' --id noncq-fallback {
  	insmod gzio
  	insmod part_gpt
  	insmod ext2
  	search --no-floppy --fs-uuid --set=root $BOOT_UUID
  	linux	$KP/vmlinuz root=$(findmnt -no SOURCE /) ro quiet libata.force=noncq intel_iommu=off
  	initrd	$KP/initrd.img
  }
EOF
  fi
  update-grub
  echo "  set: $(grep '^GRUB_CMDLINE_LINUX_DEFAULT' /etc/default/grub)"
else
  warn "skipping GRUB changes"
fi

log "  SSD write-size cap (1280 KiB, kernel 7.0 regression)"
cat > /etc/udev/rules.d/60-apple-ssd-max-sectors.rules <<'EOF'
# Apple SSD SM0xxxG (firmware BXW1SA0Q) throws host bus errors and drops the root fs
# read-only on writes over 1280 KiB since kernel 7.0 raised the default to 4 MiB.
# Second guard: libata.force=max_sec=2560 caps it in the kernel, but only while it is
# the sole force entry (libata applies the first match; noncq would win).
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ATTRS{model}=="APPLE SSD SM0*", ATTR{queue/max_sectors_kb}="1280"
EOF
udevadm control --reload
udevadm trigger --action=change --subsystem-match=block --sysname-match=sda

# ============================================================= POWER
log "Power"

log "  hardware helpers"
apt-get update -qq
apt-get install -y mbpfan msr-tools

if [ "$SKIP_DGPU" != "1" ]; then
  log "  AMD dGPU: bind to amdgpu, power off through the gmux at boot"
  cat > /etc/modprobe.d/blacklist-amdgpu.conf <<'EOF'
# MacBookPro11,5: bind the R9 M370X to amdgpu (Cape Verde = SI) so it registers a
# vga_switcheroo client; dgpu-off.service then cuts its power through the gmux.
blacklist radeon
options radeon si_support=0
options amdgpu si_support=1
EOF
  cat > /usr/local/sbin/dgpu-off <<'EOF'
#!/bin/sh
# Power off the AMD dGPU through the gmux once amdgpu has registered with vga_switcheroo.
SW=/sys/kernel/debug/vgaswitcheroo/switch
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
for i in $(seq 1 60); do [ -e "$SW" ] && break; sleep 0.5; done
[ -e "$SW" ] || { echo "vgaswitcheroo switch never appeared" >&2; exit 1; }
grep -q '^2:DIS: :Off' "$SW" 2>/dev/null && { echo "dGPU already off"; exit 0; }
echo IGD > "$SW"
echo OFF > "$SW"
sleep 1
grep 'DIS:' "$SW"
EOF
  chmod +x /usr/local/sbin/dgpu-off
  cat > /etc/systemd/system/dgpu-off.service <<'EOF'
[Unit]
Description=Power off AMD dGPU via apple-gmux (vga_switcheroo)
After=systemd-modules-load.service
DefaultDependencies=no
Before=multi-user.target display-manager.service gdm.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/dgpu-off

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable dgpu-off.service
  cat > /etc/udev/rules.d/72-dgpu-ignore.rules <<'EOF'
# MacBookPro11,5: dgpu-off.service cuts the AMD dGPU's power at boot. Keep the desktop
# from ever opening it, or GNOME Shell may pick it as primary GPU and hang when it vanishes.
SUBSYSTEM=="drm", KERNELS=="0000:01:00.0", TAG+="mutter-device-ignore", TAG-="seat", TAG-="master-of-seat", TAG-="uaccess"
EOF
  update-initramfs -u
else
  warn "skipping dGPU power-off"
fi

log "  fan control (mbpfan), thermald off"
systemctl enable --now mbpfan
# thermald has no config for Macs: its defaults halve the power limit and inject
# idle time, which made sustained builds ~18% slower. The CPU still throttles
# itself at 100 C and mbpfan runs the fans.
systemctl disable --now thermald 2>/dev/null || true
systemctl mask thermald 2>/dev/null || true

log "  battery charge limit ${CHARGE_LIMIT}%"
# Always on AC: a battery held full and hot wears fastest and swells. The SMC
# keeps the limit across reboots, but an SMC reset or a battery unplug puts it
# back to 100, so battery-limit.service sets it again on every boot.
cat > /usr/local/sbin/bclm <<'EOF'
#!/usr/bin/env python3
# Read or set the battery charge limit (SMC key BCLM) on Intel Macs.
# Usage: bclm         print the limit
#        bclm 80      stop charging at 80 %
import os, sys, time

DATA, CMD = 0x300, 0x304
READ, WRITE = 0x10, 0x11
AWAITING_DATA, IB_CLOSED, BUSY = 1, 2, 4

fd = os.open("/dev/port", os.O_RDWR)
inb = lambda port: os.pread(fd, 1, port)[0]
outb = lambda val, port: os.pwrite(fd, bytes([val]), port)

def wait_status(val, mask):
    us = 8
    for i in range(24):
        if inb(CMD) & mask == val:
            return
        time.sleep(us / 1e6)
        if i > 9:
            us <<= 1
    raise IOError("SMC not responding")

def send_byte(b, port):
    wait_status(0, IB_CLOSED)
    wait_status(BUSY, BUSY)
    outb(b, port)

def send_command(c):
    wait_status(0, IB_CLOSED)
    outb(c, CMD)

def start(cmd, key, length):
    try:
        wait_status(0, BUSY)
    except IOError:
        send_command(READ)
        wait_status(0, BUSY)
    send_command(cmd)
    for ch in key.encode():
        send_byte(ch, DATA)
    send_byte(length, DATA)

def read_key(key):
    start(READ, key, 1)
    wait_status(AWAITING_DATA | BUSY, AWAITING_DATA | BUSY)
    val = inb(DATA)
    for _ in range(16):
        time.sleep(8 / 1e6)
        if not inb(CMD) & AWAITING_DATA:
            break
        inb(DATA)
    wait_status(0, BUSY)
    return val

def write_key(key, val):
    start(WRITE, key, 1)
    send_byte(val, DATA)
    wait_status(0, BUSY)

if len(sys.argv) > 1:
    limit = int(sys.argv[1])
    if not 20 <= limit <= 100:
        sys.exit("limit must be 20-100")
    write_key("BCLM", limit)
print(read_key("BCLM"))
EOF
chmod 755 /usr/local/sbin/bclm
# Runs before mbpfan so their SMC accesses can't interleave.
cat > /etc/systemd/system/battery-limit.service <<EOF
[Unit]
Description=Stop charging the battery at ${CHARGE_LIMIT}%
Before=mbpfan.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/bclm ${CHARGE_LIMIT}

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable battery-limit.service
systemctl stop mbpfan
systemctl restart battery-limit.service || warn "could not set the charge limit"
systemctl start mbpfan

if [ "$UNDERVOLT_MV" != "0" ]; then
  log "  CPU undervolt ${UNDERVOLT_MV} mV"
  # The CPU runs at its 100 C limit under load. Less voltage means less heat, so it holds
  # a higher clock there: -75 mV passed 2 h of mprime and bit-identical builds; -65 keeps
  # a margin. Writes to the voltage MSR are allowed without a kernel warning.
  echo "options msr allow_writes=on" > /etc/modprobe.d/msr-writes.conf
  cat > /usr/local/sbin/undervolt <<'EOF'
#!/bin/bash
# Read or set the CPU voltage offset (MSR 0x150) on Haswell. Core and cache share one
# rail, so both get the same offset. The offset resets on every reboot.
# Usage: undervolt          print the offset in mV
#        undervolt -65      set it
#        undervolt boot -65 set it at boot, unless the last boot crashed while undervolted
#        undervolt stop     mark a clean shutdown
set -e
FLAG=/var/lib/undervolt/active
modprobe msr
get() {
  wrmsr -p0 0x150 0x8000001000000000
  local o=$(( (0x$(rdmsr -p0 0x150) >> 21) & 0x7ff ))
  [ $o -ge 1024 ] && o=$((o - 2048))
  echo $(( (o * 1000 - 512) / 1024 ))
}
set_mv() {
  [ "$1" -le 0 ] && [ "$1" -ge -100 ] || { echo "offset must be -100 to 0 mV" >&2; exit 1; }
  local o=0 p
  [ "$1" -ne 0 ] && o=$(( ($1 * 1024 - 500) / 1000 ))
  for p in 0 2; do wrmsr -a 0x150 "$(printf '0x80000%d11%08x' $p $(( (o & 0x7ff) << 21 )))"; done
}
case "${1:-}" in
  "") get ;;
  boot)
    # The flag is removed on a clean shutdown. If it's still here, the last boot ended in
    # a crash while undervolted: stay at stock this once, so a bad offset can't loop.
    if [ -e $FLAG ]; then
      rm -f $FLAG; echo "last boot crashed while undervolted; staying at stock"
    else
      set_mv "$2"; mkdir -p ${FLAG%/*}; get | tee $FLAG; sync
    fi ;;
  stop) rm -f $FLAG ;;
  *) set_mv "$1"; get ;;
esac
EOF
  chmod 755 /usr/local/sbin/undervolt
  cat > /etc/systemd/system/undervolt.service <<EOF
[Unit]
Description=Undervolt the CPU by ${UNDERVOLT_MV} mV

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/undervolt boot ${UNDERVOLT_MV}
ExecStop=/usr/local/sbin/undervolt stop

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable undervolt.service
  systemctl restart undervolt.service || warn "could not set the undervolt"
fi

# ======================================================= UNUSED DEVICES
if [ "$SKIP_DEVICES" != "1" ]; then
  log "Unused devices off (Bluetooth, camera, SD reader, Thunderbolt)"
  # Bluetooth: stop service + soft-block radio (persists via systemd-rfkill)
  systemctl disable --now bluetooth 2>/dev/null || true
  rfkill block bluetooth 2>/dev/null || true
  # ...and switch the controller (05ac:8290) off: while blocked it times out on every
  # USB suspend attempt and prints "usb 1-8: Failed to suspend device, error -110".
  printf '%s\n' \
    '# Internal Bluetooth (Broadcom 05ac:8290): unused, and while rfkill-blocked it times out' \
    '# on every USB suspend attempt ("usb 1-8: Failed to suspend device, error -110").' \
    'ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="05ac", ATTR{idProduct}=="8290", ATTR{authorized}="0"' \
    > /etc/udev/rules.d/70-bluetooth-off.rules

  # FaceTime HD camera: never bind its driver
  echo "blacklist uvcvideo" > /etc/modprobe.d/disable-camera.conf

  # SD card reader (Apple 05ac:8406) and Bluetooth (05ac:8290): deauthorize now + persist
  for dev in /sys/bus/usb/devices/*/; do
    case "$(cat "$dev/idVendor" 2>/dev/null):$(cat "$dev/idProduct" 2>/dev/null)" in
      05ac:8406|05ac:8290) echo 0 > "$dev/authorized" 2>/dev/null || true ;;
    esac
  done
  printf '%s\n' 'ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="05ac", ATTR{idProduct}=="8406", ATTR{authorized}="0"' \
    > /etc/udev/rules.d/70-cardreader-off.rules

  # Thunderbolt: nothing is plugged in, yet with its driver bound the controller stays
  # powered and holds the CPU out of deep idle (~2.5 W). Without a driver it may sleep,
  # and the Mac then cuts its power. The internal USB devices may autosuspend too (a
  # keypress wakes the keyboard), so the USB controller can sleep.
  echo "blacklist thunderbolt" > /etc/modprobe.d/thunderbolt-off.conf
  printf '%s\n' \
    '# Unused Thunderbolt controller (8086:156c, no driver) and the USB controller (8086:8c31)' \
    '# may sleep; the internal keyboard/trackpad, Bluetooth and SD reader may autosuspend.' \
    'ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x8086", ATTR{device}=="0x156c|0x8c31", ATTR{power/control}="auto"' \
    'ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="05ac", ATTR{idProduct}=="0274|8290|8406", ATTR{power/control}="auto"' \
    > /etc/udev/rules.d/71-idle-power.rules
  update-initramfs -u
  udevadm control --reload-rules
else
  warn "skipping unused-device power-off"
fi

# ============================================================ SUMMARY
log "Summary"
printf '  grub        : %s\n' "$(grep '^GRUB_CMDLINE_LINUX_DEFAULT' /etc/default/grub)"
printf '  ssd cap     : max_sectors_kb=%s (1280 = capped)\n' "$(cat /sys/block/sda/queue/max_sectors_kb 2>/dev/null)"
printf '  dgpu-off    : %s (powers the dGPU off after reboot)\n' "$(systemctl is-enabled dgpu-off 2>/dev/null || echo skipped)"
printf '  mbpfan      : %s, thermald %s\n' "$(systemctl is-active mbpfan)" "$(systemctl is-enabled thermald 2>/dev/null)"
printf '  battery     : limit %s%%\n' "$(/usr/local/sbin/bclm 2>/dev/null || echo '?')"
printf '  undervolt   : %s mV\n' "$(/usr/local/sbin/undervolt 2>/dev/null || echo 0)"
printf '  devices off : bluetooth=%s camera=%s sd-reader=%s\n' \
  "$(rfkill list bluetooth 2>/dev/null | grep -q 'Soft blocked: yes' && echo yes || echo no)" \
  "$(lsmod | grep -q '^uvcvideo' && echo no || echo yes)" \
  "$(lsblk -o NAME 2>/dev/null | grep -qx 'sdb' && echo no || echo yes)"
echo
echo "NEXT: continue with setup/linux-worker/SKILL.md step 3, then reboot and run both verify scripts."
