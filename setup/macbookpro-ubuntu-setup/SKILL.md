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
| `LAN_CIDR=…` | also allow SSH from the LAN (default: Tailscale only) |
| `DOCKER_ON=1` | Docker running at boot (default: installed, off) |
| `HEADLESS=1` | boot to a text console instead of GDM |
| `SKIP_GRUB`, `SKIP_DGPU`, `SKIP_WIFI_PS`, `SKIP_DEVICES`, `SKIP_SERVICES`, `SKIP_TUNING` | skip that part |

What it sets up:

| Area | Result | Files |
| --- | --- | --- |
| Boot | `quiet libata.force=max_sec=2560 intel_iommu=off`, no splash, `noncq-fallback` GRUB entry | `/etc/default/grub`, `/etc/grub.d/40_custom` |
| SSD | I/O capped at 1280 KiB, NCQ on | `/etc/udev/rules.d/60-apple-ssd-max-sectors.rules` |
| dGPU | powered off through the gmux at boot, hidden from GNOME | `/etc/modprobe.d/blacklist-amdgpu.conf`, `/usr/local/sbin/dgpu-off`, `dgpu-off.service`, `/etc/udev/rules.d/72-dgpu-ignore.rules` |
| Thermal/power | mbpfan, never sleeps, ignores lid | `/etc/systemd/logind.conf.d/99-no-sleep.conf` |
| Wi-Fi | country set, power-save off | `wifi-regdom.service`, `/etc/NetworkManager/conf.d/99-wifi-powersave.conf` |
| Off | Bluetooth, camera, SD reader, CUPS, ModemManager, update notifiers, snapd at boot | `/etc/modprobe.d/disable-camera.conf`, `/etc/udev/rules.d/70-cardreader-off.rules` |
| Memory/disk | zram swap (zstd), `noatime`, tmpfs `/tmp`, inotify 524288 | `/etc/systemd/zram-generator.conf`, `/etc/fstab`, `/etc/sysctl.d/60-fleet-perf.conf` |
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

- It boots to GDM. After `ssh saturn`, run `doff` to stop the desktop and blank
  the panel. `don` brings it back. Neither asks for a password.
- Docker stays off until `dockeron` (`dockeroff` to stop, `dkstat` for status). No
  password either. Containers don't come back after a reboot.
- Dev servers on saturn are reachable from the laptop at `saturn-mbp:<port>`.
- Keep job files in `~/jobs`. `/tmp` is RAM and is wiped on every boot.
- To hand work over, add `saturn` as an SSH environment in T3 Code, or run
  `ssh saturn 'bash -ls'` with a `claude --bg` or tmux + `claude -p` heredoc
  (see `FLEET.md`).
