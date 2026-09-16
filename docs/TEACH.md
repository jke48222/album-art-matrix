# Teach the wall a song

When a player names a song and the microphone hears the room, the wall can
learn a twenty-second sample. If the online recognizer misses three times,
it can also look for that exact artist and title's iTunes preview. The
next time it hears the recording it tries its own library first. Turn on
`[features] teach = true` in the active build, then use Hearing's Taught
songs controls. Teach by ear defaults on, but does nothing until the feature
is enabled. No microphone audio is written to disk.

The library lives in `~/.config/album-art-matrix/olaf/`. `library.json` keeps
title, artist, album, sleeve URL, duration, ISRC when known, learning method,
added time and match count. `db/` is Olaf's native LMDB fingerprint database.
Per-song CSVs keep fingerprint hashes and time/frequency points, so a song
can be erased without retaining its recording. These files remain until
forgotten or cleared from Hearing. A forgotten song will not be automatically
relearnt during the current process. Clear deletes the native database and
all fingerprint CSVs. Queued older teaching work is discarded on a wipe.

## Build and installation

Run `pi/install-olaf.sh` in each checkout that needs it. On the Pi the exact
command is `/home/pi/wall-codex/pi/install-olaf.sh`. It needs git, a C compiler,
make, and ffmpeg. ffmpeg already ships with the wall's video support.
No new Python runtime dependency is required. For tests only:

```sh
/home/pi/wall-codex/.venv/bin/pip install pytest
```

This build uses Olaf, not audfprint. The installer pins upstream revision
`532f1991ba170b39d2156b43935428814e833614`, keeps its complete source and
AGPL license in `vendor/Olaf`, and compiles the native C core as `bin/olaf`.
The upstream source is [JorenSix/Olaf](https://github.com/JorenSix/Olaf).
The brain calls its `store`, `print`, `query` and `name_to_id` CLI commands.
The newer Zig convenience CLI is not needed for in-memory raw audio.
`bin/olaf-forget` links the same native database implementation and is
AGPL-3.0-or-later, with source in `pi/olaf_forget.c`.

The reproducible installer applies four compatibility fixes to the pinned
source: use `OLAF_DB_ROOT` to select this feature's database without changing
HOME; link `olaf_fft.c` in the core target; use GNU C11 so strdup is declared
on the Pi's compiler; and supply metadata output to print mode and flush its
final fingerprint batch. The last two print fixes prevent a crash and
incomplete fingerprint erasure. No recognition algorithm parameters change.

## Timing, limits, and verification

The lookup subprocess has a one-second limit. A missing engine, timeout or
busy library writer falls through quietly to Shazam. Room teaching waits
for 20 seconds of a stable named source and audible room. A source change,
silence or feature disable discards the partial sample. Source snapshots
older than eight seconds are not trusted. Catalogue learning starts after
three misses and retries a missing preview no more than hourly per song.
The worker queues at most two jobs and retains only the current 20-second
sample plus those jobs in memory.

The native store, noisy-query, unrelated-query, erase, reload, capture-limit
and miss-trigger tests pass on the Mac and Pi. The complete 40-test suite
passed on the Pi in 1.86 seconds. A synthesized noisy-query took 20 ms on
the Pi. `python -m scripts.teach_qa` also verified the known gap:

- Tower of Roses by MALI, iTunes preview, 168 aligned matches.
- Store: 109 ms; noisy nine-second excerpt query: 20 ms on the Pi.
- The test used a temporary fingerprint library, erased it and retained no audio.

See `docs/verification/mali-preview-pi.txt` and `pi-tests.txt` for output.
This proves catalogue matching, not microphone recognition of the physical
MALI single. Sparse pure tones are fragile under noise; the synthetic fixture
includes a repeatable noise floor as well as changing chords. A single-song
latency result is not a measurement of a collection with hundreds of songs.

## API and phone

`GET /teach` lists the library, engine availability, feature state, loading
state and any error. `POST /teach/forget {"id": "..."}` and `POST /teach/clear
{}` accept work with HTTP 202. Poll the list until busy is false. Wiping works
when the feature is disabled. Hearing shows the same list, supports swiping
to forget, and has a Clear action with confirmation.

Deploy `brain/teach.py`, `brain/main.py`, `brain/control.py`,
`brain/nowplaying/ears.py`, `brain/nowplaying/listenbrainz.py`, `brain/tuning.py`,
`pi/install-olaf.sh`, `pi/olaf_forget.c` and the tests to their exact paths in
`wall-codex`, then build the engine and restart the live Codex brain. The
ListenBrainz reader fix prevents this wall's vinyl announcements from
becoming a streaming-source feedback loop. Preserve the Pi's config and
HomeKit pairing. The separate app command is `tessera/Tools/install.sh codex`.

There is no new visual face: recognized art uses the existing sleeve
pipeline at 64 and 192. No pixel regions are added. The phone simulator build
passes; the physical install needs an Xcode signing account and a Codex App
Group provisioning profile. Xcode currently reports No Accounts.
