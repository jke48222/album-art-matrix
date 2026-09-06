#!/usr/bin/env bash
# Start the display daemon. The wall's shape comes from ~/album-art-matrix/wall
# ("COLSxROWS", e.g. 3x3), so bringing panels up a chain at a time is a one
# line change on the Pi and a restart, not an edit to this script:
#   echo 3x1 > ~/album-art-matrix/wall     # one port, three panels
#   echo 3x3 > ~/album-art-matrix/wall     # the whole wall
# Rows are PORTS on the Triple Bonnet (one to three) and columns are the
# panels chained off each port. The library clocks every port together, so
# each port must carry the SAME number of panels.
#   -d 64  : 64-bit BCM (the camera-flicker killer, with the 9600 Hz refresh)
#   -g 2.2 : decode our sRGB-encoded frames to linear for BCM
#   -t none: no tone mapping — album art should not be "enhanced"
#   -l 1.0 : spatial dithering on. Turning it off, and halving the bit depth,
#            were tried against the last-row ghost; neither touched it and
#            both cost colour, so both are back where they were.
#   -b 160 : brightness cap 0-254; raise once PSU headroom is confirmed
set -euo pipefail
FIFO="${FRAME_FIFO:-/tmp/album-frame.fifo}"
[ -p "$FIFO" ] || mkfifo "$FIFO"
export FRAME_FIFO="$FIFO"
# Map-rate cap; must cover [animation] fps in config.toml (the brain produces
# at fps, this decides how many of those map). Set HERE so a tuned value has
# one home that survives reboots — the systemd unit runs this script.
MAPHZ="$(cat "$HOME/album-art-matrix/map-hz" 2>/dev/null || echo 60)"
case "$MAPHZ" in ''|*[!0-9]*) MAPHZ=60 ;; esac
export MAX_MAP_HZ="${MAX_MAP_HZ:-$MAPHZ}"
# The panel's own brightness cap, 1-254. The brain writes this file when the
# cap is changed from the phone and restarts the renderer, because the cap is
# a launch flag: there is no way to change it in a running panel.
BRIGHT="$(cat "$HOME/album-art-matrix/panel-brightness" 2>/dev/null || echo 160)"
case "$BRIGHT" in ''|*[!0-9]*) BRIGHT=160 ;; esac
[ "$BRIGHT" -ge 1 ] 2>/dev/null && [ "$BRIGHT" -le 254 ] 2>/dev/null || BRIGHT=160
# The panel's row addressing, 0-7. This board ghosts the content's colour into
# the last row of its scan, which is what a wrong addressing looks like, so it
# is worth sweeping. Written by the brain, same as the cap.
# Row-change settle in the library's scan loop (see the block below): the
# output stays off this long after every row address change. Dark time, so
# the cap above pays it back; tune with the file, 0 turns it off.
SETTLE="$(cat "$HOME/album-art-matrix/addr-settle-ns" 2>/dev/null || echo 1000)"
case "$SETTLE" in ''|*[!0-9]*) SETTLE=1000 ;; esac
export HUB75_ADDR_SETTLE_NS="$SETTLE"
# Spatial dithering strength, 0-10. It buys colour in dark areas by toggling
# the lowest bits, and at the very bottom of the range that shows as single
# LEDs of one colour in a field that should be grey — red first, because a
# red LED reaches current soonest in a drive window. A file, so it can be
# tuned against the panel without editing this script.
DITHER="$(cat "$HOME/album-art-matrix/dither" 2>/dev/null || echo 1.0)"
case "$DITHER" in ''|*[!0-9.]*) DITHER=1.0 ;; esac
# Bit depth, 4-64 in fours. Higher is more colour and a slower refresh.
DEPTH="$(cat "$HOME/album-art-matrix/bit-depth" 2>/dev/null || echo 64)"
case "$DEPTH" in ''|*[!0-9]*) DEPTH=64 ;; esac
# The panel's row addressing, 0-7. Written by the brain, same as the rest.
PTYPE="$(cat "$HOME/album-art-matrix/panel-type" 2>/dev/null || echo 0)"
case "$PTYPE" in ''|*[!0-9]*) PTYPE=0 ;; esac
# The wall: COLS x ROWS panels of TILE pixels. Anything unreadable falls back
# to the single panel this started as, because a wrong geometry is a wall of
# scrambled tiles and a missing file should not produce one.
TILE="${PANEL_TILE:-64}"
WALL="$(cat "$HOME/album-art-matrix/wall" 2>/dev/null || echo 1x1)"
COLS="${WALL%%x*}"; ROWS="${WALL##*x}"
case "$COLS" in ''|*[!0-9]*) COLS=1 ;; esac
case "$ROWS" in ''|*[!0-9]*) ROWS=1 ;; esac
[ "$COLS" -ge 1 ] && [ "$COLS" -le 8 ] || COLS=1
[ "$ROWS" -ge 1 ] && [ "$ROWS" -le 3 ] || ROWS=1     # three ports on the bonnet
W=$((COLS * TILE)); H=$((ROWS * TILE))
# The library wants the total width in multiples of 32.
[ $((W % 32)) -eq 0 ] || { echo "wall $COLS x $TILE = $W is not a multiple of 32" >&2; exit 1; }
# -P takes one panel type per panel: colons across a port, commas between
# ports. Every panel here is the same type, so it is that type repeated.
ROW="$PTYPE"; for _ in $(seq 2 "$COLS"); do ROW="$ROW:$PTYPE"; done
PMAP="$ROW"; for _ in $(seq 2 "$ROWS"); do PMAP="$PMAP,$ROW"; done
echo "[renderer] wall ${COLS}x${ROWS} panels = ${W}x${H}, ports=$ROWS chain=$COLS" >&2
exec "$HOME/album-art-matrix/renderer/art_display" \
  -w "$TILE" -h "$TILE" -p "$ROWS" -c "$COLS" -x "$W" -y "$H" \
  -d "$DEPTH" -f 120 -g 2.2 -t none -l "$DITHER" -b "$BRIGHT" -P "$PMAP"

# The last row. This panel used to ghost the content's own colour into the
# bottom row of its scan (a red clock left a red line there) on frames whose
# bottom rows were exactly zero. None of the flags here touch that: the cause
# was the library changing the row address with the output still enabled, and
# the fix is in its scan loop (pi/hub75-address-guard.py): the output held
# off while the row address settles, a microsecond by default, because the
# row just left keeps conducting the new row's data until its driver is off.
# The flags are the panel's original set and should stay that way.
