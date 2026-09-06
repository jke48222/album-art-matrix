# The room, rendered

`room.py` builds the room design's scene in Blender 5.1 headless and renders
the app's layers. Put a square sleeve at `cover.jpg` beside it (it is only the
stand-in on the wall and the record label), then, from this folder:

    /Applications/Blender.app/Contents/MacOS/Blender -b -P room.py -- <mode>

Modes:

- `base`: the still, 3x, with the wall dark and the record and label left as
  holes for the app to fill.
- `light`: the room lit by the wall alone, in white; the app tints it with the
  wall's colour and screens it over the still.
- `cover`: the glass cover alone, open, for the lid layer.
- `badge`: the mark's plates alone, in white, on the closed cover; the app
  tints them with the accent (`RoomBadge`, with `badge_box` in the geometry).
- `recshade`: the record and label matte white, with the deck as shadow
  catcher; the app multiplies the pressing under it (`RecordShade`, with
  `record_box`). `RecordSpec` is the still's own record crop cut with the
  shade's alpha, added on top for the reflections.
- `needle`: the arm grid: cradle, swing, 32 groove positions x 5 heights.
- `geom`: where things are in the image, as `room-geometry.json`.
- `intro`: the opening, 108 frames, with a per-frame track of the wall, the
  record, the label and the plates in `room-intro-track.json`.
- `lightfilm`, `badgefilm`: the same 108 frames rendered as the light pass and
  the plates pass, for `room-light.mov` and `room-badge.mov`, which the app
  plays in lockstep with the opening, tinted like the stills.
- `overhead`, `overshade`, `overlight`, `overgeom`: the deck from straight
  above, the cover open and the arm home, for the close view of the record
  (`OverheadBase`/`OverheadShade`/`OverheadLight` at 3x, `OverheadSpec` cut
  from the base by the shade's alpha, `over_record_quad`/`over_record_box`/
  `over_label` in the geometry).
- `dive`, `divelight`, `divebadge`: 36 frames of the camera rising from the
  seat to straight over the deck as the cover swings up, in the opening's
  three passes, with `room-dive-track.json`; encoded forwards as
  `room-dive(-light/-badge).mov` and backwards (`-vf reverse`) as the `-out`
  films, the way back.
- `mark`, `marklight`, `markbadge`: the second opening, 96 frames from the
  seat: nine plates fly in and build the mark before the wall, grow into the
  panel's cells and fade to the live wall, while the table and deck assemble
  out of voxel blocks (Remesh in blocks mode plus a Build modifier) that
  refine into the real geometry; `room-mark(-light/-badge).mov` and
  `room-mark-track.json`, whose `cells` field tells the app how coarse to
  draw the arriving wall.

Staging: base, light, cover, badge and recshade go into the imagesets at 3x,
the needle PNGs into `Tessera/Needle/`, the two JSON files alongside them, and
each film's frames through ffmpeg:

    ffmpeg -framerate 30 -i room_%04d.png -vf "format=rgba,premultiply=inplace=1" \
      -c:v hevc_videotoolbox -alpha_quality 0.8 -q:v 65 -tag:v hvc1 -pix_fmt bgra \
      -movflags +faststart room-intro.mov

The premultiply matters: AVPlayerLayer composites HEVC alpha as premultiplied,
and straight frames make every half-transparent pixel (the glass) too bright.
Blender gotchas met on the way: `kernel_optimization_level = 'OFF'` (Metal
kernel specialisation aborts otherwise), never `transform_apply(scale=True)`
on a placed object (it bakes the location too), and build parts about a pivot
at the origin so the parent inverse stays identity. In every light pass the
wall's emitter has `visible_camera` off: it lights the room but is not seen,
so the app's live wall never has a bright edge beside it.
