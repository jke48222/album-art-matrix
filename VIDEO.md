# Video on the wall

Paste a YouTube link in Tessera (the Video tile), and the wall plays it.

## Where the work happens

- **The wall fetches.** `brain/video/youtube.py` asks YouTube's player
  endpoint the way the iPhone app does. That client's answer carries plain
  stream URLs, no signature puzzle, and from the wall they download at full
  speed when asked for in byte ranges (measured 2026-09-06: 3 MB/s ranged,
  32 KB/s whole). It is YouTube's arrangement to change; when it does, the
  resolver changes, and yt-dlp is the fallback (a Python package plus a
  JavaScript runtime such as deno, which YouTube support in yt-dlp now needs).
  Any other link ffmpeg can read (an mp4, a webm, an HLS playlist) goes
  through `brain/video/direct.py`.
- **The picture is decoded on the wall,** by ffmpeg, from a 240p stream
  (cropped square that is 240 px, and the last step down wants something to
  throw away), Lanczos-scaled to 192, then finished in Python exactly as an
  album sleeve is: Lanczos to 64 and the same unsharp, at 15 frames a
  second. It used to be a box filter straight from 144p, which the art
  pipeline's own notes call mud, and it looked like it.
- **A dark clip is lifted once,** at the start, by a gamma read from its own
  first second. Film is graded for a dark room and sits below the level a
  64 px panel can hold steadily; under that the renderer dithers in time and
  the picture becomes a field of single LEDs blinking red and green. The
  lift is decided once, not per frame, so the wall does not breathe at every
  cut.
  ffmpeg runs at nice 10 on its own thread and writes raw frames down a pipe; the reader
  keeps a window of two minutes ahead of the playhead and twenty seconds
  behind (about 26 MB) and lets ffmpeg block on the pipe beyond that. A
  two-hour video costs no more memory than a two-minute one.
- **The main loop never waits.** It asks the player for the frame of the
  moment and gets it or the last one it had. While a video is on, the slow
  now-playing poll (two seconds on the Pi) is skipped, so the picture never
  freezes for it.
- **The sound plays on the phone.** The wall has no speaker. The wall
  downloads the audio track (AAC in mp4, 130 kbps, or 50 kbps past twenty
  minutes) into `/dev/shm` and serves it with byte ranges at `/video/audio`;
  the phone plays it with AVPlayer through whatever it is connected to
  (speaker, AirPods, AirPlay), and every second posts where it is to
  `/video/clock`. The phone is the clock: the wall shows the frame for the
  moment the phone names. Pause on the phone and the wall pauses; scrub and
  the wall follows (a scrub outside the decoded window restarts ffmpeg at
  the new place). With the sound off, the wall keeps its own time.
- **When the video ends,** or is stopped, or another face is chosen, the
  player stops, the file is deleted, and the wall goes back to the face it
  was showing.

## The API

    POST /video          {url, sound?, loop?}   fetch and play
    GET  /video          status, title, position, buffered, sound progress
    GET  /video/audio    the sound, m4a, byte ranges
    POST /video/clock    {t, playing}           the phone's player says where it is
    POST /video/control  {action: play|pause|seek, t?}   the wall's own clock
    POST /video/stop

`GET /state` carries the same under `video` while one is on.

## Sharing to the wall

The share sheet has a Tessera in it (`tessera/TesseraShare/`): from the
YouTube app, Safari, or a link AirDropped to the phone, Share, then
Tessera. The sheet carries the link into the app through its own scheme
(`tessera://video?url=`) and the app puts it on the wall, the way a typed
link goes; the phone is the speaker, so the app has to be open anyway.

A video from the library reaches the app as a document: Tessera declares
itself an opener of movies, so "Open in Tessera" (from Photos, Files, or
an AirDropped file) lands the file in the app. The app makes a small
square H.264 copy of the picture (160 px, 15 fps, about 300 kbps:
`VideoHandoff.swift`), sends it to `POST /video/upload`, and plays the
sound from the original; the wall waits for the phone's clock as it does
for a link.

The share sheet could take library videos too, by handing the file across
an App Group. That needs the extension's own App ID registered with the
App Groups capability, which the command line can only do with an Apple ID
signed into Xcode, so it is left for a session with Xcode open.

AirDrop, AirPlay and Bluetooth are not routes to the panel. AirDrop only
runs between Apple devices, so the Pi cannot be a target (AirDrop to the
phone, then Share to Tessera, is the two-step version). An AirPlay receiver
on the Pi is a large third-party stack that mirrors a whole phone screen in
1080p H.264, which the 1 GB Pi 5 has to decode in software, and the YouTube
app will not hand video to one anyway. Bluetooth carries no video, and the
sound already plays on the phone.

## YouTube's token wall, and yt-dlp

Some videos, seen so far on big label releases, come back from every client
identity the wall asks with streams that serve about the first megabyte and
then answer 403 to everything, with no refill (measured 2026-09-06 on
FyS5dAywkEo, from the Pi and the Mac alike, across eleven client
identities). That is YouTube's signed-in "proof of origin" token being
enforced, and the wall cannot mint one.

So there are two ways in, and the wall tries them in order:

1. **The wall's own resolver** (`youtube.py`), about a second. The proof
   that YouTube will really serve the video is the picture arriving whole,
   so that download happens during resolution; pieces start at a megabyte
   and halve on a refusal, which handles servers that merely cap the piece
   size.
2. **yt-dlp** (`ytdlp.py`), when the first is refused. It runs as its own
   process at nice 10, downloads the picture and the sound itself into the
   RAM disk, and hands back two files. It reaches these videos through a
   visionOS client identity carrying a visitor id, which is exactly the
   kind of thing that changes month to month and exactly why the job
   belongs to a project that tracks it. Measured on the Mac: the refused
   video plays, ready in 7.3 s against 1.8 s for the fast path.

`GET /video` says which got it, under `by`. `GET /health` says which
version of yt-dlp is installed, or null.

**No JavaScript runtime is installed.** yt-dlp warns that YouTube
extraction without one is deprecated, but the client it reaches these
videos with needs no player script, so deno's 80 MB and V8's appetite stay
off a 1 GB board. If a video ever does need one, yt-dlp says so and the
wall reports it; installing deno is then the next step.

Install or update with `pi/install-ytdlp.sh`, which ends by fetching the
known-refused video as its own proof.

## What it does not do

- Live streams (there is no file to make the sound from).
- Videos whose sound would not fit in memory (over 80 MB of audio).
- Play without the phone when sound is on: the wall waits at "ready" for
  the phone's clock. Sound off plays at once.
