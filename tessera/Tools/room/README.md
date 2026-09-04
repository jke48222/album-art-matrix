# The room, rendered

`room.py` builds the room design's scene in Blender 5.1 headless and renders
the app's layers. Put a square sleeve at `cover.jpg` beside it (it is only the
stand-in on the wall and the record label), then, from this folder:

    /Applications/Blender.app/Contents/MacOS/Blender -b -P room.py -- <mode>

Modes: `base` (the still, 3x), `light` (the room lit by the wall alone),
`spin` (one turn of the record, 54 frames), `needle` (the arm grid: cradle,
swing, 32 groove positions x 5 heights), `intro` (the opening, 108 frames),
`geom` (where things are in the image, as `room-geometry.json`).

Staging: base and light go into `RoomBase`/`RoomLight` imagesets at 3x, the
needle PNGs into `Tessera/Needle/`, the spin and intro frames through ffmpeg
(`hevc_videotoolbox`, `-alpha_quality 1` for the spin) into `room-spin.mov`
and `room-intro.mov`, and `room-geometry.json` gets the spin box from
`room-spin.json` added.
