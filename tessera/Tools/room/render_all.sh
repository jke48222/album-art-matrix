#!/bin/zsh
# Render every layer of the room for the app, then stage it all into
# tessera/Tessera: the stills and their crops, the needle grid, the
# geometry, the three films and their tracks. Long: the films are most of it.
#
#   tessera/Tools/room/render_all.sh [logs dir] [first pass]
#
# With a first pass it resumes there: the passes before it are kept as they
# are, the needle keeps the sprites already on disk, and each film pass that
# runs starts from an empty folder. It holds the Mac awake while it runs.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
APP=$(cd "$HERE/../../Tessera" && pwd)
B=/Applications/Blender.app/Contents/MacOS/Blender
LOG=${1:-$HERE/render-logs}
mkdir -p "$LOG"
cd "$HERE"
caffeinate -i -s -w $$ &
FROM=${2:-}

run() {
  echo "== $1 $(date +%H:%M:%S)"
  "$B" -b -P "$HERE/room.py" -- "$1" > "$LOG/$1.log" 2>&1
  local c=$?
  grep -E "Error|Traceback" "$LOG/$1.log" | tail -3
  echo "   $1 exit $c $(date +%H:%M:%S)"
}
enc() {   # frames pattern, output, extra filter
  ffmpeg -v error -y -framerate 30 -i "$1" -vf "format=rgba,premultiply=inplace=1$3" \
    -c:v hevc_videotoolbox -alpha_quality 0.8 -q:v 65 -tag:v hvc1 -pix_fmt bgra -movflags +faststart "$2" \
    && echo "   encoded $(basename $2)"
}

PASSES=(geom base light recshade needle overgeom overhead overshade overlight dive divelight intro lightfilm mark marklight)
if [ -z "$FROM" ]; then
  # a full run starts clean: the needle skips sprites it finds on disk
  rm -rf room-needle room-divebadge room-markbadge room-badgefilm
elif (( ! ${PASSES[(Ie)$FROM]} )); then
  echo "render_all.sh: no pass $FROM"; exit 2
fi
started=0; [ -z "$FROM" ] && started=1
for m in $PASSES; do
  [ "$m" = "$FROM" ] && started=1
  (( started )) || continue
  case $m in dive|divelight|intro|lightfilm|mark|marklight) rm -rf "room-$m" ;; esac
  run $m
done

echo "== staging $(date +%H:%M:%S)"
python3 - "$HERE" "$APP" <<'PY'
import json, os, shutil, sys, glob
from PIL import Image
R, APP = sys.argv[1], sys.argv[2]
A = os.path.join(APP, "Assets.xcassets")
def put(src, imageset, name):
    s = os.path.join(R, src)
    if os.path.exists(s):
        shutil.copy(s, os.path.join(A, imageset + ".imageset", name)); print("   still", imageset)
    else:
        print("   MISSING", src)
def spec(base, shade, box, imageset, name):
    B = Image.open(os.path.join(R, base)).convert("RGBA"); Sh = Image.open(os.path.join(R, shade)).convert("RGBA")
    W, H = B.size; x0, y0 = round(box[0] * W), round(box[1] * H)
    r, g, b, _ = B.crop((x0, y0, x0 + Sh.width, y0 + Sh.height)).split()
    Image.merge("RGBA", (r, g, b, Sh.getchannel("A"))).save(os.path.join(A, imageset + ".imageset", name)); print("   spec", imageset)
geo = json.load(open(os.path.join(R, "room-geometry.json")))
for f in ("room-recshade.json", "room-overgeom.json", "room-overshade.json"):
    geo.update(json.load(open(os.path.join(R, f))))
for k in ("cover", "badge", "badge_box"): geo.pop(k, None)
json.dump(geo, open(os.path.join(APP, "room-geometry.json"), "w")); print("   geometry", sorted(geo))
put("room-base.png", "RoomBase", "room-base@3x.png")
put("room-light.png", "RoomLight", "room-light@3x.png")
put("room-recshade.png", "RecordShade", "RecordShade@3x.png")
spec("room-base.png", "room-recshade.png", geo["record_box"], "RecordSpec", "RecordSpec@3x.png")
put("room-overhead.png", "OverheadBase", "OverheadBase@3x.png")
put("room-overlight.png", "OverheadLight", "OverheadLight@3x.png")
put("room-overshade.png", "OverheadShade", "OverheadShade@3x.png")
spec("room-overhead.png", "room-overshade.png", geo["over_record_box"], "OverheadSpec", "OverheadSpec@3x.png")
sprites = sorted(glob.glob(os.path.join(R, "room-needle", "needle-*.png")))
if len(sprites) == 174:
    for f in glob.glob(os.path.join(APP, "Needle", "needle-*.png")): os.remove(f)
    for f in sprites: shutil.copy(f, os.path.join(APP, "Needle", os.path.basename(f)))
    print("   needle sprites", len(sprites))
else:
    print("   NEEDLE INCOMPLETE", len(sprites))
for t in ("room-dive-track.json", "room-intro-track.json", "room-mark-track.json"):
    if os.path.exists(os.path.join(R, t)): shutil.copy(os.path.join(R, t), os.path.join(APP, t)); print("   track", t)
PY

f() { ls "$1"/*.png >/dev/null 2>&1; }
f room-dive      && enc "room-dive/dive_%04d.png" "$APP/room-dive.mov" "" && enc "room-dive/dive_%04d.png" "$APP/room-dive-out.mov" ",reverse"
f room-divelight && enc "room-divelight/light_%04d.png" "$APP/room-dive-light.mov" "" && enc "room-divelight/light_%04d.png" "$APP/room-dive-light-out.mov" ",reverse"
f room-intro     && enc "room-intro/room_%04d.png" "$APP/room-intro.mov" ""
f room-lightfilm && enc "room-lightfilm/light_%04d.png" "$APP/room-light.mov" ""
f room-mark      && enc "room-mark/mark_%04d.png" "$APP/room-mark.mov" ""
f room-marklight && enc "room-marklight/light_%04d.png" "$APP/room-mark-light.mov" ""

# the dust cover and its badge are gone from the scene
rm -f "$APP/room-badge.mov" "$APP/room-dive-badge.mov" "$APP/room-dive-badge-out.mov" "$APP/room-mark-badge.mov"
rm -rf "$APP/Assets.xcassets/RoomCover.imageset" "$APP/Assets.xcassets/RoomBadge.imageset"
echo "== done $(date +%H:%M:%S)"
