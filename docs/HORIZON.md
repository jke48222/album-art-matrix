# Horizon

Horizon appears only after a wake detection. The current picture compresses
vertically for 250 ms, then becomes a sleeve-coloured line. Speech lifts it,
a moving bead means thinking, and the new face opens from the line in
400 ms. If no speech was caught, dashes last 800 ms, close to black in
160 ms, and the prior face resumes. A phone control cancels the animation.

Enable both `wake` and `horizon` in `[features]`. There is no idle or saved
Horizon mode. Timings are named constants at the top of
`brain/art/horizon.py`. The line takes the most saturated bright pixel of
the captured sleeve, with warm paper as the no-art fallback. All frames go
through the same finish and white-balance pipeline as existing faces.

## Pixel layouts, inspected

At 64, the settled line occupies x=2 through 61 on y=31. Its bead is six
pixels wide. Loud syllables put one or two extra pixels at its ends while
the middle stays still. The collapse retains the full 64-pixel horizontal
picture and shrinks only its height. In the verification fixture the left
half is copper and the right half navy. The final “Yes” occupies the central
three-letter region using the answer font, with black around it.

At 192, the line occupies x=9 through 182, y=94 through 96. Its bead is
18 pixels wide. Wider margins and a three-pixel line fit the larger wall;
the destination answer uses its own 3x font layout. Dashed segments are
nine pixels long with nine-pixel gaps. No whole-frame 3x scaling is used.

Run `.venv/bin/python -m scripts.render_horizon`. The preview sink writes
12 states for each size in `docs/verification/horizon`, with native strips
and two-row contact sheets. Both sheets were visually inspected. Tests
check the unaltered first frame, line thickness, bead movement, saturated
ink, release, exact destination, and black ending at both sizes. Physical
wake-to-panel timing remains pending a spoken room test.
