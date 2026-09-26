#!/usr/bin/env bash
# move-session.sh - move a Claude Code session between this machine and a
# worker, so it continues on the other side (claude --resume, or T3 Code's
# import of recent sessions).
#
# Usage:
#   scripts/move-session.sh pull <host> [session-id]   worker → this machine
#   scripts/move-session.sh push <host> [session-id]   this machine → worker
#
# Options:
#   --cwd <dir>   project folder on the destination (default: the same path
#                 under its $HOME, so /home/saturn/Code/fleet → ~/Code/fleet)
#   --force       overwrite a copy that already exists on the destination
#
# Without a session id it takes the source's most recently active session.
# <host> is an SSH alias from ~/.ssh/config (saturn, neptune). The transcript
# and its subagent files are copied and their working directory rewritten;
# the source copy is left alone. Run it after the session's turn has finished.
set -euo pipefail

usage() { sed -n '6,13s/^# \{0,1\}//p' "$0"; exit 2; }
die() { echo "move-session: $*" >&2; exit 1; }

DIRECTION= HOST= ID= DST_CWD= FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --cwd) [ $# -ge 2 ] || usage; DST_CWD=$2; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage ;;
    -*) usage ;;
    *)
      if [ -z "$DIRECTION" ]; then DIRECTION=$1
      elif [ -z "$HOST" ]; then HOST=$1
      elif [ -z "$ID" ]; then ID=$1
      else usage
      fi
      shift ;;
  esac
done

case "$DIRECTION" in
  pull) SRC=$HOST DST=local ;;
  push) SRC=local DST=$HOST ;;
  *) usage ;;
esac
[ -n "$HOST" ] || usage
if [ -n "$ID" ] && ! [[ $ID =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  die "not a session id: $ID"
fi

# run <side> <command>: side is "local" or an SSH host. Commands stick to
# POSIX sh, since the remote login shell may be bash or zsh.
run() {
  if [ "$1" = local ]; then sh -c "$2"; else ssh "$1" "$2"; fi
}
name() { if [ "$1" = local ]; then hostname -s; else echo "$1"; fi; }

# Paths are passed inside single quotes, and written into JSON as they are.
check_path() {
  case "$1" in *[\'\"\\]*) die "unsupported character in path: $1" ;; esac
}

# Find the transcript on the source.
if [ -n "$ID" ]; then
  SRC_FILE=$(run "$SRC" "ls \"\$HOME\"/.claude/projects/*/$ID.jsonl 2>/dev/null | head -1")
  [ -n "$SRC_FILE" ] || die "no session $ID on $(name "$SRC")"
else
  SRC_FILE=$(run "$SRC" "ls -t \"\$HOME\"/.claude/projects/*/*.jsonl 2>/dev/null | head -1")
  [ -n "$SRC_FILE" ] || die "no sessions on $(name "$SRC")"
  ID=$(basename "$SRC_FILE" .jsonl)
fi
check_path "$SRC_FILE"
SRC_DIR=$(dirname "$SRC_FILE")

SRC_CWD=$(run "$SRC" "grep -m1 -o '\"cwd\":\"[^\"]*\"' '$SRC_FILE'" | sed 's/^"cwd":"//; s/"$//')
[ -n "$SRC_CWD" ] || die "session $ID has no working directory recorded"
check_path "$SRC_CWD"

# Map the project folder onto the destination.
if [ -z "$DST_CWD" ]; then
  SRC_HOME=$(run "$SRC" 'printf %s "$HOME"')
  DST_HOME=$(run "$DST" 'printf %s "$HOME"')
  case "$SRC_CWD" in
    "$SRC_HOME"/*) DST_CWD=$DST_HOME/${SRC_CWD#"$SRC_HOME"/} ;;
    *) DST_CWD=$SRC_CWD ;;
  esac
fi
DST_CWD=${DST_CWD%/}
check_path "$DST_CWD"
run "$DST" "test -d '$DST_CWD'" \
  || die "$DST_CWD doesn't exist on $(name "$DST"). Clone the repo there, or pass --cwd <dir>."

# Claude Code keeps a project's sessions in ~/.claude/projects/<path with
# every non-alphanumeric character turned into ->.
DST_DIR=.claude/projects/$(printf %s "$DST_CWD" | sed 's/[^A-Za-z0-9]/-/g')
if [ "$FORCE" = 0 ] && run "$DST" "test -e \"\$HOME\"/'$DST_DIR/$ID.jsonl'"; then
  die "session $ID is already on $(name "$DST"). Pass --force to overwrite it."
fi

if [ -n "$(run "$SRC" "find '$SRC_FILE' -mmin -1")" ]; then
  echo "Warning: the session changed in the last minute. If a turn is still" >&2
  echo "running, copy it again with --force once it has finished." >&2
fi

# Copy the transcript and its subagent folder, rewrite the working directory,
# then unpack on the destination.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
run "$SRC" "cd '$SRC_DIR' && COPYFILE_DISABLE=1 tar -cf - '$ID.jsonl' \$(test -d '$ID' && echo '$ID')" \
  | tar -xf - -C "$TMP"
find "$TMP" -name '*.jsonl' -exec env SRC_CWD="$SRC_CWD" DST_CWD="$DST_CWD" \
  perl -pi -e 's/"cwd":"\Q$ENV{SRC_CWD}\E(?=["\/])/"cwd":"$ENV{DST_CWD}/g' {} +
(cd "$TMP" && COPYFILE_DISABLE=1 tar -cf - .) \
  | run "$DST" "mkdir -p \"\$HOME\"/'$DST_DIR' && tar -xf - -C \"\$HOME\"/'$DST_DIR'"

cat <<EOF
Moved session $ID
  from $(name "$SRC"):$SRC_CWD
  to   $(name "$DST"):$DST_CWD

Continue it on $(name "$DST"):
  cd $DST_CWD && claude --resume $ID
or in T3 Code, add $DST_CWD as a project in $(name "$DST")'s environment and
import its recent sessions.

Stop using it on $(name "$SRC"), or the two copies go separate ways.
EOF
