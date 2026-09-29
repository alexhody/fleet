#!/usr/bin/env bash
# link-agents.sh - point Claude Code, Codex and opencode on this machine at the
# shared instructions in agents/AGENTS.md. Safe to run again.
#
# ~/.claude/CLAUDE.md becomes a one-line import of that file, and
# ~/.codex/AGENTS.md and ~/.config/opencode/AGENTS.md become symlinks to it.
# A different file already in one of those places is kept as <name>.bak.
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)/agents/AGENTS.md"
[ -f "$SRC" ] || { echo "link-agents: missing $SRC" >&2; exit 1; }

backup() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    mv "$1" "$1.bak"
    echo "kept the old $1 as $1.bak"
  fi
}

claude=$HOME/.claude/CLAUDE.md
if [ "$(cat "$claude" 2>/dev/null)" != "@$SRC" ]; then
  mkdir -p "$(dirname "$claude")"
  backup "$claude"
  printf '@%s\n' "$SRC" > "$claude"
fi

for link in "$HOME/.codex/AGENTS.md" "$HOME/.config/opencode/AGENTS.md"; do
  [ "$(readlink "$link" 2>/dev/null)" = "$SRC" ] && continue
  mkdir -p "$(dirname "$link")"
  backup "$link"
  ln -s "$SRC" "$link"
done

echo "Claude Code, Codex and opencode read $SRC"
