# The room, rendered

`room.py` builds the room design's scene in Blender 5.1 headless and renders
the app's layers. The record player on the table is the **Tessera TT-900WW**,
turntable and both speakers, a 1:1 replica of the Gemini TT-900 made by
ChatGPT (source project `~/Desktop/github/gemini-tt900`, `build_model.py`).
Its white finish is vendored here as `tt900-white.blend`, a copy of that
project's `exports/Tessera_TT-900WW.blend` with only the white collection
kept; room.py appends it and stands it on the table. Put a square sleeve at
`cover.jpg` beside it (it is only the stand-in on the wall), then, from this
folder:

    /Applications/Blender.app/Contents/MacOS/Blender -b -P room.py -- <mode>

or render and stage everything with `render_all.sh [logs dir] [first pass]`,
which holds the Mac awake while it runs and, given a first pass, resumes there
(the needle keeps the sprites already on disk). A full run takes about two
hours; start it in its own session (python's `os.setsid()` then exec) so a
closed terminal or a restarted Claude session does not kill it.

What room.py does to the model: renames the parts the passes ask for
(`plinth`, `platter`, `slipmat`, `spindle`, `armrest`, `cradle`), lays a
270 mm record on the mat for the app's pressing (inside the 280 mm platter,
so it never hangs off the deck; its label and the groove's lead-in and run-out
scale with it), re-parents the tonearm
about its turret (the hex housing and bearing turn; shaft, sleeve,
counterweight, headshell, cartridge and stylus also tilt about the bearing,
which is the lift), and opens the rest clip's hook into a cradle so the arm
lifts out of it rather than through it. The model is built with the arm
parked, so the rest is no turn; the arm swings in with negative angles, and
the needle's search runs between the rest and the swing that brings the
stylus nearest the spindle. The TT-900 has no dust cover; its Tessera prints
(plinth, mat, both speakers) are part of the model, so the old cover and
badge passes are gone.

Modes:

- `base`: the still, 3x, with the wall dark.
- `light`: the room lit by the wall alone, in white; the app tints it with the
  wall's colour and screens it over the still. The back wall is out of camera
  in every light pass, so the light lands on the table, deck, speakers and
  frame and never washes the wall: behind the wall the app shows its own
  background, the sleeve's gradient, the same one the sting opening sits on.
- `recshade`: the record and label matte white, with the deck as shadow
  catcher; the app multiplies the pressing under it (`RecordShade`, with
  `record_box`). `RecordSpec` is the still's own record crop cut with the
  shade's alpha, added on top for the reflections.
- `needle`: the arm grid: cradle, swing, 32 groove positions x 5 heights. On
  the cradle the stylus rises from where it lies to the full lift; elsewhere
  it sits on the record's face plus a fraction of 10 mm.
- `geom`: where things are in the image, as `room-geometry.json`.
- `overhead`, `overshade`, `overlight`, `overgeom`: the deck from straight
  above with the arm home, for the close view of the record
  (`OverheadBase`/`OverheadShade`/`OverheadLight` at 3x, `OverheadSpec` cut
  from the base by the shade's alpha, `over_record_quad`/`over_record_box`/
  `over_label` in the geometry).
- `dive`, `divelight`: 36 frames of the camera rising from the seat to
  straight over the deck, with `room-dive-track.json`; encoded forwards as
  `room-dive(-light).mov` and backwards (`-vf reverse`) as the `-out` films.
- `intro`, `lightfilm`: the film opening, 108 frames: close over the Tessera
  print on the plinth, drifting in, then back to the seat, with
  `room-intro-track.json` (no wall while the camera is close on the deck);
  `room-intro.mov` and `room-light.mov`.
- `mark`, `marklight`: the second opening, 96 frames from the seat: nine
  plates fly in and build the mark before the wall, grow into the panel's
  cells and fade to the live wall, while the table and deck assemble out of
  voxel blocks that refine into the real geometry; `room-mark(-light).mov`
  and `room-mark-track.json`, whose `cells` field tells the app how coarse to
  draw the arriving wall.

Staging (what `render_all.sh` does): base, light, recshade and the overhead
set into the imagesets at 3x with the two Spec crops cut, the needle PNGs
into `Tessera/Needle/`, the merged geometry and the tracks alongside them, and
each film's frames through ffmpeg:

    ffmpeg -framerate 30 -i room_%04d.png -vf "format=rgba,premultiply=inplace=1" \
      -c:v hevc_videotoolbox -alpha_quality 0.8 -q:v 65 -tag:v hvc1 -pix_fmt bgra \
      -movflags +faststart room-intro.mov

The premultiply matters: AVPlayerLayer composites HEVC alpha as premultiplied,
and straight frames make every half-transparent pixel too bright. The needle
mode skips sprites it finds on disk, so clear `room-needle/` before a
re-render. Blender gotchas met on the way: `kernel_optimization_level = 'OFF'`
(Metal kernel specialisation aborts otherwise), never
`transform_apply(scale=True)` on a placed object (it bakes the location too),
and build moving parts about a pivot at the origin so the parent inverse
stays identity. In every light pass the
wall's emitter has `visible_camera` off: it lights the room but is not seen,
so the app's live wall never has a bright edge beside it; the back wall is off
too, and the room screen draws no bloom, so the wall area is the app's own
background and matches the opening. A render that sleeps stalls: run long passes
under `caffeinate -i -s`.
