---
name: neptune
description: Use when provisioning, reprovisioning or fixing neptune, the MacBookPro18,2 (M1 Max, 32 GB) macOS worker for work projects and mobile testing, or when setting up its self-hosted RustDesk server. Runs the generic setup/macos-worker skill with neptune's values, then the optional scripts/rustdesk-server.sh. Trigger on "set up neptune", "reprovision neptune", "neptune broke", "neptune unreachable", "RustDesk server", "remote desktop to neptune".
---

# neptune — MacBookPro18,2 macOS worker

Target: MacBookPro18,2 (M1 Max, 10 cores, 32 GB), current macOS, user
`neptune`, name `neptune-mbp`, on the personal tailnet. It lives in the server
room, for work projects and unattended mobile work (see `FLEET.md`).

Provisioning follows `setup/macos-worker/SKILL.md` (step 0 first) with
`U=neptune NAME=neptune-mbp H=neptune`. This file covers only what differs and
the RustDesk server. Problems are in `setup/macos-worker/TROUBLESHOOTING.md`.

## Differences from the generic steps

- **Step 1:** wired Ethernet through a USB-C adapter and an HDMI dummy plug
  (the lid stays closed in the server room).
- **Step 2:** `ssh -t neptune@$IP 'MAC_NAME=neptune-mbp bash ~/setup.sh'`, with
  the default options (Android Studio, AVD `Pixel_10`, no OrbStack).
- **Step 3:** SSH config on jupiter:

  ```
  Host neptune
      HostName neptune-mbp.<tailnet>.ts.net
      User neptune
      IdentityFile ~/.ssh/id_ed25519
      UseKeychain yes
      AddKeysToAgent yes
  ```

  Tailscale SSH runs in check mode, so a login can print a `login.tailscale.com`
  link to approve first. On the same LAN, `ssh neptune@neptune-mbp.local` uses
  the key in `~/.ssh/authorized_keys` instead.
- **Step 5:** git commits with the work email from `credentials.md`.
- `sudo` asks for a password, so anything that needs it runs from neptune's T3
  terminal. A restart without sudo:
  `ssh neptune 'osascript -e "tell application \"System Events\" to restart"'`.

Health check: `ssh neptune bash -s < setup/macos-worker/scripts/verify.sh`. It
also checks the RustDesk ports once the server is installed.

## RustDesk server

A self-hosted RustDesk ID server (`hbbs`) and relay (`hbbr`) for remote
desktop over Tailscale and the LAN. RustDesk ships server binaries only for
Linux and Windows, so the script builds them from source:

```bash
ssh neptune 'bash ~/Code/fleet/setup/neptune/scripts/rustdesk-server.sh'
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

- **ID server**: `neptune-mbp.<tailnet>.ts.net` (Tailscale), or `neptune-mbp.local` for devices on its LAN but not on the tailnet
- **Key**: `ssh neptune cat /opt/homebrew/var/rustdesk-server/id_ed25519.pub`
- **Relay server** and **API server**: empty. The relay defaults to the ID server host; the API is Pro only.

To control neptune's own desktop, set up its RustDesk app once over Screen
Sharing (`open vnc://neptune-mbp.<tailnet>.ts.net`):

1. `brew install --cask rustdesk`, open it, and enter the server settings above.
2. Allow **Screen Recording** and **Accessibility** when it asks (System
   Settings > Privacy & Security). Without them, sessions show a black screen
   or ignore input.
3. If it says the service is not running, click **Start service** (admin
   password), so it runs after a reboot.
4. Settings > Security > Unlock security settings > **Set permanent password**.
   Until then only the one-time password shown in its window works.
5. Note the ID in its main window and record it in `credentials.md`. Other
   devices connect to that ID with the permanent password.

When the app first registers, its log shows one `UUID_MISMATCH` and then
registers its key; that is normal. Errors about port 21114 (`/api/...`) are
the Pro-only API and can be ignored.

To remove the server:

```bash
for b in hbbs hbbr; do launchctl bootout gui/$(id -u)/com.rustdesk.$b; rm ~/Library/LaunchAgents/com.rustdesk.$b.plist /opt/homebrew/bin/$b; done; rm -rf /opt/homebrew/var/rustdesk-server /opt/homebrew/var/log/rustdesk-server ~/Library/Caches/rustdesk-server
```

That deletes the key: clients need the new one after a reinstall.
