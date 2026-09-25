#!/usr/bin/env bash
# verify.sh - check saturn's MacBookPro11,5 hardware setup after reboot. Needs no root.
#
# From the client, after the generic checks:
#   ssh saturn bash -s < setup/linux-worker/scripts/verify.sh
#   ssh saturn bash -s < setup/saturn/scripts/verify.sh

fail=0
check() {  # check <name> <expected> <actual>
  if [ "$3" = "$2" ]; then printf 'ok    %-14s %s\n' "$1" "$3"
  else printf 'FAIL  %-14s got "%s", want "%s"\n' "$1" "$3" "$2"; fail=1; fi
}

cmd=" $(cat /proc/cmdline) "
has_arg() { case "$cmd" in *" $1 "*) return 0 ;; esac; return 1; }
check cmdline      yes "$(has_arg libata.force=max_sec=2560 && has_arg intel_iommu=off && ! has_arg libata.force=noncq && echo yes || echo no)"
check ncq          32   "$(cat /sys/block/sda/device/queue_depth 2>/dev/null)"
check ssd-cap      1280 "$(cat /sys/block/sda/queue/max_hw_sectors_kb 2>/dev/null)"
check ata-errors   0    "$(journalctl -k -b 2>/dev/null | grep -cE 'ata1.*(error|failed)|host bus error|FPDMA')"
check dgpu         D3hot "$(cat /sys/bus/pci/devices/0000:01:00.0/power_state 2>/dev/null)"
check dgpu-off     active "$(systemctl is-active dgpu-off)"
check mbpfan       active "$(systemctl is-active mbpfan)"
check thermald     masked "$(systemctl is-enabled thermald 2>/dev/null)"
check battery-limit active "$(systemctl is-active battery-limit)"
# The offset set at boot must match the unit's value; empty on both when setup skipped it.
check undervolt    "$(grep -o 'boot -[0-9]*' /etc/systemd/system/undervolt.service 2>/dev/null | cut -d' ' -f2)" "$(cat /var/lib/undervolt/active 2>/dev/null)"
# Reading the limit needs root; instead check the battery isn't charging past 80 %.
bat=/sys/class/power_supply/BAT0
check charge-limit held "$([ "$(cat $bat/status)" = Charging ] && [ $(( $(cat $bat/charge_now) * 100 / $(cat $bat/charge_full) )) -gt 81 ] && echo charging || echo held)"
check thunderbolt  D3hot "$(cat /sys/bus/pci/devices/0000:00:01.1/power_state 2>/dev/null)"
check bluetooth-usb off "$(lsusb | grep -q 05ac:8290 && [ "$(cat /sys/bus/usb/devices/1-8/authorized 2>/dev/null)" = 1 ] && echo on || echo off)"

exit $fail
