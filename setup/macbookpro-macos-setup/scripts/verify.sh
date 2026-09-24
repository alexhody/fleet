#!/usr/bin/env bash
# verify.sh - check a provisioned macOS worker after reboot. Needs no root.
#
# From the client:  ssh neptune bash -s < scripts/verify.sh
# That shell is non-interactive, like the ones remote agents get, so the tool
# checks at the end prove PATH works there. Exits non-zero if any check failed.

fail=0
check() {  # check <name> <expected> <actual>
  if [ "$3" = "$2" ]; then printf 'ok    %-14s %s\n' "$1" "$3"
  else printf 'FAIL  %-14s got "%s", want "%s"\n' "$1" "$3" "$2"; fail=1; fi
}
has() { [ -n "$2" ] && echo yes || echo no; }
ac() { pmset -g custom | awk -v k="$1" '/^AC Power/{a=1;next} /^[A-Z]/{a=0} a && $1==k {print $2}'; }
bat() { pmset -g custom | awk -v k="$1" '/^Battery Power/{a=1;next} /^[A-Z]/{a=0} a && $1==k {print $2}'; }
listening() { nc -z -G 2 localhost "$1" >/dev/null 2>&1 && echo yes || echo no; }

# Power and recovery
check arch          arm64 "$(uname -m)"
for k in sleep displaysleep disksleep standby powernap hibernatemode; do check "ac-$k" 0 "$(ac $k)"; done
check ac-womp       1     "$(ac womp)"
check battery-sleep 0     "$(bat sleep)"
check filevault     "FileVault is Off." "$(fdesetup status | head -1)"
check autologin     "$USER" "$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null)"
check screenlock    off   "$(sysadminctl -screenLock status 2>&1 | grep -q 'screenLock is off' && echo off || echo on)"
check auto-install  0     "$(defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates 2>/dev/null)"
check auto-download 0     "$(defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload 2>/dev/null)"
check on-ac         yes   "$(pmset -g batt | head -1 | grep -q 'AC Power' && echo yes || echo no)"

# Remote access
check sshd          yes   "$(listening 22)"
check ssh-hardening yes   "$(grep -qx 'PermitRootLogin no' /etc/ssh/sshd_config.d/000-fleet-hardening.conf 2>/dev/null && echo yes || echo no)"
check screensharing yes   "$(listening 5900)"
check tailscaled    yes   "$(pgrep -x tailscaled >/dev/null && echo yes || echo no)"
check tailscale-ip  yes   "$(has ip "$(tailscale ip -4 2>/dev/null)")"
check tailscale-gui absent "$([ -d /Applications/Tailscale.app ] && echo present || echo absent)"

if [ -f "$HOME/Library/LaunchAgents/com.rustdesk.hbbs.plist" ]; then  # optional, see SKILL.md section 7
  check rustdesk-hbbs yes "$(listening 21116)"
  check rustdesk-hbbr yes "$(listening 21117)"
fi

# Tuning
check spotlight     off   "$(mdutil -s / 2>/dev/null | grep -q 'Indexing disabled' && echo off || echo on)"
check maxfiles      65536 "$(launchctl limit maxfiles | awk '{print $2}')"

# Toolchain
check xcode-select  /Applications/Xcode.app/Contents/Developer "$(xcode-select -p 2>/dev/null)"
check xcodebuild    yes   "$(xcodebuild -version >/dev/null 2>&1 && echo yes || echo no)"
check ios-runtime   yes   "$(has rt "$(xcrun simctl list runtimes 2>/dev/null | grep '^iOS ')")"
check java17        yes   "$(/usr/libexec/java_home -v 17 >/dev/null 2>&1 && echo yes || echo no)"
check JAVA_HOME-17  yes   "$("${JAVA_HOME:-/nonexistent}/bin/java" -version 2>&1 | grep -q '"17\.' && echo yes || echo no)"
check android-home  yes   "$([ -d "${ANDROID_HOME:-/nonexistent}/platform-tools" ] && echo yes || echo no)"
check avd           yes   "$(has avd "$(emulator -list-avds 2>/dev/null)")"
check argent-mcp    yes   "$(grep -q '"argent"' "$HOME/.claude.json" 2>/dev/null && echo yes || echo no)"

# Remote agents run through non-interactive shells; every tool must resolve there.
for t in brew git gh tmux jq rg node npm pnpm bun watchman pod java adb emulator claude codex opencode argent; do
  check "$t" yes "$(has "$t" "$(command -v "$t")")"
done

exit $fail
