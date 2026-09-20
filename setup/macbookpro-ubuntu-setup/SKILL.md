---
name: macbookpro-ubuntu-setup
description: Use ONLY when provisioning a freshly installed Ubuntu on an Apple MacBook Pro (MacBookPro11,x, e.g. 11,5) for headless remote agentic-coding use. Covers required GRUB kernel parameters, Apple driver checks, disabling the AMD dGPU (iGPU-only), key-only SSH, Tailscale, no-sleep/lid handling, dev toolchain, mbpfan, UFW hardening, and the Wi-Fi regulatory domain. Trigger on "fresh Ubuntu on MacBook Pro", "set up this MacBook", "SSH into the Ubuntu MacBook".
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
applies the GRUB parameters, dGPU blacklist, initramfs, and logind changes.

```
Phase 0  Preflight        read-only: identify box, collect inputs, driver sanity
Phase 1  Boot parameters  GRUB cmdline quirks (SSD NCQ, IOMMU)             <-- first
Phase 2  Hardware         dGPU off, fans, Wi-Fi reg domain, power/sleep
Phase 3  Remote access    base pkgs, key-only SSH, Tailscale, UFW
Phase 4  Workload         dev toolchain, Docker, Node/uv, Pro, (headless)
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

### 2.1 Disable the AMD dGPU (use the Intel iGPU only)

The AMD R9 M370X has no working runtime PM (`amdgpu: Runtime PM not available`) and
the indexed gmux does **not** let Linux cut its power rail. Keep the driver from
binding so only the iGPU is used. Do **not** rely on the `gpu-power-prefs` EFI
variable — Apple's firmware clears it on reboot.

```bash
cat > /etc/modprobe.d/blacklist-amdgpu.conf <<'EOF'
# MacBookPro11,x: disable AMD dGPU, use Intel iGPU only
blacklist radeon
blacklist amdgpu
EOF
update-initramfs -u        # takes effect on the Phase 5 reboot
```

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

**Phase 2 verify:** iGPU drives the panel, dGPU has no driver, fans active,
`iw reg get` shows your country, sleep targets masked.

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

### 4.1 Dev packages + Docker

```bash
apt-get install -y \
  git build-essential ca-certificates curl wget gnupg unzip zip \
  tmux screen htop jq ripgrep fd-find bat tree gh \
  python3-pip python3-venv python3-dev docker.io docker-compose-v2
ln -sf "$(command -v fdfind)" /usr/local/bin/fd
ln -sf "$(command -v batcat)" /usr/local/bin/bat
usermod -aG docker "$ADMIN_USER"
systemctl enable --now docker
```

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

### 4.4 Optional: go headless

Frees ~0.5–1 GB RAM for agents. Skip if you want the desktop.

```bash
systemctl disable --now gdm
systemctl set-default multi-user.target
```

Add `don`/`doff`/`dstat` helpers so the desktop can be toggled on demand
(written to `~/.bash_aliases`, which Ubuntu's default `~/.bashrc` sources):

```bash
cat >> ~/.bash_aliases <<'EOF'
# Desktop session toggles
unalias don doff 2>/dev/null
BL=/sys/class/backlight/gmux_backlight
BL_STATE=$HOME/.doff_brightness

don() {
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
}

alias dstat='systemctl is-active gdm'
EOF
```

- `don` — start GDM (switch to it with `Fn+Ctrl+Alt+F2`; Apple F-keys need `Fn`).
- `doff` — power off the panel backlight, then stop GDM. Run from SSH — it
  blanks the local screen.
- `dstat` — show GDM status.

## Phase 5 — Reboot + verify

Reboot now to apply the GRUB parameters, dGPU blacklist, initramfs, logind and
headless changes.

```bash
reboot
```

After it comes back:

```bash
cat /proc/cmdline                            # expect libata.force=noncq intel_iommu=off
lspci -k | grep -A2 -E 'VGA|Network'
lsmod | grep -E 'amdgpu|radeon' || echo "dGPU drivers not loaded (good)"
cat /sys/class/drm/card1-eDP-1/status        # connected
systemctl is-active ssh tailscaled docker mbpfan
ufw status | head -1
tailscale status | head -3
```

From the client laptop: `ssh "$ADMIN_USER"@<tailscale-name>` -> key-only login, and
it survives lid-close. That is the working state.

## Gotchas learned on real hardware

- **GRUB quirks are mandatory here**: `libata.force=noncq` (Apple SSD NCQ bug) and
  `intel_iommu=off` (Apple DMAR). Set before first boot.
- **dGPU cannot be powered off.** Blacklist only; it stays at D0. Don't chase it.
- **`gpu-power-prefs` does not persist** on this firmware.
- **apt can ship a broken `noble/main` index**; re-index if `liberror-perl` is missing.
- **Disable password auth only after key login is proven.** Keep local access as the
  recovery path (or re-enable passwords with a `sed` on the hardening drop-in).
- **Back up the client private key**; with passwords off, losing it needs local access.
- **Local IP is DHCP** and may change (e.g. `<LAN IP>`); prefer the Tailscale name.
- **Battery health** may be degraded (this unit: 56%); fine on AC, poor unplugged.

## Bundled script

`scripts/setup.sh` implements Phases 1-4 (all non-interactive steps) in this order
and prints the manual follow-ups. Set the variables at the top (or export them),
then run as root. See the header of `scripts/setup.sh` for options.
