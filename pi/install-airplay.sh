#!/usr/bin/env bash
# AirPlay to the wall, installed without root.
#
# Debian's shairport-sync (trixie, 4.3.7) is a classic AirPlay build:
#   4.3.7-libdaemon-OpenSSL-Avahi-ALSA-jack-pa-dummy-stdout-pipe-soxr-...-metadata-...
# no AirPlay 2, so no nqptp and no privileged ports; it runs as the pi user
# and announces itself through the avahi daemon that is already running.
# This fetches the package and the two libraries it needs that the Pi does
# not have (libconfig11, libmosquitto1), unpacks them under
# ~/opt/shairport-sync, and checks the binary runs. The brain starts and
# watches the receiver itself (brain/nowplaying/airplay.py): no system
# service, no sudo. Run it again to update.
#
#     ~/wall-claude/pi/install-airplay.sh
set -euo pipefail
DEST="${1:-$HOME/opt/shairport-sync}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" "$DEST.new"' EXIT
cd "$WORK"
echo ">>> fetching shairport-sync and its libraries"
apt-get download shairport-sync libconfig11 libmosquitto1 >/dev/null
mkdir -p "$DEST.new/root"
for d in *.deb; do dpkg-deb -x "$d" "$DEST.new/root"; done
BIN="$DEST.new/root/usr/bin/shairport-sync"
LIBS="$(find "$DEST.new/root" -name '*.so*' -printf '%h\n' | sort -u | tr '\n' ':')"
if LD_LIBRARY_PATH="$LIBS" ldd "$BIN" | grep -q "not found"; then
  echo "still missing:"
  LD_LIBRARY_PATH="$LIBS" ldd "$BIN" | grep "not found"
  exit 1
fi
VERSION="$(LD_LIBRARY_PATH="$LIBS" "$BIN" -V 2>&1 | head -n1)"
case "$VERSION" in
  *AirPlay2*) echo "note: this build is AirPlay 2 and wants nqptp, which needs root; it will not play here" ;;
esac
rm -rf "$DEST.old"
[ -d "$DEST" ] && mv "$DEST" "$DEST.old"
mv "$DEST.new" "$DEST"
echo "$VERSION" > "$DEST/VERSION"
rm -rf "$DEST.old"
echo ">>> shairport-sync $VERSION"
echo ">>> in $DEST; the brain starts it"
