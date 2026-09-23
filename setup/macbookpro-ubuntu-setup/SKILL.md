---
name: macbookpro-ubuntu-setup
description: Use when provisioning a fresh Ubuntu 24.04 install on a MacBook Pro 11,x (the saturn worker) into a remote agentic-coding worker driven from the control laptop over Tailscale and key-only SSH. Runs scripts/setup.sh (GRUB quirks, dGPU power-off, fans, no-sleep, SSH, Tailscale, UFW, memory/disk tuning, dev toolchain, Claude Code, Codex, opencode), then the manual logins and scripts/verify.sh. Trigger on "set up saturn", "reprovision the worker", "fresh Ubuntu on MacBook Pro", "saturn broke", "saturn won't boot".
---

# MacBook Pro Ubuntu → agentic-coding worker

Target: MacBookPro11,5, Ubuntu 24.04 with the HWE kernel, user `saturn`. It's
driven from the control laptop over Tailscale and key-only SSH.

Everything scriptable is in `scripts/setup.sh`. `scripts/verify.sh` checks the
result. If something breaks later, or a step needs undoing, see
`TROUBLESHOOTING.md`.

## 1. At the MacBook (once)

Install Ubuntu, create user `saturn`, join Wi-Fi, then:

```bash
sudo apt-get update && sudo apt-get install -y openssh-server
ip -brief addr show wlp4s0        # note the LAN IP
```

That is the only step that needs the local keyboard.

## 2. Run setup (from the control laptop)

From the repo root:

```bash
IP=192.168.x.y                                    # LAN IP from step 1
ssh-copy-id -i ~/.ssh/id_ed25519.pub saturn@$IP
scp setup/macbookpro-ubuntu-setup/scripts/setup.sh saturn@$IP:
ssh -t saturn@$IP 'sudo COUNTRY=<cc> LAN_CIDR=192.168.x.0/24 bash ~/setup.sh'
```

Takes about 10 minutes. It is safe to re-run. Password SSH stays on until step 3.

| Option | Effect |
| --- | --- |
| `COUNTRY=<cc>` | Wi-Fi regulatory domain (skipped if unset) |
| `CHARGE_LIMIT=80` | battery stops charging at this % (default 80, `100` for no limit) |
| `LAN_CIDR=…` | also allow SSH from the LAN (default: Tailscale only) |
| `DOCKER_ON=1` | Docker running at boot (default: installed, off) |
| `GUI_ON_BOOT=1` | boot straight to the desktop (default: text console) |
| `SKIP_GRUB`, `SKIP_DGPU`, `SKIP_WIFI_PS`, `SKIP_DEVICES`, `SKIP_SERVICES`, `SKIP_TUNING` | skip that part |

What it sets up:

| Area | Result | Files |
| --- | --- | --- |
| Boot | `quiet loglevel=3 libata.force=max_sec=2560 intel_iommu=off consoleblank=60`, no splash, `noncq-fallback` GRUB entry; text console shows only the login prompt and blanks the panel after 60 s | `/etc/default/grub`, `/etc/grub.d/40_custom`, `/etc/sysctl.d/20-quiet-console.conf` |
| SSD | I/O capped at 1280 KiB, NCQ on | `/etc/udev/rules.d/60-apple-ssd-max-sectors.rules` |
| dGPU | powered off through the gmux at boot, hidden from GNOME | `/etc/modprobe.d/blacklist-amdgpu.conf`, `/usr/local/sbin/dgpu-off`, `dgpu-off.service`, `/etc/udev/rules.d/72-dgpu-ignore.rules` |
| Thermal/power | mbpfan, `thermald` masked (~18 % faster sustained builds), battery stops charging at 80 % (set again on every boot), never sleeps, ignores lid | `/usr/local/sbin/bclm`, `battery-limit.service`, `/etc/systemd/logind.conf.d/99-no-sleep.conf` |
| Wi-Fi | country set, power-save off | `wifi-regdom.service`, `/etc/NetworkManager/conf.d/99-wifi-powersave.conf` |
| Off | Bluetooth (radio and USB controller), camera, SD reader, Thunderbolt (powered down; internal USB devices autosuspend), CUPS, ModemManager, update notifiers, SSSD, colord, avahi, rsyslog, remote desktop, firmware update checks, boot wait for Wi-Fi | `/etc/modprobe.d/{disable-camera,thunderbolt-off}.conf`, `/etc/udev/rules.d/70-{cardreader,bluetooth}-off.rules`, `/etc/udev/rules.d/71-idle-power.rules` |
| Removed | snapd and every snap (Firefox, Snap Store, …), pinned so apt can't reinstall it (Chrome from apt is unaffected); apport | `/etc/apt/preferences.d/no-snapd` |
| Memory/disk/net | zram swap (zstd), `noatime`, tmpfs `/tmp`, inotify 524288, BBR + `fq` | `/etc/systemd/zram-generator.conf`, `/etc/fstab`, `/etc/sysctl.d/60-fleet-perf.conf` |
| Crash recovery | a kernel hang or oops panics, saves a dump, reboots in 10 s; dumps cleared from NVRAM once archived | `/etc/sysctl.d/61-crash-reboot.conf`, `pstore-efi-cleanup.service` |
| Access | key-only SSH, Tailscale, UFW (tailscale0 + LAN:22) | `/etc/ssh/sshd_config.d/99-hardening.conf` |
| Toolchain | build-essential, git, gh, tmux, rg, fd, jq, Python, Docker, fnm + Node LTS, uv | |
| Agents | Claude Code, Codex, opencode; tool PATH above the `.bashrc` interactive guard; `~/jobs`, `~/Code` | `~/.bashrc` |
| Shell | `don`/`doff`/`dstat` (desktop), `dockeron`/`dockeroff`/`dkstat` (Docker), no sudo password | `~/.bash_aliases`, `/etc/sudoers.d/desktop-toggles`, `/etc/sudoers.d/docker-toggles` |

## 3. Tailscale and key-only SSH

```bash
ssh -t saturn@$IP 'sudo tailscale up'       # open the printed URL here and approve
ssh saturn@$IP tailscale ip -4               # note the 100.x IP
```

Point `~/.ssh/config` on the control laptop at it:

```
Host saturn
    HostName 100.x.y.z
    User saturn
    IdentityFile ~/.ssh/id_ed25519
    UseKeychain yes
    AddKeysToAgent yes
```

Turn off password auth only after a key-only login succeeds:

```bash
ssh -o PreferredAuthentications=publickey saturn true && \
ssh -t saturn "sudo sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config.d/99-hardening.conf && sudo sshd -t && sudo systemctl restart ssh"
```

## 4. Reboot and verify

```bash
ssh -t saturn sudo reboot                    # back in about 30 s
ssh saturn bash -s < setup/macbookpro-ubuntu-setup/scripts/verify.sh
```

Every line must read `ok`. For any `FAIL`, see `TROUBLESHOOTING.md`.

## 5. Log in the agents (once)

```bash
ssh -t saturn claude auth login              # open the URL here, paste the code back
ssh -t saturn codex login --device-auth
ssh -t saturn opencode auth login
ssh -t saturn gh auth login                  # GitHub.com, HTTPS, yes to git credentials
ssh saturn 'git config --global user.name "<git name>"; git config --global user.email <personal email>'
ssh saturn 'claude auth status; codex login status; gh auth status'
```

Optional: `sudo pro attach <TOKEN> && sudo pro enable esm-apps esm-infra livepatch`.

## 6. Daily use

- It boots to a text console with Wi-Fi, SSH and Tailscale up. `don` starts the
  desktop (about 5 s), `doff` stops it and turns the panel off, `dstat` reports.
  None asks for a password.
- Docker stays off until `dockeron` (`dockeroff` to stop, `dkstat` for status). No
  password either. Containers don't come back after a reboot.
- Dev servers on saturn are reachable from the laptop at `saturn-mbp:<port>`.
- Keep job files in `~/jobs`. `/tmp` is RAM and is wiped on every boot.
- If it hangs, it reboots itself within about 40 s. Crash dumps land in
  `/var/lib/systemd/pstore/` (see `TROUBLESHOOTING.md`).
- To hand work over, add `saturn` as an SSH environment in T3 Code, or run
  `ssh saturn 'bash -ls'` with a `claude --bg` or tmux + `claude -p` heredoc
  (see `FLEET.md`).
