# Two knocks, or a whistle

In this build's Pi config set `[features] knock = true`. In Tessera's Hearing
page turn on Knock, Whistle, or both. Two brief knocks 150 to 800 ms apart
toggle the current face. Rising pitch turns it on, falling pitch turns it
off, and a level whistle toggles it. Off remembers the face as `knock_ret`
in control.json, shared with other phones and kept through a restart.

The detector consumes the existing microphone stream. Ten-millisecond
slices measure a spike against a one-second power average. A candidate
must last less than 80 ms and contain energy below 500 Hz and above 2 kHz.
The default required rise is 20 dB. While the music gate is open, the
required absolute level is also at least 6 dB above the measured music.
Every candidate logs its rise, peak, duration and two spectral fractions.
The microphone thread queues actions; a separate worker changes control
state and writes it to disk. Audio is not saved.

Whistles use 1024 samples with a 512-sample hop. The strongest frequency
and its neighboring bins must carry 70 percent of the 800 to 3500 Hz
energy for 300 ms. The neighboring bins count because a frequency between
FFT bins naturally straddles them. A two-second debounce follows either
gesture. The feature needs a second of room sound before detecting knocks.

## What to expect

A successful double knock changes the face within the current 100 ms
capture chunk plus the brief decay and one render frame: a target of
under 200 ms after the second knock. A whistle takes 300 to 400 ms of
steady sound before the action. These are scheduling budgets; physical
latency and tuning require the frame and room. Two drum transients with
exactly the same acoustic signature as knocks cannot be distinguished by
this microphone alone. Turn Knock off and use Whistle in that room.

Run `.venv/bin/python -m pytest brain/tests/test_gestures.py -q` offline.
Fixtures cover decaying broadband noise, narrow-band clicks, sine sweeps,
short tones, invalid intervals, debounce, a bass/snare loop, and persisted
return state. The fixtures are generated at test time; no room recording
is stored. The drum fixture is not proof against every real music track.

## Deploy

Copy and compare checksums for `brain/gestures.py`, `brain/tuning.py`,
`brain/control.py`, `brain/main.py`, `brain/nowplaying/ears.py` and
`brain/tests/test_gestures.py` into matching paths under `wall-codex`.
No dependency is added. Restart only the live Codex brain by killing its
MainPID. Install the updated phone with `tessera/Tools/install.sh codex`.
The controls are persisted by the wall's existing tuning store.

No face is added: 64 and 192 retain the exact existing frame when toggled
back on. Real knocking on the frame, observed false positives, and latency
measurements remain hardware acceptance checks. There are no new pixel
regions or preview PNGs for this feature.
