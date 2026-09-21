#!/usr/bin/env bash
# setup.sh - provision a fresh Ubuntu MacBook Pro as a remote agentic-coding box.
#
# Phases (boot params, then hardware, then remote access, then workload):
#   1. Boot params : GRUB quirks (SSD NCQ, IOMMU) - must precede first reboot
#   2. Hardware    : apt helpers, dGPU off, fans, Wi-Fi reg domain, no-sleep,
#                    unused devices off (Bluetooth, camera, SD reader) and
#                    unused services off (CUPS, ModemManager, update notifiers)
#   3. Remote      : base pkgs, key-only SSH, Tailscale, UFW
#   4. Workload    : dev toolchain, Docker (off on demand), Node/uv,
#                    GUI-on-boot + don/doff toggles (HEADLESS=1 = no GUI)
#
# Usage:
#   sudo ADMIN_USER=saturn \
#        SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" \
#        LAN_CIDR=192.168.x.0/24 \
#        COUNTRY=<cc> \
#        bash setup.sh
#
# Options (env):
#   ADMIN_USER    login user to configure (default: invoking sudo user)
#   SSH_PUBKEY    public key line to authorize (or use SSH_PUBKEY_FILE)
#   LAN_CIDR      LAN subnet allowed to SSH (default: none -> Tailscale only)
#   COUNTRY       2-letter Wi-Fi country code (default: skip reg-domain step)
#   SKIP_DGPU=1   do not blacklist the AMD dGPU
#   SKIP_GRUB=1   do not touch GRUB cmdline
#   SKIP_DEVICES=1 do not turn off Bluetooth/camera/SD reader
#   SKIP_SERVICES=1 do not turn off CUPS/ModemManager/update-notifier
#   DOCKER_ON=1   leave Docker enabled at boot (default: installed but off)
#   HEADLESS=1    boot to a text console (default: GUI on boot + don/doff toggles)
#
set -euo pipefail

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

ADMIN_USER="${ADMIN_USER:-${SUDO_USER:-}}"
if [ -z "${ADMIN_USER:-}" ] || ! id "$ADMIN_USER" >/dev/null 2>&1; then
  echo "Set ADMIN_USER to a real login user." >&2
  exit 1
fi
ADMIN_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
LAN_CIDR="${LAN_CIDR:-}"
COUNTRY="${COUNTRY:-}"
SKIP_DGPU="${SKIP_DGPU:-0}"
SKIP_GRUB="${SKIP_GRUB:-0}"
SKIP_DEVICES="${SKIP_DEVICES:-0}"
SKIP_SERVICES="${SKIP_SERVICES:-0}"
DOCKER_ON="${DOCKER_ON:-0}"
HEADLESS="${HEADLESS:-0}"

if [ -n "${SSH_PUBKEY_FILE:-}" ] && [ -z "${SSH_PUBKEY:-}" ]; then
  SSH_PUBKEY="$(cat "$SSH_PUBKEY_FILE")"
fi
SSH_PUBKEY="${SSH_PUBKEY:-}"

IS_MAC=0
grep -q 'MacBookPro' /sys/class/dmi/id/product_name 2>/dev/null && IS_MAC=1

log "Phase 0 - preflight"
echo "  user : $ADMIN_USER ($ADMIN_HOME)"
echo "  DMI  : $(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
echo "  mac  : $IS_MAC"

# ======================================================== PHASE 1: BOOT PARAMS
log "Phase 1 - GRUB boot parameters"
if [ "$SKIP_GRUB" != "1" ] && [ "$IS_MAC" = "1" ]; then
  cp -n /etc/default/grub /etc/default/grub.bak 2>/dev/null || true
  sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="quiet splash libata.force=noncq intel_iommu=off"|' /etc/default/grub
  update-grub
  echo "  set: $(grep '^GRUB_CMDLINE_LINUX_DEFAULT' /etc/default/grub)"
else
  warn "skipping GRUB changes"
fi

# ============================================================ PHASE 2: HARDWARE
log "Phase 2 - hardware"

log "  2.0 apt reindex + hardware helpers"
rm -rf /var/lib/apt/lists/*
apt-get update
apt-get install -y iw mbpfan

if [ "$SKIP_DGPU" != "1" ] && [ "$IS_MAC" = "1" ]; then
  log "  2.1 disabling AMD dGPU (iGPU-only)"
  cat > /etc/modprobe.d/blacklist-amdgpu.conf <<'EOF'
# MacBookPro11,x: disable AMD dGPU, use Intel iGPU only
blacklist radeon
blacklist amdgpu
EOF
  update-initramfs -u
else
  warn "skipping dGPU blacklist"
fi

log "  2.2 fan control (mbpfan)"
systemctl enable --now mbpfan

if [ -n "$COUNTRY" ]; then
  log "  2.3 Wi-Fi regulatory domain = $COUNTRY"
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

if [ "$SKIP_DEVICES" != "1" ] && [ "$IS_MAC" = "1" ]; then
  log "  2.5 turning off unused devices (Bluetooth, camera, SD reader)"
  # Bluetooth: stop service + soft-block radio (persists via systemd-rfkill)
  systemctl disable --now bluetooth 2>/dev/null || true
  rfkill block bluetooth 2>/dev/null || true

  # FaceTime HD camera: never bind its driver
  echo "blacklist uvcvideo" > /etc/modprobe.d/disable-camera.conf

  # SD card reader (Apple 05ac:8406): deauthorize wherever it enumerated + persist
  for dev in /sys/bus/usb/devices/*/; do
    if [ "$(cat "$dev/idVendor" 2>/dev/null)" = "05ac" ] && \
       [ "$(cat "$dev/idProduct" 2>/dev/null)" = "8406" ]; then
      echo 0 > "$dev/authorized" 2>/dev/null || true
    fi
  done
  printf '%s\n' 'ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="05ac", ATTR{idProduct}=="8406", ATTR{authorized}="0"' \
    > /etc/udev/rules.d/70-cardreader-off.rules
  udevadm control --reload-rules
else
  warn "skipping unused-device power-off"
fi

if [ "$SKIP_SERVICES" != "1" ]; then
  log "  2.6 disabling unused services (printing, modem, update notifiers)"
  # CUPS: printing daemon + network printer discovery (no printers configured)
  systemctl disable --now cups.path cups.socket cups.service cups-browsed.service 2>/dev/null || true
  # ModemManager: Wi-Fi only, no WWAN modem
  systemctl disable --now ModemManager.service 2>/dev/null || true
  # Cosmetic update notices + MOTD news (keep unattended-upgrades for security)
  systemctl disable --now motd-news.timer update-notifier-download.timer update-notifier-motd.timer 2>/dev/null || true
else
  warn "skipping unused-service power-off"
fi

# ======================================================= PHASE 3: REMOTE ACCESS
log "Phase 3 - remote access"

log "  3.0 base packages"
apt-get install -y openssh-server ufw

log "  3.1 SSH (passwords stay ON until a key is proven)"
install -d /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
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
else
  warn "no SSH_PUBKEY given; add one to $ADMIN_HOME/.ssh/authorized_keys manually"
fi

log "  3.2 Tailscale"
apt-get install -y tailscale
systemctl enable --now tailscaled

log "  3.3 UFW (SSH via Tailscale${LAN_CIDR:+ + $LAN_CIDR})"
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0
[ -n "$LAN_CIDR" ] && ufw allow from "$LAN_CIDR" to any port 22 proto tcp
ufw --force enable

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
sudo -u "$ADMIN_USER" -H bash -c 'cat >> "$HOME/.bash_aliases" <<'"'"'EOF'"'"'
# Docker on-demand (installed but off by default)
dockeron()  { sudo systemctl enable --now containerd docker docker.socket; }
dockeroff() { sudo systemctl disable --now docker.socket docker containerd; }
dkstat()    { systemctl is-active containerd docker docker.socket; }

# Shell shortcuts
alias oc='"'"'opencode'"'"'
alias c='"'"'clear'"'"'
EOF' || warn "could not write $ADMIN_USER docker aliases"

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

log "  4.3 snapd off at boot + don/doff/dstat toggles"
# snapd only backs GUI snaps (Firefox, snap-store); don/doff toggle it.
systemctl disable --now snapd.service snapd.socket 2>/dev/null || true

sudo -u "$ADMIN_USER" -H bash -c 'cat >> "$HOME/.bash_aliases" <<'"'"'EOF'"'"'
# Desktop session toggles
unalias don doff 2>/dev/null
BL=/sys/class/backlight/gmux_backlight
BL_STATE=$HOME/.doff_brightness

don() {
    sudo systemctl start snapd.socket snapd.service
    sudo systemctl start gdm
    if [ -f "$BL_STATE" ]; then
        sudo sh -c "echo 0 > $BL/bl_power"
        sudo sh -c "echo $(cat "$BL_STATE") > $BL/brightness"
    fi
}

doff() {
    cat "$BL/brightness" > "$BL_STATE" 2>/dev/null
    sudo sh -c "echo 1 > $BL/bl_power"
    sudo systemctl stop gdm
    sudo systemctl stop snapd.service snapd.socket
}

alias dstat='"'"'systemctl is-active gdm'"'"'
EOF' || warn "could not write $ADMIN_USER shell aliases"

if [ "$HEADLESS" = "1" ]; then
  log "  4.4 headless boot (no GUI): multi-user.target, GDM removed from boot"
  systemctl set-default multi-user.target
  # `systemctl disable gdm` is a no-op (static unit); drop the display-manager link.
  rm -f /etc/systemd/system/display-manager.service
  systemctl stop gdm 2>/dev/null || true
else
  log "  4.4 GUI on boot (default): GDM stays enabled; run 'doff' after SSH"
fi

# ================================================================ SUMMARY
log "Summary"
printf '  grub        : %s\n' "$(grep '^GRUB_CMDLINE_LINUX_DEFAULT' /etc/default/grub)"
printf '  sshd        : %s / %s\n' "$(systemctl is-active ssh)" "$(systemctl is-enabled ssh)"
printf '  docker      : %s (service %s; use dockeron/dockeroff)\n' \
  "$(docker --version 2>/dev/null | sed 's/Docker version //;s/,.*//' || echo missing)" \
  "$(systemctl is-active docker 2>/dev/null)"
printf '  devices off : bluetooth=%s camera=%s sd-reader=%s\n' \
  "$(rfkill list bluetooth 2>/dev/null | grep -q 'Soft blocked: yes' && echo yes || echo no)" \
  "$(lsmod | grep -q '^uvcvideo' && echo no || echo yes)" \
  "$(lsblk -o NAME 2>/dev/null | grep -qx 'sdb' && echo no || echo yes)"
printf '  services off: cups=%s modemmanager=%s motd-news=%s\n' \
  "$(systemctl is-active cups 2>/dev/null)" \
  "$(systemctl is-active ModemManager 2>/dev/null)" \
  "$(systemctl is-active motd-news.timer 2>/dev/null)"
printf '  desktop     : gdm=%s, default=%s (use don/doff)\n' \
  "$(systemctl is-active gdm 2>/dev/null)" "$(systemctl get-default)"
printf '  mbpfan      : %s\n' "$(systemctl is-active mbpfan)"
printf '  ufw         : %s\n' "$(ufw status | head -1)"
printf '  dGPU driver : %s (0 = disabled)\n' "$(lsmod | grep -cE 'amdgpu|radeon')"
echo
echo "MANUAL FOLLOW-UPS:"
echo "  1. sudo tailscale up            # authenticate, note the 100.x IP"
echo "  2. verify key login from client, then disable password auth (see above)"
echo "  3. sudo pro attach <TOKEN> && sudo pro enable esm-apps esm-infra livepatch"
echo "  4. reboot to apply GRUB + dGPU blacklist + initramfs + logind changes"
