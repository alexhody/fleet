---
name: macbookpro-macos-setup
description: Use when provisioning an Apple Silicon MacBook Pro on macOS (the neptune worker) into a remote agentic-coding and mobile-testing worker for React Native, iOS, Android and web, driven from the control laptop over Tailscale and SSH. Runs scripts/setup.sh (no sleep, no auto-updates, auto-login, SSH, Screen Sharing, Tailscale daemon with Tailscale SSH, Spotlight off, open-file limit, Homebrew toolchain, JDK 17, Node, Xcode, Android SDK + AVD, Claude Code, Codex, opencode, Argent MCP), then the manual logins and scripts/verify.sh. Also installs an optional self-hosted RustDesk server (scripts/rustdesk-server.sh). Trigger on "set up neptune", "RustDesk server", "set up another mac", "reprovision the mac worker", "new MacBook worker", "neptune broke", "neptune unreachable".
---

# MacBook Pro macOS → agentic-coding + mobile-testing worker

Target: Apple Silicon MacBook Pro, current macOS, user `neptune`, name
`neptune-mbp`. First built on a MacBookPro18,2 (M1 Max, 32 GB). It lives in the
server room and is driven from the control laptop over Tailscale and SSH.

Everything scriptable is in `scripts/setup.sh`. `scripts/verify.sh` checks the
result. If something breaks later, or a step needs undoing, see
`TROUBLESHOOTING.md`.

Budget for 32 GB: two or three agent sessions, each with at most one iOS
simulator or Android emulator. More than that swaps.

## 1. At the Mac (once)

These need the local keyboard or an Apple ID. Everything else runs remotely.

1. Setup Assistant: create admin user `neptune`. **Do not turn on FileVault.**
   If it is on, turn it off in System Settings > Privacy & Security > FileVault.
2. Sign in to the App Store and install **Xcode**. It is large; start it first.
3. System Settings > General > Sharing: turn on **Remote Login** and **Screen Sharing**.
4. System Settings > Battery > Charging (info button): **Charge Limit 80%**.
5. Note the LAN IP: `ipconfig getifaddr en0` (or the Ethernet adapter's `enX`).

Hardware: power adapter in, wired Ethernet through a USB-C adapter, and an HDMI
dummy plug before you close the lid. Without an external display (or the dummy
plug), a closed MacBook lid forces sleep regardless of settings.

## 2. Run setup (from the control laptop)

From the repo root:

```bash
IP=192.168.x.y                                    # LAN IP from step 1
ssh-copy-id -i ~/.ssh/id_ed25519.pub neptune@$IP
scp setup/macbookpro-macos-setup/scripts/setup.sh neptune@$IP:
ssh -t neptune@$IP 'MAC_NAME=neptune-mbp bash ~/setup.sh'
```

Run it as `neptune`, not with sudo: Homebrew refuses root. It asks for the sudo
password once, and for the login password once each for auto-login and screen
lock if those are not set yet. It takes 20 to 40 minutes on a fresh Mac, mostly
Homebrew, Android Studio and the SDK. It is safe to re-run. Password SSH stays
on until step 3.

| Option | Effect |
| --- | --- |
| `MAC_NAME=neptune-mbp` | computer, Bonjour and host name |
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
| Login | auto-login as `neptune`, no screen lock, no screen saver | `sysadminctl -autologin`, `sysadminctl -screenLock off` |
| Name | `neptune-mbp` for ComputerName, LocalHostName, HostName | `scutil` |
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

```bash
ssh -t neptune@$IP 'sudo tailscale up --ssh --hostname=neptune-mbp'   # open the printed URL, approve
ssh neptune@$IP tailscale ip -4                                         # note the 100.x IP
```

In the Tailscale admin console:

- **Disable key expiry** for `neptune-mbp` (machine menu). Otherwise it logs out
  after 180 days and needs a browser login in the server room.
- Restrict Tailscale SSH to your own user with an `ssh` rule in the ACL.
- Remove the old node if this Mac was on the tailnet before with the GUI app.

Point `~/.ssh/config` on the control laptop at it:

```
Host neptune
    HostName neptune-mbp
    User neptune
    IdentityFile ~/.ssh/id_ed25519
    UseKeychain yes
    AddKeysToAgent yes
```

Turn off password auth for LAN SSH only after a key-only login succeeds. sshd
starts per connection on macOS, so no restart is needed:

```bash
ssh -o PreferredAuthentications=publickey neptune@$IP true && \
ssh -t neptune "sudo sed -i '' 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config.d/000-fleet-hardening.conf && sudo sshd -t"
```

## 4. Reboot and verify

```bash
ssh -t neptune sudo reboot                  # back in about 60 s, logged in on its own
ssh neptune bash -s < setup/macbookpro-macos-setup/scripts/verify.sh
```

Every line must read `ok`. `on-ac` fails when the adapter is out. For any
`FAIL`, see `TROUBLESHOOTING.md`.

## 5. Log in the agents (once)

```bash
ssh -t neptune claude auth login            # open the URL here, paste the code back
ssh -t neptune codex login --device-auth
ssh -t neptune opencode auth login
ssh -t neptune gh auth login                # GitHub.com, HTTPS, yes to git credentials
ssh neptune 'git config --global user.name "<git name>"; git config --global user.email <personal email>'
ssh neptune 'claude auth status; codex login status; gh auth status'
```

Optional: `ssh neptune argent telemetry disable`.

## 6. Daily use

- Run agents inside tmux so they outlive the SSH connection:
  `ssh -t neptune tmux new -A -s main`, then `claude --remote-control` to drive
  the session from claude.ai/code or the Claude app as well.
- For parallel agents on one repo, give each a git worktree and its own
  simulator or emulator. Argent's tools take the device id.
- GUI when needed: Screen Sharing to `vnc://neptune-mbp` over Tailscale.
- Emulators run headless: `emulator -avd Pixel_10 -no-window -no-audio -no-boot-anim`.
  Keep snapshots on: warm boot is about 3 s, cold about 25 s.
- Dev servers on neptune are reachable from the laptop at `neptune-mbp:<port>`.
- macOS and Xcode update only by hand, over Screen Sharing, when your React
  Native version supports the new SDK.

## 7. RustDesk server (optional)

A self-hosted RustDesk ID server (`hbbs`) and relay (`hbbr`) for remote
desktop over Tailscale and the LAN. RustDesk ships server binaries only for
Linux and Windows, so the script builds them from source:

```bash
ssh neptune 'bash ~/Code/fleet/setup/macbookpro-macos-setup/scripts/rustdesk-server.sh'
```

It installs Rust from Homebrew if needed, builds `RUSTDESK_VERSION` (default
1.1.16) in `~/Library/Caches/rustdesk-server`, and runs both as launchd agents
(`com.rustdesk.hbbs`, `com.rustdesk.hbbr`) that start at auto-login and restart
if they exit. Both run with `-k _`: only clients with the server's key connect.
Files follow the Homebrew layout, which `neptune` owns, so no sudo is needed.
Safe to re-run; run it again with a new `RUSTDESK_VERSION` to upgrade.

| Item | Where |
| --- | --- |
| Binaries | `/opt/homebrew/bin/{hbbs,hbbr}` |
| Key pair, peer DB | `/opt/homebrew/var/rustdesk-server/` (back up `id_ed25519`) |
| Logs | `/opt/homebrew/var/log/rustdesk-server/` |
| Source, build cache | `~/Library/Caches/rustdesk-server` (about 2 GB, safe to delete) |
| Ports | TCP 21115-21117, UDP 21116, TCP 21118/21119 (web client) |

Every RustDesk app that uses this server, including neptune's own, needs the
same two settings in Settings > Network > Unlock network settings > ID/Relay
server:

- **ID server**: `neptune-mbp` (Tailscale), or the LAN IP for devices not on the tailnet
- **Key**: `ssh neptune cat /opt/homebrew/var/rustdesk-server/id_ed25519.pub`
- **Relay server** and **API server**: empty. The relay defaults to the ID server host; the API is Pro only.

To control neptune's own desktop, set up its RustDesk app once over Screen
Sharing (`open vnc://neptune-mbp`):

1. `brew install --cask rustdesk`, open it, and enter the server settings above.
2. Allow **Screen Recording** and **Accessibility** when it asks (System
   Settings > Privacy & Security). Without them, sessions show a black screen
   or ignore input.
3. If it says the service is not running, click **Start service** (admin
   password), so it runs after a reboot.
4. Settings > Security > Unlock security settings > **Set permanent password**.
   Until then only the one-time password shown in its window works.
5. Note the ID in its main window (`<rustdesk id>` on neptune-mbp now). Other
   devices connect to that ID with the permanent password.

When the app first registers, its log shows one `UUID_MISMATCH` and then
registers its key; that is normal. Errors about port 21114 (`/api/...`) are
the Pro-only API and can be ignored.
