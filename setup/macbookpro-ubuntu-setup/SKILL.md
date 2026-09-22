---
name: macbookpro-ubuntu-setup
description: Use ONLY when provisioning a freshly installed Ubuntu on an Apple MacBook Pro (MacBookPro11,x, e.g. 11,5) for headless remote agentic-coding use. Covers required GRUB kernel parameters, Apple driver checks, disabling the AMD dGPU (iGPU-only), key-only SSH, Tailscale, no-sleep/lid handling, dev toolchain, mbpfan, UFW hardening, the Wi-Fi regulatory domain and Wi-Fi power-save, turning off unused devices (Bluetooth, FaceTime camera, SD card reader) and unused services (CUPS printing, ModemManager, update-notifier/motd-news), and installing Docker but leaving it off on demand. Trigger on "fresh Ubuntu on MacBook Pro", "set up this MacBook", "SSH into the Ubuntu MacBook", "turn off Bluetooth/camera/SD reader", "disable CUPS/ModemManager", "turn off Wi-Fi power-save", "enable/disable Docker on the MacBook".
---

# Fresh Ubuntu on a MacBook Pro -> remote agentic-coding box

Goal: take a stock Ubuntu install on a MacBook Pro and make it a reliable, headless,
remotely-reachable machine you can `ssh` into from another laptop.

## Target hardware (verified working)

MacBookPro11,5 (mid-2015 15"): Intel i7-4870HQ, 16 GB, dual GPU
(Intel Iris Pro = `i915`, AMD R9 M370X = `amdgpu`), Broadcom BCM43602 Wi-Fi
(`brcmfmac`), `bcm5974` trackpad, `applesmc` fans, `apple-gmux` (indexed 4.0.20).
Apple SSD `SM0512G`. OS: Ubuntu 24.04 LTS. All core drivers are in-tree.

## Provisioning order (and why)

Boot parameters come first because they are foundational and only take effect on a
reboot. Then configure the **hardware**, while you still have local access and before
the box goes headless. **Remote access comes next**, so the final reboot can be done
and recovered remotely. **Workload tooling comes last**. A single reboot at the end
applies the GRUB parameters, dGPU power-off, initramfs, and logind changes.

```
Phase 0  Preflight        read-only: identify box, collect inputs, driver sanity
Phase 1  Boot parameters  GRUB cmdline quirks (SSD NCQ, IOMMU)             <-- first
Phase 2  Hardware         dGPU off, fans, Wi-Fi reg domain, power/sleep,
                          unused devices + services off
Phase 3  Remote access    base pkgs, key-only SSH, Tailscale, UFW
Phase 4  Workload         dev toolchain, Docker (off on demand), Node/uv,
                          GUI-on-boot + don/doff toggles (HEADLESS=1 = no GUI)
Phase 5  Reboot + verify  apply everything, confirm SSH from the client
```

## Inputs to collect (Phase 0)

| Variable     | Example / note                                           |
| ------------ | -------------------------------------------------------- |
| `ADMIN_USER` | the login user, e.g. `saturn`                            |
| `SSH_PUBKEY` | admin's **public** key from the client laptop (one line) |
| `LAN_CIDR`   | local subnet, e.g. `192.168.x.0/24`                      |
| `COUNTRY`    | 2-letter Wi-Fi country, e.g. `CZ`                        |
| Pro token    | optional, https://ubuntu.com/pro (free personal)         |

---

## Phase 0 — Preflight (read-only)

```bash
cat /sys/class/dmi/id/product_name        # expect MacBookPro11,5 (or 11,x)
lspci -nn | grep -Ei 'vga|network'        # Intel + AMD GPU, Broadcom Wi-Fi
lsmod | grep -E 'i915|brcmfmac|bcm5974|applesmc|apple_gmux'
ip -brief addr                            # Wi-Fi up?
```

If `product_name` is **not** a MacBook Pro 11,x, skip the Apple-specific steps in
Phases 1-2 and treat it as generic Ubuntu.

## Phase 1 — Boot parameters (GRUB) — do this first

These two quirks are required for stability on this hardware and must be set before
the first reboot:

- `libata.force=noncq` — the Apple `SM0512G` SSD has buggy NCQ; disabling it avoids
  ATA I/O errors/hangs under Linux.
- `intel_iommu=off` — Apple's DMAR/IOMMU tables are unreliable; disabling avoids
  boot/DMA problems.

```bash
cp /etc/default/grub /etc/default/grub.bak
sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="quiet splash libata.force=noncq intel_iommu=off"|' /etc/default/grub
update-grub
grep GRUB_CMDLINE_LINUX_DEFAULT /etc/default/grub   # verify
```

Trade-off to note: `intel_iommu=off` disables VT-d, which weakens DMA-attack
protection and blocks PCI/GPU passthrough. Acceptable for a coding box; re-enable if
you later need VFIO/passthrough. Takes effect on the Phase 5 reboot; confirm with
`cat /proc/cmdline`.

## Phase 2 — Hardware

### 2.0 Prerequisite: repair apt + install hardware helpers

A known failure: `git` depends on `liberror-perl`, which can be missing from the
`noble/main` index. Re-index if any install fails this way.

```bash
rm -rf /var/lib/apt/lists/* && apt-get update      # only if apt is broken
apt-get install -y iw mbpfan
```

### 2.1 Power off the AMD dGPU through the gmux

The R9 M370X has no PX runtime PM (`amdgpu: Runtime PM not available`), but the
indexed gmux can still cut its power rail: `apple-gmux` exposes that through
`vga_switcheroo`, and since kernel 6.4 `amdgpu` registers a switcheroo client on
gmux Macs. So bind the card to `amdgpu` (Cape Verde needs `si_support=1`) and let a
oneshot unit switch it off a few seconds into boot. Blacklisting the driver instead
leaves the card in D0 with no power interface at all — roughly 10 W and a hotter
chassis for nothing. Do **not** rely on the `gpu-power-prefs` EFI variable: it only
picks the boot GPU, and Apple's firmware clears it on reboot anyway.

```bash
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
systemctl daemon-reload && systemctl enable dgpu-off.service

# Hide the dGPU from GNOME Shell and the seat (72 runs after 71-seat.rules adds the tags)
cat > /etc/udev/rules.d/72-dgpu-ignore.rules <<'EOF'
# MacBookPro11,5: dgpu-off.service cuts the AMD dGPU's power at boot. Keep the desktop
# from ever opening it, or GNOME Shell may pick it as primary GPU and hang when it vanishes.
SUBSYSTEM=="drm", KERNELS=="0000:01:00.0", TAG+="mutter-device-ignore", TAG-="seat", TAG-="master-of-seat", TAG-="uaccess"
EOF
update-initramfs -u        # takes effect on the Phase 5 reboot
```

After the reboot `cat /sys/kernel/debug/vgaswitcheroo/switch` must show
`2:DIS: :Off:0000:01:00.0` and `/sys/bus/pci/devices/0000:01:00.0/power_state`
reads `D3hot`. Measured on saturn at idle: fans 3500 → 2150 rpm, package 67 → 59 °C.
The `EDID err ... eDP-2` lines amdgpu logs at boot are harmless — the gmux never
routes the panel to the dGPU.

Both the udev rule and `Before=gdm.service` are required. amdgpu finishes init about
7 s into boot, right as GDM starts; without them GNOME Shell sometimes grabs the dGPU
as its primary GPU, the power cut pulls it away, and the boot hangs
(`MESA: error: amdgpu: Failed to allocate a buffer`, then `ring sdma0 timeout`).
On saturn that was 3 of 5 boots. Check with
`journalctl -b | grep 'selected primary'` — it must name `card1` (i915).

### 2.2 Fan control

`applesmc` exposes both fans; `mbpfan` (installed in 2.0) drives them.

```bash
systemctl enable --now mbpfan
systemctl is-active mbpfan
```

### 2.3 Wi-Fi regulatory domain

Default is `country 00` (world), which limits 5 GHz channels and triggers a
brcmfmac warning. Set the real country and persist it two ways:

```bash
iw reg set "$COUNTRY"
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
systemctl daemon-reload && systemctl enable --now wifi-regdom.service
update-initramfs -u
iw reg get | head -3          # expect: country $COUNTRY
```

### 2.3b Disable Wi-Fi power-save (latency over micro-power)

`brcmfmac` leaves power-save **on**, so the AP buffers frames until the next wake
interval. On this box that adds only jitter, not loss: measured ping to `1.1.1.1`
went from `mdev ~40 ms / max ~240 ms` to `mdev ~3 ms / max ~34 ms` with it off, at
`0%` packet loss either way. It saves just ~0.1-0.4 W, which is negligible on a box
that normally sits on AC. Because this is a headless agent box (long-lived SSH and
streaming agent output), trade the micro-power for steady latency. Set the global
default, pin existing connections, then reapply:

```bash
# Global default for future connections: 2 = disable (0=default,1=ignore,2=disable,3=enable)
cat > /etc/NetworkManager/conf.d/99-wifi-powersave.conf <<'EOF'
[connection]
wifi.powersave = 2
EOF

# Pin existing Wi-Fi connections too
for c in $(nmcli -t -f NAME,TYPE connection show | awk -F: '$2=="802-11-wireless"{print $1}'); do
  nmcli connection modify "$c" wifi.powersave 2
done

iw dev wlp4s0 set power_save off
systemctl reload NetworkManager
nmcli device reapply wlp4s0
iw dev wlp4s0 get power_save          # expect: Power save: off
```

This is a latency/jitter trade-off, **not** a stability requirement: at good signal
(this box: -35 dBm) power-save never dropped packets. Revert for battery life with
`nmcli connection modify <name> wifi.powersave 3` (or delete the conf.d file).

### 2.4 Power: never sleep, ignore lid-close

Critical for a headless box: closing the lid must not suspend it.

```bash
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
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
# also stop GNOME idling (run as the user, inside the session):
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
gsettings set org.gnome.desktop.session idle-delay 0
```

### 2.5 Power: turn off unused devices (Bluetooth, camera, SD reader)

A headless coding box does not need Bluetooth, the FaceTime HD camera, or the SD
card reader. Turning them off is zero-risk for coding and shaves a little idle
power. (This unit has no Ethernet and only Wi-Fi, so keep Wi-Fi.)

```bash
# Bluetooth: stop the service and soft-block the radio (persists via systemd-rfkill)
systemctl disable --now bluetooth
rfkill block bluetooth

# FaceTime HD camera: never let its driver bind
echo "blacklist uvcvideo" > /etc/modprobe.d/disable-camera.conf

# SD card reader: deauthorize the USB device (true off) + persist the block.
# Port is 2-4 here; confirm with: lsusb | grep -i card  ->  05ac:8406
echo 0 > /sys/bus/usb/devices/2-4/authorized
printf '%s\n' 'ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="05ac", ATTR{idProduct}=="8406", ATTR{authorized}="0"' \
  > /etc/udev/rules.d/70-cardreader-off.rules
udevadm control --reload-rules
```

Revert any of them:

```bash
systemctl enable --now bluetooth && rfkill unblock bluetooth
rm /etc/modprobe.d/disable-camera.conf
rm /etc/udev/rules.d/70-cardreader-off.rules && echo 1 > /sys/bus/usb/devices/2-4/authorized
```

Deliberately **not** touched: SATA ALPM (`max_performance`) and PCIe ASPM
(`default`). They save only ~1-2 W and risk I/O instability on a remote box with
no physical access — not worth it. The dGPU is the dominant draw; 2.1 powers it
off through the gmux.

### 2.6 Disable unused services (printing, modem, update notifiers)

None of these are needed on a headless coding box, and none touch SSH/Tailscale:

```bash
# Printing daemon + network printer discovery (no printers configured)
systemctl disable --now cups.path cups.socket cups.service cups-browsed.service

# Mobile-broadband manager (Wi-Fi only, no WWAN modem)
systemctl disable --now ModemManager.service

# Cosmetic update notices + MOTD news (keep unattended-upgrades for security)
systemctl disable --now motd-news.timer update-notifier-download.timer update-notifier-motd.timer
```

Re-enable any with `systemctl enable --now <unit>`. Deliberately **kept**:
`unattended-upgrades` + `apt-daily*.timer` (automatic security patching) and
`snapd` (only needed if you use the desktop/Firefox snaps). `avahi-daemon` is
left running too — it is tiny and `cups-browsed` was its only consumer.

**Phase 2 verify:** iGPU drives the panel, `dgpu-off.service` active, fans active,
`iw reg get` shows your country, Wi-Fi power-save off (`iw dev <if> get power_save`),
sleep targets masked, Bluetooth soft-blocked, `uvcvideo` not loaded,
`sdb`/card reader gone (`lsblk`), and `cups`/`ModemManager`/`motd-news.timer`
inactive.

## Phase 3 — Remote access

### 3.0 Base packages

```bash
apt-get install -y openssh-server ufw
```

### 3.1 SSH — key-only access

Install with passwords still ON, add the key, verify, then turn passwords off.

```bash
install -d /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
X11Forwarding no
EOF
systemctl enable --now ssh

install -d -m700 -o "$ADMIN_USER" -g "$ADMIN_USER" /home/"$ADMIN_USER"/.ssh
echo "$SSH_PUBKEY" >> /home/"$ADMIN_USER"/.ssh/authorized_keys
chmod 600 /home/"$ADMIN_USER"/.ssh/authorized_keys
chown "$ADMIN_USER":"$ADMIN_USER" /home/"$ADMIN_USER"/.ssh/authorized_keys
```

From the client, confirm key auth works:
`ssh -o PreferredAuthentications=publickey "$ADMIN_USER"@<box-ip>` and check
`ssh -v ... 2>&1 | grep 'Authentication succeeded'` shows `(publickey)`.
**Only then** disable passwords:

```bash
sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' \
  /etc/ssh/sshd_config.d/99-hardening.conf
sshd -t && systemctl restart ssh
sshd -T | grep -i passwordauth        # expect: passwordauthentication no
```

### 3.2 Tailscale (reach it from anywhere, no port-forwarding)

```bash
apt-get install -y tailscale
systemctl enable --now tailscaled
tailscale up        # interactive: authenticate in the browser, note the 100.x IP
```

### 3.3 UFW — expose SSH only to Tailscale + LAN

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0
ufw allow from "$LAN_CIDR" to any port 22 proto tcp
ufw --force enable
ufw status verbose
```

## Phase 4 — Workload tooling

### 4.1 Dev packages + Docker (installed, left OFF)

```bash
apt-get install -y \
  git build-essential ca-certificates curl wget gnupg unzip zip \
  tmux screen htop jq ripgrep fd-find bat tree gh \
  python3-pip python3-venv python3-dev docker.io docker-compose-v2
ln -sf "$(command -v fdfind)" /usr/local/bin/fd
ln -sf "$(command -v batcat)" /usr/local/bin/bat
usermod -aG docker "$ADMIN_USER"

# Docker is installed but NOT running: the box is idle most of the time and
# containerd/dockerd only burn RAM/CPU when there are no containers. Leave it
# off and start it on demand.
systemctl disable --now docker.socket docker containerd 2>/dev/null || true
```

Add on-demand helpers to `~/.bash_aliases` (Ubuntu's default `~/.bashrc` sources it):

```bash
cat >> ~/.bash_aliases <<'EOF'
# Docker on-demand (installed but off by default)
dockeron()  { sudo systemctl enable --now containerd docker docker.socket; }
dockeroff() { sudo systemctl disable --now docker.socket docker containerd; }
dkstat()    { systemctl is-active containerd docker docker.socket; }

# Shell shortcuts
alias oc='opencode'
alias c='clear'
EOF
```

Set `DOCKER_ON=1` at setup time if you want Docker running from the start.

### 4.2 Node LTS + Python uv (run as `ADMIN_USER`, not root)

```bash
curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell
export PATH="$HOME/.local/share/fnm:$PATH"; eval "$(fnm env)"
fnm install --lts && fnm default lts-latest
echo 'command -v fnm >/dev/null && eval "$(fnm env --use-on-cd)"' >> ~/.bashrc
curl -LsSf https://astral.sh/uv/install.sh | sh
```

### 4.3 Ubuntu Pro (optional, free for personal use)

```bash
pro attach <TOKEN>
pro enable esm-apps esm-infra livepatch
```

### 4.4 Desktop: GUI on boot + `don`/`doff` toggles (default)

The default is a **GUI on every reboot**: GDM starts and shows the login screen,
while Tailscale and SSH come up on their own. The usual workflow is to SSH in over
Tailscale and run `doff` to reclaim the GUI (backlight off, GDM + snapd stopped);
`don` brings it back. Nothing here changes the boot target, so GDM returns on every
reboot.

snapd only backs GUI snaps (Firefox, snap-store); keep it off at boot and let
`don`/`doff` start/stop it with the desktop:

```bash
systemctl disable --now snapd.service snapd.socket
```

Install the toggles for `ADMIN_USER` (written to `~/.bash_aliases`, which
Ubuntu's default `~/.bashrc` sources):

```bash
cat >> ~/.bash_aliases <<'EOF'
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

alias dstat='systemctl is-active gdm'
EOF
```

- `don` — start snapd (for GUI snaps like Firefox) + GDM (switch to it with
  `Fn+Ctrl+Alt+F2`; Apple F-keys need `Fn`).
- `doff` — power off the panel backlight, then stop GDM and snapd. Run from SSH —
  it blanks the local screen.
- `dstat` — show GDM status.
- snapd stays disabled at boot (~48 MB saved); `don`/`doff` toggle it per session.

#### Optional: boot with no GUI (`HEADLESS=1`)

If you'd rather the box boot to a text console (no GDM), add:

```bash
systemctl set-default multi-user.target
# `systemctl disable gdm` is a NO-OP: gdm.service is a static unit with no
# [Install]. Remove the display-manager designation instead:
rm -f /etc/systemd/system/display-manager.service
systemctl stop gdm
```

`don`/`doff` still work in this mode (they start/stop GDM manually).

## Phase 5 — Reboot + verify

Reboot now to apply the GRUB parameters, dGPU power-off, initramfs, logind and
desktop/toggle changes.

```bash
reboot
```

After it comes back:

```bash
cat /proc/cmdline                            # expect libata.force=noncq intel_iommu=off
lspci -k | grep -A2 -E 'VGA|Network'
cat /sys/kernel/debug/vgaswitcheroo/switch   # 2:DIS: :Off:0000:01:00.0
cat /sys/bus/pci/devices/0000:01:00.0/power_state   # D3hot
cat /sys/class/drm/card1-eDP-1/status        # connected
systemctl is-active ssh tailscaled docker mbpfan
systemctl is-active gdm                         # active = GUI on boot (default)
systemctl is-active snapd                       # inactive = snapd off at boot
ufw status | head -1
tailscale status | head -3
```

From the client laptop: `ssh "$ADMIN_USER"@<tailscale-name>` -> key-only login, and
it survives lid-close. That is the working state.

## Gotchas learned on real hardware

- **GRUB quirks are mandatory here**: `libata.force=noncq` (Apple SSD NCQ bug) and
  `intel_iommu=off` (Apple DMAR). Set before first boot.
- **dGPU power-off needs `amdgpu` bound.** With the driver blacklisted there is no
  switcheroo client, no `switch` node, and the card sits in D0. Bind it and let
  `dgpu-off.service` cut the power (2.1).
- **Keep GNOME Shell off the dGPU.** It races amdgpu at boot and hangs if it picked
  the card before the power cut. The `72-dgpu-ignore.rules` udev rule plus
  `Before=gdm.service` on `dgpu-off` prevent it (2.1).
- **`gpu-power-prefs` does not persist** on this firmware, and would not cut power anyway.
- **apt can ship a broken `noble/main` index**; re-index if `liberror-perl` is missing.
- **Disable password auth only after key login is proven.** Keep local access as the
  recovery path (or re-enable passwords with a `sed` on the hardening drop-in).
- **Back up the client private key**; with passwords off, losing it needs local access.
- **Local IP is DHCP** and may change (e.g. `<LAN IP>`); prefer the Tailscale name.
- **Docker is installed but off by default** (no containers on an idle box). Use
  `dockeron` / `dockeroff` / `dkstat`. Because the daemon is disabled, containers
  will **not** autostart after a reboot until you run `dockeron`.
- **Unused devices are off**: Bluetooth soft-blocked, `uvcvideo` blacklisted,
  SD reader deauthorized (see 2.5 for the one-line reverts). The card reader's USB
  path (`2-4`) is stable on this model but can change if USB topology changes.
- **Unused services are off**: CUPS (`cups.path/socket/service`), `cups-browsed`,
  `ModemManager`, and the `motd-news`/`update-notifier` timers (see 2.6). Re-enable
  with `systemctl enable --now <unit>`. `unattended-upgrades` is kept for security.
- **snapd is off at boot** and toggled by `don`/`doff` (it only backs GUI snaps
  like Firefox/snap-store; ~48 MB). Don't expect `snap` commands or auto
  snap updates while the desktop is off.
- **avahi-daemon is not needed** here (mDNS is unrelated to the NIC, so a future
  USB Ethernet adapter does not require it). It's left running only because it is
  tiny; its sole consumer, `cups-browsed`, is disabled.
- **Default boots to the GUI.** GDM is enabled via `display-manager.service` (→
  `gdm3`) and `graphical.target`, so it loads on every reboot; `doff` only stops it
  for the current boot. `systemctl disable gdm` is a **no-op** (static unit) — to
  boot without a GUI use `set-default multi-user.target` + remove
  `/etc/systemd/system/display-manager.service` (see 4.4).
- **Battery health** may be degraded (this unit: 56%); fine on AC, poor unplugged.
- **Wi-Fi power-save is off** (`wifi.powersave=2` in `/etc/NetworkManager/conf.d/99-wifi-powersave.conf`
  plus pinned per connection) to cut latency jitter (~40 ms -> ~3 ms `mdev`) for a
  cost of ~0.1-0.4 W. It only added jitter, never packet loss, so this is a
  latency-over-power choice, not a fix. Re-enable per connection with
  `nmcli connection modify <name> wifi.powersave 3` if you want battery life.

## Bundled script

`scripts/setup.sh` implements Phases 1-4 (all non-interactive steps) in this order
and prints the manual follow-ups. Set the variables at the top (or export them),
then run as root. See the header of `scripts/setup.sh` for options.

Relevant options: `SKIP_DEVICES=1` (keep Bluetooth/camera/SD reader on),
`SKIP_SERVICES=1` (keep CUPS/ModemManager/update-notifier on),
`SKIP_WIFI_PS=1` (keep Wi-Fi power-save on — battery over latency),
`DOCKER_ON=1` (leave Docker enabled at boot instead of on-demand),
`HEADLESS=1` (boot to a text console instead of the default GUI-on-boot), plus
`SKIP_DGPU`, `SKIP_GRUB`.
