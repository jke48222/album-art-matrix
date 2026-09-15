# Album Art Matrix: the build brief

This is the prompt. It is given, word for word, to two builders: Claude, working
inside the repository with a shell, the Pi and the phone, and Codex (GPT-6 Astra High), working in a checkout of the same repository
with its own shell. Both produce a complete
version of every feature below. The owner compares the two and picks, feature
by feature. Neither builder is told what the other did.

Read all of it before writing anything. Then build in the order given, one
feature at a time, each to the standard in "The bar", and stop for nothing
except a real question that changes the work.

---

## 1. What the wall is

A 64 by 64 RGB LED panel on the wall of a bedroom, showing the sleeve of
whatever song is playing in the room, and doing a dozen other things when
nothing is. It is a piece of furniture with a personality, not a dashboard.
The owner's taste: calm, physical, restrained. Glow, grain, neon, synthwave,
"AI slop" gradients and pixel-font cosplay have all been rejected. Think
Teenage Engineering and Braun, not a gaming rig.

### Hardware

- Raspberry Pi 5 running Raspberry Pi OS (Bookworm, 64-bit), Python 3.13 in
  a venv at `~/album-art-matrix/.venv`, hostname `album-matrix`, on Wi-Fi at
  192.168.12.118. Core 3 is isolated (`isolcpus=3`) and belongs to the panel
  driver. Everything else shares cores 0 to 2.
- Waveshare P2.5 64x64 HUB75 panels (FM6124 driver), on an Adafruit RGB
  Matrix Bonnet. TODAY: one panel. SOON: nine panels in a 3x3, 192x192
  pixels, 480 mm square. Both are real targets. See section 3.
- Adafruit 3367 USB microphone (16 kHz mono capture), zip tied to the bottom
  edge of the board. There is no speaker on the wall.
- No camera. A ring of addressable LEDs behind the object (the halo) is
  designed and coded (`brain/halo.py`) but not wired; do not build on it.
- The owner's iPhone, an iPad, an Apple TV (currently offline), a Mac
  (Jalens-MacBook-Pro.local) that plays Apple Music and reports what it plays.

### Software, as it stands

Repository: `~/fun-project/album-art-matrix` on the Mac, synced to
`~/album-art-matrix` on the Pi by file (rsync one file to its exact path,
then compare md5). The Pi owns its `config.toml`; the Mac's copy is a seed.

- `brain/` Python. `main.py` is the loop: a poller thread asks the source
  chain every 2 s, the loop renders the face that is up, pushes frames to the
  sink. `control.py` is the HTTP API on port 8788 (`ControlState`, its
  `apply(patch)`, `public_state()`, `services()`, `journal_*`, and the
  handler with every route). `tuning.py` holds every LED knob with ranges,
  served to the phone as knob specs so a new knob needs no app build.
  `services.py` holds keys and usernames the phone hands over
  (`~/.config/album-art-matrix/services.json`), one `FIELDS` table with a
  regex per field. `wall.py` is the geometry (`Wall`: tile, cols, rows,
  order, rotate; `fit()` scales a 64x64 phone frame to the wall,
  `phone_view()` scales a wall frame down to 64 for the phone). `homekit.py`
  is the HomeKit bridge (light, television, two sensors, pairing QR on the
  panel). `halo.py`, `sun.py` exist.
- `brain/nowplaying/` the sources: `pushed.py` (the phone posts what it
  plays), `applemusic.py` (the Mac reporter on port 8787; on the Pi it is a
  remote), `macmedia.py`, `applemusic_account.py`, `spotify.py`, `lastfm.py`,
  `listenbrainz.py` (read-only, username only), `ears.py` (the microphone:
  a 15 s ring of 16 kHz audio, level every 100 ms, a gate with a learned
  floor, clips sent to Shazam through `shazamio`, hits dressed with duration
  and 600 px art from iTunes by ISRC, progress extrapolated from Shazam's
  offset; status dict served in `/services` as `hearing`). `SourceChain`:
  first answer wins, a PLAYING answer beats a paused one, a playing answer
  with no art is passed over. `NowPlaying` dataclass: `track_id`, `title`,
  `artist`, `album`, `art_url`, `progress_ms`, `duration_ms`, `is_playing`.
- `brain/art/` the faces: `pipeline.py` (fetch, Lanczos to the wall size,
  unsharp, white balance in linear light, the three finishes clean, dither,
  poster; `dominant_colors`), `disc.py` (the spinning record), `effects.py`
  (ambient: solid, breathe, pulse, rainbow, gradient, plaid, weave, deco,
  snake), `text_modes.py` (Ticker, Clock, Countdown, Crawl; glyphs are the
  5x7 pixel font in `pixelfont.py` at an integer scale, with Hangul and a
  world set), `lyrics.py` (LRCLIB synced lyrics drawn over the sleeve on the
  song's clock), `nine.py` (the last nine sleeves as a 3x3 of 20 px tiles).
- `brain/video/` a YouTube or any link, decoded by ffmpeg, played on the
  wall with the phone as the speaker and clock.
- `brain/sinks/` `pi_renderer.py` (frames into a FIFO for the C renderer,
  remapped per tile) and `mac_preview.py` (frames as PNGs into
  `preview_out/`, for building on a laptop).
- `renderer/art_display.c` the C program on the Pi that owns the panels
  through rpi-rgb-led-matrix, reads the FIFO, applies gamma, the cap, and
  temporal dithering. Not to be changed for these features.
- `scripts/mac_reporter.py` runs on the Mac (a launchd agent) and reports
  what the Mac plays.
- `tessera/` the iPhone app, SwiftUI, about 20,000 lines. `WallLink.swift`
  talks to the wall (host `album-matrix.local:8788`, editable), polls
  `/state`, pulls frames, pushes now-playing. Pages: the room (a rendered
  record player whose arm follows the song), the classic wall, the iPod,
  Settings sheet with pages for services (Spotify, Last.fm, ListenBrainz),
  hearing, tuning, panel, sleep, wake, sun, light, guests, health, archive.
  Design: warm paper, ink, Archivo and IBM Plex Mono, hairlines, flat.
  Nothing glassy. Built with `xcodebuild` (absolute paths, never `cd`),
  installed with `devicectl`.
- `docs/ROADMAP.md` the list of features and their state. `README.md` has a
  status table with one row per piece. Both are updated with every feature.

### The control API, as it stands

```
GET  /state            settings + now_showing + progress + wall geometry
POST /state            partial update {"mode": "ambient", "brightness": 0.4}
GET  /journal          what the wall has worn, newest first (?limit=N)
POST /replay           {"ts"} re-show a journal entry
POST /frame            {"px": base64 raw RGB 64x64 or wall-sized} -> mode frame
POST /push             what the phone is playing
GET  /nowplaying       the chain's answer, or 204
GET  /services         services and their state (incl. "hearing")
POST /services         {spotify:{client_id}, lastfm:{api_key,user}, listenbrainz:{user}, ears:{device}}
POST /spotify/tokens   POST /spotify/unlink
POST /video  GET /video  GET /video/audio  POST /video/clock  POST /video/control  POST /video/stop  POST /video/upload
GET  /tuning  POST /tuning  POST /tuning/reset  POST /tuning/restart
GET  /health           fps, temperature, throttling, loop age, mode
GET  /homekit          POST /homekit/show?s=  POST /homekit/hide  POST /homekit/refresh
GET  /frame.raw        the frame on the wall, 64x64 for the phone
GET  /finishes         the three finishes of the face that is up, as PNGs
```

Modes: `art cd ambient off frame ticker clock clip timer nine lyrics video`.
Idle in silence: `black hold dim ambient`. Away: `stay off`. Settings live in
`~/.config/album-art-matrix/control.json`; the journal in `journal.jsonl`
(entries: ts, title, artist, album, art_url, source).

### Conventions

- Python: plain prose comments that say WHY, in the voice of the existing
  code (read `brain/nowplaying/ears.py` and `brain/homekit.py` first). Module
  docstrings explain the idea and the trade-offs. No em dashes anywhere, in
  code comments, docs or UI text. Log lines start with a `[tag]` and are
  printed with `flush=True` (systemd buffers otherwise). Threads for anything
  that can block; the render loop never waits on the network. Every knob a
  person might turn goes through `tuning.py` so it shows on the phone.
  Secrets come from the phone through `/services` and `services.json`, never
  from code or git. Config keys are documented in `config.example.toml`.
- Swift: match the app's existing components (`Components.swift`, `Theme.swift`,
  `SettingsSheet.swift` for the page pattern). No new dependencies. Every
  new setting is a `SetupGroup` on an existing or new page.
- Tests: offline unit tests under `brain/tests/` (pytest), for anything with
  logic that does not need the network or the panel. Fixtures over mocks.
- Docs: a status row in `README.md`, the state in `docs/ROADMAP.md`, and a
  short `docs/<FEATURE>.md` only when the feature has an operating manual
  worth writing (the ears and the video have one).
- Deploy: the brain restarts by `kill -KILL` of its MainPID (systemd brings
  it back in 5 s; there is no passwordless `systemctl restart`). Never touch
  `~/.config/album-art-matrix/homekit.state` on the Pi: that is the pairing.

---

## 2. The bar

"Maximum fidelity, attention to every detail" means, concretely:

1. Complete code. No placeholders, no "left as an exercise", no TODOs in
   the delivered files. If a dependency is needed, it goes in
   `brain/requirements.txt` with a comment saying why, and the install
   line for the Pi is stated.
2. Every state drawn. Empty (nothing playing, no library, no network),
   loading, error, offline, first run, and the happy path. The panel never
   shows a stack trace, a blank, or a half-drawn frame. An error is a log
   line and a quiet fallback to the face that was up.
3. Both geometries (section 3), rendered and looked at, not assumed.
4. The phone side, when the feature has one: a page or a group in the
   existing app, in its existing style, with the setting persisted on the
   wall (not on the phone) so a second phone sees it.
5. Latency stated and met. What the person sees, how many seconds after
   what they did, and where the time goes.
6. Nothing on the render loop that can block. Network, disk, models and
   recognizers run on their own threads or processes and hand results back
   through the existing `ctrl` events (`nudge`, `dirty`).
7. Resource budget on the Pi: the brain must stay under one core in steady
   state and under 400 MB; the renderer keeps core 3. Any recognizer that
   needs more runs when asked, not continuously.
8. Privacy: the microphone yields levels and short clips for recognition
   only; nothing is stored unless a feature says so, and then it says where
   and for how long, and the phone can wipe it.
9. Documentation: the README row, the ROADMAP state, `config.example.toml`,
   and the control API docstring at the top of `control.py` all updated in
   the same change.
10. Tests for the logic (parsers, matchers, generators, game rules,
    scorers), runnable offline.
11. Idempotent deploy: the same files copied twice change nothing; a restart
    loses nothing a person set.
12. The feature is explained in one paragraph a non-programmer could
    follow, at the top of its module.

---

## 3. One panel and nine panels

The wall is a `Wall` of `tile` pixels per panel, `cols` by `rows`. Today
`tile=64, cols=1, rows=1` (size 64). Soon `tile=64, cols=3, rows=3` (size
192). Every face receives `size` and draws for it. The phone always speaks
64x64: frames it sends are scaled up by `Wall.fit`, frames it reads are
scaled down by `Wall.phone_view`.

Rules for every visual feature:

- Design for 64 first: that is the wall on the wall today, and it is the
  harder canvas. Then design the 192 as its own layout, not a 3x blow-up.
  Text gets a bigger scale of the 5x7 font (2x at 64 reads at arm's length;
  4x to 6x at 192 reads across a room), more lines, wider margins. Grids
  (games) use the room: a Wordle grid at 192 has 24 px cells with real
  gutters; at 64 it has 9 px cells and 1 px gutters.
- Layout constants derive from `size` in one place per face, never scattered
  magic numbers. A face is a class with `frame_at(t, ...)` returning an RGB
  `numpy` array of `size x size`, like the existing ones.
- Colour and brightness are handled by the pipeline after the face
  (`white_balance`, the finish, the cap). Faces draw in plain sRGB.
- Both sizes are rendered with the preview sink on the Mac
  (`[panel] width/height` and `[wall] cols/rows` in a test config) and
  looked at as PNGs before the feature is called done. Claude attaches the
  PNGs; Codex describes exactly what each pixel region contains.
- Anything that maps a 64-frame from the phone (doodles, game boards drawn
  on the phone) goes through `Wall.fit`; do not scale by hand.
- Testing is on the one panel until the nine-panel wall is finished. Nothing
  is deployed to the Pi that would break at 64.

---

## 4. The features, in build order

Numbering follows `docs/ROADMAP.md`. Items 1 to 4 (HomeKit) are done.

### 6. Vinyl scrobbling

What: every record the ear names is written to the owner's ListenBrainz
history, as a streamed song would be.

Behaviour:
- When the ear names a song (a new `EarsSource` hit with title and artist),
  post `playing_now` at once. When half the song's length, or four minutes,
  has been heard, whichever is less, post a `single` listen with
  `listened_at` = the moment the song was first heard. Length comes from the
  ear's iTunes dressing; when unknown, a listen posts after four minutes of
  the same song being held.
- Only the ear scrobbles. Streaming sources scrobble themselves; the Mac
  reporter and the phone are not the wall's to report. A config key
  `[scrobble] sources = ["ears"]` says so and can widen later.
- `additional_info`: `media_player = "Album Art Matrix"`,
  `submission_client = "album-art-matrix"`, `submission_client_version`,
  `music_service_name = "vinyl"`, `isrc` when known, `duration_ms` when
  known, `tags = ["wall"]`.
- Dedupe: the same song held through noise or re-heard within its own
  length is one listen. A song heard again after it ended is a new listen.
- Offline queue: failed posts (no network, 5xx, 429) are queued in
  `~/.config/album-art-matrix/scrobbles.jsonl` and retried with backoff
  (1, 5, 15 min, then hourly) at most 7 days back, as `import` in batches
  of up to 50. 4xx other than 429 is logged and dropped.
- Token: `listenbrainz.token` becomes a field in `services.py` FIELDS
  (a ListenBrainz user token is 36 characters, UUID shaped). The phone's
  ListenBrainz page gets a "User token" field with a link to
  listenbrainz.org/settings. `/services` reports `listenbrainz: {user,
  token_set, last_listen: {title, artist, at}, queued: N, problem}`.
- Journal: the entry for an ear hit gets `scrobbled: true/false`.
- Wall: nothing changes on the panel. The phone's ListenBrainz page shows
  the last listen and the queue.

Tests: the half-or-four-minutes rule, dedupe across holds, queue and
backoff with a fake clock, payload shape against the ListenBrainz JSON doc.

### 7. Knock twice

What: two knocks on the frame toggle the wall between off and the face it
had. A whistle does the same when a knock cannot be told from the music.

Behaviour:
- The ear already reads 100 ms chunks. Add a transient detector on the raw
  stream: a knock is a spike that rises at least 20 dB over the 1 s average
  within 20 ms, lasts under 80 ms, and is broadband (energy in both the
  below-500 Hz and above-2 kHz bands). Two such spikes 150 ms to 800 ms
  apart, and nothing else louder in between, is a double knock.
- While music is loud (the gate is open) the threshold rises by the music's
  level plus 6 dB; the double-knock rule is what keeps drums from counting.
  Log every candidate with its numbers so the threshold can be tuned.
- Whistle: a near-pure tone (one spectral peak carrying at least 70 percent
  of the energy between 800 and 3500 Hz) held at least 300 ms. Rising pitch
  over the whistle = on, falling = off. Detected on 1024-sample FFTs of the
  same stream.
- Both are Hearing knobs on the phone: `knock` (bool), `knock_sensitivity`
  (dB, default 20), `whistle` (bool). Both fire `ctrl.homekit` buttons later
  if the bridge gains a programmable switch; for now they toggle the wall.
- Toggle: off remembers the face (`ctrl.get()["mode"]`) in control state
  under `knock_ret`; on restores it, default art.
- A knock in the first 2 s after a toggle is ignored (debounce).

Tests: synthetic clips (a knock is a decaying noise burst; a whistle is a
sine sweep) through the detectors, and drum-loop audio must not trigger.
Claude records real knocks on the Pi with the owner and reports the numbers.

### 8. Teach the wall a song

What: songs Shazam does not know (the owner's friends' releases, obscure
pressings) are recognised from the wall's own library.

Behaviour:
- Engine: Olaf (github.com/JorenSix/Olaf, C, AGPL) built on the Pi, CLI
  `olaf store` and `olaf query`, database under
  `~/.config/album-art-matrix/olaf/`. Python drives it by subprocess. If Olaf
  will not build, audfprint (Python) is the fallback; say which was used.
- Two ways in. (a) Automatic: when any source names a song that the ear
  then fails to name while it is audibly playing (three misses while loud),
  fetch its 30 s iTunes preview by the source's title and artist and store
  it under `artist - title | album | isrc | art_url`. (b) By ear: while a
  source names a song and the ear's gate is open, store 20 s of the room
  recording under the same name (opt-in knob `teach_by_ear`, default on;
  clips are stored as fingerprints only, never as audio).
- Lookup order in `EarsSource._ask`: the local library first (a query takes
  under a second for a few hundred songs); a hit with score above a knob
  `teach_match_score` counts as named and is dressed like a Shazam hit;
  otherwise Shazam as today.
- Manage: `/teach` GET lists the library (name, added, how learnt, times
  matched); `POST /teach/forget {id}`; `POST /teach/clear`. The phone's
  Hearing page gets a "Taught songs" group with the list and a swipe to
  forget.
- The known gap: "Tower of Roses" by MALI must match from its preview.

Tests: store a synthetic tone sequence, query a noisy copy, match; query an
unrelated clip, no match. Claude proves it on the Pi with the MALI single.

### 9. Ask the wall

What: a spoken question, answered by Claude, shown as words on the panel.

Behaviour:
- Endpoint `POST /ask {"text": "...", "reply": "wall" | "text"}` returns
  `{"answer": "...", "shown": true}` within 6 s. The answer is shown in a
  new face `answer`: lines of 2x text at 64 (about 10 characters a line, up
  to 6 lines, paged every 3 s when longer), 3x text at 192 with 20
  characters a line and 12 lines. The answer face returns to the previous
  face after the last page plus 4 s, or on any control change.
- Claude: the Python SDK, model `claude-opus-5`, adaptive thinking, a system
  prompt that says the answer is read on a 64 pixel LED panel and must fit
  the line budget, plain words, no markdown, no lists unless asked. Tools:
  `wall_state` (mode, now showing, progress, hearing state), `journal`
  (what played, when), `set_face` (a mode change), `set_brightness`,
  `timer` (minutes). The API key is a services field `claude.api_key` set
  from the phone (a new "Claude" page under Services), never in config.
  Cost logged per answer.
- Siri Shortcut path: a Shortcut named "Ask the wall" that dictates,
  POSTs to `/ask` with `reply: "text"`, and speaks the answer. Ship it as a
  `.shortcut` file plus instructions in `docs/ASK.md`.
- Ears path: after item 10 the wake word routes speech here when it is not a
  known command.
- Errors: no key -> the face shows "no key yet" once and the phone page
  explains; network down -> "no answer right now"; refusal or empty -> a
  short apology line. All logged with `[ask]`.

Tests: line wrapping and paging at both sizes; tool dispatch with a fake
client; the Shortcut's request shape.

### 10. The wall's own ears (wake word and speech)

What: "hey wall" followed by a sentence, understood on the Pi.

Behaviour:
- Wake word: openWakeWord with a custom model for "hey wall" trained from
  synthetic speech (the trainer notebook or `openwakeword-trainer`), plus
  the pretrained "hey jarvis" as a fallback until the custom model is in
  hand. Runs on the ear's 16 kHz stream continuously (the model is small).
  Threshold knob `wake_threshold`, default 0.5; `wake_word` knob to switch
  models.
- On wake: the Horizon face (item 5) comes up, the wall records until 0.8 s
  of silence or 8 s, then whisper.cpp (`tiny` by default, `base` as a knob)
  transcribes on the Pi. Latency budget: wake to face under 300 ms; end of
  speech to text under 3 s.
- Commands, matched locally by fuzzy phrase before anything goes to the
  network: off, on, art, disc, ambient, clock, lyrics, nine, video off,
  brighter, dimmer, louder/quieter are aliases for brighter/dimmer, "what is
  this" (the song's name across the panel), "timer N minutes", "listen"
  (force an ear ask), "teach this, it is X by Y" (item 8 by voice).
  Everything else goes to item 9.
- Feedback: the Horizon face's states (listening, thinking, answered, did
  not catch that). Nothing audible, there is no speaker.
- Knobs on the Hearing page: `wake`, `wake_threshold`, `speech_model`.
- Privacy: audio after the wake word lives in memory only, for the length
  of the request.

Tests: command matcher with misspellings from a real transcriber; a
recorded "hey wall" clip through the wake model on the Pi.

### 5. The listening face, Horizon

What: the face the wall shows while it listens to a person. Only on the
wake word, never as an idle face.

Design (the mock in the chat, kept here in words):
- On wake, the picture that is up collapses to a one pixel line across the
  middle in the ink of the last sleeve (the brightest saturated colour in
  it), in 250 ms, the way a CRT switches off. At 192 the line is 3 px.
- While listening, the line's brightness follows the voice level with a
  fast attack and a 400 ms release, and its ends fray by a pixel or two
  with the louder syllables.
- While thinking, a bright bead 6 px long (18 at 192) travels the line
  left to right every 1.2 s.
- On an answer, the line opens vertically into the answer face over 400 ms.
  On a command, it opens into the new face. On "did not catch that", the
  line goes dashed for 800 ms and closes to black, then the old face returns.
- All timings are constants at the top of the face's module.

Tests: frame sequences at both sizes rendered to PNG strips.

### 11. Leave a note

What: "Hey Siri, tell the wall back at six" puts the words on the panel.

Behaviour: a Shortcut that dictates and POSTs `/state {"mode": "ticker",
"ticker_text": ..., "ticker_loop": false, "ticker_style": "across"}`. Plus a
`POST /note {"text", "minutes"}` that shows the note in the ticker style
for `minutes` (default 30) and returns to the previous face. Documented in
`docs/ASK.md` with the Ask shortcut.

### 12. AirPlay to the wall

What: the wall is an AirPlay 2 receiver named "Wall". Adding it to any
AirPlay group hands the wall the exact title, artist, art and progress of
whatever an Apple device plays.

Behaviour:
- shairport-sync built with AirPlay 2 support and nqptp on the Pi
  (document the exact build), output `-o stdout` discarded or to a USB DAC
  when `[airplay] output = "alsa"` is set; metadata pipe on; the brain's new
  source `brain/nowplaying/airplay.py` reads the metadata pipe (title,
  artist, album, artwork bytes, progress, play state) and answers as a
  NowPlaying with `track_id = "airplay:" + hash`. Artwork bytes are cached
  to a temp file and served as an `art_url` on the control port
  (`GET /art/airplay.jpg`).
- Order: `airplay` goes before `ears` and after `phone` in the chain.
- Status in `/services`: `airplay: {name, running, connected_from, last}`.
- If the owner has an AirPlay speaker, document grouping; the wall does not
  need to make sound.

Tests: a recorded metadata pipe stream parsed into NowPlaying answers.

### 13. The shelf

What: the owner's Discogs collection, known to the wall.

Behaviour:
- Fields: `discogs.token` (personal access token) and `discogs.user`, set
  from a new Discogs page under Services. Sync on set and every 6 hours:
  every release in folder 0, with title, artists, year, labels, formats,
  catalogue numbers, cover, and the owner's rating, stored in
  `~/.config/album-art-matrix/shelf.json`.
- Match: a playing song's album and artist matched to the shelf by
  normalised title and artist (strip brackets, feat., case, punctuation),
  then by MusicBrainz release group when Discogs provides an mbid. A match
  means "you own this on vinyl".
- Wall: a corner mark on the sleeve for streamed songs the owner owns on
  vinyl: a 5x5 disc glyph at 64 (bottom right, 2 px inset), 11x11 at 192,
  in the sleeve's ink, drawn by the pipeline as an overlay so every face
  that shows the sleeve gets it. Knob `shelf_mark` on the phone to turn it
  off.
- Phone: when a record plays (the ear or AirPlay), the room screen shows
  the pressing: year, label, country, catalogue number, and the lowest
  price on the Discogs marketplace (`/marketplace/stats/{release_id}`), with
  a link to the release. A Shelf page lists the collection with the count
  played per release from the journal.
- Rate limits: Discogs allows 60 requests a minute with a token; the sync
  paces itself and resumes after a restart.

Tests: matcher against a fixture of 40 releases with tricky titles.

### 14. Earworm finder

What: say the words you remember; the wall names the song and shows it.

Behaviour: `POST /earworm {"text"}` sends the words to Claude with the
instruction to return JSON `{title, artist, confidence, alternatives[]}`
(structured output); the top answer is looked up on iTunes for art and
shown in the `frame` face as the sleeve with the title and artist crawling
under it for 8 s; alternatives go back to the phone. Voice path through
item 10 ("what song goes ..."). Below confidence 0.4 the wall shows two
sleeves side by side at 192, or alternates them at 64, and the phone asks
which.

### 15. Show me, play me

What: "show the Blond cover" and "play the Gameboy video" by voice or from
the phone.

Behaviour: `POST /show {"query"}` searches iTunes (album, then song) and
puts the sleeve in the frame face for 10 minutes or until a control change;
`POST /play {"query"}` searches YouTube (through the existing resolver,
`yt-dlp` `ytsearch1:` as the fallback) and starts the video face with the
phone as speaker as today. Both are commands in item 10's matcher. The
phone gets a search field on the wall screen that does the same.

### 16. Image creator by description

What: "create a purple elephant" draws one on the panel.

Behaviour:
- `POST /imagine {"prompt"}`: the prompt is expanded by Claude into an image
  prompt suited to a 64 or 192 pixel LED panel (bold shapes, high contrast,
  no fine text, centred subject, plain background), then sent to an image
  model. Choose the model with a services field `images.provider` and
  `images.api_key`: support OpenAI `gpt-image-1` and Google Imagen through
  their REST APIs (both documented in code), default OpenAI. The result is
  downscaled through the pipeline (Lanczos, unsharp) at the wall size and
  shown in the frame face; kept in `~/.config/album-art-matrix/imagined/`
  with the prompt, listed by `GET /imagine`, re-shown by `POST /imagine/show
  {id}`.
- Phone: an Imagine page with the prompt field, the gallery, and re-show.
- Voice: "create ..." and "draw ..." in item 10.
- Cost and rate: one image per 10 s at most, cost logged.

### 17. Weather faces

What: a weather display with faces that change with the weather.

Behaviour:
- Source: Open-Meteo (no key), for the location the phone sets (`lat`,
  `lon` already exist in control state; a Weather page adds a place search
  through Open-Meteo geocoding). Refresh every 10 minutes, cached, shown
  stale with a small mark after an hour without an update.
- Mode `weather`. The face: the temperature in 2x digits (4x at 192) and a
  scene that IS the weather, drawn, not iconified: clear day is a sun with a
  slow arc across the top; clear night a moon with the real phase; clouds
  drift; rain falls with density from the precipitation rate; snow falls
  and settles on the bottom edge; fog dims the whole face; wind bends the
  rain and moves the clouds faster; thunder flashes on the real forecast.
  Colours from a palette per condition, restrained.
- At 192: adds today's high and low, the next six hours as a row of small
  scenes, and sunrise and sunset ticks.
- Every WMO weather code maps to a scene; the mapping is a table in the
  module with the scene name per code.
- Idle option: `weather` joins `IDLES` so the wall can rest on the weather
  in silence.

Tests: the code table covers all WMO codes; frames at both sizes for eight
conditions rendered to PNG.

### 18. Posters for what you watch

What: when the Mac plays an episode or a film, the wall shows its poster.

Behaviour: the Mac reporter's browser and app answers with a show title
(and no artist or album) are looked up on The Movie Database
(`tmdb.api_key` services field): TV first by name, then films; the poster
becomes the `art_url`, the answer counts as playing with art, and the
journal marks it `kind: "show"`. Cached per title for 30 days. When nothing
matches, the answer stays sleeveless as today. Phone: the TMDB field on the
Mac page under Services.

### The games, 19 to 35

Shared shell, built first:
- `brain/games/` package with `Game` base class: `state` (JSON), `apply(move,
  player)`, `frame_at(size, t)`, `phone_view()`; a `GameHost` in the brain
  that owns one running game, mode `game`, `GET /game`, `POST /game/start
  {"name", "options"}`, `POST /game/move {"player", "move"}`, `POST /game/end`,
  `GET /game/list`. State changes bump a sequence so phones poll cheaply.
- Players: names from the phones (`player` field, remembered on the wall),
  a scoreboard face shared by all games, streaks in
  `~/.config/album-art-matrix/games.json`.
- Voice: when the app is open, the phone's `SFSpeechRecognizer` with
  `contextualStrings` set to the game's valid words; the phone posts the
  move. Otherwise item 10's ears post it. A move by voice is confirmed on
  the wall within a second.
- Phone: a Games page listing the games, each with its own screen that
  shows the same board as the wall, touch input where it makes sense, and
  the scoreboard.
- Puzzles are our own: generators for Wordle (a curated answer list plus a
  larger guess list), Sudoku (generator plus unique-solution check and a
  difficulty rating), Spelling Bee (seven letters with at least one
  pangram from a word list), Letter Boxed (twelve letters with a known
  solution), Strands (a filled grid from a themed word set), the mini
  crossword (a 5x5 fill from a word list, clues by Claude), Contexto (a
  secret word and a rank from a local 50-dimension word vector file); Claude
  writes Connections sets (four groups of four with a theme each and a
  difficulty order) and pub quiz rounds; Heardle uses iTunes previews
  (30 s clips) chosen from the journal or the shelf; the sliding puzzle and
  cover reveal use sleeves from the journal or the shelf.
- Each game states its board at 64 and at 192, its input methods, its win
  and lose states, and its scoring. Cover reveal: the sleeve is shown as
  4x4 blocks and refines every 3 s to 8, 16, 32, 64. Twenty questions:
  Claude asks, the panel shows the question in 2x text, knock = yes,
  whistle = no, phone buttons as well. AI pictionary: item 16 draws at three
  detail levels. Whistle bird: pitch to height, obstacles, score. Reaction
  knock: red, random 2 to 6 s, green, the knock's latency in ms in 2x
  digits, best per player. The arcade: pong (phones' tilt over `/game/move`
  at 20 Hz), snake and tetris on the Control Centre remote's keys through
  the HomeKit television's `RemoteKey` (route them to the game host when a
  game is up).

---

## 5. What the owner supplies

Asked once, entered on the phone, never in code:

| For | What | Where it goes |
| --- | --- | --- |
| 6 | ListenBrainz user token | Services > ListenBrainz |
| 9, 14, 16, games | Anthropic API key | Services > Claude |
| 13 | Discogs token and username | Services > Discogs |
| 16 | Image provider key | Services > Images |
| 17 | The wall's location | Weather page |
| 18 | TMDB key | Services > Mac |
| 12 | How the speakers are wired | a sentence in chat |
| 7 | Five minutes of knocking on the frame | a test in chat |

---

## 6. Working apart

Two builders, one wall, one phone. Nothing either does may collide with the
other, and the owner tests each on its own.

- Git: Claude works on the branch `claude/build`; Codex works on `codex/build`. `main` stays as it was until the
  owner picks. Both branches start from the same `main`.
- The Pi: `~/album-art-matrix` is a symlink. `~/wall-claude` and
  `~/wall-codex` are two complete trees, each with its own venv and
  `config.toml`. `pi/switch.sh claude` or `pi/switch.sh codex` re-points the
  link and restarts the brain in a few seconds; a bare `pi/switch.sh` says
  which is live. Settings, the journal, services and the HomeKit pairing are
  shared in `~/.config/album-art-matrix`, so a token entered once serves
  both and the wall keeps its place in the Home app. Deploys land in the
  live tree: check first.
- The phone: `tessera/Tools/install.sh claude` installs the app as
  "Tessera"; `install.sh codex` installs "Tessera Codex" with its own bundle
  id, so both live on the phone at once with their own settings.
- Features: `[features]` in `config.toml` has a switch per feature, read at
  the moment the feature would act (`brain/features.py`, `GET /features`).
  Every new feature checks its switch. The owner turns one on at a time.
- Shared state files get a name per feature under
  `~/.config/album-art-matrix/` (`scrobbles.jsonl`, `shelf.json`,
  `games.json`, `olaf/`), never a generic name, so two builds writing the
  same file is a deliberate choice, not an accident.

## 7. How to deliver

For each feature, in order:

1. A one-paragraph plan naming the files.
2. The files, complete. Changed files as full contents or as unified diffs
   against the current repository.
3. The tests and their output.
4. The two renders (64 and 192) for anything visual.
5. The README row, the ROADMAP state, the config example, the API
   docstring.
6. A deploy note: which files go to the Pi, what to install, what to
   restart, what the owner does on the phone.
7. What was assumed, and what was left out and why.

Both builders run the tests and the preview renders in their own checkout.
Claude deploys to `~/wall-claude` on the Pi and installs "Tessera" on the
phone. Codex, on `codex/build`, deploys to `~/wall-codex` and installs
"Tessera Codex" when it has the `wall` ssh alias and the phone; when it does
not, it says exactly which steps it could not run and leaves the commands
ready. Neither touches the other's tree, branch or app. Both stop and ask only when a
decision would change the work materially; otherwise they decide, say so,
and continue.
