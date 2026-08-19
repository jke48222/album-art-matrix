# Pi setup — flash to first light

## 1. Flash the SD (on the Mac)
Raspberry Pi Imager → CHOOSE DEVICE: Raspberry Pi 5 → CHOOSE OS: **Raspberry
Pi OS Lite (64-bit)** → ⚙️ Edit settings:
- hostname: **album-matrix**
- username: **pi** (the systemd unit and deploy.sh assume it)
- your Wi-Fi credentials
- Services tab: enable SSH, public-key auth (paste your key)

Boot the Pi on its official 27 W USB-C supply. Wait ~90 s, then:
`ssh pi@album-matrix.local`

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

## Troubleshooting
- **Interleaved / scrambled rows:** flip the bonnet's **E switch** (E on IDC
  pin 4 vs 8; the #3649 panel documents a non-standard E position — the
  switch exists for exactly this).
- **Nothing at all:** ribbon in the panel's INPUT (not OUTPUT)?
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
