# Album-Art Matrix

A gallery-finish LED wall showing the currently-playing album cover as a
spinning CD, rotating in time with the music. Camera-flicker-free (9600 Hz,
64-bit BCM via bitslip6/rpi-gpu-hub75-matrix on a Pi 5).

**Current stage: S1** — Pi 5 + one 64×64 P2.5 panel + Apple Music.
Deliverable: a photo of the panel next to the album cover on the phone, and
they match. (Research: PASS-3 §19; staged plan lives there.)

## Layout
| Path | What |
|---|---|
| `PARTS.md` | The S1 order list (with links) |
| `config.toml` | Live config (from `config.example.toml`; no keys needed) |
| `brain/` | Python: now-playing adapters → art pipeline → frame sinks |
| `brain/nowplaying/applemusic.py` | PRIMARY: Music.app + MusicKit account tiers |
| `brain/nowplaying/spotify.py` | Dormant but complete (PKCE OAuth) |
| `brain/art/pipeline.py` | Lanczos+unsharp → linear → per-channel WB → re-encode |
| `brain/sinks/` | `mac_preview` (dev) / `pi_renderer` (FIFO to the wall) |
| `renderer/` | C daemon linking librpihub75_gpu: FIFO frames → 64-bit BCM |
| `pi/` | `PI-SETUP.md` (flash→first light), `bootstrap.sh`, systemd unit |
| `scripts/` | mac_reporter (Pi polls it), Pico colorimeter, WB procedure, smoke test |
| `deploy.sh` | rsync to the Pi (+ `--bootstrap` first time) |

## Now-playing: how the Apple Music adapter works
Apple has no server-side currently-playing API, so the adapter mirrors the
proven `now-playing.jsx` Übersicht widget, in tiers:
0. `now-spinning` state.json (Group Container) when present and playing
1. **osascript → Music.app** — real-time local playback, incl. AirPlay from the Mac
2. **MusicKit account recently-played** (`~/.config/widgetsuite/musickit-fetch.py`)
   — catches playback on the **iPhone** / any device on the account

Artwork is URL-based (MusicKit catalog `--cover`, then the iTunes Search
ladder) and cached by `brain/art/fetch.py`. On the Pi, tiers 0–2 run on the
Mac inside `scripts/mac_reporter.py`; the Pi polls `http://<mac>.local:8787`.
Two consequences to know about: the wall shows the account's *last-played*
sleeve when nothing is actively playing (a feature, for an art piece), and if
the Mac is asleep the Pi sees nothing — S3's acoustic fingerprinting removes
the Mac from the loop entirely.

## Weekend runbook
1. **Order** everything in `PARTS.md`.
2. **Try it now (Mac, before any hardware):**
   ```
   .venv/bin/python -m brain.main --config config.toml
   ```
   Play something (Mac or iPhone) — `preview_out/panel.png` becomes the
   current sleeve at 64 px. No accounts, no keys: it reuses the widgetsuite
   MusicKit setup.
3. **Pi arrives:** `pi/PI-SETUP.md` top to bottom (flash → `./deploy.sh
   --bootstrap` → reboot → wire → first light).
4. **White balance:** `scripts/WB-PROCEDURE.md` (Pico 2 W + TCS34725), then
   the deliverable photo.

## Architecture notes (don't architect out the later stages)
- **Now-playing** is a `SourceChain`; S3 adds acoustic fingerprinting
  (Chromaprint→AcoustID→MusicBrainz→Cover Art Archive) as the bulletproof
  floor ahead of everything, then Last.fm, then local player. Spotify stays
  dormant in the chain, one config line from live.
- **Analysis (S4)** runs locally on real audio: SuperFlux onsets + BTrack
  realtime beat (librosa.beat is offline-only), plus a cached per-track beat
  grid so visuals ANTICIPATE structure — works for vinyl too.
- **Renderer** already speaks "frames over a FIFO", so S5's shader/spinning-CD
  work replaces the frame producer, not the display path (bitslip6 runs
  ShaderToy-style GLSL natively).
- **Power (S2):** injection per panel from a bus bar (14 AWG, 10 A blade fuse
  each), NTC inrush limiter (SL22 10005) in the AC line, star ground at PSU.
