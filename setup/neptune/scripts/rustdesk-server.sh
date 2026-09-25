#!/usr/bin/env bash
# rustdesk-server.sh - build and run a self-hosted RustDesk server (hbbs ID
# server + hbbr relay) on the neptune worker.
#
# RustDesk ships server binaries only for Linux and Windows, so this builds
# them from source with cargo and runs them as launchd agents of the login
# user. They start at the auto-login and restart if they exit. Files follow the
# Homebrew layout (bin/, var/, var/log/ under the Homebrew prefix), which the
# login user owns, so no sudo is needed. Both run with
# `-k _`, so only clients configured with this server's public key can use it.
#
# Ports: TCP 21115-21117, UDP 21116 (and TCP 21118/21119 for the web client).
# The macOS application firewall is off on this worker, so they are reachable
# over Tailscale and the LAN; the router does not forward them.
#
# Usage (on neptune, as neptune, safe to re-run):
#   bash ~/Code/fleet/setup/neptune/scripts/rustdesk-server.sh
#
# Options (env):
#   RUSTDESK_VERSION  rustdesk-server release tag to build (default 1.1.16)
#   SRC_DIR           source checkout + build cache (default ~/Library/Caches/rustdesk-server)
#
set -euo pipefail

log()  { printf '\n==> %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$(uname -s)" = Darwin ] || { echo "macOS only." >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || { echo "Run as the login user, not root." >&2; exit 1; }

RUSTDESK_VERSION="${RUSTDESK_VERSION:-1.1.16}"
SRC_DIR="${SRC_DIR:-$HOME/Library/Caches/rustdesk-server}"
PREFIX="$(brew --prefix)"
BIN_DIR="$PREFIX/bin"
DATA_DIR="$PREFIX/var/rustdesk-server"      # id_ed25519 key pair + db_v2.sqlite3
LOG_DIR="$PREFIX/var/log/rustdesk-server"
AGENTS="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"

log "Rust toolchain"
have cargo || brew install rust
cargo --version

log "Source at $RUSTDESK_VERSION"
if [ ! -d "$SRC_DIR/.git" ]; then
  git clone --depth 1 --branch "$RUSTDESK_VERSION" --recurse-submodules --shallow-submodules \
    https://github.com/rustdesk/rustdesk-server.git "$SRC_DIR"
elif [ "$(git -C "$SRC_DIR" describe --tags --exact-match 2>/dev/null)" != "$RUSTDESK_VERSION" ]; then
  git -C "$SRC_DIR" fetch --depth 1 origin tag "$RUSTDESK_VERSION"
  git -C "$SRC_DIR" checkout -q "$RUSTDESK_VERSION"
  git -C "$SRC_DIR" submodule update --init --depth 1
fi

log "Build (about 2 minutes the first time)"
cargo build --release --locked --manifest-path "$SRC_DIR/Cargo.toml" --bin hbbs --bin hbbr

log "Install"
install -d "$BIN_DIR" "$DATA_DIR" "$LOG_DIR" "$AGENTS"
chmod 700 "$DATA_DIR"
for b in hbbs hbbr; do
  launchctl bootout "$DOMAIN/com.rustdesk.$b" 2>/dev/null || true
  install -m 755 "$SRC_DIR/target/release/$b" "$BIN_DIR/$b"
done

agent() {  # agent <binary>
  cat > "$AGENTS/com.rustdesk.$1.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.rustdesk.$1</string>
  <key>ProgramArguments</key>
  <array><string>$BIN_DIR/$1</string><string>-k</string><string>_</string></array>
  <key>WorkingDirectory</key><string>$DATA_DIR</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>SoftResourceLimits</key><dict><key>NumberOfFiles</key><integer>65536</integer></dict>
  <key>StandardOutPath</key><string>$LOG_DIR/$1.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/$1.log</string>
</dict>
</plist>
EOF
  plutil -lint -s "$AGENTS/com.rustdesk.$1.plist"
  launchctl bootstrap "$DOMAIN" "$AGENTS/com.rustdesk.$1.plist"
}

log "Start hbbs, then hbbr once the key pair exists"
# hbbs writes id_ed25519 on first start; hbbr must read the same key, not make its own.
agent hbbs
for _ in $(seq 20); do [ -s "$DATA_DIR/id_ed25519.pub" ] && break; sleep 0.5; done
[ -s "$DATA_DIR/id_ed25519.pub" ] || { echo "hbbs did not write a key; see $LOG_DIR/hbbs.log" >&2; exit 1; }
chmod 600 "$DATA_DIR/id_ed25519"
agent hbbr
sleep 2

for p in 21115 21116 21117; do
  nc -z -G 2 localhost "$p" 2>/dev/null && echo "   tcp $p listening" || echo "   tcp $p NOT listening (see $LOG_DIR)" >&2
done

NAME="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || true)"
cat <<EOF

RustDesk server is running. In each client: Settings > Network > ID/Relay server
  ID server : $NAME (Tailscale${TS_IP:+, $TS_IP}) or ${LAN_IP:-<LAN IP>} (LAN)
  Relay     : leave empty (defaults to the ID server host)
  API       : leave empty (Pro only)
  Key       : $(cat "$DATA_DIR/id_ed25519.pub")
Back up $DATA_DIR/id_ed25519: a new key means every client must be reconfigured.
EOF
