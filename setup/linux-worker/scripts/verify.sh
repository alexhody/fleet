#!/usr/bin/env bash
# verify.sh - check a provisioned Linux worker after reboot. Needs no root.
#
# From the client:  ssh <host> bash -s < setup/linux-worker/scripts/verify.sh
# Prints one line per check and exits non-zero if any failed. Machine checks
# live in setup/<host>/scripts/verify.sh.

fail=0
check() {  # check <name> <expected> <actual>
  if [ "$3" = "$2" ]; then printf 'ok    %-14s %s\n' "$1" "$3"
  else printf 'FAIL  %-14s got "%s", want "%s"\n' "$1" "$3" "$2"; fail=1; fi
}
has() { [ -n "$2" ] && echo yes || echo no; }
netdev=$(ip route show default 2>/dev/null | awk '{print $5; exit}')

check zram         yes  "$(has zram "$(swapon --show=NAME --noheadings | grep zram)")"
check tmp          tmpfs "$(findmnt -no FSTYPE /tmp)"
check noatime      yes  "$(has noatime "$(findmnt -no OPTIONS / | grep noatime)")"
check inotify      524288 "$(sysctl -n fs.inotify.max_user_watches)"
check tcp-bbr      "bbr fq" "$(sysctl -n net.ipv4.tcp_congestion_control) $(tc qdisc show dev "$netdev" 2>/dev/null | cut -d' ' -f2)"
check failed-units 0    "$(systemctl --failed --no-legend | wc -l | tr -d ' ')"
for u in ssh tailscaled; do check "$u" active "$(systemctl is-active "$u")"; done
check snapd        gone "$(command -v snap >/dev/null && echo present || echo gone)"
check sleep        masked "$(systemctl is-enabled sleep.target 2>/dev/null)"
check boot-target  multi-user.target "$(systemctl get-default)"
check sudo         passwordless "$(sudo -n true 2>/dev/null && echo passwordless || echo password)"
check console-blank 60  "$(cat /sys/module/kernel/parameters/consoleblank)"
check console-log  3    "$(cut -f1 /proc/sys/kernel/printk)"
check panic-reboot 10   "$(sysctl -n kernel.panic)"
check hang-panic   "1 1 1" "$(sysctl -n kernel.softlockup_panic kernel.hardlockup_panic kernel.hung_task_panic | xargs)"
if [ -d /sys/firmware/efi/efivars ]; then
  check nvram-dumps 0   "$(ls /sys/firmware/efi/efivars 2>/dev/null | grep -c '^dump-')"
fi
check tailscale    yes  "$(has ts "$(tailscale ip -4 2>/dev/null)")"

# Remote agents run through non-interactive shells; every tool must resolve there.
for t in node npm uv git gh claude codex opencode; do
  check "$t" yes "$(has "$t" "$(command -v "$t")")"
done

exit $fail
