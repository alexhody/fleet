#!/usr/bin/env bash
# setup.sh - provision an Apple Silicon Mac on macOS as a remote
# agentic-coding and mobile-testing worker.
#
# Phases:
#   0. Preflight : checks, sudo keep-alive, Homebrew
#   1. Power     : never sleep, wake on LAN, restart after freeze, no automatic
#                  macOS/App Store updates, no screen lock, auto-login
#   2. Remote    : computer name, Remote Login (SSH) + hardening, authorized key,
#                  Screen Sharing, Tailscale as a system daemon (Tailscale SSH)
#   3. Tuning    : Spotlight off, launchd open-file limit raised
#   4. Workload  : CLI tools, JDK 17, Node (fnm) + corepack + npm globals,
#                  Xcode (select, license, first launch, iOS runtime),
#                  Android SDK + AVD, agent CLIs (Claude Code, Codex, opencode),
#                  Argent MCP, tool PATH for non-interactive shells (~/.zshenv)
#
# Run as the admin user, NOT root: Homebrew refuses root. The script asks for
# the sudo password once and keeps it alive until it exits.
#
# Usage (from the control laptop):
#   ssh -t <user>@<ip> 'MAC_NAME=<name> SSH_PUBKEY="ssh-ed25519 AAAA..." bash ~/setup.sh'
#
# Options (env):
#   MAC_NAME        computer / Bonjour / host name (default: current LocalHostName)
#   SSH_PUBKEY      public key line to authorize (or SSH_PUBKEY_FILE)
#   AUTOLOGIN=0     do not set up automatic login (default: set it, asks for the login password)
#   ANDROID_STUDIO=0  skip the Android Studio app (SDK + emulator are still installed)
#   ANDROID_PACKAGES  sdkmanager packages (default: the set below)
#   AVD_NAME / AVD_DEVICE / AVD_IMAGE / AVD_RAM   emulator to create if missing
#   NPM_GLOBALS     global npm packages (default: "@swmansion/argent eas-cli vercel")
#   ORBSTACK=1      also install OrbStack (Docker runtime; default: skip)
#   SKIP_POWER, SKIP_REMOTE, SKIP_TUNING, SKIP_XCODE, SKIP_ANDROID, SKIP_AGENTS  skip that part
#   SUDO_ASKPASS    helper that prints the sudo password, for unattended runs
#
set -euo pipefail

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

if [ "$(id -u)" -eq 0 ]; then
  echo "Run as the admin user, not root (Homebrew refuses root)." >&2; exit 1
fi
[ "$(uname -s)" = Darwin ] || { echo "macOS only." >&2; exit 1; }
[ "$(uname -m)" = arm64 ]  || { echo "Apple Silicon only." >&2; exit 1; }
id -Gn | tr ' ' '\n' | grep -qx admin || { echo "$USER must be an administrator." >&2; exit 1; }

# Unattended runs: let sudo read the password from an askpass helper.
if [ -n "${SUDO_ASKPASS:-}" ]; then sudo() { command sudo -A "$@"; }; fi

ME="$USER"
MAC_NAME="${MAC_NAME:-$(scutil --get LocalHostName 2>/dev/null || hostname -s)}"
AUTOLOGIN="${AUTOLOGIN:-1}"
ANDROID_STUDIO="${ANDROID_STUDIO:-1}"
ANDROID_HOME="$HOME/Library/Android/sdk"
ANDROID_PACKAGES="${ANDROID_PACKAGES:-platform-tools emulator platforms;android-37.0 build-tools;36.0.0 system-images;android-37.2;google_apis_playstore_ps16k;arm64-v8a}"
AVD_NAME="${AVD_NAME:-Pixel_10}"
AVD_DEVICE="${AVD_DEVICE:-pixel_10}"
AVD_IMAGE="${AVD_IMAGE:-system-images;android-37.2;google_apis_playstore_ps16k;arm64-v8a}"
AVD_RAM="${AVD_RAM:-4096}"
NPM_GLOBALS="${NPM_GLOBALS:-@swmansion/argent eas-cli vercel}"
ORBSTACK="${ORBSTACK:-0}"
SKIP_POWER="${SKIP_POWER:-0}"; SKIP_REMOTE="${SKIP_REMOTE:-0}"; SKIP_TUNING="${SKIP_TUNING:-0}"
SKIP_XCODE="${SKIP_XCODE:-0}"; SKIP_ANDROID="${SKIP_ANDROID:-0}"; SKIP_AGENTS="${SKIP_AGENTS:-0}"
JDK17_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home

if [ -n "${SSH_PUBKEY_FILE:-}" ] && [ -z "${SSH_PUBKEY:-}" ]; then
  SSH_PUBKEY="$(cat "$SSH_PUBKEY_FILE")"
fi
SSH_PUBKEY="${SSH_PUBKEY:-}"

filevault_on() { fdesetup status 2>/dev/null | grep -q 'FileVault is On'; }

# ============================================================ PHASE 0: PREFLIGHT
log "Phase 0 - preflight"
echo "  user  : $ME ($HOME)"
echo "  model : $(sysctl -n hw.model) / $(sysctl -n machdep.cpu.brand_string) / $(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
echo "  macOS : $(sw_vers -productVersion)"
echo "  name  : $MAC_NAME"

sudo -v
( while true; do sudo -n true 2>/dev/null; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
KEEPALIVE=$!
trap 'kill "$KEEPALIVE" 2>/dev/null || true' EXIT

if filevault_on; then
  warn "FileVault is on. After any unplanned reboot the Mac waits at the unlock screen with no"
  warn "network, no SSH and no Tailscale. Turn it off (System Settings > Privacy & Security >"
  warn "FileVault) or plan every reboot with 'sudo fdesetup authrestart'. Auto-login is skipped."
fi

log "  0.1 Homebrew"
if [ ! -x /opt/homebrew/bin/brew ]; then
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$(/opt/homebrew/bin/brew shellenv)"
export HOMEBREW_NO_INSTALL_UPGRADE=1 HOMEBREW_NO_ENV_HINTS=1
brew_need() {  # brew_need <formula>...: install the ones not yet installed
  local f missing=()
  for f in "$@"; do brew list --formula "${f##*/}" >/dev/null 2>&1 || missing+=("$f"); done
  [ ${#missing[@]} -eq 0 ] || brew install "${missing[@]}"
}
cask_need() {  # cask_need <cask> <app path or -> : install unless present
  if [ "$2" != "-" ] && [ -e "$2" ]; then return 0; fi
  brew list --cask "$1" >/dev/null 2>&1 || brew install --cask "$1"
}

# ================================================================ PHASE 1: POWER
log "Phase 1 - power, updates, login"
if [ "$SKIP_POWER" != "1" ]; then
  log "  1.1 never sleep, wake on LAN, restart after a freeze"
  sudo pmset -c sleep 0 displaysleep 0 disksleep 0 standby 0 powernap 0 hibernatemode 0 womp 1 tcpkeepalive 1
  sudo pmset -b sleep 0 displaysleep 0 disksleep 0 standby 0 powernap 0 hibernatemode 0 tcpkeepalive 1
  sudo pmset -c autorestart 1 2>/dev/null || true   # MacBooks power on when AC returns anyway
  sudo systemsetup -setcomputersleep Never >/dev/null 2>&1 || true
  sudo systemsetup -setrestartfreeze on    >/dev/null 2>&1 || true

  log "  1.2 no automatic macOS or App Store installs (update by hand)"
  # Checking stays on so updates show up; XProtect/security data keeps installing.
  sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
  sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
  sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false

  log "  1.3 no screen lock, no screen saver"
  defaults -currentHost write com.apple.screensaver idleTime -int 0
  if sysadminctl -screenLock status 2>&1 | grep -q 'screenLock is off'; then
    echo "   screen lock already off"
  else
    echo "   enter the login password for $ME:"
    sysadminctl -screenLock off -password - || warn "turn off 'Require password' in System Settings > Lock Screen"
  fi

  log "  1.4 automatic login as $ME"
  if [ "$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null)" = "$ME" ]; then
    echo "   already set"
  elif [ "$AUTOLOGIN" != "1" ]; then
    warn "AUTOLOGIN=0: simulators and Xcode need a logged-in GUI session after every reboot"
  elif filevault_on; then
    warn "auto-login is impossible while FileVault is on"
  else
    echo "   enter the login password for $ME:"
    sudo sysadminctl -autologin set -userName "$ME" -password - \
      || warn "set it in System Settings > Users & Groups > Automatically log in as"
  fi
else
  warn "skipping power/update/login settings"
fi

# =============================================================== PHASE 2: REMOTE
log "Phase 2 - remote access"
if [ "$SKIP_REMOTE" != "1" ]; then
  log "  2.1 name = $MAC_NAME"
  sudo scutil --set ComputerName  "$MAC_NAME"
  sudo scutil --set LocalHostName "$MAC_NAME"
  sudo scutil --set HostName      "$MAC_NAME"

  log "  2.2 SSH (passwords stay ON until a key is proven)"
  HARDEN=/etc/ssh/sshd_config.d/000-fleet-hardening.conf
  if [ -f "$HARDEN" ]; then
    echo "   $HARDEN exists, left as is"
  else
    sudo tee "$HARDEN" >/dev/null <<'EOF'
# sshd keeps the first value it reads. This file sorts before 100-macos.conf.
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
X11Forwarding no
EOF
  fi
  sudo /usr/sbin/sshd -t || { warn "sshd config invalid; removing $HARDEN"; sudo rm -f "$HARDEN"; }
  # systemsetup -setremotelogin needs Full Disk Access for the terminal; launchctl does not.
  sudo launchctl enable system/com.openssh.sshd
  sudo launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true
  nc -z -G 2 localhost 22 >/dev/null 2>&1 && echo "   sshd listening on 22" || warn "sshd is not listening; turn on Remote Login in System Settings > General > Sharing"

  if [ -n "$SSH_PUBKEY" ]; then
    install -d -m 700 "$HOME/.ssh"
    grep -qxF "$SSH_PUBKEY" "$HOME/.ssh/authorized_keys" 2>/dev/null || printf '%s\n' "$SSH_PUBKEY" >> "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"
  elif [ -s "$HOME/.ssh/authorized_keys" ]; then
    echo "   using existing ~/.ssh/authorized_keys"
  else
    warn "no SSH_PUBKEY given; add one to ~/.ssh/authorized_keys"
  fi

  log "  2.3 Screen Sharing"
  sudo launchctl enable system/com.apple.screensharing
  sudo launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true
  nc -z -G 2 localhost 5900 >/dev/null 2>&1 && echo "   listening on 5900" || warn "turn on Screen Sharing in System Settings > General > Sharing"

  log "  2.4 Tailscale as a system daemon (starts before login, can serve Tailscale SSH)"
  if [ -d /Applications/Tailscale.app ]; then
    # The App Store and Standalone GUI apps can't be a Tailscale SSH server or run before login.
    echo "   removing the Tailscale GUI app"
    osascript -e 'quit app "Tailscale"' >/dev/null 2>&1 || true
    sleep 2
    sudo rm -rf /Applications/Tailscale.app
  fi
  brew_need tailscale
  if ps -axco comm | grep -qx tailscaled; then  # pgrep can't see root processes
    echo "   tailscaled running"
  else
    sudo brew services start tailscale
  fi
else
  warn "skipping remote access"
fi

# =============================================================== PHASE 3: TUNING
log "Phase 3 - tuning"
if [ "$SKIP_TUNING" != "1" ]; then
  log "  3.1 Spotlight indexing off (it re-indexes DerivedData, node_modules, Gradle caches)"
  sudo mdutil -a -i off >/dev/null

  log "  3.2 open-file limit 65536/524288 for launchd sessions (SSH logins, GUI apps)"
  # launchd defaults to 256, which Metro, watchman and Gradle hit over SSH (EMFILE).
  sudo tee /Library/LaunchDaemons/limit.maxfiles.plist >/dev/null <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>limit.maxfiles</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/launchctl</string><string>limit</string><string>maxfiles</string>
    <string>65536</string><string>524288</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
  sudo chown root:wheel /Library/LaunchDaemons/limit.maxfiles.plist
  sudo chmod 644 /Library/LaunchDaemons/limit.maxfiles.plist
  sudo launchctl bootout system/limit.maxfiles 2>/dev/null || true
  sudo launchctl bootstrap system /Library/LaunchDaemons/limit.maxfiles.plist
else
  warn "skipping tuning"
fi

# ============================================================= PHASE 4: WORKLOAD
log "Phase 4 - workload tooling"

log "  4.1 CLI tools + JDK 17"
brew_need git gh tmux jq ripgrep watchman cocoapods fnm starship openjdk@17 oven-sh/bun/bun
# React Native's Gradle needs JDK 17; Android Studio's bundled JDK is too new.
sudo ln -sfn /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk /Library/Java/JavaVirtualMachines/openjdk-17.jdk
export JAVA_HOME="$JDK17_HOME"
[ "$ORBSTACK" = "1" ] && cask_need orbstack /Applications/OrbStack.app

log "  4.2 Node (fnm, LTS) + corepack (pnpm, yarn) + npm globals"
export FNM_DIR="$HOME/.local/share/fnm"
eval "$(fnm env --shell bash)"
if ! fnm list 2>/dev/null | grep -q default; then
  fnm install --lts
  fnm default lts-latest
fi
fnm use default >/dev/null
corepack enable
for p in $NPM_GLOBALS; do
  npm ls -g --depth=0 "$p" >/dev/null 2>&1 || npm install -g "$p"
done

log "  4.3 Xcode"
if [ "$SKIP_XCODE" = "1" ]; then
  warn "skipping Xcode"
else
  XCODE_APP=/Applications/Xcode.app
  [ -d "$XCODE_APP" ] || XCODE_APP="$(ls -d /Applications/Xcode*.app 2>/dev/null | sort | tail -1)"
  if [ -z "$XCODE_APP" ] || [ ! -d "$XCODE_APP" ]; then
    warn "Xcode is not installed. Install it from the App Store, then re-run this script."
  else
    echo "   using $XCODE_APP"
    sudo xcode-select -s "$XCODE_APP/Contents/Developer"
    sudo xcodebuild -license accept
    sudo xcodebuild -runFirstLaunch >/dev/null
    if xcrun simctl list runtimes 2>/dev/null | grep -q '^iOS '; then
      echo "   iOS simulator runtime present"
    else
      xcodebuild -downloadPlatform iOS || warn "iOS runtime download failed; retry: xcodebuild -downloadPlatform iOS"
    fi
  fi
fi

log "  4.4 Android SDK + emulator"
if [ "$SKIP_ANDROID" = "1" ]; then
  warn "skipping Android"
else
  [ "$ANDROID_STUDIO" = "1" ] && cask_need android-studio "/Applications/Android Studio.app"
  SDKM="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
  if [ ! -x "$SDKM" ]; then
    cask_need android-commandlinetools -
    mkdir -p "$ANDROID_HOME"
    yes 2>/dev/null | /opt/homebrew/bin/sdkmanager --sdk_root="$ANDROID_HOME" --licenses >/dev/null || true
    /opt/homebrew/bin/sdkmanager --sdk_root="$ANDROID_HOME" "cmdline-tools;latest"
  fi
  yes 2>/dev/null | "$SDKM" --sdk_root="$ANDROID_HOME" --licenses >/dev/null || true
  read -r -a PKGS <<< "$ANDROID_PACKAGES"
  "$SDKM" --sdk_root="$ANDROID_HOME" "${PKGS[@]}" | grep -vE '^\[|^Loading|^$' || true

  AVDM="$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager"
  if "$AVDM" list avd -c 2>/dev/null | grep -qx "$AVD_NAME"; then
    echo "   AVD $AVD_NAME exists"
  else
    echo no | "$AVDM" create avd -n "$AVD_NAME" -k "$AVD_IMAGE" -d "$AVD_DEVICE"
    CFG="$HOME/.android/avd/$AVD_NAME.avd/config.ini"
    sed -i '' -e '/^hw.ramSize=/d' -e '/^hw.gpu.enabled=/d' -e '/^hw.gpu.mode=/d' -e '/^hw.keyboard=/d' "$CFG"
    printf 'hw.ramSize=%s\nhw.gpu.enabled=yes\nhw.gpu.mode=host\nhw.keyboard=yes\n' "$AVD_RAM" >> "$CFG"
  fi
fi

log "  4.5 agent CLIs (Claude Code, Codex, opencode) + Argent MCP"
if [ "$SKIP_AGENTS" = "1" ]; then
  warn "skipping agent CLIs"
else
  export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"
  have claude   || curl -fsSL https://claude.ai/install.sh | bash
  have codex    || curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh
  have opencode || curl -fsSL https://opencode.ai/install | bash
  if grep -q '"argent"' "$HOME/.claude.json" 2>/dev/null; then
    echo "   Argent MCP already registered"
  else
    claude mcp add --scope user argent -- argent mcp || warn "register Argent later: claude mcp add --scope user argent -- argent mcp"
  fi
fi
mkdir -p "$HOME/Code" "$HOME/jobs"

log "  4.6 PATH for non-interactive shells (~/.zshenv)"
# `ssh host cmd` runs `zsh -c`, which reads only ~/.zshenv - not .zprofile or .zshrc.
# Remote agents and control planes use exactly that shell, so tool paths go here.
if grep -q FLEET_PATH_SET "$HOME/.zshenv" 2>/dev/null; then
  echo "   already present"
else
  cat >> "$HOME/.zshenv" <<'EOF'
# fleet: tool PATH for every zsh, including non-interactive `ssh host cmd`,
# which reads only this file. Keep it silent and fast.
if [ -z "${FLEET_PATH_SET:-}" ]; then
  export FLEET_PATH_SET=1
  export ANDROID_HOME="$HOME/Library/Android/sdk"
  export JAVA_HOME="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
  export FNM_DIR="$HOME/.local/share/fnm"
  for d in /opt/homebrew/sbin /opt/homebrew/bin \
           "$ANDROID_HOME/cmdline-tools/latest/bin" "$ANDROID_HOME/emulator" "$ANDROID_HOME/platform-tools" \
           "$FNM_DIR/aliases/default/bin" "$HOME/.opencode/bin" "$HOME/.local/bin"; do
    [ -d "$d" ] && PATH="$d:$PATH"
  done
  export PATH
fi
EOF
fi
grep -q 'fnm env' "$HOME/.zshrc" 2>/dev/null || echo 'command -v fnm >/dev/null && eval "$(fnm env --use-on-cd --shell zsh)"' >> "$HOME/.zshrc"
grep -q 'starship init' "$HOME/.zshrc" 2>/dev/null || echo 'command -v starship >/dev/null && eval "$(starship init zsh)"' >> "$HOME/.zshrc"

# ================================================================ SUMMARY
log "Summary"
printf '  power      : %s\n' "$(pmset -g custom | awk '/AC Power/{a=1} a&&/ sleep /{print "sleep="$2} a&&/womp/{print "womp="$2}' | xargs)"
printf '  filevault  : %s\n' "$(fdesetup status | head -1)"
printf '  autologin  : %s\n' "$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || echo none)"
printf '  ssh        : %s\n' "$(nc -z -G 2 localhost 22 >/dev/null 2>&1 && echo listening || echo off)"
printf '  screenshare: %s\n' "$(nc -z -G 2 localhost 5900 >/dev/null 2>&1 && echo listening || echo off)"
printf '  tailscale  : %s\n' "$(tailscale ip -4 2>/dev/null || echo 'not logged in')"
printf '  maxfiles   : %s\n' "$(launchctl limit maxfiles | awk '{print $2"/"$3}')"
printf '  xcode      : %s\n' "$(xcode-select -p)"
printf '  java 17    : %s\n' "$(/usr/libexec/java_home -v 17 2>/dev/null || echo missing)"
printf '  avds       : %s\n' "$("$ANDROID_HOME/emulator/emulator" -list-avds 2>/dev/null | xargs)"
echo
echo "NEXT (see SKILL.md steps 3-6):"
echo "  1. sudo tailscale up --ssh --hostname=$MAC_NAME   # open the printed URL, approve"
echo "  2. in the Tailscale admin console: disable key expiry, restrict SSH in the ACL"
echo "  3. verify key login from the client, then disable password auth"
echo "  4. reboot, then run scripts/verify.sh from the client"
echo "  5. log in: claude auth login, codex login --device-auth, opencode auth login, gh auth login"
