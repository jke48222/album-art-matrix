# Find a song, sleeve or video

Tessera's Find page has one title field with Show sleeve and Play video,
plus a separate remembered-words field. The Room screen carries the same
compact title search below the current record. It uses native SwiftUI fields,
clear labels, a single existing accent and tactile buttons; loading, result,
empty and request-error states stay in context. No query history is stored.

## Earworm

`POST /earworm {"text":"..."}` sends only those remembered words to Claude.
The Messages request requires a JSON-schema result with title, artist,
confidence and alternatives. Track words are data, never instructions.
Apple's public music catalogue supplies the real sleeve. Confidence at or
above 0.4 shows the top match. Below 0.4 the 64-pixel wall alternates the two
best sleeves every two seconds, while the 192-pixel wall places two 88-pixel
sleeves side by side with separate labels. The response includes the best
match, confidence and alternatives for the phone.

The Claude key from Services is required. No key shows `no key yet`; an
empty catalogue shows `nothing certain yet`; malformed model output, timeout
or network trouble shows `could not find it`. The original face returns
after eight seconds, and any control change cancels the result. Voice routes
“what song goes ...” and “find the song ...” here.

## Show and play

`POST /show {"query":"..."}` searches catalogue albums first and songs
second, upgrades Apple's artwork URL to 1200 pixels, and keeps the result
face up for ten minutes or until a control change. No account or key is
needed. “Show the Blond cover” routes here locally after transcription.

`POST /play {"query":"..."}` asks the installed yt-dlp for `ytsearch1:`,
turns the returned video ID into a normal YouTube watch URL, and hands it to
the existing video player. The phone remains its speaker and clock. “Play
the Gameboy video” routes here. YouTube search can take up to 15 seconds;
the wall's existing video loading and error states handle the next stage.

## Verified layouts

Run `.venv/bin/python -m scripts.render_results`. For a certain result at
64, artwork occupies x=6..57 and y=0..51; a one-pixel-scale title moves
through y=56..62. At 192, artwork occupies x=18..173 and y=0..155; the
three-pixel title moves through y=164..184. In the uncertain 64 strip, rust
and blue sleeves alternate every two seconds. At 192, they occupy x=4..91
and x=96..183, y=16..103, with two-pixel labels at y=110..123. Remaining
pixels are black. All four strips were visually inspected.

Offline tests cover catalogue ordering and artwork URLs, both result layouts,
strict structured output, low-confidence alternatives, feature gates and
transcriber command routes. Live model and catalogue acceptance needs the
owner's Claude key. Live video search uses the already installed yt-dlp.

Enable `[features] earworm = true` and `show = true`. No new secret or
Python dependency is added. The controls and endpoints are documented in
`brain/control.py`; both feature states appear through `/features`.
