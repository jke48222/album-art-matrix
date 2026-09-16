#!/bin/bash
# This runs on the Pi. It changes only the selected symlink and brain PID.
set -euo pipefail
link="$HOME/album-art-matrix"
if [ "$#" -eq 0 ]; then
    readlink -f "$link"
    exit 0
fi
case "$1" in claude|codex) variant=$1;; *) echo 'Usage: switch.sh [claude|codex]' >&2; exit 2;; esac
target="$HOME/wall-$variant"
[ -L "$link" ] || { echo '[switch] album-art-matrix must already be a symlink' >&2; exit 1; }
[ -x "$target/.venv/bin/python" ] && [ -f "$target/config.toml" ] || {
    echo "[switch] $target needs its own venv and config.toml" >&2; exit 1;
}
[ "$(readlink -f "$link")" != "$target" ] || { echo "[switch] $variant already live"; exit 0; }
next="$HOME/.album-art-matrix-next-$$"
trap 'rm -f "$next"' EXIT
ln -s "$target" "$next"
mv -Tf "$next" "$link"
pid=$(systemctl show album-art-matrix --property MainPID --value)
if [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ]; then
    kill -KILL "$pid"
fi
echo "[switch] $variant selected; systemd restarts the brain within five seconds"
