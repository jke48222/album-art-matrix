# Tessera — the visual redesign checklist

Inventory date: 23 September 2026. Baseline: main at `7b4e2c8`, plus the weather
parity correction in this change. This is a source audit of the shipped app and
its companion surfaces, not a claim that every flow has been exercised on a
physical device. Local work on the separate `codex/site` checkout is noted below.

There are **99 review units** below. We will take **one review unit at a time**. Weather is first; everything else is
queued. A checkbox means the complete pass has been reviewed, not merely that a
screen exists. IDs stay stable so “do C03 next” has an unambiguous meaning.

## The standard for every pass

1. Capture the current phone screen, its interactions and actual wall frame.
2. Study relevant Mobbin screens/flows and primary web references. Save direct
   links and the specific ideas worth using; do fresh research for each feature.
3. Design the complete feature: typography, composition, colour, motion,
   interaction feedback, accessibility, loading, empty, offline and error states.
4. For content shown on the wall, **the phone and wall share the same visual
   composition and meaning**. Adapt scale and omit truly unreadable microcopy at
   64×64; do not substitute an unrelated “LED version.” Phone controls can remain
   outside the artwork. Intentional previews must be clearly labeled.
5. Compare the full-resolution view with true 64×64 and 192×192 output at matched
   data/time/units. Inspect pixel output without smoothing; then check the real
   panel. Software RGB previews cannot certify the LEDs' physical colour.
6. Test relevant behaviour; deploy to the wall and the connected iPhone 18 Pro Max
   as previously requested. Commit and push the scoped change to main, with no
   co-author trailer. Record validation and any remaining limitations.

## W — Weather · first

Source: [WeatherPage](../tessera/Tessera/WeatherPage.swift),
[WeatherAtmosphere](../tessera/Tessera/WeatherAtmosphere.swift),
[wall renderer](../brain/art/weather.py), [design notes](WEATHER-DESIGN.md).

- [ ] **W01 — Weather.** Native current-conditions hero; place editing; °F/°C;
  next-six-hours selection and return to Now; feels-like, wind, cloud and rain
  instruments; daylight arc; refresh, stale and unavailable states; wall action
  and live preview. **Current pass:** phone redesign shipped; wall composition
  corrected in this change. Physical visual review remains open.

Weather references already studied: [Apple Weather](https://mobbin.com/screens/f7e0b42a-b5ea-4e48-9fb4-0ab3f04d7064),
[(Not Boring) Weather](https://mobbin.com/screens/2f5d6c68-0085-4a81-b708-3754398d677f),
[Lumy](https://mobbin.com/screens/491f5781-df9b-46ea-86ec-fb258a83d369),
[The Weather Channel](https://mobbin.com/screens/2a9e8135-5669-4923-a97b-48fed3144d5e),
[Atmos by Diana L. Wong](https://www.dianalwong.com/atmos).
The attached phone screenshot is the composition target. Future-hour exploration
is explicitly a preview; the wall continues to show current weather.

## A — The app, now playing, and the wall

Sources: [RootView](../tessera/Tessera/RootView.swift),
[WallScreen](../tessera/Tessera/WallScreen.swift),
[ControlCenter](../tessera/Tessera/ControlCenter.swift),
[NowPlaying](../tessera/Tessera/NowPlaying.swift),
[Archive](../tessera/Tessera/Archive.swift).

- [ ] **A01 — App shell and navigation.** Wall/Archive paging, Settings, Studio,
  sheets, dismissals, safe areas and transitions.
- [ ] **A02 — Classic wall home.** Live panel, drag-to-dim, title/artist, playback
  progress, connection state and the inactive wall.
- [ ] **A03 — Room home.** Room lighting, physical wall placement, dive into the
  wall, return transition, day/night room assets and reduced-motion behaviour.
- [ ] **A04 — iPod home.** Click wheel, menus, now-playing display, artwork,
  controls, focus and tactile feedback.
- [ ] **A05 — Now-playing identity.** Sleeve, record, label, title/artist, progress,
  beat response, needle and pause/song-change transitions across the homes.
- [ ] **A06 — Face picker and control center.** Art, Spin, Lyrics, Nine, Design,
  Video, Lamp, Clock, Games, Off; mode-specific controls and selection feedback.
- [ ] **A07 — Brightness and colour controls.** Panel gesture, slider/value,
  colour bar, palette extraction and live response.
- [ ] **A08 — Archive.** History browsing, day groupings, artwork grid, item detail
  and putting a previous record back on the wall.
- [ ] **A09 — Listening statistics.** Worn statistics, listening time, play counts
  and their presentation inside the archive.
- [ ] **A10 — Pressings and record labels.** Release details, owned-record marker,
  Discogs pressing selection, and paper/neon/coin/holo/mono label styles.

## C — Display content and creation

Sources: [wall modes](../brain/control.py), [Studio](../tessera/Tessera/Studio.swift),
[Framing](../tessera/Tessera/Framing.swift), [Lyrics](../tessera/Tessera/Lyrics.swift),
[Video](../tessera/Tessera/Video.swift), [art renderers](../brain/art).

- [ ] **C01 — Album art.** Full-panel sleeve, crop, loading/replacement transition
  and response to a new track.
- [ ] **C02 — Spin.** Rotating disc, album-art versus pressing face, RPM, label,
  spindle and the relationship between phone record and wall record.
- [ ] **C03 — Lyrics.** Word/line treatment, synchronized highlighting, timing
  offset, no-lyrics state, phone reading view and wall canvas.
- [ ] **C04 — Nine.** The nine-cover composition, updates and cover legibility.
- [ ] **C05 — Finishes.** Clean, dither and poster; live swatches and consistent
  treatment of phone preview and sent artwork.
- [ ] **C06 — Lamp.** Solid, breathe, pulse, rainbow, gradient, plaid, weave,
  deco and snake; both colour controls, match-art, speed and transitions.
- [ ] **C07 — Studio drawing.** Pixel canvas, pen, fine/wide brush, erase, fill,
  ink/palette, undo, redo and clear.
- [ ] **C08 — Studio lettering.** Text entry, word size, placement and colour;
  readable composition on the small panel.
- [ ] **C09 — Photo import and framing.** Photo permission/picker, pan/zoom/crop,
  outside-crop treatment, pixel preview and sending a still frame.
- [ ] **C10 — Clips and video.** Local video, URL entry, video library, framing,
  playhead, conversion/upload progress, playback, sound and errors.
- [ ] **C11 — Saved creations.** “Made” collection, loading a creation, deletion,
  still versus animated content and the “On the wall” confirmation.
- [ ] **C12 — Ticker.** Text, individual colours, loop, across/rising/crawl styles
  and phone/wall readability. Includes use by notes and answers.

## R — Time, light and everyday routines

Source: [SettingsSheet and routine pages](../tessera/Tessera/SettingsSheet.swift),
[ControlCenter](../tessera/Tessera/ControlCenter.swift), [brain](../brain/main.py).

- [ ] **R01 — Clock.** 12/24-hour choice and the full clock composition.
- [ ] **R02 — Timer and alarm.** Duration entry, countdown/ring, cancel/stop,
  alarm time and enabled/disabled states.
- [ ] **R03 — Follow the sun.** Location, daytime/night brightness and live state.
- [ ] **R04 — Sleep.** Fade duration, remaining time, cancel and completion.
- [ ] **R05 — Wake up.** Enabled state, time picker, fade minutes and schedule.
- [ ] **R06 — Idle, away and off.** Nothing-playing choices: black, hold, dim,
  ambient or weather; away stay/off; recovery to music and explicit Off.

## F — Smart and conversational features

Sources: [Features](../tessera/Tessera/Features.swift),
[Imagine](../tessera/Tessera/SettingsSheet.swift),
[Hearing](../tessera/Tessera/Hearing.swift), [feature registry](../brain/features.py).

- [ ] **F01 — Ask the wall.** Prompt entry, thinking, answer card, wall text,
  spoken answer and failure/retry.
- [ ] **F02 — Notes.** Message entry, duration, wall preview, active note and expiry.
- [ ] **F03 — Show me.** Find a cover/picture/video by name, result identity,
  loading, display and failures; web search and configured Google Images.
- [ ] **F04 — Earworm.** Remembered lyrics, identification progress, song result
  and putting the discovered music on the wall.
- [ ] **F05 — Imagine.** Prompt, generation, waiting artwork, result, live/generative
  mode where supported, errors and subsequent creations.
- [ ] **F06 — Voice.** Wake word, listen/think/speak wall states, microphone and
  wake meters, enrollment/calibration, recent commands and transcript feedback.
- [ ] **F07 — Hearing and gestures.** Room recognition, Shazam/local match status,
  microphone levels, knock/whistle controls and rejected-match feedback.
- [ ] **F08 — Teach the wall.** Song library, adding/learning songs, room learning,
  fingerprints, match confidence and recognition feedback.
- [ ] **F09 — The shelf.** Discogs collection, sync/read again, record membership
  and ownership markers across phone and wall.

## G — Games · a separate pass for every game

Sources: [hub and shared play shell](../tessera/Tessera/Games.swift),
[puzzle boards](../tessera/Tessera/GamesBoards.swift),
[play boards](../tessera/Tessera/GamesPlay.swift), [wall games](../brain/games).
Every game pass includes its instructions, input, board, feedback, result,
restart/exit and wall counterpart. Colour must not be the only cue.

- [ ] **G00 — Games hub and shared shell.** Catalog, active game, player names,
  multiplayer turns, speech input, scores, wins/streaks, result and resume/exit.
- [ ] **G01 — Wordle.** Guesses, keyboard and letter-state reveal.
- [ ] **G02 — Sudoku.** Selection, number entry, givens and validation.
- [ ] **G03 — Connections.** Word selection, groups, mistakes and solved rows.
- [ ] **G04 — Spelling Bee.** Letter honeycomb, central-letter rule, words and score.
- [ ] **G05 — Letter Boxed.** Edge letters, paths, word chaining and solution.
- [ ] **G06 — Strands.** Letter grid, path selection, theme and spangram.
- [ ] **G07 — Mini crossword.** Grid, clues, entry direction and completion.
- [ ] **G08 — Contexto.** Guess entry, semantic ranking and history.
- [ ] **G09 — Sliding puzzle.** Image tiles, empty space, moves and solved reveal.
- [ ] **G10 — Cover reveal.** Progressive album-art reveal and answer state.
- [ ] **G11 — Reaction knock.** Ready/wait/go, early knock and reaction time.
- [ ] **G12 — Whistle bird.** Pitch input, flight, obstacles and score.
- [ ] **G13 — Heardle.** Audio snippets, guesses, skip and track reveal.
- [ ] **G14 — Twenty questions.** Question/answer history and final guess.
- [ ] **G15 — Pub quiz.** Question, options, answer reveal and scoring.
- [ ] **G16 — AI pictionary.** Drawing reveal, guesses and result.
- [ ] **G17 — Pong.** Paddles, ball, controls, score and match result.
- [ ] **G18 — Snake.** Board, directional control, food, score and game over.
- [ ] **G19 — Tetris.** Falling piece, controls, stack, line clear and score.

## S — Connections and services

Sources: [Services and setup pages](../tessera/Tessera/Services.swift),
[service buttons](../tessera/Tessera/ServiceButtons.swift),
[HomeKit page](../tessera/Tessera/Features.swift).
All connection passes include disconnected, connecting, connected, refused,
expired/retry and unlink states wherever the integration supports them.

- [ ] **S01 — Services overview.** Connection status, source precedence,
  recommendations and clear routes into setup.
- [ ] **S02 — Apple Music.** Permission, denied-permission recovery, current playback
  and supported “listen on Apple Music” actions.
- [ ] **S03 — Spotify.** Sign-in/OAuth, fallback setup, account state and disconnect.
- [ ] **S04 — Last.fm.** Username, account linkage, currently listening and errors.
- [ ] **S05 — ListenBrainz and scrobbling.** Token, listening status, counted time,
  last written listen and offline queue.
- [ ] **S06 — Other music players.** Tidal, Deezer, SoundCloud, YouTube Music and
  Amazon Music guidance via reporting/scrobbling; do not imply native OAuth exists.
- [ ] **S07 — Claude setup.** Key/workspace configuration, model/status, recent
  question and errors; credential inputs must remain private.
- [ ] **S08 — Discogs setup.** Token, account/collection state and sync.
- [ ] **S09 — Posters.** TMDB key, poster lookup and recent film/series result.
- [ ] **S10 — Images provider.** OpenAI/Google choice, key, quality and availability.
- [ ] **S11 — AirPlay.** Receiver on/off, name, connection state and artwork.
- [ ] **S12 — Mac reporter.** Endpoint, connection guidance, status and diagnostics.
- [ ] **S13 — HomeKit.** Pairing code/QR, connection state and Home controls.
- [ ] **S14 — Pictures search setup.** Google key and search-engine ID, connected
  state, web/Wikipedia fallback guidance and the last displayed picture.

## D — Setup, calibration and maintenance

Sources: [Onboarding](../tessera/Tessera/Onboarding.swift),
[SettingsSheet](../tessera/Tessera/SettingsSheet.swift),
[Calibrate](../tessera/Tessera/Calibrate.swift),
[Tuning](../tessera/Tessera/Tuning.swift), [knob registry](../brain/tuning.py).

- [ ] **D01 — First run.** Welcome, wall discovery/found/no-wall, glow, service
  setup, light and done; permission states and offline stand-in.
- [ ] **D02 — Settings landing.** Status, next-step card, grouping, feature
  discoverability, rows and navigation.
- [ ] **D03 — True colour.** Camera permission, capture/measurement, RGB gains,
  comparison, result and correction/reset state.
- [ ] **D04 — Panel check.** Flat test colours, defective-light inspection and exit.
- [ ] **D05 — Guests.** Wi-Fi details, QR generation, wall display and readability.
- [ ] **D06 — How it's doing.** Health, refresh, errors and understandable status.
- [ ] **D07 — Addresses and diagnostics.** Wall/Mac endpoints, connection recovery,
  sent-state feedback and flight-log/journal visibility where exposed.
- [ ] **D08 — About and design choice.** Classic/Room/iPod choice, version/info,
  onboarding/intro replay and discovery of advanced tuning.
- [ ] **D09 — Advanced panel tuning.** Live preview and test patterns; panel drive,
  colour, dark end, sharpness, video, shelf, hearing and voice knobs; defaults,
  reset, restart-needed feedback and clear explanations.

## E — Surfaces outside the main app

Sources: [widgets](../tessera/TesseraWidgets),
[shared intents](../tessera/Shared/WallIntents.swift),
[share extension](../tessera/TesseraShare/ShareViewController.swift),
[desktop widget](../tessera/Desk/README.md).

- [ ] **E01 — Home-screen widgets.** Small/medium layouts, artwork, labels,
  snapshot freshness, deep links and unavailable wall.
- [ ] **E02 — Lock screen and Dynamic Island.** Live Activity states, compact and
  expanded layouts, Art/Lamp/Off actions and enable/disable setup.
- [ ] **E03 — Share extension.** Photo, video and URL handoff; preview, progress,
  completion, cancellation and errors.
- [ ] **E04 — Siri, Shortcuts and deep links.** Mode, brightness, sleep and timer
  intents, feedback and app routing. Assess system-owned UI within its limits.
- [ ] **E05 — Mac desktop widget.** Live LED view, song, progress, shelf status,
  mode chips, scroll brightness, drag/resize/reset and stale connection.
- [ ] **E06 — Openings and transitions.** Sting, room/film/mark sequences, wall
  startup and Imagine waiting sequence; replay, interruption and reduced motion.

## B — Web companion

Source: [web routes](../web/src/routes), [web components](../web/src/components).
These are existing companion tools; inventory does not imply every control is
currently synchronized with the native app or connected to the wall.

- [ ] **B01 — Web shell.** Navigation, responsive layout, current wall status,
  not-found and error pages.
- [ ] **B02 — Dashboard.** Current art and track, rendering controls, interactive
  preview and the wall handoff.
- [ ] **B03 — Pipeline and test patterns.** Inspectable image-processing steps,
  calibration patterns and frame/config export.
- [ ] **B04 — History.** Search, days, track detail, source/settings and listening
  statistics.
- [ ] **B05 — Sources.** Service setup, source state and failure feedback.
- [ ] **B06 — Balance.** White-balance profiles, measurements, RGB/XYZ entry,
  default-versus-measured labeling and procedure.
- [ ] **B07 — Power.** Panel/power calculations, assumptions and diagrams.
- [ ] **B08 — Setup.** Wall/pipeline configuration, idle policy, push and export.

## X — Shared foundations and secondary scope

Sources: [Theme](../tessera/Tessera/Theme.swift),
[Components](../tessera/Tessera/Components.swift), [Panel](../tessera/Tessera/Panel.swift),
[README](../README.md), [design tools](../design).

- [ ] **X01 — Typography, colour and controls.** Technor/Switzer/Martian Mono,
  spacing, colour semantics, icons, buttons, selection, focus and haptics.
- [ ] **X02 — Accessibility and resilience.** Dynamic Type, VoiceOver, contrast,
  reduced motion, long/localized text, offline/stand-in, reconnect and outbox.
- [ ] **X03 — Preview fidelity.** Shared pixel scale/crop, linear colour handling,
  frame freshness, 64/192 layout and phone/wall visual regression evidence.
- [ ] **X04 — Project documentation and physical-build visuals.** Readme, parts,
  assembly, panel layout, enclosure/PCB diagrams and generated design previews.
  This is secondary to the product interface; do not change hardware as a UI pass.

## Registry coverage and boundaries

The 15 wall modes are covered: `art` C01, `cd` C02, `ambient` C06, `off` R06,
`frame` C07–C09, `ticker` C12, `clock` R01, `clip` C10, `timer` R02, `nine` C04,
`lyrics` C03, `video` C10, `weather` W01, `game` G00–G19, `imagine` F05.
All nine lamp effects and all 19 registered games are named above. The feature
registry's HomeKit, scrobble, knock, teach, ask, voice, note, AirPlay, shelf,
earworm, show, imagine, weather, posters, games and sting are also represented.

`ios-companion/` is the predecessor app, not a second active Tessera redesign.
The local `codex/site` checkout has unrelated work in progress. The Show me
web-search update and Pictures setup that reached main during this audit are
included in F03/S14. Other uncommitted changes were neither incorporated nor
published by this weather pass. Reconcile those features when their pass starts.
Marketing/site work outside main should be inventoried when its branch is ready;
this checklist does not pretend that unmerged routes are shipped.

Suggested order after W01: **A02 + A05** (home/now playing), **A06** (controls),
**C02** (Spin), **A08** (Archive), **C07** (Studio), **C03** (Lyrics), then choose
from the remaining IDs. The pair A02/A05 can be reviewed together because the
same artwork, title and progress presentation span both.
