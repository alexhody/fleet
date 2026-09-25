---
name: linux-worker
description: Use when provisioning any Ubuntu or Debian machine (laptop, PC, mini PC) into a remote agentic-coding worker driven from the control laptop through T3 Connect, Tailscale and key-only SSH, or when tuning, measuring or fixing one. Runs scripts/setup.sh (quiet text console, no-sleep, SSH, Tailscale, UFW, unused services off, zram/tmpfs/BBR, crash recovery, dev toolchain, Claude Code, Codex, opencode), then the machine's own script if it has one, the logins, T3 Connect and scripts/verify.sh. TUNING.md covers idle power, throttling and undervolting. Trigger on "set up a Linux worker", "new Ubuntu worker", "provision a PC as a worker", "worker idles at high power", "worker throttles", "undervolt".
---

# Ubuntu/Debian → agentic-coding worker

Any apt-based machine that runs agents unattended and is driven from the
control laptop through T3 Connect, Tailscale and key-only SSH. `FLEET.md` covers
the daily workflow.

Everything generic is in `scripts/setup.sh`, and `scripts/verify.sh` checks it.
Machine quirks (drivers, fans, firmware) live in that machine's folder, for
example `setup/saturn/`. If something breaks later, or a step needs undoing, see
`TROUBLESHOOTING.md`. To cut idle power or find why it throttles, see
`TUNING.md` and `MEASURE.md`.

The commands below use `U` for the login user and `H` for the SSH alias, both
usually the machine's name (`saturn`).

## 0. Before you start

Read `fleet.local.md` at the repo root (copy `fleet.local.example.md` if it is
missing). Before running any command, ask the user in one go for whatever it
lacks:

- login user and host name (`<user>-mbp`), and whether it is a work or a
  personal machine (that picks the git email)
- the machine's current LAN IP, for the first connection
- tailnet and Tailscale account, T3 Connect account, GitHub account, git name
  and email
- Wi-Fi country

Offer to save new answers to `fleet.local.md`.

Secrets never go into chat, files, commands or this repo. The user types them
only at the machine's own prompts: the login and sudo password, and the
browser approvals (Tailscale link, T3 device code, `claude`, `codex` and `gh`
logins). Prefer those interactive logins over auth keys or tokens; if one is
ever needed, the user pastes it at the prompt on the machine.

## 1. At the machine (once)

Install Ubuntu, create the login user, join the network, then:

```bash
sudo apt-get update && sudo apt-get install -y openssh-server
ip -brief addr                   # note the LAN IP
```

That is the only step that needs the local keyboard. Set the BIOS to power on
after AC loss if it offers that.

## 2. Run setup (from the control laptop)

From the repo root:

```bash
IP=192.168.x.y U=<user>                               # LAN IP from step 1
ssh-copy-id -i ~/.ssh/id_ed25519.pub $U@$IP
scp setup/linux-worker/scripts/setup.sh $U@$IP:
ssh -t $U@$IP 'sudo COUNTRY=<cc> bash ~/setup.sh'
```

Then run the machine's own script if it has one (`setup/<host>/SKILL.md` says
how), before the first reboot. Setup takes about 10 minutes and is safe to
re-run. Password SSH stays on until step 3.

| Option | Effect |
| --- | --- |
| `COUNTRY=<cc>` | Wi-Fi regulatory domain (skipped if unset) |
| `DOCKER_ON=1` | Docker running at boot (default: installed, off) |
| `GUI_ON_BOOT=1` | boot straight to the desktop (default: text console) |
| `SKIP_NOPASSWD=1` | keep the sudo password prompt (default: passwordless sudo) |
| `SKIP_GRUB`, `SKIP_WIFI_PS`, `SKIP_SERVICES`, `SKIP_TUNING` | skip that part |

What it sets up:

| Area | Result | Files |
| --- | --- | --- |
| Boot | `quiet loglevel=3 consoleblank=60`, no splash; text console shows only the login prompt and blanks the panel after 60 s | `/etc/default/grub`, `/etc/sysctl.d/20-quiet-console.conf` |
| Power | never sleeps, ignores the lid and power key | `/etc/systemd/logind.conf.d/99-no-sleep.conf` |
| Wi-Fi | country set, power-save off | `wifi-regdom.service`, `/etc/NetworkManager/conf.d/99-wifi-powersave.conf` |
| Off | CUPS, ModemManager, update notifiers, SSSD, colord, rsyslog, remote desktop, firmware update checks, boot wait for Wi-Fi | |
| Removed | snapd and every snap (Firefox, Snap Store, …), pinned so apt can't reinstall it (Chrome from apt is unaffected); apport | `/etc/apt/preferences.d/no-snapd` |
| Memory/disk/net | zram swap (zstd), `noatime`, tmpfs `/tmp`, inotify 524288, BBR + `fq` | `/etc/systemd/zram-generator.conf`, `/etc/fstab`, `/etc/sysctl.d/60-fleet-perf.conf` |
| Crash recovery | a kernel hang or oops panics, saves a dump, reboots in 10 s; dumps cleared from EFI NVRAM once archived | `/etc/sysctl.d/61-crash-reboot.conf`, `pstore-efi-cleanup.service` |
| Access | SSH (hardening file left alone on re-runs), Tailscale, UFW (everything on tailscale0; SSH and mDNS from any private LAN range), avahi for `<name>.local`, passwordless sudo (the console login still asks for the password) | `/etc/ssh/sshd_config.d/99-hardening.conf`, `/etc/sudoers.d/zz-<user>-nopasswd` |
| Toolchain | build-essential, git, gh, tmux, rg, fd, jq, Python, Docker, fnm + Node LTS, uv | |
| Agents | Claude Code, Codex, opencode; tool PATH above the `.bashrc` interactive guard; `~/jobs`, `~/Code` | `~/.bashrc` |
| Shell | `don`/`doff`/`dstat` (desktop; `doff` also turns the panel's backlight off), `dockeron`/`dockeroff`/`dkstat` (Docker), no sudo password | `~/.bash_aliases`, `/etc/sudoers.d/desktop-toggles`, `/etc/sudoers.d/docker-toggles` |

## 3. Tailscale and key-only SSH

Join the tailnet from `fleet.local.md` and approve as its Tailscale account:

```bash
ssh -t $U@$IP 'sudo tailscale up'       # open the printed URL here and approve
```

In the admin console, disable key expiry for the node. Then point
`~/.ssh/config` on the control laptop at it:

```
Host <alias>
    HostName <name>.<tailnet>.ts.net
    User <user>
    IdentityFile ~/.ssh/id_ed25519
    UseKeychain yes
    AddKeysToAgent yes
```

Turn off password auth only after a key-only login succeeds:

```bash
H=<alias>
ssh -o PreferredAuthentications=publickey $H true && \
ssh -t $H "sudo sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config.d/99-hardening.conf && sudo sshd -t && sudo systemctl restart ssh"
```

## 4. Reboot and verify

```bash
ssh -t $H sudo reboot                    # back in about 30 s
ssh $H bash -s < setup/linux-worker/scripts/verify.sh
```

Every line must read `ok`. Run the machine's own `verify.sh` too, if it has one.
For any `FAIL`, see `TROUBLESHOOTING.md`.

## 5. Log in the agents (once)

```bash
ssh -t $H claude auth login              # open the URL here, paste the code back
ssh -t $H codex login --device-auth
ssh -t $H opencode auth login
ssh -t $H gh auth login                  # GitHub.com, HTTPS, yes to git credentials
GIT_NAME='<git name>' GIT_EMAIL=<git email>   # fleet.local.md: work or personal email
ssh $H "git config --global user.name '$GIT_NAME'; git config --global user.email $GIT_EMAIL"
ssh $H 'claude auth status; codex login status; gh auth status'
```

Optional on Ubuntu: `sudo pro attach <TOKEN> && sudo pro enable esm-apps esm-infra livepatch`.

## 6. T3 Code service and T3 Connect

Needs the `t3` CLI in `~/.local/bin` (T3 Code installs it the first time it
connects to the host over SSH).

```bash
ssh $H 't3 service install'
ssh -t $H 't3 connect link --headless'   # yes to the relay client; approve the code with the personal T3 account
ssh $H 't3 service restart && t3 connect status'
```

`t3 connect status` must show `Environment link: provisioned`. On jupiter, pick
the host in T3 Code under Settings → Connections. From then on its terminal is
a way in that doesn't need Tailscale (see `FLEET.md`).

## 7. Daily use

- It boots to a text console with the network, SSH and Tailscale up. `don`
  starts the desktop (about 5 s), `doff` stops it and turns the panel off,
  `dstat` reports. None asks for a password.
- `sudo` never asks for a password (installs, apt). The password is only needed
  at the text-console login after a reboot.
- Docker stays off until `dockeron` (`dockeroff` to stop, `dkstat` for status). No
  password either. Containers don't come back after a reboot.
- Dev servers are reachable from the laptop at `<name>.<tailnet>.ts.net:<port>`.
- On the same LAN, `ssh <user>@<name>.local` skips Tailscale. The name follows
  whatever network it's on, so no IP is kept anywhere.
- Keep job files in `~/jobs`. `/tmp` is RAM and is wiped on every boot.
- If it hangs, it reboots itself within about 40 s. Crash dumps land in
  `/var/lib/systemd/pstore/` (see `TROUBLESHOOTING.md`).
- Hand work over through T3 Code, `claude --bg` or tmux + `claude -p` (see `FLEET.md`).
