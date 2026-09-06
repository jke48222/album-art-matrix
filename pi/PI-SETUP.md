# Pi setup — flash to first light

**Wiring map:** [wiring.svg](wiring.svg) — every part, every cable, all three
configurations (S1 / bench rig / 9-panel wall). Keep it open at the bench.

## 1. Flash the SD (on the Mac)
Raspberry Pi Imager → CHOOSE DEVICE: Raspberry Pi 5 → CHOOSE OS: **Raspberry
Pi OS Lite (64-bit)** → ⚙️ Edit settings:
- hostname: **album-matrix**
- username: **pi** (the systemd unit and deploy.sh assume it)
- your Wi-Fi credentials
- Services tab: enable SSH, public-key auth (paste your key)

Boot the Pi on its official 27 W USB-C supply. Wait ~90 s, then:
`ssh wall` (the alias in `~/.ssh/config`, pinned to the Pi's address because
`album-matrix.local` resolves inconsistently on this network)

## 2. Bootstrap (from the Mac)
```
./deploy.sh --bootstrap
```
Installs build deps, clones + builds bitslip6 with `-DADA_3HAT=1` (Adafruit
Triple Bonnet mapping), appends `isolcpus=3 nohz_full=3` to
/boot/firmware/cmdline.txt, builds the renderer, sets up the python venv.
**Reboot when it tells you to.**

## 3. Wiring (everything POWERED OFF — never hot-plug HUB75)
1. Riser header on the Pi's GPIO (clears the Active Cooler), Triple Bonnet on
   top.
2. IDC ribbon: bonnet **port 1** → panel **INPUT** connector (the silkscreen
   arrow points INPUT → OUTPUT; data flows with the arrow).
3. Panel power harness (fork lugs) → LRS-50-5 screw terminals: red → +V,
   black → -V.
4. Mains pigtail into the LRS-50-5 input terminals — US cord colors:
   black → L, white → N, green → ⏚ (earth; never skip). Wire it UNPLUGGED,
   no exposed copper outside the terminals, tug-test each wire, keep the
   clear terminal cover on. Check finger clearance before
   plugging in.
5. Grounds: for ONE panel the IDC ribbon carries the logic ground reference.
   (S2 scale: star ground at the PSU — a weak Pi ground is the #1 cause of
   random glitching pixels.)
6. The Pi keeps its own 27 W USB-C supply. Two supplies, one shared ground.
   Never feed the panel from the Pi.

## 4. First light
```
# on the Mac — the Pi polls this for Apple Music now-playing:
python3 scripts/mac_reporter.py          # or the launchd plist in scripts/

# Pi, shell 1:
~/album-art-matrix/pi/run_renderer.sh
# Pi, shell 2:
cd ~/album-art-matrix && .venv/bin/python -m brain.main --config config.toml
```
Pi-side config.toml needs two edits (deploy.sh copies the Mac file verbatim):
`[sink] type = "pi"` and
`[applemusic] endpoint = "http://Jalens-MacBook-Pro.local:8787"`.

Play a record. Take the photo.

## 5. Panel QA, and the wall

First light proves one panel. The other nine are unknown, and the faults that
matter cannot be fixed once the wall is assembled.

The panels are proved a chain at a time, in the arrangement they will live
in, off the wall supply rather than the bench one. The whole sequence, from
the supply's first check to nine panels lit and the phone rebuilt, is
**[docs/WALL-BUILD.md](../docs/WALL-BUILD.md)**.

The shape lives in one file on the Pi:

```
echo 3x1 > ~/album-art-matrix/wall     # one port, three panels
echo 3x3 > ~/album-art-matrix/wall     # the whole wall
sudo systemctl restart album-art-renderer
```

`run_renderer.sh` reads it and works out the rest (`-p` ports, `-c` chain,
`-x`/`-y`, the panel type map). Rows are ports on the bonnet, columns are
the panels chained off each port, and every port carries the same number.
The brain's `[panel]` size and `[wall]` block in the Pi's config.toml have to
agree with it; it prints what it believes at startup.

## Troubleshooting
- **Interleaved / scrambled rows:** flip the bonnet's **E switch** (E on IDC
  pin 4 vs 8; the #3649 panel documents a non-standard E position — the
  switch exists for exactly this).
- **Nothing at all:** ribbon in the panel's INPUT (not OUTPUT)?
- **`mlockall failed` and the renderer exits at once:** the user's lockable-memory
  limit is 8 MB (`ulimit -l`). Install `/etc/security/limits.d/hub75.conf`
  (`pi - memlock unlimited`, `pi - rtprio 99`; bootstrap.sh writes it) and log
  in again; the systemd unit carries `LimitMEMLOCK=infinity`. Never run
  `run_renderer.sh` by hand while the `album-art-renderer` service is active:
  two renderers on one bonnet.
- **Renderer permissions:** re-login after bootstrap (gpio/video/render group
  membership), or reboot.
- **Reporter unreachable:** Mac asleep? Firewall prompt accepted? Same Wi-Fi?
  `curl http://Jalens-MacBook-Pro.local:8787/nowplaying` from the Pi to test.
- **Dim / brown-out on white frames:** raise `-b` in run_renderer.sh
  gradually; one P2.5 64×64 pulls ~4 A at full white.
- **Custom renderer won't compile** (library API drift): compare against
  `~/rpi-gpu-hub75-matrix/example.c` and adapt renderer/art_display.c. Prove
  the panel meanwhile with the library's own binary:
  `cd ~/rpi-gpu-hub75-matrix && ./example -w 64 -h 64 -p 1 -c 1 -x 64 -y 64 -d 64 -s shaders/cartoon.glsl`

## The bottom row

The panel library ghosts each row onto the next while the row address settles,
which shows only on the bottom row (it takes the middle row's colour at the
wrap). `pi/hub75-address-guard.py` patches the library's scan loops to hold the
output off for the first four clocks of every row; run it after any fresh
checkout of `~/rpi-gpu-hub75-matrix`, then `make libgpu` there and `make -B`
in `renderer/`. The renderer links that home build ahead of `/usr/local`.

### The settle (2026-09-06)

The guard alone held only 4 clocks, about 200 ns at the Pi 5's loop speed,
and the ghost came back on a red clock whose digits cross the middle row:
the bottom row of each half shows a faint copy of the top row of the other
half while the row just left is still conducting. `pi/hub75-row-settle.py`
(run after the guard script, then `make libgpu`, then restart the renderer)
keeps the output off for a real settle after every row change, 1000 ns by
default, read from `HUB75_ADDR_SETTLE_NS`; `run_renderer.sh` takes that from
`~/album-art-matrix/addr-settle-ns`. It is dark time, roughly a fifth of the
row, so `panel-brightness` went from 160 to 200 to keep the same light (the
average current, which is what the supply sees, is unchanged). If a ghost
ever shows again, raise the settle file and restart the renderer; 0 turns it
off. The renderer's own OE jitter must stay off (`jitter_brightness = false`
in art_display.c): with it on the change lands with the output on at random.
