---
name: macos-worker
description: Use when provisioning any Apple Silicon Mac on macOS into a remote agentic-coding and mobile-testing worker for React Native, iOS, Android and web, driven from the control laptop through T3 Connect, Tailscale and SSH, or when fixing one. Runs scripts/setup.sh (no sleep, no auto-updates, auto-login, SSH, Screen Sharing, Tailscale daemon with Tailscale SSH, Spotlight off, open-file limit, Homebrew toolchain, JDK 17, Node, Xcode, Android SDK + AVD, Claude Code, Codex, opencode, Argent MCP), then the logins, T3 Connect and scripts/verify.sh. Trigger on "set up a Mac worker", "set up another mac", "new MacBook worker", "Mac worker unreachable", "simulators fail on the worker".
---

# Apple Silicon Mac → agentic-coding + mobile-testing worker

Target: any Apple Silicon Mac on current macOS, driven from the control laptop
through T3 Connect, Tailscale and SSH. `FLEET.md` covers the daily workflow.
Machine-specific notes and extras live in that machine's folder, for example
`setup/neptune/`.

Everything scriptable is in `scripts/setup.sh`. `scripts/verify.sh` checks the
result. If something breaks later, or a step needs undoing, see
`TROUBLESHOOTING.md`.

The commands below use `U` for the admin user, `NAME` for the host name
(`<user>-mbp`) and `H` for the SSH alias.

## 0. Before you start

Read `credentials.md` at the repo root (copy `credentials.example.md` if it is
missing). Before running any command, ask the user in one go for whatever it
lacks:

- login user and host name (`<user>-mbp`), and whether it is a work or a
  personal machine (that picks the git email)
- the machine's current LAN IP, for the first connection
- tailnet and Tailscale account, T3 Connect account, GitHub account, git name
  and email
- whether an Apple ID is signed in at the Mac for Xcode

Offer to save new answers to `credentials.md`.

Secrets never go into chat, files, commands or this repo. The user types them
only at the machine's own prompts: the login and sudo password (setup reads it
with `-password -`), the Apple ID at the Mac, and the browser approvals
(Tailscale link, T3 device code, `claude`, `codex` and `gh` logins). Prefer those interactive logins over auth keys or tokens; if one is
ever needed, the user pastes it at the prompt on the machine.

## 1. At the Mac (once)

These need the local keyboard or an Apple ID. Everything else runs remotely.

1. Setup Assistant: create the admin user. **Do not turn on FileVault.**
   If it is on, turn it off in System Settings > Privacy & Security > FileVault.
2. Sign in to the App Store and install **Xcode**. It is large; start it first.
3. System Settings > General > Sharing: turn on **Remote Login** and **Screen Sharing**.
4. System Settings > Battery > Charging (info button): **Charge Limit 80%**.
5. Note the LAN IP: `ipconfig getifaddr en0` (or the Ethernet adapter's `enX`).

Hardware: power adapter in, and wired Ethernet if it has a fixed place. A MacBook
needs an HDMI dummy plug before you close the lid: without an external display,
a closed lid forces sleep regardless of settings.

## 2. Run setup (from the control laptop)

From the repo root:

```bash
IP=192.168.x.y U=<user> NAME=<user>-mbp            # LAN IP from step 1
ssh-copy-id -i ~/.ssh/id_ed25519.pub $U@$IP
scp setup/macos-worker/scripts/setup.sh $U@$IP:
ssh -t $U@$IP "MAC_NAME=$NAME bash ~/setup.sh"
```

Run it as the admin user, not with sudo: Homebrew refuses root. It asks for the sudo
password once, and for the login password once each for auto-login and screen
lock if those are not set yet. It takes 20 to 40 minutes on a fresh Mac, mostly
Homebrew, Android Studio and the SDK. It is safe to re-run. Password SSH stays
on until step 3.

| Option | Effect |
| --- | --- |
| `MAC_NAME=<name>` | computer, Bonjour and host name |
| `SSH_PUBKEY="ssh-ed25519 …"` | authorize a key (not needed after `ssh-copy-id`) |
| `AUTOLOGIN=0` | skip auto-login (simulators then need a manual GUI login after reboot) |
| `ANDROID_STUDIO=0` | skip the Android Studio app; SDK and emulator still install |
| `ANDROID_PACKAGES`, `AVD_NAME`, `AVD_DEVICE`, `AVD_IMAGE`, `AVD_RAM` | Android SDK set and the AVD to create |
| `NPM_GLOBALS="…"` | global npm packages (default Argent, eas-cli, vercel) |
| `ORBSTACK=1` | also install OrbStack for Docker |
| `SKIP_POWER`, `SKIP_REMOTE`, `SKIP_TUNING`, `SKIP_XCODE`, `SKIP_ANDROID`, `SKIP_AGENTS` | skip that part |
| `SUDO_ASKPASS=/path` | unattended run: sudo reads the password from that helper |

What it sets up:

| Area | Result | Files / commands |
| --- | --- | --- |
| Power | never sleeps on AC or battery, no standby/Power Nap/hibernate, wake on LAN, restart after freeze | `pmset`, `systemsetup -setrestartfreeze on` |
| Updates | no automatic macOS or App Store installs; checking and XProtect stay on | `/Library/Preferences/com.apple.SoftwareUpdate.plist`, `com.apple.commerce.plist` |
| Login | auto-login as the admin user, no screen lock, no screen saver | `sysadminctl -autologin`, `sysadminctl -screenLock off` |
| Name | `MAC_NAME` for ComputerName, LocalHostName, HostName | `scutil` |
| SSH | Remote Login on, root login off, password auth on until step 3 | `/etc/ssh/sshd_config.d/000-fleet-hardening.conf` |
| GUI access | Screen Sharing on port 5900 | `com.apple.screensharing` |
| Tailscale | GUI app removed; Homebrew `tailscaled` system daemon, starts before login, serves Tailscale SSH | `brew services` (`sh.brew.tailscale`) |
| Tuning | Spotlight indexing off; open-file limit 65536 for SSH and GUI sessions (launchd default is 256) | `mdutil -a -i off`, `/Library/LaunchDaemons/limit.maxfiles.plist` |
| Toolchain | Homebrew, git, gh, tmux, jq, ripgrep, watchman, CocoaPods, bun, starship, JDK 17 (registered for `java_home`) | `/Library/Java/JavaVirtualMachines/openjdk-17.jdk` |
| Node | fnm + Node LTS as default, corepack (pnpm, yarn), Argent, eas-cli, vercel | `~/.local/share/fnm` |
| iOS | Xcode selected, license accepted, first launch done, iOS simulator runtime | `xcode-select`, `xcodebuild -downloadPlatform iOS` |
| Android | Android Studio, SDK (platform-tools, emulator, API 37, build-tools 36, arm64 16 KB Play image), AVD `Pixel_10` with 4 GB RAM | `~/Library/Android/sdk`, `~/.android/avd` |
| Agents | Claude Code, Codex, opencode; Argent registered as a user-scope MCP server; `~/Code`, `~/jobs` | `~/.claude.json` |
| Shell | tool PATH, `JAVA_HOME`, `ANDROID_HOME` in `~/.zshenv`, so non-interactive `ssh host cmd` finds every tool | `~/.zshenv`, `~/.zshrc` |

## 3. Tailscale and key-only SSH

Join the tailnet from `credentials.md` and approve as its Tailscale account:

```bash
ssh -t $U@$IP "sudo tailscale up --ssh --hostname=$NAME"   # open the printed URL, approve
```

In the Tailscale admin console:

- **Disable key expiry** for the node (machine menu). Otherwise it logs out
  after 180 days and needs a browser login in the server room.
- Restrict Tailscale SSH to your own user with an `ssh` rule in the ACL.
- Remove the old node if this Mac was on the tailnet before with the GUI app.

Point `~/.ssh/config` on the control laptop at it:

```
Host <alias>
    HostName <name>.<tailnet>.ts.net
    User <user>
    IdentityFile ~/.ssh/id_ed25519
    UseKeychain yes
    AddKeysToAgent yes
```

Turn off password auth for LAN SSH only after a key-only login succeeds. sshd
starts per connection on macOS, so no restart is needed:

```bash
H=<alias>
ssh -o PreferredAuthentications=publickey $U@$IP true && \
ssh -t $H "sudo sed -i '' 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config.d/000-fleet-hardening.conf && sudo sshd -t"
```

## 4. Reboot and verify

```bash
ssh -t $H sudo reboot                      # back in about 60 s, logged in on its own
ssh $H bash -s < setup/macos-worker/scripts/verify.sh
```

Every line must read `ok`. `on-ac` fails when the adapter is out.
The screen lock can't be read over SSH, so check it in System Settings >
Lock Screen: "Require password after screen saver begins" must be **Never**. For any
`FAIL`, see `TROUBLESHOOTING.md`.

## 5. Log in the agents (once)

```bash
ssh -t $H claude auth login            # open the URL here, paste the code back
ssh -t $H codex login --device-auth
ssh -t $H opencode auth login
ssh -t $H gh auth login                # GitHub.com, HTTPS, yes to git credentials
GIT_NAME='<git name>' GIT_EMAIL=<git email>   # credentials.md: work or personal email
ssh $H "git config --global user.name '$GIT_NAME'; git config --global user.email $GIT_EMAIL"
ssh $H 'claude auth status; codex login status; gh auth status'
```

Optional: `ssh $H argent telemetry disable`.

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

Most work goes through T3 Code (see `FLEET.md`). Beyond that:

- For agents outside T3, use tmux so they outlive the SSH connection:
  `ssh -t $H tmux new -A -s main`, then `claude --remote-control` to drive
  the session from claude.ai/code or the Claude app as well.
- For parallel agents on one repo, give each a git worktree and its own
  simulator or emulator. Argent's tools take the device id.
- GUI when needed: Screen Sharing to `vnc://<name>.<tailnet>.ts.net`.
- Emulators run headless: `emulator -avd Pixel_10 -no-window -no-audio -no-boot-anim`.
  Keep snapshots on: warm boot is about 3 s, cold about 25 s.
- Dev servers are reachable from the laptop at `<name>.<tailnet>.ts.net:<port>`.
- On the same LAN, `ssh <user>@<name>.local` (Bonjour) skips Tailscale. It uses
  the key in `~/.ssh/authorized_keys`, not Tailscale SSH.
- macOS and Xcode update only by hand, over Screen Sharing, when your React
  Native version supports the new SDK.
