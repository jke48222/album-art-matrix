# AirPlay to the wall

The wall is an AirPlay speaker called **Wall**. Pick it in the AirPlay menu
on an iPhone, iPad, Mac or Apple TV, alone or together with another speaker,
and the wall is handed the exact title, artist, album, artwork and position
of whatever plays, from any app. No account, no key, no guessing. The wall
makes no sound of its own.

## How it runs

- `pi/install-airplay.sh` unpacks Debian's shairport-sync 4.3.7 under
  `~/opt/shairport-sync`, with the two libraries the Pi does not have
  (libconfig11, libmosquitto1). No root: Debian builds classic AirPlay
  (`4.3.7-libdaemon-OpenSSL-Avahi-ALSA-jack-pa-dummy-stdout-pipe-soxr-...-metadata-...`),
  which needs no nqptp and no privileged port, and it announces itself
  through the avahi daemon the Pi already runs. Run the script again to
  update.
- The brain starts it (`brain/nowplaying/receiver.py`) with a config of its
  own in `~/.config/album-art-matrix/shairport-sync.conf`: the name from the
  phone, the dummy output, cover art on, the metadata pipe
  `/tmp/shairport-sync-metadata`. It restarts it when it stops, with a
  growing pause, restarts it when the name changes, stops it when the phone
  turns the speaker off, and stops it with the brain. A shairport-sync the
  system already runs is left alone and read the same way.
- `brain/nowplaying/airplay.py` reads the pipe: title, artist, album,
  length, the artwork bytes, the position, pause, resume and end, the
  sender's name. It answers in the source chain right after the phone. The
  artwork is served at `GET /art/airplay/<key>.jpg` for the phone. When a
  song arrives with no artwork (some apps send none), the sleeve is found
  by name after four seconds.

## From the phone

Settings, Services, AirPlay: whether the wall is receiving and from whom, a
switch to stop being a speaker, and the name it shows in the AirPlay menu.

## Check

```bash
curl -s localhost:8788/airplay | python3 -m json.tool
```

`receiver.running` is true and `receiver.name` is the name. Play something
to it and `state` says playing, with `connected_from` the device. From a
Mac, `dns-sd -B _raop._tcp local.` lists it as `...@Wall`.

## Tested

On 2026-09-15, on the Pi: the Mac listed it as an AirPlay speaker called
Wall, and a song played to it from an Apple device (AirPlay/980.77.1) came
through whole, title and artist read, with no fault. pyatv, a Python
AirPlay sender, is the one thing that trips it: pyatv sends raw PCM (L16),
this shairport-sync hands that to its ALAC decoder, and the decoder faults
within seconds. The brain starts the receiver again two seconds later.
Apple devices send ALAC.

## AirPlay 2

Grouping the wall with HomePods in the Home app, and choosing it there,
needs AirPlay 2: shairport-sync built from source with `--with-airplay-2`
and nqptp running beside it. nqptp listens on ports 319 and 320, which takes
root, so that build is done at the Pi with sudo, following
<https://github.com/mikebrady/shairport-sync/blob/master/BUILD.md>. The
brain's own receiver steps aside for a system shairport-sync by itself, and
the metadata pipe and its reader are the same either way.
