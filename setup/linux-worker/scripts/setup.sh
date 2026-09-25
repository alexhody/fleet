#!/usr/bin/env bash
# setup.sh - provision an Ubuntu (or Debian) machine as a remote agentic-coding worker.
#
# Phases:
#   1. Boot     : quiet text console that blanks after 60 s, no splash
#   2. System   : Wi-Fi reg domain and power-save off, no sleep, unused services
#                 off (CUPS, ModemManager, notifiers, SSSD, snapd, desktop extras),
#                 zram, noatime, tmpfs /tmp, inotify limits, BBR, crash recovery
#                 (panic on hang, dump to pstore, auto-reboot, NVRAM cleanup)
#   3. Remote   : base pkgs, SSH, Tailscale, UFW, passwordless sudo
#   4. Workload : dev toolchain, Docker (off on demand), Node/uv,
#                 non-interactive-shell PATH, agent CLIs (Claude Code,
#                 Codex, opencode), text-console boot + don/doff toggles
#
# Machine quirks (drivers, fans, firmware) live in setup/<host>/scripts. Run
# those after this script, before the first reboot.
#
# Usage:
#   sudo ADMIN_USER=<user> \
#        SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" \
#        COUNTRY=<cc> \
#        bash setup.sh
#
# Options (env):
#   ADMIN_USER    login user to configure (default: invoking sudo user)
#   SSH_PUBKEY    public key line to authorize (or use SSH_PUBKEY_FILE)
#   COUNTRY       2-letter Wi-Fi country code (default: skip reg-domain step)
#   SKIP_GRUB=1   do not touch the GRUB cmdline
#   SKIP_WIFI_PS=1 do not disable Wi-Fi power-save (keep battery over latency)
#   SKIP_SERVICES=1 do not turn off CUPS/ModemManager/notifiers/SSSD/snaps/desktop extras
#   SKIP_TUNING=1  do not set up zram, noatime, tmpfs /tmp, inotify limits, BBR
#   DOCKER_ON=1   leave Docker enabled at boot (default: installed but off)
#   GUI_ON_BOOT=1 boot straight to the desktop (default: text console; don/doff toggle it)
#   SKIP_NOPASSWD=1 keep the sudo password prompt for ADMIN_USER
#
set -euo pipefail

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

# install_sudoers <name>: validate the rule on stdin, then install it to /etc/sudoers.d.
install_sudoers() {
  local tmp; tmp="$(mktemp)"
  cat > "$tmp"
  if visudo -cf "$tmp" >/dev/null; then
    install -m 0440 -o root -g root "$tmp" "/etc/sudoers.d/$1"
  else
    warn "sudoers rule $1 failed validation; its commands will ask for a password"
  fi
  rm -f "$tmp"
}

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
command -v apt-get >/dev/null || { echo "Ubuntu or Debian (apt) only." >&2; exit 1; }

ADMIN_USER="${ADMIN_USER:-${SUDO_USER:-}}"
if [ -z "${ADMIN_USER:-}" ] || ! id "$ADMIN_USER" >/dev/null 2>&1; then
  echo "Set ADMIN_USER to a real login user." >&2
  exit 1
fi
ADMIN_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
COUNTRY="${COUNTRY:-}"
SKIP_GRUB="${SKIP_GRUB:-0}"
SKIP_WIFI_PS="${SKIP_WIFI_PS:-0}"
SKIP_SERVICES="${SKIP_SERVICES:-0}"
SKIP_TUNING="${SKIP_TUNING:-0}"
DOCKER_ON="${DOCKER_ON:-0}"
GUI_ON_BOOT="${GUI_ON_BOOT:-0}"
SKIP_NOPASSWD="${SKIP_NOPASSWD:-0}"

if [ -n "${SSH_PUBKEY_FILE:-}" ] && [ -z "${SSH_PUBKEY:-}" ]; then
  SSH_PUBKEY="$(cat "$SSH_PUBKEY_FILE")"
fi
SSH_PUBKEY="${SSH_PUBKEY:-}"

log "Phase 0 - preflight"
echo "  user : $ADMIN_USER ($ADMIN_HOME)"
echo "  DMI  : $(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"

# ============================================================== PHASE 1: BOOT
log "Phase 1 - boot: quiet text console"
if [ "$SKIP_GRUB" != "1" ] && [ -f /etc/default/grub ]; then
  cp -n /etc/default/grub /etc/default/grub.bak 2>/dev/null || true
  # splash holds boot in plymouth until GDM starts, which a text console never does.
  sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/s/ *\bsplash\b//' /etc/default/grub
  # consoleblank: with the lid ignored, a lit panel keeps the CPU out of deep idle.
  grub_add quiet loglevel=3 consoleblank=60
  update-grub
  echo "  set: $(grep '^GRUB_CMDLINE_LINUX_DEFAULT' /etc/default/grub)"
else
  warn "skipping GRUB changes"
fi

# Keep kernel error noise off the text console; the journal still has it.
cat > /etc/sysctl.d/20-quiet-console.conf <<'EOF'
# Keep kernel error messages off the text console; they still go to the journal.
# Loads after Ubuntu's 10-console-messages.conf, which would reset it to 4.
kernel.printk = 3 4 1 7
EOF
sysctl -q -p /etc/sysctl.d/20-quiet-console.conf

# ============================================================ PHASE 2: SYSTEM
log "Phase 2 - system"

log "  2.1 apt reindex + iw"
rm -rf /var/lib/apt/lists/*
apt-get update
apt-get install -y iw

if [ -n "$COUNTRY" ]; then
  log "  2.2 Wi-Fi regulatory domain = $COUNTRY"
  iw reg set "$COUNTRY" || true
  echo "options cfg80211 ieee80211_regdom=$COUNTRY" > /etc/modprobe.d/cfg80211-regdom.conf
  cat > /etc/systemd/system/wifi-regdom.service <<EOF
[Unit]
Description=Set Wi-Fi regulatory domain to $COUNTRY
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/iw reg set $COUNTRY
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now wifi-regdom.service
  update-initramfs -u
fi

if [ "$SKIP_WIFI_PS" != "1" ]; then
  log "  2.3 Wi-Fi power-save off (latency; negligible cost on AC)"
  WIFI_IF="$(nmcli -t -f DEVICE,TYPE dev 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')"
  # Global default for future connections: 2 = disable (0=default,1=ignore,2=disable,3=enable)
  cat > /etc/NetworkManager/conf.d/99-wifi-powersave.conf <<'EOF'
[connection]
wifi.powersave = 2
EOF
  if [ -n "$WIFI_IF" ]; then
    while IFS=: read -r name type; do
      [ "$type" = "802-11-wireless" ] || continue
      nmcli connection modify "$name" wifi.powersave 2 || true
    done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null)
    systemctl reload NetworkManager 2>/dev/null || systemctl restart NetworkManager 2>/dev/null || true
    iw dev "$WIFI_IF" set power_save off || true
    nmcli device reapply "$WIFI_IF" >/dev/null 2>&1 || true
    echo "  $WIFI_IF $(iw dev "$WIFI_IF" get power_save 2>/dev/null | sed 's/^ *//')"
  else
    warn "no Wi-Fi interface found; power-save preference set for future connections"
  fi
else
  warn "skipping Wi-Fi power-save change"
fi

log "  2.4 disable sleep / lid-close / power-key"
install -d /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/99-no-sleep.conf <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandlePowerKey=ignore
IdleAction=ignore
EOF
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1 || true
sudo -u "$ADMIN_USER" -H bash -lc '
  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type nothing 2>/dev/null || true
  gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null || true
' || true

if [ "$SKIP_SERVICES" != "1" ]; then
  log "  2.5 disabling unused services (printing, modem, notifiers, snaps, desktop extras)"
  # CUPS: printing daemon + network printer discovery (no printers configured)
  systemctl disable --now cups.path cups.socket cups.service cups-browsed.service 2>/dev/null || true
  # ModemManager: no WWAN modem on a worker
  systemctl disable --now ModemManager.service 2>/dev/null || true
  # Cosmetic update notices + MOTD news (keep unattended-upgrades for security)
  systemctl disable --now motd-news.timer update-notifier-download.timer update-notifier-motd.timer 2>/dev/null || true
  # SSSD (company/LDAP logins): unconfigured here, so its sockets fail at every boot.
  # Masked, not removed: PAM and nsswitch reference it.
  systemctl mask sssd.service sssd-nss.socket sssd-autofs.socket sssd-pac.socket \
    sssd-pam.socket sssd-pam-priv.socket sssd-ssh.socket sssd-sudo.socket 2>/dev/null || true
  # Snaps: only desktop apps (Firefox, Snap Store, Firmware Updater) use them; Chrome
  # comes from apt. Purging snapd removes every snap. The pin keeps apt from pulling
  # it back in as a dependency.
  systemctl stop snapd.service snapd.socket snapd.seeded.service 2>/dev/null || true
  DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq firefox snapd >/dev/null 2>&1 || true
  rm -rf /var/lib/snapd /var/cache/snapd /snap
  cat > /etc/apt/preferences.d/no-snapd <<'EOF'
# This worker has no snap apps. Stop apt from pulling snapd back in as a dependency.
# To install a snap again: delete this file, then apt install snapd.
Package: snapd
Pin: release *
Pin-Priority: -1
EOF
  # Apport (crash reports to Ubuntu): kernel crashes already go to pstore.
  DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq apport apport-gtk apport-core-dump-handler >/dev/null 2>&1 || true
  # avahi (mDNS) stays on: it answers <name>.local, the LAN name that follows the network.
  systemctl unmask avahi-daemon.service avahi-daemon.socket 2>/dev/null || true
  systemctl enable --now avahi-daemon.socket avahi-daemon.service 2>/dev/null || true
  # Desktop extras with no job on a headless worker: colour profiles, screen
  # sharing, light sensor, crash reporters, a second syslog, GPU switching,
  # firmware update checks (run `fwupdmgr` by hand when wanted).
  for u in colord.service gnome-remote-desktop.service \
           iio-sensor-proxy.service kerneloops.service rsyslog.service \
           switcheroo-control.service fwupd-refresh.timer; do
    systemctl disable --now "$u" 2>/dev/null || true
    systemctl mask "$u" 2>/dev/null || true
  done
  # Boot need not wait for Wi-Fi; SSH and Tailscale pick it up when it connects.
  systemctl disable NetworkManager-wait-online.service 2>/dev/null || true
else
  warn "skipping unused-service power-off"
fi

if [ "$SKIP_TUNING" != "1" ]; then
  log "  2.6 zram swap, noatime, tmpfs /tmp, inotify limits"
  apt-get install -y systemd-zram-generator
  cat > /etc/systemd/zram-generator.conf <<'EOF'
# Compressed RAM swap; the 4 GB /swap.img stays as a low-priority last resort.
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
swap-priority = 100
EOF
  cp -n /etc/fstab /etc/fstab.bak 2>/dev/null || true
  awk '$2=="/" && $3=="ext4" && $4=="defaults" {$4="defaults,noatime"} {print}' OFS='\t' /etc/fstab > /etc/fstab.new && mv /etc/fstab.new /etc/fstab
  cp /usr/share/systemd/tmp.mount /etc/systemd/system/tmp.mount
  systemctl daemon-reload
  systemctl enable tmp.mount
  cat > /etc/sysctl.d/60-fleet-perf.conf <<'EOF'
# zram swap is far cheaper than the disk, so prefer it over dropping page cache.
vm.swappiness = 180
# zram has no seek cost; read-ahead of neighbouring swap pages only wastes work.
vm.page-cluster = 0
# File watchers (node, vite, tsc) fail silently on large repos at the default 65536.
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
# BBR keeps queues short: ~38% less lag and half the retransmits when sending
# over Wi-Fi. fq paces its packets.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl -p /etc/sysctl.d/60-fleet-perf.conf
else
  warn "skipping memory/disk tuning"
fi

log "  2.7 crash recovery: panic on a kernel hang, save a dump, reboot in 10 s"
cat > /etc/sysctl.d/61-crash-reboot.conf <<'EOF'
# Unattended worker: turn a real kernel hang or oops into a panic, which saves a
# dump to EFI pstore (archived to /var/lib/systemd/pstore on next boot), then reboot.
kernel.panic = 10
kernel.panic_on_oops = 1
kernel.softlockup_panic = 1
kernel.hardlockup_panic = 1
# A task stuck in uninterruptible I/O for 5 minutes (e.g. a disk stall) is never healthy.
kernel.hung_task_timeout_secs = 300
kernel.hung_task_panic = 1
EOF
sysctl -p /etc/sysctl.d/61-crash-reboot.conf >/dev/null
if [ -d /sys/firmware/efi/efivars ]; then
  cat > /usr/local/sbin/pstore-efi-cleanup <<'EOF'
#!/bin/sh
# systemd-pstore archives kernel crash dumps but leaves them in EFI NVRAM, which
# also holds boot settings. Remove each dump once its archived copy exists on disk.
for f in /sys/firmware/efi/efivars/dump-type0-*; do
  [ -e "$f" ] || continue
  # dump-type0-<part>-<count>-<time>-C-<guid>  ->  dmesg-efi_pstore-<time><part:2><count:3>
  set -- $(basename "$f" | tr '-' ' ')
  id=$(printf '%s%02d%03d' "$5" "$3" "$4")
  ls /var/lib/systemd/pstore/*/*/"dmesg-efi_pstore-$id" >/dev/null 2>&1 || { echo "not archived, kept: $f"; continue; }
  chattr -i "$f" && rm -f "$f" && echo "removed $(basename "$f")"
done
EOF
  chmod +x /usr/local/sbin/pstore-efi-cleanup
  cat > /etc/systemd/system/pstore-efi-cleanup.service <<'EOF'
[Unit]
Description=Remove archived crash dumps from EFI NVRAM
After=systemd-pstore.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pstore-efi-cleanup

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable pstore-efi-cleanup.service
fi

# ======================================================= PHASE 3: REMOTE ACCESS
log "Phase 3 - remote access"

log "  3.0 base packages"
apt-get install -y openssh-server ufw curl

log "  3.1 SSH (passwords stay ON until a key is proven)"
install -d /etc/ssh/sshd_config.d
# Left alone once it exists, so a re-run can't turn password auth back on.
[ -f /etc/ssh/sshd_config.d/99-hardening.conf ] || cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
X11Forwarding no
EOF
systemctl enable --now ssh

if [ -n "$SSH_PUBKEY" ]; then
  install -d -m700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$ADMIN_HOME/.ssh"
  grep -qxF "$SSH_PUBKEY" "$ADMIN_HOME/.ssh/authorized_keys" 2>/dev/null || \
    printf '%s\n' "$SSH_PUBKEY" >> "$ADMIN_HOME/.ssh/authorized_keys"
  chmod 600 "$ADMIN_HOME/.ssh/authorized_keys"
  chown "$ADMIN_USER:$ADMIN_USER" "$ADMIN_HOME/.ssh/authorized_keys"
  echo "   -> after confirming key login, disable passwords:"
  echo "      sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config.d/99-hardening.conf && sshd -t && systemctl restart ssh"
elif [ -s "$ADMIN_HOME/.ssh/authorized_keys" ]; then
  echo "   using existing $ADMIN_HOME/.ssh/authorized_keys"
else
  warn "no SSH_PUBKEY given; add one to $ADMIN_HOME/.ssh/authorized_keys manually"
fi

log "  3.2 Tailscale"
command -v tailscale >/dev/null 2>&1 || curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled

log "  3.3 UFW (everything via Tailscale; SSH and mDNS from any private LAN)"
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0
# Private ranges rather than one subnet, so LAN SSH works on whatever network it joins.
for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
  ufw allow from "$net" to any port 22 proto tcp
  ufw allow from "$net" to any port 5353 proto udp
done
ufw --force enable

if [ "$SKIP_NOPASSWD" != "1" ]; then
  log "  3.4 passwordless sudo for $ADMIN_USER"
  # The console login still needs the password and SSH is key-only; the docker group
  # is root-equivalent anyway. zz- sorts last so it wins over the narrow rules below.
  install_sudoers "zz-$ADMIN_USER-nopasswd" <<EOF
# $ADMIN_USER runs sudo without a password (the console login still asks for one).
$ADMIN_USER ALL=(ALL:ALL) NOPASSWD: ALL
EOF
else
  warn "skipping passwordless sudo"
fi

# ========================================================= PHASE 4: WORKLOAD
log "Phase 4 - workload tooling"

log "  4.1 dev packages + Docker (off on demand)"
apt-get install -y \
  git build-essential ca-certificates curl wget gnupg unzip zip \
  tmux screen htop jq ripgrep fd-find bat tree gh \
  python3-pip python3-venv python3-dev docker.io docker-compose-v2
[ -x "$(command -v fdfind 2>/dev/null)" ] && ln -sf "$(command -v fdfind)" /usr/local/bin/fd
[ -x "$(command -v batcat 2>/dev/null)" ] && ln -sf "$(command -v batcat)" /usr/local/bin/bat
usermod -aG docker "$ADMIN_USER"
if [ "$DOCKER_ON" = "1" ]; then
  systemctl enable --now containerd docker docker.socket
else
  # Idle box: don't run dockerd/containerd until needed.
  systemctl disable --now docker.socket docker containerd 2>/dev/null || true
fi

log "  4.1b Docker on-demand helpers"
grep -q dockeron "$ADMIN_HOME/.bash_aliases" 2>/dev/null || \
sudo -u "$ADMIN_USER" -H bash -c 'cat >> "$HOME/.bash_aliases" <<'"'"'EOF'"'"'
# Docker on-demand (installed but off by default)
dockeron()  { sudo systemctl enable --now containerd docker docker.socket; }
dockeroff() { sudo systemctl disable --now docker.socket docker containerd; }
dkstat()    { systemctl is-active containerd docker docker.socket; }

# Shell shortcuts
alias oc='"'"'opencode'"'"'
alias c='"'"'clear'"'"'
EOF' || warn "could not write $ADMIN_USER docker aliases"

install_sudoers docker-toggles <<EOF
# dockeron/dockeroff (~/.bash_aliases) toggle Docker without a password prompt.
$ADMIN_USER ALL=(root) NOPASSWD: /usr/bin/systemctl enable --now containerd docker docker.socket, \\
    /usr/bin/systemctl disable --now docker.socket docker containerd
EOF

log "  4.2 Node (fnm) + uv for $ADMIN_USER"
sudo -u "$ADMIN_USER" -H bash -lc '
  set -e
  if ! command -v fnm >/dev/null 2>&1; then
    curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell
  fi
  export PATH="$HOME/.local/share/fnm:$PATH"; eval "$(fnm env)"
  fnm install --lts && fnm default lts-latest
  grep -q "fnm env" "$HOME/.bashrc" 2>/dev/null || \
    echo '"'"'command -v fnm >/dev/null && eval "$(fnm env --use-on-cd)"'"'"' >> "$HOME/.bashrc"
  command -v uv >/dev/null 2>&1 || curl -LsSf https://astral.sh/uv/install.sh | sh
' || warn "user tooling step failed; run it manually as $ADMIN_USER"

log "  4.2b PATH for non-interactive shells"
# Ubuntu's ~/.bashrc returns early for non-interactive shells, so PATH lines
# appended to it never reach `ssh host cmd` or `bash -lc` - the shells remote
# agents and control planes use. Put tool paths above that early return.
BRC="$ADMIN_HOME/.bashrc"
if [ ! -f "$BRC" ]; then
  warn "no $BRC; skipping non-interactive PATH step"
elif grep -q FLEET_PATH_SET "$BRC"; then
  log "    already present"
else
  BLK="$(mktemp)"; NEW="$(mktemp)"
  cat > "$BLK" <<'FLEETPATH'
# Tool PATH for every kind of shell. The interactive early-return below hides
# anything past it from `ssh host cmd` and `bash -lc` - the shells remote
# agents and control planes use - so tool paths belong here, above it.
if [ -z "${FLEET_PATH_SET:-}" ]; then
    export FLEET_PATH_SET=1
    FNM_DIR="$HOME/.local/share/fnm"
    for d in "$HOME/.local/bin" "$FNM_DIR" "$FNM_DIR/aliases/default/bin" \
             "$HOME/.opencode/bin"; do
        [ -d "$d" ] && PATH="$d:$PATH"
    done
    export PATH
fi

FLEETPATH
  cp -p "$BRC" "$BRC.bak"
  awk -v blk="$BLK" '
    !done && /^# If not running interactively/ {
      while ((getline line < blk) > 0) print line
      done = 1
    }
    { print }
    END { if (!done) exit 3 }
  ' "$BRC" > "$NEW" \
    && install -m644 -o "$ADMIN_USER" -g "$ADMIN_USER" "$NEW" "$BRC" \
    || warn "could not locate the interactive guard in $BRC; patch it by hand"
  rm -f "$BLK" "$NEW"
fi

log "  4.2c agent CLIs (Claude Code, Codex, opencode) + ~/jobs"
sudo -u "$ADMIN_USER" -H bash -c '
  export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"
  command -v claude   >/dev/null 2>&1 || curl -fsSL https://claude.ai/install.sh | bash
  command -v codex    >/dev/null 2>&1 || curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh
  command -v opencode >/dev/null 2>&1 || curl -fsSL https://opencode.ai/install | bash
  mkdir -p "$HOME/jobs" "$HOME/Code"
' || warn "agent CLI install failed; rerun the installers as $ADMIN_USER"

log "  4.3 don/doff/dstat toggles"
# doff also turns the panel off. With no backlight the tee lines fail quietly.
BL="$(ls -d /sys/class/backlight/* 2>/dev/null | head -1)"
BL="${BL:-/sys/class/backlight/none}"
grep -q 'doff()' "$ADMIN_HOME/.bash_aliases" 2>/dev/null || \
sudo -u "$ADMIN_USER" -H BL="$BL" bash -c 'cat >> "$HOME/.bash_aliases" <<EOF
# Desktop session toggles
unalias don doff 2>/dev/null
BL=$BL
BL_STATE=\$HOME/.doff_brightness

don() {
    sudo systemctl start gdm
    if [ -f "\$BL_STATE" ]; then
        echo 0 | sudo tee "\$BL/bl_power" >/dev/null
        sudo tee "\$BL/brightness" < "\$BL_STATE" >/dev/null
    fi
}

doff() {
    cat "\$BL/brightness" > "\$BL_STATE" 2>/dev/null
    echo 1 | sudo tee "\$BL/bl_power" >/dev/null
    sudo systemctl stop gdm
}

alias dstat='"'"'systemctl is-active gdm'"'"'
EOF' || warn "could not write $ADMIN_USER shell aliases"

# Let don/doff run without a password: only their exact commands, never a shell.
install_sudoers desktop-toggles <<EOF
# don/doff (~/.bash_aliases) toggle the desktop without a password prompt.
$ADMIN_USER ALL=(root) NOPASSWD: /usr/bin/systemctl start gdm, /usr/bin/systemctl stop gdm, \\
    /usr/bin/tee $BL/bl_power, /usr/bin/tee $BL/brightness
EOF

if [ "$GUI_ON_BOOT" = "1" ]; then
  log "  4.4 boot to the desktop (GDM); 'doff' stops it"
  systemctl set-default graphical.target
else
  # GDM stays installed; graphical.target is never reached, so only 'don' starts it.
  log "  4.4 boot to a text console; 'don' starts the desktop, 'doff' stops it"
  systemctl set-default multi-user.target
fi

# ================================================================ SUMMARY
log "Summary"
printf '  grub        : %s\n' "$(grep '^GRUB_CMDLINE_LINUX_DEFAULT' /etc/default/grub)"
printf '  sshd        : %s / %s\n' "$(systemctl is-active ssh)" "$(systemctl is-enabled ssh)"
printf '  docker      : %s (service %s; use dockeron/dockeroff)\n' \
  "$(docker --version 2>/dev/null | sed 's/Docker version //;s/,.*//' || echo missing)" \
  "$(systemctl is-active docker 2>/dev/null)"
printf '  services off: cups=%s modemmanager=%s motd-news=%s\n' \
  "$(systemctl is-active cups 2>/dev/null)" \
  "$(systemctl is-active ModemManager 2>/dev/null)" \
  "$(systemctl is-active motd-news.timer 2>/dev/null)"
printf '  desktop     : gdm=%s, default=%s (use don/doff)\n' \
  "$(systemctl is-active gdm 2>/dev/null)" "$(systemctl get-default)"
printf '  wifi        : power_save=%s (NM wifi.powersave=%s)\n' \
  "$(iw dev "$(nmcli -t -f DEVICE,TYPE dev 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')" get power_save 2>/dev/null | sed 's/.*: //')" \
  "$(grep -h '^wifi.powersave' /etc/NetworkManager/conf.d/99-wifi-powersave.conf 2>/dev/null | awk -F= '{gsub(/ /,"",$2); print $2}')"
printf '  sudo        : %s\n' \
  "$(sudo -u "$ADMIN_USER" sudo -n true 2>/dev/null && echo passwordless || echo password required)"
printf '  ufw         : %s\n' "$(ufw status | head -1)"
printf '  tuning      : zram=%s tmp.mount=%s inotify=%s (zram + /tmp after reboot)\n' \
  "$([ -f /etc/systemd/zram-generator.conf ] && echo configured || echo skipped)" \
  "$(systemctl is-enabled tmp.mount 2>/dev/null || echo skipped)" \
  "$(sysctl -n fs.inotify.max_user_watches)"
printf '  crash       : panic reboot after %ss, NVRAM cleanup %s\n' "$(sysctl -n kernel.panic)" "$(systemctl is-enabled pstore-efi-cleanup 2>/dev/null || echo skipped)"
echo
echo "NEXT: run the machine script if it has one (setup/<host>/scripts), then SKILL.md steps 3-6:"
echo "  1. sudo tailscale up            # authenticate, note the 100.x IP"
echo "  2. verify key login from the client, then disable password auth (see above)"
echo "  3. reboot, then run scripts/verify.sh from the client"
echo "  4. log in: claude auth login, codex login --device-auth, opencode auth login, gh auth login"
