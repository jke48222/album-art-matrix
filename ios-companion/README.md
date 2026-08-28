# Album Wall — iOS companion

Two jobs:
1. **Real-time iPhone now-playing.** Apple has no server API for "currently
   playing" — the account tier lags by ~a track. This app reads the system
   Music player on-device (the one place that knows) and POSTs to the Mac
   reporter's `/push` endpoint, which outranks every other tier.
2. **Wall remote.** Mode (Art / Spin / Ambient / Off), brightness, spin rate,
   ambient effects + colors — straight to the brain's control API on the Pi
   (port 8788), no Mac in the path.

## Build it (once — you have a paid dev account, so no weekly re-sign)

1. Xcode → **File > New > Project > iOS > App**.
   Product Name **AlbumWall**, Interface SwiftUI, Language Swift.
   Save it anywhere (e.g. `~/fun-project/album-art-matrix/ios-companion/`,
   "Create Git repository" off).
2. Delete the generated `AlbumWallApp.swift` and `ContentView.swift`, then
   drag the four files from `ios-companion/AlbumWall/` into the project
   navigator (check "Copy items if needed" OFF if you dragged from this repo —
   editing in place keeps the repo the source of truth).
3. Target → **Signing & Capabilities**:
   - Team: your dev account team.
   - **+ Capability → Background Modes** → check **Audio, AirPlay, and
     Picture in Picture** (this is what lets the silent-audio keepalive run).
4. Target → **Info** tab, add three keys:
   - `Privacy - Media Library Usage Description` →
     "Reads what's playing to show it on the album wall."
   - `Privacy - Local Network Usage Description` →
     "Talks to the album wall and the Mac reporter on your network."
   - `App Transport Security Settings` (dict) → `Allows Local Networking` = YES
5. Plug in the iPhone, pick it as the run target, **Run**. First launch
   prompts for media library + local network access — allow both.

## Using it

- The reporter (`scripts/mac_reporter.py`) must be running on the Mac for
  pushes to land; the wall controls talk to the Pi directly and work
  regardless.
- "Push in background" keeps a muted audio session open so iOS doesn't
  suspend the app (`.mixWithOthers` — it never interrupts Music). Costs a
  little battery; toggle it off if you only care while the app is open.
- Hosts are editable at the bottom of the app if names ever change
  (defaults: `Jalens-MacBook-Pro.local:8787`, `album-matrix.local:8788`).

## Wire protocol (for future me)

`POST /push` to the reporter: `{track, artist, album, id?, playing,
progress_ms, duration_ms}` — no art field; the reporter runs its own
MusicKit/iTunes art ladder. 40s TTL, 15s heartbeat while playing.

`GET|POST /state` on the Pi: `{mode, brightness, rpm, effect, color,
color2, speed}` + read-only `now_showing`. Partial POSTs fine; invalid keys
come back in `rejected`.
