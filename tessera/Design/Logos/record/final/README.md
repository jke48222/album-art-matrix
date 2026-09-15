# Tessera Record sting, final

White nine by nine disc on pure black; the name in Technor Bold revealed by
a feathered wipe. Built as one flat vector animation, then re-rendered
through Higgsfield with that animation as the motion reference and the
first and last frames pinned, upscaled to 4K, and married to a four-cue
sound design placed on the animation's own timeline.

| File | What it is |
|---|---|
| `tessera-record-final-4k.mp4` | The final product: Higgsfield reference-driven render, Topaz-upscaled to 3840 x 2160, with sound. |
| `tessera-record-final-720p.mp4` | The same render before upscaling, with sound. |
| `tessera-record-vector-4k.mp4` | The vector source itself at 3840 x 2160, with the same sound. Pixel-exact. |
| `tessera-record-vector-1080p.mp4` | The vector source at 1920 x 1080, with sound. |
| `end-frame.png` | The resting lockup, 1920 x 1080, as pinned for the render. |
| `storyboard.png` | Eight frames of the vector source. |
| `sound/` | The four generated cues: riser, clicks, lock, shimmer (48 kHz wav). |

Timeline: lattice fades up from the centre (0.0 to 0.3 s); the disc builds
along its groove, rim to spindle, while spinning down and locking (0.15 to
1.6 s); the mark slides left and the name is revealed left to right behind
a feathered edge with a slight settle (1.42 to 2.2 s); hold to 5 s.
Sound: riser 0.0 to 1.5 s, clicks under the build from 0.2 s, the lock thud
at 1.55 s, the shimmer from 1.6 s as the letters switch on.

The generative pass lands its beats later than the source (disc complete at
about 1.3 s, name from about 2.8 s), so its sound is cut with
`record_sound.py ... --lock 1.3 --word 2.8`; the vector versions use the
defaults. The first pass of this render smeared a second rotation after the
lock; the prompt now states that the disc makes one spin and is motionless
from the lock onward, which fixed it.

Source and tools: `tessera/Tools/record_sting.py` (the animation, page and
vector renders; `--mode` picks the name's arrival, `--options` renders the
three alternatives that were considered), `tessera/Tools/record_sound.py`
(the mix), the page itself in `../sting/record-sting.html`.

## In the app

`tessera/Tessera/record-sting.mp4` (HEVC 2160p) is the "Sting" opening;
`record-sting-alpha.mov` (HEVC with alpha, the alpha being the picture's own
luma, cleaned of codec noise) is the "In room" opening, keyed over the room's
light with the pixel glitch after it. Both are made from
`tessera-record-final-4k.mp4` by the ffmpeg lines in the session notes; the
openings are muted in the app like the other openings, the sound is in the
MP4 if that changes. `RecordMark.swift` draws the mark live; the icon and the
cover badge are still images made from the same geometry.
