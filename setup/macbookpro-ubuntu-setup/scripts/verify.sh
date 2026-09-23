#!/usr/bin/env bash
# verify.sh - check a provisioned worker after reboot. Needs no root.
#
# From the client:  ssh saturn bash -s < scripts/verify.sh
# Prints one line per check and exits non-zero if any failed.

fail=0
check() {  # check <name> <expected> <actual>
  if [ "$3" = "$2" ]; then printf 'ok    %-14s %s\n' "$1" "$3"
  else printf 'FAIL  %-14s got "%s", want "%s"\n' "$1" "$3" "$2"; fail=1; fi
}
has() { [ -n "$2" ] && echo yes || echo no; }

cmd=$(cat /proc/cmdline)
check cmdline      yes "$(echo "$cmd" | grep -q 'libata.force=max_sec=2560 intel_iommu=off' && ! echo "$cmd" | grep -q noncq && echo yes || echo no)"
check ncq          32   "$(cat /sys/block/sda/device/queue_depth 2>/dev/null)"
check ssd-cap      1280 "$(cat /sys/block/sda/queue/max_hw_sectors_kb 2>/dev/null)"
check ata-errors   0    "$(journalctl -k -b 2>/dev/null | grep -cE 'ata1.*(error|failed)|host bus error|FPDMA')"
check dgpu         D3hot "$(cat /sys/bus/pci/devices/0000:01:00.0/power_state 2>/dev/null)"
check dgpu-off     active "$(systemctl is-active dgpu-off)"
check zram         yes  "$(has zram "$(swapon --show=NAME --noheadings | grep zram)")"
check tmp          tmpfs "$(findmnt -no FSTYPE /tmp)"
check noatime      yes  "$(has noatime "$(findmnt -no OPTIONS / | grep noatime)")"
check inotify      524288 "$(sysctl -n fs.inotify.max_user_watches)"
check tcp-bbr      "bbr fq" "$(sysctl -n net.ipv4.tcp_congestion_control) $(tc qdisc show dev wlp4s0 2>/dev/null | cut -d' ' -f2)"
check failed-units 0    "$(systemctl --failed --no-legend | wc -l | tr -d ' ')"
for u in ssh tailscaled mbpfan; do check "$u" active "$(systemctl is-active "$u")"; done
check thermald     masked "$(systemctl is-enabled thermald 2>/dev/null)"
# Reading the limit needs root; instead check the battery isn't charging past 80 %.
bat=/sys/class/power_supply/BAT0
check charge-limit held "$([ "$(cat $bat/status)" = Charging ] && [ $(( $(cat $bat/charge_now) * 100 / $(cat $bat/charge_full) )) -gt 81 ] && echo charging || echo held)"
check console-blank 60  "$(cat /sys/module/kernel/parameters/consoleblank)"
check thunderbolt  D3hot "$(cat /sys/bus/pci/devices/0000:00:01.1/power_state 2>/dev/null)"
check bluetooth-usb off "$(lsusb | grep -q 05ac:8290 && [ "$(cat /sys/bus/usb/devices/1-8/authorized 2>/dev/null)" = 1 ] && echo on || echo off)"
check snapd        gone "$(command -v snap >/dev/null && echo present || echo gone)"
check sleep        masked "$(systemctl is-enabled sleep.target 2>/dev/null)"
check boot-target  multi-user.target "$(systemctl get-default)"
check console-log  3    "$(cut -f1 /proc/sys/kernel/printk)"
check panic-reboot 10   "$(sysctl -n kernel.panic)"
check hang-panic   "1 1 1" "$(sysctl -n kernel.softlockup_panic kernel.hardlockup_panic kernel.hung_task_panic | xargs)"
check nvram-dumps  0    "$(ls /sys/firmware/efi/efivars 2>/dev/null | grep -c '^dump-')"
check tailscale    yes  "$(has ts "$(tailscale ip -4 2>/dev/null)")"

# Remote agents run through non-interactive shells; every tool must resolve there.
for t in node npm uv git gh claude codex opencode; do
  check "$t" yes "$(has "$t" "$(command -v "$t")")"
done

exit $fail
