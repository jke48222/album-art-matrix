#!/usr/bin/env bash
# Which wall software is live on the Pi: Claude's tree or Codex's.
#
#   switch.sh            say which one is live
#   switch.sh claude     ~/album-art-matrix -> ~/wall-claude, restart the brain
#   switch.sh codex      ~/album-art-matrix -> ~/wall-codex,  restart the brain
#
# ~/album-art-matrix is a symlink, and both systemd units run through it, so
# pointing it elsewhere and restarting the brain is the whole switch. The
# two trees share ~/.config/album-art-matrix (settings, journal, services,
# tuning, the HomeKit pairing), so a token typed once on the phone serves
# both builds and the wall keeps its place in the Home app. Each tree has
# its own venv, config.toml, `wall` file and panel files. The renderer keeps
# running across a switch: it is the same program in both trees and its
# FIFO is shared. Deploys from the Mac land in whichever tree is live, so
# check with a bare `switch.sh` before copying files over.
set -euo pipefail
LINK="$HOME/album-art-matrix"

case "${1:-}" in
  "")
    if [ -L "$LINK" ]; then echo "live: $(readlink "$LINK")"; else echo "live: $LINK (a real directory, not switched yet)"; fi
    exit 0 ;;
  claude|codex) TARGET="$HOME/wall-$1" ;;
  *) echo "usage: switch.sh [claude|codex]"; exit 2 ;;
esac

[ -d "$TARGET" ] || { echo "no such tree: $TARGET"; exit 1; }
if [ ! -x "$TARGET/.venv/bin/python" ]; then
  echo "$TARGET has no venv yet. Make one:"
  echo "  python3 -m venv $TARGET/.venv && $TARGET/.venv/bin/pip install -r $TARGET/brain/requirements.txt"
  exit 1
fi
if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
  echo "$LINK is a real directory. Move it aside first:"
  echo "  mv $LINK $HOME/wall-claude && ln -s $HOME/wall-claude $LINK"
  exit 1
fi

ln -sfn "$TARGET" "$LINK"
PID="$(systemctl show -p MainPID --value album-art-matrix.service)"
if [ "$PID" != "0" ]; then kill -KILL "$PID"; fi      # Restart=on-failure brings it back in 5 s
for _ in $(seq 1 40); do
  sleep 1
  if curl -s --max-time 2 http://127.0.0.1:8788/health >/dev/null 2>&1; then break; fi
done
echo "live: $(readlink "$LINK")"
echo "brain: $(curl -s --max-time 2 http://127.0.0.1:8788/health | cut -c1-120)"
