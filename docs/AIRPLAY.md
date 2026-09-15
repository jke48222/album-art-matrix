# AirPlay to the wall

The Pi becomes an AirPlay receiver called **Wall**. Pick it in the AirPlay
menu on an iPhone, a Mac or an Apple TV, alone or in a group with a real
speaker, and the wall is handed the exact title, artist, album, artwork and
position of whatever plays. No account, no key, no guessing. The wall does
not have to make a sound.

The brain's side is built (`brain/nowplaying/airplay.py`): it reads
shairport-sync's metadata pipe and answers in the source chain right after
the phone and before the ears. What is left is installing shairport-sync,
which needs sudo on the Pi.

## Install

Debian trixie ships shairport-sync 4.3.7. On the Pi:

```bash
sudo apt install shairport-sync
```

## Configure

Edit `/etc/shairport-sync.conf`. Three sections matter; the file's own
comments explain the rest.

```
general =
{
  name = "Wall";
  output_backend = "dummy";   // "alsa" instead to play through a USB DAC
};

metadata =
{
  enabled = "yes";
  include_cover_art = "yes";
  pipe_name = "/tmp/shairport-sync-metadata";
  pipe_timeout = 5000;
};

sessioncontrol =
{
  allow_session_interruption = "yes";
  session_timeout = 20;
};
```

`dummy` receives the stream and discards the sound, which is what a wall
wants when the room's speaker is in the same AirPlay group. For a DAC on
the Pi use `alsa` and set `alsa = { output_device = "hw:1"; };` to the card
`aplay -l` lists.

Then:

```bash
sudo systemctl enable --now shairport-sync
```

The brain's config needs nothing: `[airplay]` in `config.toml` can name a
different pipe, and `[features] airplay = false` turns the source off.

## Check

- `ls -l /tmp/shairport-sync-metadata` shows a pipe (`p` at the start of
  the mode) once shairport-sync has started.
- `curl -s localhost:8788/services | python3 -m json.tool` has an `airplay`
  block: `running` (the process), `pipe_exists`, `reading` (the brain has the
  pipe open; it opens the moment a stream begins), `state`, and
  `connected_from` (the device's name) while something plays.
- Play a song to Wall from an iPhone. The brain logs
  `[main] Frank Ocean — Nights (Blonde)` and the sleeve goes up as soon as
  the artwork arrives, a beat after the title. The Services page on the
  phone shows AirPlay's state.

## AirPlay 2 and nqptp

Debian's 4.3.7 is an AirPlay 2 build (its help text names port 7000 for
AirPlay 2), and an AirPlay 2 build wants `nqptp`, the timing daemon, running
beside it; without it shairport-sync warns at start and AirPlay 2 sessions
do not work. Debian has no nqptp package, so it is built from source, which
takes a few minutes on the Pi:

```bash
sudo apt install --no-install-recommends build-essential git autoconf automake libtool
git clone https://github.com/mikebrady/nqptp.git
cd nqptp
autoreconf -fi
./configure --with-systemd-startup
make
sudo make install
sudo systemctl enable --now nqptp
sudo systemctl restart shairport-sync
```

With nqptp up the wall can sit in a group with HomePods and other AirPlay 2
speakers and is picked from the Home app as well as the AirPlay menu. The
metadata pipe and the brain's reader are the same either way.

## Artwork

The artwork arrives as bytes on the pipe. The brain keeps the last few and
serves them at `GET /art/airplay/<key>.jpg` (or `.png`) on the control port,
which is the `art_url` in the journal, so the phone's history and the
room's sleeve fetch it the same way they fetch a streamed song's cover.
