# Troubleshooting and fallbacks — MacBook Pro macOS worker

Each entry: what you see, why, and what to do. The commands assume `ssh neptune`
unless an entry says you need the local keyboard or Screen Sharing.

## Unreachable after a reboot

### No SSH, no Tailscale, no Screen Sharing after a reboot or power cut

Most likely FileVault. With FileVault on, the Mac stops at the pre-boot unlock
screen before any network comes up.

- **Recover (local keyboard):** type the password at the unlock screen.
- **Fix:** turn FileVault off in System Settings > Privacy & Security. Check with
  `fdesetup status`. Decrypting takes a while but the Mac stays usable.
- **If policy requires FileVault:** reboot only with
  `sudo fdesetup authrestart -delayminutes 0`, which unlocks the next boot once.
  It does not cover macOS updates, crashes or power loss. Auto-login is
  impossible with FileVault on.

### It comes back on the network, but simulators or Xcode fail

Nobody is logged in to the GUI. Simulators, Xcode signing and the keychain need
a window session.

- Check: `defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser`
  must print `neptune`.
- Fix: `sudo sysadminctl -autologin set -userName neptune -password -`, or
  System Settings > Users & Groups > Automatically log in as.
- Until the next reboot, log in once over Screen Sharing.

### It went to sleep with the lid closed

A closed MacBook lid forces sleep unless it is on power **and** sees a display.
`pmset sleep 0` does not override the lid switch.

- Fix: keep the adapter in and plug an HDMI dummy plug in. That is supported
  clamshell mode.
- Avoid `sudo pmset -a disablesleep 1`. It is undocumented, keeps a closed laptop
  running even on battery, and Apple can change it.
- Wake it: `wakeonlan <MAC of the Ethernet adapter>` from the LAN (`womp 1`), or
  open the lid.

### It rebooted by itself overnight

A macOS update installed. Check the settings:

```bash
defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates   # 0
defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload                  # 0
```

Re-run `setup.sh` with the other phases skipped to restore them. `softwareupdate
--schedule off` is deprecated on recent macOS and does nothing, so the script
does not rely on it.

## Remote access

### `systemsetup -setremotelogin on` says it needs Full Disk Access

The script uses `launchctl` instead, which does not:

```bash
sudo launchctl enable system/com.openssh.sshd
sudo launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist
```

On a fresh Mac, turn Remote Login on in System Settings for the very first
connection (SKILL.md step 1).

### SSH config change seems ignored

sshd keeps the **first** value it reads. `/etc/ssh/sshd_config` includes
`sshd_config.d/*` in name order, and `100-macos.conf` is Apple's. Our file is
`000-fleet-hardening.conf` so it wins. Validate with `sudo sshd -t`. sshd starts
per connection, so the next login already uses the new config.

### Locked out after disabling password auth

Use Tailscale SSH (`ssh neptune@neptune-mbp` over the tailnet does not use the
authorized keys), or Screen Sharing, then fix `~/.ssh/authorized_keys` (mode
600, `~/.ssh` mode 700).

### Tailscale SSH doesn't work or `tailscale up --ssh` is rejected

Only the open-source `tailscaled` build can be a Tailscale SSH server. The App
Store and Standalone GUI apps are sandboxed or run as a network extension, and
they only start after login.

- Check: `ls /Applications/Tailscale.app` must fail, and `pgrep -x tailscaled`
  must print a PID.
- The old GUI's network extension shows as "waiting to uninstall on reboot" in
  `systemextensionsctl list` until the next reboot. That is harmless.
- Restart the daemon: `sudo brew services restart tailscale`.
- The node changes identity when you switch variants. Remove the old node in
  the admin console.

### Tailscale logged out after months

Node key expiry (180 days by default). Re-run
`sudo tailscale up --ssh --hostname=neptune-mbp` over LAN SSH or Screen Sharing,
approve the URL, then disable key expiry for the node in the admin console.

### Screen Sharing is blurry or tiny

With no display attached, macOS falls back to a low-resolution virtual screen.
An HDMI dummy plug gives it a proper display. Pick the resolution in System
Settings > Displays over Screen Sharing.

## Toolchain

### `xcodebuild` says the active developer directory is CommandLineTools

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch
```

After installing a new Xcode (for example `Xcode-beta.app`), select it the same
way. Download a missing iOS runtime with `xcodebuild -downloadPlatform iOS`.

### Gradle fails with an unsupported Java version

Android Studio bundles a JDK that is too new for React Native's Gradle. Use JDK
17: `~/.zshenv` sets `JAVA_HOME` to Homebrew's `openjdk@17`. Check with
`echo $JAVA_HOME; java -version`. In Android Studio, set Settings > Build Tools >
Gradle > Gradle JDK to the same path.

### `command not found` for node, claude, adb… over `ssh neptune cmd`

`ssh host cmd` runs a non-interactive zsh, which reads only `~/.zshenv`. The
block marked `FLEET_PATH_SET` there must exist. Check with
`ssh neptune 'echo $PATH; command -v node claude adb'`. In login shells,
`/etc/zprofile` runs `path_helper`, which moves system paths first; `.zprofile`
and `.zshrc` re-add Homebrew and fnm, so interactive shells are fine too.

### `EMFILE: too many open files` from Metro, watchman or Gradle over SSH

Processes started by launchd, including SSH logins, inherit launchd's open-file
limit, which defaults to 256.

- Check: `launchctl limit maxfiles` must show `65536` as the soft limit. The hard
  limit shows as `unlimited` because it equals `kern.maxfiles`.
- Fix: `sudo launchctl bootstrap system /Library/LaunchDaemons/limit.maxfiles.plist`.
  Start a new SSH session afterwards.
- `watchman shutdown-server` clears a watchman that started under the old limit.

### Android emulator is slow or won't boot headless

- Use arm64-v8a system images only. x86_64 images run under translation.
- Boot headless with snapshots: `emulator -avd Pixel_10 -no-window -no-audio -no-boot-anim`.
  Adding `-no-snapshot-load` costs about 25 s per boot.
- For `adb root` or a writable system, create a second AVD from a
  `google_apis` image instead of `google_apis_playstore`.
- Give it more RAM in `~/.android/avd/<name>.avd/config.ini` (`hw.ramSize`).

### Everything is slow

Memory pressure. Check `memory_pressure` and `sysctl vm.swapusage`. A rough
budget per item: Xcode build 4 to 8 GB, iOS simulator 1 to 2 GB, Android
emulator 4 GB, Metro 1 GB, each agent session 0.5 to 1 GB. Shut down idle
devices: `xcrun simctl shutdown all`, `adb emu kill`.

Spotlight should be off: `mdutil -s /` prints `Indexing disabled.`

## Battery

The battery is always on the charger. Keep the macOS Charge Limit at 80%
(System Settings > Battery > Charging). macOS still tops up to 100% now and
then to calibrate. Check health with
`system_profiler SPPowerDataType | grep -E 'Cycle Count|Condition|Maximum Capacity'`.
If the case or trackpad starts to bulge, power it off and replace the battery.

## Undo

| To undo | Command |
| --- | --- |
| No-sleep | `sudo pmset -c sleep 1 displaysleep 10 standby 1 powernap 1 hibernatemode 3` |
| Automatic updates | `sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool true` (and `AutomaticDownload`) |
| Auto-login | `sudo sysadminctl -autologin off` |
| Screen lock | `sysadminctl -screenLock immediate -password -` |
| Spotlight | `sudo mdutil -a -i on` |
| Open-file limit | `sudo launchctl bootout system/limit.maxfiles && sudo rm /Library/LaunchDaemons/limit.maxfiles.plist` |
| SSH hardening | `sudo rm /etc/ssh/sshd_config.d/000-fleet-hardening.conf` |
| Tailscale daemon | `sudo tailscale logout; sudo brew services stop tailscale; brew uninstall tailscale` |
| Shell PATH | delete the `FLEET_PATH_SET` block from `~/.zshenv` |
| RustDesk server | `for b in hbbs hbbr; do launchctl bootout gui/$(id -u)/com.rustdesk.$b; rm ~/Library/LaunchAgents/com.rustdesk.$b.plist /opt/homebrew/bin/$b; done; rm -rf /opt/homebrew/var/rustdesk-server /opt/homebrew/var/log/rustdesk-server ~/Library/Caches/rustdesk-server` (deletes the key: clients need the new one after a reinstall) |
