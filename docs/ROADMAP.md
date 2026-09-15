# Roadmap: the microphone, the voice, HomeKit and the games

Decided 2026-09-15. Thirty-five items, built roughly in this order.
HomeKit landed the same night: paired in a new hub-less home after the
old home's unreachable Apple TV hub rolled back every add, and the wall's
mDNS name had to be given to the HomeKit library too (see brain/homekit.py). A row moves
to **done** when it is running on the Pi and, where it has a phone side, in the
app. Nothing here is a promise about a date.

## Features

| # | Item | What it is | State |
| --- | --- | --- | --- |
| 1 | HomeKit: Siri for free | The wall is a light in the Home app: on, off, brightness, colour. Siri, Watch, Control Centre, scenes. | **done** 2026-09-15 |
| 2 | HomeKit: the wall as a television | Modes become inputs; the Control Centre remote's arrows, play and back drive the wall. | **done** 2026-09-15 |
| 3 | HomeKit: the ear as a house sensor | "Sound in the room" and "music playing" appear as sensors, so lamps and notifications can follow them. | **done** 2026-09-15 |
| 4 | HomeKit: pair by scanning the panel | The wall draws its own pairing code on the 64x64. | **done** 2026-09-15 |
| 5 | The listening face, Horizon | Only when the wake word is said: the picture collapses to a line, the line follows your voice, a bead runs while it thinks, the answer opens from the line. | **done** 2026-09-15, on the wake word |
| 6 | Vinyl scrobbling | Records the ear names go to ListenBrainz as playing-now and as listens. | **done** 2026-09-15, needs the token |
| 7 | Knock twice | Two knocks on the frame toggle the wall; whistle as the fallback. | **done** 2026-09-15, numbers to tune with real knocks |
| 8 | Teach the wall a song | A local fingerprint library (Olaf) seeded from iTunes previews and room recordings, asked before Shazam. | **done** 2026-09-15, own fingerprinter (no Olaf on this Pi) |
| 9 | Ask the wall | A spoken question, answered by Claude with the wall's own state attached, shown as short lines on the panel. Via a Siri Shortcut or the wall's ears. | **done** 2026-09-15, needs the Claude key |
| 10 | The wall's own ears | Wake word (openWakeWord) plus whisper.cpp on the Pi; short commands stay local. | **done** 2026-09-15, "hey Jarvis" until a "hey wall" head is trained |
| 11 | Leave a note | "Hey Siri, tell the wall back at six" puts words on the panel through a Shortcut. | **done** 2026-09-15 |
| 12 | AirPlay to the wall | The Pi is an AirPlay 2 receiver; any Apple device in the group hands over exact title, art and position. | planned |
| 13 | The shelf | Discogs collection sync: a corner mark on streamed songs you own on vinyl; pressing details and price when a record plays. | **done** 2026-09-15: brain/shelf.py, the mark in brain/art/mark.py, a Discogs page in the app; waiting for the token |
| 14 | Earworm finder | Say the words you remember; Claude names the song; the sleeve goes up. | **done** 2026-09-15, needs the Claude key |
| 15 | Show me, play me | "Show the Blond cover" (iTunes search, frame mode); "play the Gameboy video" (YouTube search, video mode). | **done** 2026-09-15 |
| 16 | Image creator by description | "Create a purple elephant" draws one on the panel. Image model to be chosen. | **done** 2026-09-15: brain/imagine.py, OpenAI gpt-image-1 or Google Imagen chosen on the phone, an Imagine page with the gallery; waiting for a key |
| 17 | Weather faces | A weather display with dedicated faces that change with the weather. | **done** 2026-09-15 |
| 18 | Posters for what you watch | When the Mac plays an episode, the show's poster (The Movie Database) instead of nothing. | **done** 2026-09-15: brain/posters.py, the reporter's X-Mac-Show header, a Posters page in the app; waiting for the key and a reporter restart |

## Games

All games keep their board in the brain, so every phone sees the same board
and the wall draws it. Voice goes through the phone's own speech recognition
when the app is open (biased to the valid words), and through the wall's ears
otherwise. Puzzles are our own: local generators for the word and number
games, Claude for Connections sets and crossword clues.

| # | Game | Notes | State |
| --- | --- | --- | --- |
| 19 | Wordle | Five-by-six grid, spoken whole-word guesses. | planned |
| 20 | Connections | Four groups of four; Claude writes the sets. | planned |
| 21 | Sudoku | On the phone by touch, on the wall as the grid; voice optional. | planned |
| 22 | Spelling Bee | Seven letters, one in the middle, say words. | planned |
| 23 | Letter Boxed | Twelve letters round a square, the wall draws the lines. | planned |
| 24 | Strands | Letter grid with a theme; say a word, the wall lights its path. | planned |
| 25 | Mini crossword | Five-by-five, clues on the phone, answers by voice. | planned |
| 26 | Contexto | Guess the secret word by meaning; ranks from a local word file. | planned |
| 27 | Heardle | The phone plays the first seconds of a song; say it; the sleeve is the reveal. | planned |
| 28 | Sliding picture puzzle | A sleeve scrambled into sliding blocks; slide them back. | planned |
| 29 | Cover reveal | A sleeve sharpens over thirty seconds; first to name it wins. | planned |
| 30 | Twenty questions with knocks | Knock once for yes, whistle for no; Claude guesses. | planned |
| 31 | AI pictionary | The image creator draws a secret word; guess by voice. | planned |
| 32 | Pub quiz | Claude writes a round on a theme; voice answers; scoreboard. | planned |
| 33 | Whistle bird | Pitch of your whistle sets the bird's height. | planned |
| 34 | Reaction knock | Red, then green, knock; milliseconds on the panel. | planned |
| 35 | The arcade | Pong with phones as tilt paddles; snake and tetris on the remote. | planned |

## The picture, later

**A receiving card instead of the bonnet.** The panels are driven from the
Pi today: 64 brightness slots per scan, dithered in time to fake the levels
between, and the dark end of a sleeve breaks into single primaries in any
photo. A Colorlight 5A-75B ($26) takes the picture over Ethernet and scans
the same panels itself at kilohertz rates with 12 to 14 bits of greyscale,
so shadows are shadows and the renderer, the library patches and the panel
tuning knobs retire. On the nine-panel sin:bliss simulation the LEDs left
showing a lone primary go from 6,890 to 202. Not started; flagged
2026-09-15 after the temporal dither shipped. The whole plan, parts and the
one Windows hour it needs are in docs/COLORLIGHT-PLAN.md.

## Dropped along the way

Kept here so they are not pitched twice: the room decides, room presence,
side awareness, pulse in time, the lathe, dust in the lead-in, platter lock,
ring wear, developing, sound diary, exposure, rattle, stepping back, whistle
language, applause, noticing the house, instrument faces, halo swell,
HomeKit remote buttons, answers through a HomePod, teach by telling, notes
on records, an alarm that listens, home and away from Apple, skip alarm,
stylus hours, crackle score, lyrics in your language, ambient by
description, name that record, set list card, lyric blanks, the year game,
Bop It, rhythm Simon, hush, Countdown, Picross, Mastermind, chess by voice,
Codenames, Taboo.
