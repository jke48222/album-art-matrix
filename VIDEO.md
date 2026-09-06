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
- **The picture is decoded on the wall,** by ffmpeg, from the smallest
  stream there is (144p, already four times the panel's pixels), cropped
  square, area-scaled to 64 px, sharpened a touch, at 15 frames a second.
  Twenty seconds of 144p costs a third of a second of one core. ffmpeg runs
  at nice 10 on its own thread and writes raw frames down a pipe; the reader
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

## What it does not do

- Live streams (there is no file to make the sound from).
- Videos whose sound would not fit in memory (over 80 MB of audio).
- Play without the phone when sound is on: the wall waits at "ready" for
  the phone's clock. Sound off plays at once.
