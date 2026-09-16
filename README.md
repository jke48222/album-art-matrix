# Album Art Matrix

A design for an LED wall that shows the cover of whatever song is playing, rendered as a slowly
spinning disc. Nine square LED panels tiled three by three, 480 mm on a side, driven by a Raspberry
Pi 5.

**No hardware has been driven yet.** Not nine panels, not one. This repository is the design, the
circuit simulation, and the software that will run on it. Some of the first light parts have since
been ordered; no panel has arrived. The section below is exact about what exists.

## Building it

[docs/ASSEMBLY.md](docs/ASSEMBLY.md) is the current guide: nine panels are
lit and mapped, and it takes them from the floor to a hung wall. The design
being built is in [design/](design/), the parts and prices at the end of
[PARTS.md](PARTS.md), and [docs/WALL-BUILD.md](docs/WALL-BUILD.md) is the
record of how the wiring was arrived at.

## Status

| Piece | State |
| --- | --- |
| Circuit simulation (`pcb/sims/`) | Done and reproducible. Eight ngspice decks, verified to regenerate their committed outputs bit for bit. |
| Backplane circuit (`pcb/circuit.py`) | Done as a netlist and BOM. 76 components, 105 nets, 345 pin connections. |
| PCB layout (`pcb/backplane.kicad_pcb`) | Routed. 20 design rule check runs are committed as `pcb/drc1.json` through `drc20.json`, and reading them in order is the honest record of the layout. The last run has **no rule violations and no unrouted signal**. What it still reports is 7 ground pour islands: the GND zone fragmented into pieces that no via stitches together, on a board whose entire power argument rests on a continuous return path. Its 107 warnings are 26 silkscreen clearances and, for the rest, KiCad noting that the vendored `pcb/footprints/` are not installed as a system library. |
| Fab outputs (`pcb/fab/`) | Gerbers, drill, pick and place, and board views are exported. **Stitch the ground islands before ordering.** |
| Art pipeline (`brain/art/`) | Built, runs on a laptop, has an offline test. |
| Wall control API (`brain/control.py`) | Built, 335 lines. Serves mode, brightness, spin rate, ambient settings, finishes, ticker and clock text, a sleep fade, a journal with replay, and raw frame and clip pushes on port 8788. Has run on the real Pi and answered the apps over the network; has never had a panel behind it. |
| Display modes (`brain/art/disc.py`, `effects.py`, `text_modes.py`) | Built. Spinning disc, eight ambient light effects (solid, breathe, pulse, rainbow, gradient, plaid, weave, deco), clock and ticker over a generated pixel font, plus pushed frames and clips. All verified as PNGs, none on an LED. |
| iOS companion, first app (`ios-companion/`) | Built, 4,406 lines of Swift. Reads the on device now playing state and pushes it to the reporter, and remote controls the wall. Runs on device. **The simulator cannot exercise it**, because MediaPlayer is stubbed there. Superseded by Tessera for daily use; still installs and works. |
| Tessera (`tessera/`) | The current iOS app. Three designs of the same room (a panel, an iPod with a click wheel, and a rendered room with a record player whose arm follows the song), Studio (draw, photo, words, video on one 64x64 canvas), Archive, Settings with every service set up from the phone, widgets and a Live Activity, an offline outbox, and a stand-in wall the phone runs when no hardware answers. The room's renders come from `tessera/Tools/room/room.py` (Blender, headless). The logo is the Record mark (`RecordMark.swift` and the icon) and the opening is its sting (`StingOpening.swift`: on black, or keyed over the room's light and then the room glitches in from coarse pixels; films `record-sting.mp4` and `record-sting-alpha.mov`, made by `Tools/record_sting.py` and a Higgsfield pass, see `Design/Logos/record/final/README.md`). The Room design is the default. Verified in the simulator against a local brain and installed on a phone; never against a panel. |
| Web app (`web/`) | Built and runs (TanStack Start + React). The whole pipeline reimplemented in TypeScript (Lanczos-3, Pillow-semantics unsharp, gamma 2.2, WB in linear light), plus a seven-source now-playing chain, an LED wall simulator, history, WB profiles, a wiring calculator, and push-to-wall. Verified live against `scripts/mac_reporter.py`; the brain push matches `brain/control.py`'s contract but has not been fired at the real Pi yet. |
| Panel intake QA (`scripts/panel_qa.py`) | Test pattern generator and procedure written, 271 reference frames rendered in `qa_preview/`. `qa/QA-SHEET.md` is an **empty template**. No panel has been through it. |
| Now playing, Apple Music (`brain/nowplaying/applemusic.py`, `applemusic_account.py`, `pushed.py`) | Built. On the Mac: the phone's push, then Music.app, then anything else the Mac plays (next row), then the account view through the MusicKit helper. On the Pi: the phone's push and the account view straight from MusicKit. The phone push and the Mac path have both answered live. |
| Now playing, anything the Mac plays (`brain/nowplaying/macmedia.py`) | Built. Reads macOS's own Now Playing through `media-control`, so Spotify's app, TIDAL, or a browser tab on YouTube Music, SoundCloud or Amazon Music reach the wall with their own artwork, which the reporter serves to the Pi. Verified live on this Mac: a YouTube Music tab reached the reporter with its title, progress and thumbnail, and the brain rendered it. |
| Now playing, Spotify (`brain/nowplaying/spotify.py`) | Built. The app id is pasted in Tessera and handed to the wall, the PKCE sign-in runs on the phone (`tessera://spotify`), and the wall polls from then on. Under the February 2026 rules the app id needs a Premium account, one client ID per developer and five users. **Not linked yet.** |
| Now playing, Last.fm and ListenBrainz (`lastfm.py`, `listenbrainz.py`) | Built. Last.fm needs an API key and a username; ListenBrainz needs only a username. Both are typed in Tessera and kept on the wall. Spotify, Tidal and Deezer report to Last.fm on their own; a browser scrobbler covers YouTube Music, SoundCloud and Amazon Music on a computer. **No account entered yet**, so neither has answered live. |
| Now playing, the wall's ears (`brain/nowplaying/ears.py`) | Built and proven on the Pi 2026-09-14: the USB microphone is read continuously, and when the room is louder than a gate the last few seconds are named through Shazam (shazamio; no key, but an unofficial client that Apple could break). Two six-second clips of quiet music matched in about two seconds each. AcoustID, the first attempt, was removed: it identifies whole files, not a room. Tessera's ears page shows the room's level live with the gate as a mark to drag, what was heard and where in the song, and the Hearing knobs. Handling for a noisy room (a longer clip after each miss, a named song kept through misses, a match with no catalogue record heard twice before it goes up) is built but not yet measured against a TV. |
| HomeKit (`brain/homekit.py`) | Built and running on the Pi 2026-09-15, not yet paired. One bridge: a light (on, off, brightness, a colour for the ambient face), a television (the faces as inputs, the Control Centre remote's keys), an occupancy sensor (sound in the room) and a motion sensor (music on the wall). The wall draws its pairing QR on the panel while unpaired; `GET /homekit` has the code as text. Siri, the Watch and scenes need nothing else; automations and a HomePod need a home hub. |
| Vinyl scrobbling (`brain/scrobble.py`) | Built 2026-09-15, running on the Pi, waiting for the ListenBrainz user token from the phone's ListenBrainz page. Every record the ear names is posted as playing-now, then as a listen after half the song or four minutes; held-through-noise and heard-again-within-the-song count once; listens the network refused wait in `scrobbles.jsonl` and go later in batches. Fifteen offline tests in `brain/tests/test_scrobble.py`. |
| Knock twice (`brain/nowplaying/knock.py`) | Built 2026-09-15, on the Pi, waiting for a session of real knocks to set the numbers. Two knocks on the frame, alone, toggle the wall between off and the face it had; a whistle bending up or down does the same for a frame that does not carry a knock. Both run on the ear's own chunks, log every candidate with its numbers, and are Hearing knobs on the phone. Fourteen offline tests. |
| Teach the wall a song (`brain/nowplaying/teach.py`) | Built 2026-09-15, on the Pi. The wall's own landmark fingerprint library (numpy, the Shazam idea; Olaf needs Zig, which the Pi's Debian lacks), asked before Shazam. It learns a song's iTunes preview when another source names it and the ear keeps missing it, learns the room's own hearing of a song after fifteen loud seconds, and learns by name through `POST /teach/learn`. Three Hearing knobs, a Taught songs group on the phone, nine offline tests including a clip heard through a room. |
| The wall's own ears, the voice (`brain/voice/`, `docs/VOICE.md`) | Built 2026-09-15. A wake word on the ear's stream, chosen on the phone from openWakeWord's Hey Jarvis, Hey Mycroft, Hey Marvin and Alexa, or a phrase of your own taught by saying it to the wall six times (matched on the same speech embeddings with the room's sound taken out; measured on synthetic voices, it heard 97% of new voices in an echoing room with no false wakes in 3.6 minutes of talk). Each word keeps its own sensitivity, with a live meter on the Voice page. Then the Horizon face while it listens, speech to text on the Pi (faster-whisper tiny, about a second and a half a sentence), a grammar of commands done with no cloud, and Claude for the rest. `GET /voice`, `GET /voice/meter`, `POST /voice/wakeword`, `POST /voice/enroll`, `POST /voice/wake` and `POST /voice/say` for testing without a microphone. |
| Ask the wall (`brain/ask.py`) | Built 2026-09-15, waiting for the Claude key from the phone's Services page. A question by voice or `POST /ask` goes to Claude Opus 5 with the wall's own tools (what is playing, the journal, the face, brightness, a timer) and comes back as words on the panel, paged, 1x at 64 and 2x at 192. A Siri Shortcut recipe is in `docs/ASK.md`. |
| Leave a note (`POST /note`, `docs/ASK.md`) | Built 2026-09-15. "Hey Siri, tell the wall back at six" runs the words across the panel for a while, then the wall goes back to what it was doing. Also a voice command. |
| Show me, play me, the earworm finder (`brain/show.py`) | Built 2026-09-15. A cover by name from iTunes into the frame face, a video by name through yt-dlp into the video face, and a song from the words remembered through Claude, with its sleeve. By voice or `POST /show`, `/play`, `/earworm`. |
| Weather faces (`brain/weather.py`, `brain/art/weather.py`) | Built 2026-09-15 and redrawn the same day at full fidelity, proven on the Pi with the real forecast for the room's place. A face that is the weather: a sky the colour of the hour (blue at noon, warm at the horizon at dawn and dusk, deep at night with stars that twinkle), rolling hills in silhouette, a sun with a halo and slow rays on its real arc, the moon with tonight's phase and its seas, clouds as stacked puffs with lit tops and shaded bases in two layers that drift, rain that leans with the wind and splashes on the ground, drizzle finer, showers that come and go, snow in two sizes banking up on the hills, fog as soft banks of haze drifting through, thunder with a forked bolt and a flash that fades; the temperature outlined so it reads over anything, at 192 the high and low, the next six hours and sunrise and sunset ticks where the arc meets the hills. Everything still for the hour is drawn once and kept. Every WMO code has a scene. Open-Meteo, no key; a place named once on the phone's Weather page, which is a card now: the wall's live frame, the temperature large, the sky in words, the day's range, feels, wind, sunrise, sunset and the next six hours. Seven tests. |
| The shelf (`brain/shelf.py`, `brain/art/mark.py`) | Built 2026-09-15, on the Pi, waiting for a Discogs token and username (Services > Discogs). The wall reads the collection's main folder every six hours, paced under Discogs's limit, and keeps it in `shelf.json`. A song from an album on the shelf gets a small record in the sleeve's corner, 5 px at 64 and 11 px at 192, dark on a light corner and light on a dark one, on every face that shows the sleeve; the Shelf knob turns it off. The pressing (year, label, catalogue number, country, the lowest price copies are going for) goes to the phone as `owned` and shows under the song; the price is fetched on a worker and cached a day. The Discogs page lists the shelf with plays per release from the journal. Matching folds case, accents, brackets, feat., Discogs's (2) and Deluxe tails, takes near titles (Blonde, Blond) and any listed artist, and prefers the vinyl. Seven tests over forty tricky releases. |
| Posters (`brain/posters.py`) | Built 2026-09-15, on the Pi, waiting for a TMDB key (Services > Posters) and for the Mac's reporter to be restarted from this tree. A show or a film in a browser on the Mac used to be dropped by the reporter (a browser icon is not a sleeve); now its name rides on the empty answer as an `X-Mac-Show` header, a brain that does not know about shows sees nothing new, and this brain looks the name up on The Movie Database, television first, then films. The poster is the sleeve, cut square from a little above the middle rather than squashed (`brain/art/pipeline.py` `square`, which now guards every non-square picture), the answer is playing with art, the journal marks it `kind: show`. Hits kept a month, misses a day, in `posters.json`. Six tests. |
| Imagine (`brain/imagine.py`) | Built 2026-09-15, drawing on the Pi with his OpenAI key. "Create a purple elephant", by voice or from the Imagine page: Claude rewrites the words as a prompt for one large, lit, textured, believable subject with no text; the newest OpenAI image model the key can reach draws it (gpt-image-2, then 1.5, then 1, with a fallback on a missing model) at medium quality to start (a good picture in well under a minute: 54 s for a lighthouse on gpt-image-2; high is the most detailed and takes minutes), or Google's Imagen Ultra. OpenAI streams three partial images and the wall shows the picture being drawn: the moment the words arrive it goes into its imagine face, a soft band of light sweeps across while the model thinks, each partial crossfades in as it lands, a line at the foot counts them, and the finished picture is held for ten minutes. Every image is brought to the wall's size in linear light with a gentle stretch. Kept at full size with its words in `imagined/`; `GET /imagine` lists them with the live state, `GET /imagine/<id>.png` serves one, `POST /imagine/show` puts one back with a quick reveal. AI pictionary shows its sketch forming the same way. The Imagine page shows the drawing live; Services > Images chooses the drawer and the quality. Ten tests. |
| AirPlay to the wall (`brain/nowplaying/airplay.py`, `brain/nowplaying/receiver.py`, `docs/AIRPLAY.md`) | Done 2026-09-15. The wall is an AirPlay speaker called Wall. `pi/install-airplay.sh` unpacks Debian's shairport-sync, a classic AirPlay build, so there is no nqptp and no root; the brain runs it with a config of its own, starts it again when it stops, restarts it when the phone renames it, and stops it with itself. A reader on its metadata pipe takes the title, artist, album, length, artwork, position, pause, resume, end and the sender, and answers right after the phone in the chain; a song that comes without artwork gets its sleeve by name. On the phone: whether it is receiving and from what, a switch, and the name. Proven on the Pi with an Apple device playing to it. Grouping with HomePods in the Home app needs AirPlay 2, which needs sudo. |
| Games shell and Wordle (`brain/games/`) | Built 2026-09-15 and played on the Pi over HTTP and by a spoken guess. One game at a time, held by the GameHost: mode `game`, the wall the board and the phone the hand; `GET /game/list`, `GET /game`, `POST /game/start`, `/game/move`, `/game/hear`, `/game/end`; every change bumps a sequence the phone polls; played, won, streak and best per player per game in `games.json`; a scoreboard face between games. Words heard by the wall's ears go to the running game before the command grammar. `brain/games/board.py` draws the same board at 64 and 192 from one description (tiles, grids, the 5x7 font at 1x and 3x). Word lists built from a public frequency list through the system dictionary: 30,000 common words, 2,400 five-letter answers, 8,500 valid guesses. Wordle: six guesses, the repeated-letter rule, a refused non-word does not count, the keyboard state for the phone, up to four players taking turns. Four tests. The phone's Games screen is next. |
| Sudoku, Spelling Bee, Letter Boxed, Connections (`brain/games/`) | Built 2026-09-15, each shown on the Pi. Sudoku: a full grid by randomised backtracking, digits removed while a counting solver still finds one solution, rated by the guesses that solver needs; easy, medium or hard; touch on the phone or "row three column four is seven"; wrong digits red. Spelling Bee: a hive from a common seven-letter pangram, the centre chosen to keep the most words, ranks from Beginner to Genius, Queen Bee for every word. Letter Boxed: two chaining common words that use twelve distinct letters and lay out on four sides with no two in a row from one side, kept as the par; the wall draws every word's lines. Connections: Claude writes a set (structured output) or one of eight bundled sets, yellow to purple, one away, four mistakes; say four words or tap four tiles. Fourteen tests. |
| Strands, mini crossword, Contexto, sliding puzzle, cover reveal, reaction knock, whistle bird (`brain/games/`) | Built 2026-09-15, each shown on the Pi. Strands: a themed set from Claude (structured output, forty-eight letters checked) or six bundled, threaded through the 6x8 grid by cutting a random whole-grid path (backbite moves on a serpentine) into the words, the spangram made to touch two sides; extras earn hints. Mini crossword: symmetric patterns filled from the common words most-constrained-slot first, Claude clues or a hand-clued puzzle, entered by voice ("one across is lamp") or a letter at a time, a check that marks wrongs red. Contexto: ranks by cosine on twenty thousand GloVe vectors cut to a 1.9 MB file, green under 300, the rank in big digits with a log bar. Sliding puzzle and cover reveal on a sleeve from the journal: a scramble by legal slides, blocks tapped or "up, down, left, right"; a Gaussian blur that sharpens over thirty seconds, first to name the album or artist. Reaction knock: red, green, the milliseconds on the panel, timed on the ear's own clock, false starts caught, phone taps allowed. Whistle bird: the ear's pitch, the whistler's range learnt in the first notes, pipes, a score. The ear now hands every lone knock, double, whistle and pitch to the running game first, so nothing switches the wall off mid-game. Twenty-three tests. |
| Heardle, pub quiz, twenty questions, AI pictionary, the arcade (`brain/games/`) | Built 2026-09-15. Heardle: a journal song with an iTunes preview the phone plays for one, two, four, seven, eleven, sixteen seconds as guesses miss or skip; the wall's six bars and a needle; the sleeve on the reveal. Pub quiz: a Claude round (structured output) or two bundled, twenty seconds a question, one answer per player, folded matching against every acceptable answer, scores on the wall. Twenty questions: Claude asks from the whole history and guesses when sure; a knock is yes, a whistle no; twenty and you win. AI pictionary: the image drawer draws a secret word from a list of drawable things with no text, sixty seconds to name it. The arcade: Pong (phones as paddles, the wall plays the other side alone, first to seven), Snake (a 32-cell grid, the phone the remote, or say the direction) and Tetris (a seven-piece bag, wall kicks, a ghost, levels). Eleven tests; the arcade shown on the Pi. |
| The Games sheet on the phone (`tessera/Tessera/Games.swift`, `GamesBoards.swift`, `GamesPlay.swift`) | Built 2026-09-15 and installed. A Games tile among the faces opens a sheet: the games the wall knows, your name for the scoreboard, the one that is on, its scores. Every game has its own screen polling the wall once a second and redrawing on its sequence: Wordle's rows and keyboard, Sudoku's grid and digit pad, Connections' tiles, the Spelling Bee hive, the Letter Boxed square, Strands traced by a finger, the mini crossword with its clues, Contexto's ranked list, Heardle playing the clip for the seconds allowed, the sliding blocks tapped over the wall's own frame, the reaction button, the whistle bird's slider, twenty questions' yes and no, the quiz card, pictionary's clock, Pong on the phone's tilt, Snake and Tetris on a remote and swipes. Words are typed or spoken to the phone's own recogniser, primed with the game's words. The state comes as JSON any game can shape. |
| The boards' design (`brain/games/board.py`, `scripts/render_games.py`) | Redrawn 2026-09-15 on one kit: a restrained palette, tiles with a lit top edge and a shaded bottom at 192 and their corners off at both sizes, hexagons, thick lines and arcs, soft glows, easing, a header band with a coloured mark at 192, a banner for the end of a game, a scoreboard with bars. Wordle's rows flip in a tile at a time, Connections shakes on a miss, Contexto pops its rank in, the quiz counts down on a ring, the reaction field breathes, the whistle bird flaps under stars, Pong's ball leaves a trail, Tetris has bevels, a ghost and a next piece. `scripts/render_games.py` draws every board at both sizes as one contact sheet. The phone's Games sheet has a hero card with the wall's live frame, a motif for every game in its colour, the scores as bars, and a live strip of the wall over each board. |
| Every feature in its place (`tessera/Tessera/Features.swift`, `brain/homekit.py`, `brain/art/horizon.py`, `brain/art/answer.py`) | 2026-09-15. Settings has a "What the wall can do" list: Ask the wall (a question typed, the answer on the panel or here, the last dozen), Notes (words on the panel for a set time, with what is up now), Show me (a cover or a video by name), Earworm (the words you remember, the sleeve with the name along its foot), Imagine, Weather, Games, Voice (the wake word and speech, listen now, say it from here, the last heard), HomeKit (pairing, the setup code on the panel, the remote's inputs), The shelf (the records as covers, most played first), Teach the wall (a song by name, the library). The HomeKit remote has every face as an input, the weather, the games and the last picture drawn among them; its arrows and select play a game that is on, back puts it down, play and pause switch the wall off and on. The listening line ripples along its length with the voice and glows under it; the thinking bead trails light; answers type themselves out with a cursor. An organisation-level Claude key now works: the wall sends the workspace id set beside it. |
| Service settings from the phone (`brain/services.py`, `tessera/Tessera/Services.swift`) | Built and exercised against a brain on the Mac: every key and username above is set from Tessera's Services pages, kept in `services.json` on the wall, and applied to the running adapters without a restart. No config file is edited by hand once the wall is deployed. |
| Video on the wall (`brain/video/`, `tessera/Tessera/Video.swift`, `VIDEO.md`) | Built and exercised on the Pi 2026-09-06. A YouTube link (or any link ffmpeg reads) pasted in Tessera's Video face: the wall resolves it the way the YouTube iPhone app does, streams the 144p picture through ffmpeg to 64 px at 15 fps (a third of a second of CPU per twenty seconds of video, about 26 MB of frames), and downloads the sound in ranged pieces for the phone to play; the phone's player is the clock. First frame in about a second, sound ready in under two. No new binaries on the Pi. Share-sheet target (`tessera/TesseraShare/`): from YouTube, Safari or Photos, Share, then Tessera; a library video is sent up as a small H.264 picture (`POST /video/upload`) and the phone plays its own sound. Videos behind YouTube's signed-in token (big label releases) stop after the first megabyte from every client identity the wall asks; those fall through to **yt-dlp** (`brain/video/ytdlp.py`, installed by `pi/install-ytdlp.sh`), which fetches them itself into the RAM disk. Verified on the Mac 2026-09-06: the refused video plays, ready in 7.3 s against 1.8 s for the fast path. No JavaScript runtime installed; not needed by the client yt-dlp uses. |
| Renderer (`renderer/art_display.c`) | 202 lines of C. Compiled and run on the Pi 5; frames flow through the FIFO and the map-rate cap. It has never had a panel on the other side. |
| Pi provisioning (`pi/`) | Executed on the real Pi: bootstrap, venv, renderer build, systemd units for brain and renderer. The wall boots headless and answers the network. |
| Parts | **Panels arrived**: ten Waveshare P2.5 64x64, driver confirmed FM6124HJ (conventional, no init sequence needed). Pi 5, card, cooler and sundries on hand. First light is blocked on the HUB75 bonnet and 5V supplies still on order. `PARTS-TRACKER.xlsx` carries prices actually paid; `PARTS.md` remains the list. |
| White balance gains | Placeholders. `config.example.toml` labels the current values "a GUESS" pending measurement. |

Everything above is design, simulation, and software. Nothing in this repository has met a panel,
and that is the only claim that matters until it changes.

## What problem this solves

Music has a cover, and almost nobody looks at it any more. It lives in a thumbnail the size of a
postage stamp, at the corner of a phone that is in a pocket. The cover is the one piece of visual art
that shipped with the record, and the streaming era has quietly retired it.

An LED matrix wall puts it back on the wall at the size it deserves, and makes it live: it changes
when the song changes, without anyone touching anything.

The obvious approach, a cheap TV showing a full screen image, fails for a specific reason. A TV in a
room reads as a switched-on screen. It has a bezel, a backlight glow, an off state that is a grey
rectangle. An LED matrix behind a diffuser reads as an object that emits light, closer to a lamp or a
sign than a display, and its off state is genuinely black. That difference is the entire point of
building the hard version.

## What HUB75 is

HUB75 is the de facto wiring standard for chainable RGB LED matrix panels. A 16 pin ribbon carries
six colour data lines (two sets of red, green, blue, because the panel drives two rows at once), five
row address lines named A through E, a clock, a latch, and an output enable.

The important thing about HUB75 is what it does **not** have: memory, or brightness control, or any
intelligence at all. The panel is a shift register attached to LEDs. It displays exactly one row pair
at a time, and it stays lit only for as long as you hold output enable low. To make a picture, the
host has to scan every row of the panel, over and over, fast enough that persistence of vision fuses
the rows into an image, and it has to modulate the on time of each row to produce anything other than
full brightness. If the host stops, the image does not freeze. It goes dark.

That is why this project needs a real time thread pinned to a dedicated CPU core, and why the signal
integrity of a 25 MHz clock down a ribbon cable is a design problem rather than a detail.

## How it works

```
  Mac                          Pi 5
  ---                          ----
  Music.app ---+
               +--> mac_reporter.py --HTTP--> brain/main.py
  MusicKit  ---+   (port 8787)                     |
  helper                                           | poll, detect track change
                                                   v
                                          art/fetch.py
                                          cover URL to cached image
                                                   |
                                                   v
                                          art/pipeline.py
                                          Lanczos downscale, unsharp, sRGB to
                                          linear, white balance, re-encode
                                                   |
                                                   v
                                          sinks/pi_renderer.py
                                          one RGB888 frame per open/write/close
                                                   |
                                                   v
                                          /tmp/album-frame.fifo  (named pipe)
                                                   |
                                                   v
                                          renderer/art_display  (C daemon)
                                          reader thread, plus a refresh thread
                                          pinned to isolated CPU 3
                                                   |
                                                   v
                                          HUB75 ribbon --> LED panels
```

The seam worth noticing is the named pipe. The brain and the renderer are separate processes that
share nothing but a byte stream of raw pixels, so either can be restarted, replaced, or run under a
debugger without the other caring. `art_display` re-opens the pipe on end of file and keeps showing
the last frame it received, so a crashed or upgraded brain leaves the wall lit rather than black.

On a laptop, `sinks/mac_preview.py` swaps in for the pipe and writes a scaled up PNG with a pixel
grid instead. That is how the whole image path was developed with no panel in the room.

## The simulations

This is the part of the project that is fully substantiated, and it is the part worth reading.

`pcb/sims/run_sims.py` writes ngspice decks, shells out to `ngspice -b`, and plots the results. Five
deck templates produce eight numeric output files and three figures, all committed. I re-ran all
eight decks from the committed `.cir` files and compared against the committed `.txt` outputs: every
one matches bit for bit, so the numbers below are reproducible rather than remembered.

Read them as circuit models, not as measurements. Nothing here has been checked against a real board,
because there is no real board.

### Why HUB75 lines need series termination

![Series termination sweep](pcb/sims/sim1_termination.png)

A logic driver puts out a fast edge. A 30 cm ribbon cable is not a wire, it is a transmission line
with inductance and capacitance distributed along it, and the panel at the far end is a high
impedance input that reflects almost all of the energy that arrives back toward the driver. The
reflection returns, bounces off the driver, and comes back again. What you see at the panel is
ringing: the voltage overshoots well past the supply rail, undershoots below ground, and settles only
after several round trips.

Series termination is the cheap fix. Put a resistor in line at the driver so that the driver's output
impedance plus the resistor roughly matches the cable's characteristic impedance. The reflection that
comes back is then absorbed instead of re-launched.

The sweep drives a 25 MHz pulse through an 18 ohm source resistance and a six section lumped LC
ladder standing in for the ribbon (25 nH and 2.5 pF per section), into an 18 pF panel input.

| Series resistor | Peak at panel input | Worst undershoot |
| --- | --- | --- |
| 0.1 ohm (effectively none) | 8.71 V | -4.11 V |
| 22 ohm | 7.09 V | -2.13 V |
| **33 ohm** | **6.48 V** | **-1.49 V** |
| 47 ohm | 5.86 V | -0.86 V |

Undamped, a 5 V signal swings to 8.7 V and to -4.1 V. Those excursions are what the panel driver
chip's input protection diodes have to eat, on every clock edge, forever.

47 ohm damps hardest, but it also slows the edge, and at 25 MHz the edge is a large fraction of the
bit period. 33 ohm is the value in `pcb/DESIGN.md`, chosen from this sweep as the point where
overshoot is tamed without blunting the edge. One caveat this figure carries in its own legend: the
plot says "Rs = 0" for the first trace because the script formats the label with `int(rs)`, while the
deck actually uses 0.1 ohm.

### What IR drop costs across the power distribution

![IR drop against supply trim](pcb/sims/sim2_irdrop.png)

An LED panel at full white is a serious load. One 64 by 64 P2.5 panel pulls roughly 4 A, so a section
of three panels pulls about 12 A. Copper has resistance, and 12 A through even a short run of 14 AWG
wire, a fuse, fuse clips, and a panel harness adds up to a voltage that is missing by the time it
reaches the panel. That is IR drop: current times resistance, the voltage the wiring keeps for
itself.

It matters because these panels are not tolerant. Below roughly 4.9 V the driver chips start
misbehaving, and the symptom is not a clean failure. It is dim patches, colour shifts on bright
frames, and flickering that only appears on white heavy album covers.

The deck is a DC sweep of the supply's output trim, with three constant current loads of 4 A each,
through modelled trunk wire, 7 milliohm of fuse and clips, and 0.4 m of 18 AWG harness per panel.

| Trunk length | Panel voltage at 5.00 V trim | Trim needed for 5.00 V at the panel |
| --- | --- | --- |
| 1.0 m of 14 AWG | 4.71 V | about 5.30 V |
| 0.5 m of 14 AWG | 4.81 V | about 5.20 V |

So a supply set to a perfect 5.00 V delivers 4.71 V to the panel, below the floor, and the wall
misbehaves on bright frames for reasons that look like a software bug. The answer is not thicker wire
alone, it is to trim the supply up so the panel lands in range, and the sweep says exactly how far.
Halving the trunk length is worth 0.10 V, which is why the design splits the wall into three
independent 12 A sections instead of running one 36 A trunk.

### Why inrush limiting matters

![Inrush current, first AC cycles](pcb/sims/sim3_inrush.png)

A switching power supply has a large capacitor across its input. At the instant you plug it in, that
capacitor is empty, and an empty capacitor looks like a short circuit. The only thing limiting the
current is the resistance of the mains wiring and the capacitor's own equivalent series resistance,
which together are a fraction of an ohm.

The deck models the first few AC cycles into roughly 560 uF of input bulk, at the worst case moment
of connection (the peak of the mains sine wave).

| Configuration | Peak line current |
| --- | --- |
| No limiter | 275 A |
| SL22 NTC thermistor, 10 ohm cold | 15.8 A |

275 A is a number that trips breakers, welds switch contacts, and shortens the life of everything it
passes through. The fix is a negative temperature coefficient thermistor in the mains line: cold, it
is 10 ohm and limits the surge to 16 A, and then it self heats within a second or two down to a
fraction of an ohm so it costs almost nothing during normal running. This is why an SL22 10005 is on
the Mouser line of `PARTS.md` and why the design puts it in the AC line rather than anywhere on the
board.

The model uses a generic diode bridge and a fixed cold resistance with no self heating, so it is
honest about the first cycle and says nothing about the settled behaviour.

## The board, written as a Python program

`pcb/circuit.py` is 207 lines that describe the backplane as data and emit it. Running it prints a
connectivity report and writes `backplane.net` (a KiCad netlist) and `bom.csv`. I ran it into a
scratch directory and diffed: both outputs regenerate identically to the committed files.

```
parts: 76   nets: 105   pin connections: 345
single-node nets (should be none): none
GPIOs consumed: [2, 3, 4, ..., 27]
```

The reason to do it this way instead of drawing a schematic is that most of this board is repetition
with an index. Three chains, nine panel drops, three power sections, twenty six buffered GPIO lines
each needing a series resistor from a shared pool of arrays. In a schematic editor that is a lot of
careful copying, and copying is where wiring errors come from. As a loop it is four lines, and the
pin map is stated once:

```python
SHARED = {"CLK": 17, "LAT": 4, "OE": 18, "A": 22, "B": 23, "C": 24, "D": 25, "E": 15}
CHAIN = {1: {"R1": 11, "G1": 27, "B1": 7, "R2": 8, "G2": 9, "B2": 10}, ...}
```

The script also checks itself. It reports any net with fewer than two nodes, which catches the most
common data entry mistake (a pin connected to nothing), and it prints which GPIOs the design consumes
so the fact that this pinout uses every one of BCM 2 through 27 is visible rather than discovered
later.

What this is not: a board. A netlist says what connects to what. It says nothing about whether the
parts fit in 170 by 110 mm, whether the 12 A pours are wide enough, or whether the layout passes a
manufacturer's design rules. That work is listed as the next step at the bottom of `pcb/DESIGN.md`
and has not been done.

## The render path

`renderer/art_display.c` creates the named pipe, holds it open, and streams frames out of it back
to back. It does not hand the brain's bytes to the panel library as they are: it keeps the last frame
received and, once per scanned frame, draws it again with temporal dithering, a running fraction per
LED colour, so a pixel can show a fraction of one of the library's 64 brightness slots and a dark
brown stops breaking into a lone red LED. The library bakes its brightness cap into a table once at
launch, so the renderer applies the cap itself, live, from each frame's header. It maps exactly once
per scanned frame by waiting on a swap counter that `pi/hub75-swap-counter.py` adds to the library;
before that counter the safe rate was 60 Hz and anything faster tore. The main thread calls
`render_forever()`, which owns the refresh loop.

It compiles and runs on the Pi 5. It includes `<rpihub75/rpihub75.h>` and links `-lrpihub75_gpu`,
the third party library `bitslip6/rpi-gpu-hub75-matrix`, which `pi/bootstrap.sh` clones and builds;
that has all run on the real Pi. What has not happened is a panel: the renderer's output has only
ever gone into the library, never into LEDs.

One number needs a label. The comment in `art_display.c` and the comment in `pi/run_renderer.sh` both
mention 9600 Hz. **That is the refresh rate advertised by that third party library, on hardware this
project does not own.** It is a design target that motivates the architecture (a refresh that fast is
what makes the wall photograph without banding, and what makes a torn frame invisible), and it is not
a measurement. Nothing in this repository has measured a refresh rate.

Likewise, `pi/run_renderer.sh` passes `-p 1 -c 1 -x 64 -y 64`: one port, one chain, one 64 by 64
panel. `config.example.toml` says the same thing in a comment: "S1: one 64x64 P2.5 panel. Later: 128
(4 panels) / 192 (9)". The nine panel wall is the plan. The configured system is one panel.

## CPU isolation

`pi/bootstrap.sh` appends `isolcpus=3 nohz_full=3` to the Pi's kernel command line. Two settings,
both about getting the Linux scheduler out of the way:

- `isolcpus=3` removes core 3 from the scheduler's general pool. Ordinary threads will not be placed
  there, so a thread that pins itself to core 3 has the core to itself.
- `nohz_full=3` stops the periodic timer interrupt on that core when only one thread is runnable on
  it. Without it, the kernel interrupts the core hundreds of times a second just to keep time.

The reason this is worth doing is in how HUB75 works, above. The refresh thread is not rendering
frames, it is bit banging a scan: hold a row's data on the bus, pulse the clock, latch, hold output
enable low for a precisely timed interval, repeat. The interval is what encodes brightness. If the
scheduler preempts that thread mid interval, the row stays lit longer than intended, and the result
is a visible bright line or a flicker in what should be a still image. A dropped frame in a video
game is a stutter you forgive. A late microsecond here is a defect on a wall you are staring at.

This is configured, not demonstrated. The line is in the script, the script has never run, and no
latency has been measured.

## Colour, and the number that is still a guess

The pipeline in `brain/art/pipeline.py` does white balance the correct way, which is the one part of
the image path with a real argument behind it.

RGB LED panels are not neutral. Their green and blue emitters are typically far more efficient than
their red, so a frame that says "white" comes out cyan. The correction is per channel gains. The
subtlety is *where* you apply them: an 8 bit image is gamma encoded, not linear, so scaling those
values directly scales perceptual codes rather than light. The pipeline decodes to linear light
(gamma 2.2), applies the gains there, clips, and re-encodes:

```python
linear = np.power(arr, 2.2)
linear *= np.asarray(gains, dtype=np.float32)[None, None, :]
np.clip(linear, 0.0, 1.0, out=linear)
encoded = np.power(linear, 1.0 / 2.2) * 255.0
```

The gains themselves are R 1.00, G 0.75, B 0.55, and `config.example.toml` labels them exactly as
they should be labelled:

> these starting gains are the research's typical values, a GUESS.

They are a starting point from published typical values, not a measurement of any panel. Measuring
them is a written procedure that has not been carried out: `scripts/WB-PROCEDURE.md` calls for a
TCS34725 colour sensor on a Pico 2 W (`scripts/pico_colorimeter.py`) held against a panel showing
full white (`scripts/show_white.py`), after a ten minute warm up because LED output shifts as the
panel heats.

## Running the software with no hardware

Requires Python 3.11 or newer (the config loader uses `tomllib`).

```bash
python3 -m venv .venv
.venv/bin/pip install -r brain/requirements.txt   # requests, Pillow, numpy
cp config.example.toml config.toml
```

The offline test needs no network, no accounts, and no panel. It synthesizes a 640 by 640 cover
containing a smooth gradient, a disc, and fine detail, chosen to expose banding, aliasing, and
downscale mush respectively, then runs the full art pipeline:

```bash
.venv/bin/python scripts/smoke_test.py
```

A successful run prints `smoke test OK:` and writes three files:

| File | What it shows |
| --- | --- |
| `preview_out/smoke_source.png` | The synthetic source cover |
| `preview_out/panel.png` | 64 by 64, scaled up with hard pixel edges and a grid, as the wall would show it |
| `preview_out/wb_compare.png` | Side by side, without and with the white balance step |

`wb_compare.png` will look wrong on a monitor, and that is the point. White balance compensates for
panel hardware, so on a correctly behaved screen the corrected version looks orange.

To run the live loop against Apple Music on a Mac:

```bash
.venv/bin/python -m brain.main --config config.toml
```

It polls every 5 seconds and rewrites `preview_out/panel.png` on each track change. Two caveats. The
Apple Music adapter's highest tier shells out to a MusicKit helper at
`~/.config/widgetsuite/musickit-fetch.py`, which lives outside this repository and is not verified
here; its lower tier uses `osascript` against Music.app, which triggers a one time macOS automation
prompt. Add `--once` to poll a single time and exit.

To have the Mac report every other app it plays as well (Spotify's app, TIDAL, a browser tab on
YouTube Music), install `media-control` once; both the brain on a Mac and `scripts/mac_reporter.py`
pick it up on their next start, with no setting to flip:

```bash
brew install media-control
```

Connecting a service needs no computer at all. Tessera's Settings > Services pages take the Spotify
app id, the Last.fm key and username and the ListenBrainz username, hand them to
the wall (`POST /services`), and the wall keeps them in `~/.config/album-art-matrix/services.json`
and starts using them at once. The Spotify sign-in itself runs on the phone. The values in
`config.toml` are only seeds; anything set from the phone wins. What still needs a computer is the
one-time `./deploy.sh` that puts the software on the Pi.

The developer's own keys live in `tessera/Tessera/DeveloperKeys.swift`. Only what is safe to
publish goes in there, because this repository is public. The Spotify app id qualifies: it is public
by design, the way every app with a "Sign in with Spotify" button was registered once by its
developer, and the sign-in uses PKCE so there is no secret to keep. A **Last.fm API key does not**:
it is bound to the developer's Last.fm account and a published one can be copied and revoked for
someone else's abuse, so that field is empty and the key is typed into Tessera's Services page
instead, which keeps it in `services.json` on the wall. With a key filled in, the app hands it to
any wall it meets that is missing one, and a person only ever signs in to Spotify or types a
Last.fm or ListenBrainz username. With it empty, the Services pages walk through making it by hand.

To re-run the circuit simulations, you need `ngspice` on your PATH plus numpy and matplotlib:

```bash
python3 pcb/sims/run_sims.py    # rewrites the .txt data and the three PNGs
python3 pcb/circuit.py          # rewrites backplane.net and bom.csv
```

## First light, when the parts arrive

The order of operations in `pi/PI-SETUP.md`, which is a runbook whose third step literally begins
"Pi arrives". Nothing below has been done.

1. Flash Raspberry Pi OS Lite 64 bit, hostname `album-matrix`, user `pi`, SSH key configured.
2. `./deploy.sh --bootstrap`, which rsyncs the source and remotely runs `pi/bootstrap.sh`: apt
   dependencies, zram, clone and build the panel library, append the CPU isolation flags, build the
   renderer, create the venv, install the systemd unit (not enabled).
3. Reboot, so the kernel command line change takes effect.
4. Wire it with everything unplugged. Ribbon into the panel's INPUT connector, panel power from its
   own supply, never from the Pi. Mains into the supply last.
5. Start `pi/run_renderer.sh` in one shell and the brain in another, with `[sink] type = "pi"` and
   the reporter endpoint pointed at the Mac.
6. Warm up ten minutes, then run the white balance procedure and replace the guessed gains with
   measured ones.

The first honest checkpoint is the one `pi/PI-SETUP.md` names: a photograph of the panel next to the
same cover on a phone, with the two colours matching. Until that photo exists, this project has not
displayed anything.

## Project layout

```
brain/                  4238 lines of Python: the now playing control plane
├── main.py             Poll loop, render loop, journal writes. A dirty event
│                       from the API wakes it instead of waiting out the poll.
├── services.py         Keys and usernames the phone hands the wall; kept in
│                       services.json, applied to the adapters live
├── control.py          HTTP state API on 8788. Mode, brightness, spin rate,
│                       ambient, finishes, ticker and clock, sleep fade,
│                       journal + replay, raw frame and clip pushes. State
│                       persists to control.json; plays go to journal.jsonl.
├── nowplaying/
│   ├── pushed.py       What the phone posts straight to the wall
│   ├── applemusic.py   Tiered: a state file, Music.app over osascript, any
│   │                   other app the Mac plays (macmedia), the account view
│   ├── applemusic_account.py  The account view from the Pi, no Mac in the path
│   ├── macmedia.py     macOS Now Playing via media-control: Spotify's app,
│   │                   TIDAL, browser tabs, with their artwork
│   ├── spotify.py      PKCE OAuth from the phone or a Mac; the wall polls
│   ├── lastfm.py       One account Spotify, Tidal and Deezer report to
│   ├── listenbrainz.py The open ledger; reading it needs no key
│   └── ears.py         The wall's microphone, read all the time; Shazam names it
├── art/
│   ├── fetch.py        Cover URL to cached image (decode before cache)
│   ├── pipeline.py     The colour work
│   ├── disc.py         Sleeve as a spinning disc, supersampled, fixed sheen
│   ├── effects.py      Eight ambient generators for when nothing is playing
│   ├── pixelfont.py    The 5x7 font, single source for both apps' Swift copies
│   └── text_modes.py   Clock and scrolling ticker over that font
└── sinks/              mac_preview.py (PNG, for development), pi_renderer.py (FIFO)

ios-companion/          AlbumWall, the first app, 4,406 lines of Swift
├── AlbumWall/          The app: on device now playing push, wall remote,
│                       photo and video push, App Intents, Live Activity
├── AlbumWallWidgets/   Home screen widgets and the Live Activity surface
└── design/             Screen designs the app was built from

tessera/                The current iOS app, 26,472 lines of Swift
├── Tessera/            Wall screen, Studio (draw / photo / words / video),
│                       Archive, Settings, offline outbox, stand-in wall
├── TesseraWidgets/     Home screen widgets
├── Shared/             Live Activity attributes, shared snapshot
└── Tools/              gen_pixelfont.py (regenerates both apps' fonts),
                        make_icon.py

web/                    The control plane in a browser: pipeline (same math,
                        TypeScript), source chain, wall simulator, history,
                        WB profiles, power model, push to the Pi brain.
                        `cd web && npm install && npm run dev`. See web/README.md.

pcb/
├── DESIGN.md           The backplane's rationale, signal design, power design, costs
├── circuit.py          The circuit as data. Emits the two files below.
├── backplane.net       Generated KiCad netlist, 76 parts, 105 nets
├── bom.csv             Generated bill of materials
├── layout.py           Placement, driving the KiCad board file
├── backplane.kicad_pcb The board. Routed; 7 ground pour islands left to stitch.
├── drc*.json           20 design rule check runs, in order. The trend is the story.
├── footprints/         Vendored .kicad_mod files, so the board opens anywhere
├── fab/                Gerbers, drill, pick and place, board views
└── sims/               ngspice decks, numeric outputs, three figures, run_sims.py

renderer/               art_display.c (202 lines) and its Makefile. Builds and
                        runs on the Pi; no panel has been on the other side.
pi/                     PI-SETUP.md runbook, wiring.svg, bootstrap.sh, run_renderer.sh,
                        systemd units
scripts/                mac_reporter.py (Mac HTTP endpoint the Pi polls), panel_qa.py +
                        PANEL-INTAKE.md (per panel intake), spin_demo.py, gen_tracker.py,
                        smoke_test.py, show_white.py, pico_colorimeter.py, WB-PROCEDURE.md
qa_preview/             271 rendered QA patterns
qa/QA-SHEET.md          Per panel results. Empty; no panel has been tested.
PARTS.md                Shopping list. Prices checked 2026-08-19.
PARTS-TRACKER.xlsx      What was actually ordered, and what it cost
config.example.toml     Copy to config.toml
deploy.sh               rsync to the Pi, with --bootstrap for the first run
```

## What is not built

Stated plainly, because the value of everything above depends on this list being complete.

- **No panel has been driven.** The ten panels have arrived and the Pi runs the whole software
  stack, but the bonnet and the 5V supplies have not landed, so nothing in this repository has lit
  an LED.
- **The PCB is routed but not signed off.** The last design rule check finds no violations and no
  unrouted signal, but it still reports 7 ground pour islands, which is the one defect that matters
  most on a board whose power design assumes a continuous return. Gerbers exist; stitch the ground
  first. The board is also still parked: the build uses the bonnet and bus bar path.
- **Neither iOS app's now playing path is verifiable off a phone.** They build and run on device,
  but the simulator stubs MediaPlayer, so that path is only ever exercised on real hardware.
- **No panel has been through intake QA.** The patterns and the procedure exist; the results sheet
  is an empty table.
- **The renderer's output has never reached an LED.** It compiles and runs on the Pi, but with no
  panel attached everything it maps goes into the library and stops there.
- **No streaming account is linked yet.** The Spotify, Last.fm and ListenBrainz
  adapters are written, but every credential in `config.toml` is still empty, so none of them has
  answered live. Only Apple Music (phone push, Music.app, account view) and the Mac's own Now
  Playing have.
- **Nothing on an iPhone other than Apple Music can be read by an app.** iOS gives an app only the
  Music player; Spotify, Tidal and Deezer reach the wall through their own accounts (Spotify's
  API, or Last.fm), and SoundCloud, YouTube Music and Amazon Music reach it only from a Mac or
  out loud.
- **Panel performance is unmeasured.** The software side is measured (`scripts/bench_frames.py`
  bounds the producer, the brain prints its sustained fps, and the 60 Hz map cap came out of a
  measured black-flashing regression), but refresh on real LEDs, CPU under a real load, and power
  draw are not. The 9600 Hz figure in the source comments is the panel library's specification,
  not a result from this room.
- **History is a journal, not a database.** Plays land in `journal.jsonl` (capped at 500, replay
  by timestamp); there is no search and no analytics on the brain side.
- **Every app is unproven against a wall.** Web, AlbumWall and Tessera all drive
  `brain/control.py`, and that API has run on the real Pi, but the loop from app to brain to lit
  panel has never been closed.
- **The web app's push-to-wall has not touched the Pi.** Its "Pi brain" push format matches
  `brain/control.py`'s `/frame` contract byte for byte, and the CORS headers that let a browser call
  that API are committed here, but the Pi was offline when this landed, so the loop web → brain →
  panel has never been closed. The Apple Music bridge path, by contrast, was verified live.
- **The white balance gains are unmeasured**, and labelled as such in the config.
- **No automated tests.** `scripts/smoke_test.py` is a visual check that writes PNGs for a human to
  look at, plus one assertion on frame size. There is no test runner and no CI.

---

Jalen Edusei, [jalenedusei.com](https://www.jalenedusei.com),
[github.com/jke48222](https://github.com/jke48222)
