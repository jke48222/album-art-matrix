# AirPlay to Wall

Choose Wall in the iPhone or Mac AirPlay picker. It receives the stream
silently and follows its title, artist, cover and progress. The owner has
no AirPlay speakers yet, so the output is stdout discarded by the brain.
When speakers are added, select them alongside Wall in the Music AirPlay
group picker. There is no sound from the panel and no audio is recorded.

## Isolated installation

Run on the Pi:

```sh
bash /home/pi/wall-codex/pi/install-airplay.sh --packages
```

The script uses sudo for Debian development packages and a narrow
`cap_net_bind_service` capability on `wall-codex/bin/nqptp`. This lets its
unprivileged process use UDP 319 and 320. The owner completed this step.
Shairport Sync 5.5.2 AirPlay 2 and NQPTP now live inside the Codex tree.

Pinned versions:

- shairport-sync `7bad231c18368dbd26f298577f6210e36e4b0797`
- nqptp `c925f27c1fd12e4033ac477e5a405969b0b0260b`

The build uses ALSA, stdout, soxr, Avahi, OpenSSL, AirPlay 2 and the metadata
pipe. It installs no shared system service or global receiver binary.
Sources stay in this checkout's vendor directory. The brain launches its
own two helpers only while `[features] airplay = true`, and uses a parent
supervisor to stop them after a SIGKILL restart. Switching off ends both
helpers and removes the cached cover. Rebuilding overwrites the same local
binaries and reapplies the capability. Do not run another nqptp or PTP
service simultaneously: those timing ports are exclusive.

For a DAC, set `[airplay] output = "alsa"` and configure the Pi's default
ALSA output for that DAC. For this owner's silent setup use `"stdout"`.
The pipe clock defaults to 44100 ticks per second, independently of the
receiver's output sample rate. `sample_rate` can override a sender with a
different metadata clock. The artwork hostname defaults to album-matrix.local;
set `host` if that name is different on your network.

## Display and phone

The source always follows phone and precedes ears in the chain. Metadata
batches commit together, track IDs hash title/artist/album, progress handles
32-bit wrap and freezes when paused. Artwork is normalized to JPEG on the
pipe worker and served at `/art/airplay.jpg` with a content hash in its URL.
Missing covers let the source chain keep another usable sleeve. The native
receiver is expected to deliver metadata promptly; first-cover timing is
not yet measured against a real Apple sender.

Services includes an AirPlay group showing Waiting, Ready, connected-device
name or an installation/runtime error. `/services.airplay` reports name,
running, enabled, connected_from, last, problem and output. No keys are
needed. Existing sleeve faces handle both wall sizes through the normal
pipeline; this feature introduces no new panel layout.

The current cover alone is cached in a private temporary directory, with
no music or metadata history beyond the existing journal. Graceful stop
removes it; after a hard process kill a stale temporary directory can remain
until the OS clears temporary files. Offline tests use a constructed stream
matching the upstream XML protocol, not a recorded live session. They cover
fragmentation, grouped names, pause, progress, rollover, images, malformed
items and feature-off behavior. Feature-on startup and feature-off cleanup
were verified on the Codex Pi. Live AirPlay grouping and recorded-pipe
acceptance remain pending an Apple sender selecting Wall.

Upstream primary references: [build instructions](https://github.com/mikebrady/shairport-sync/blob/master/BUILD.md),
[metadata implementation](https://github.com/mikebrady/shairport-sync/blob/master/metadata/core.c),
[NQPTP timing requirements](https://github.com/mikebrady/nqptp).
