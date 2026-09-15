# The wall on a Colorlight 5A-75B

A receiving card is what sits inside a commercial LED sign: an FPGA that
speaks every panel driver chip's protocol, scans the panels at kilohertz
rates with 12 to 14 bits of greyscale, and takes its picture over Ethernet.
Putting one between the Pi and the panels replaces the bonnet, the bit-bang
library and its patches, the renderer, its dither and its brightness tricks,
with a $26 card and one packet format.

## Before and after

|                      | today: Pi 5 + Triple Bonnet                          | with the card                                           |
|----------------------|------------------------------------------------------|---------------------------------------------------------|
| who scans the panels | the Pi, core 3 isolated, 100% busy                   | the card's FPGA                                         |
| refresh              | 146 frames/s, 64 slots each                          | 1920 Hz and up, set in the card                         |
| steps per colour     | 64 linear, dithered in time below that               | 12 to 14 bit, gamma applied by the card                 |
| dark colours         | break into primaries under 1 slot, dither shimmers   | shown as sent                                           |
| brightness           | applied in the renderer, costs steps                 | one packet, lossless                                    |
| link                 | 40-pin riser, bonnet, 3 ribbons                      | one Ethernet cable, 3 ribbons from the card             |
| Pi load              | a core for the scan, a fifth of another for dither   | a few percent for packets                               |
| moving parts         | library patches, renderer service, FIFO, tuning knobs| the sink, the card's saved config                       |
| fallback             |                                                      | `[sink] type = "pi"` brings the bonnet path back        |

The panels do not change. FM6124 chips are what the card calls "normal
chips"; their greyscale behind the card is the card's, not the chip's.

## Shopping list

- Colorlight 5A-75B, v8: $26 at Wired Watts, also Amazon (B07BRF3PSX).
  Ask for or check firmware 11.x: the brightness packet is ignored on old
  firmware (FPP forum).
- One short Cat 6 patch cable. The Pi's own Ethernet port is free (the Pi
  is on Wi-Fi), so no adapter.
- A Windows machine for an hour, with a gigabit Ethernet port or a USB
  adapter, running LEDVISION 8.8 (the vendor's tool; the card is configured
  once and keeps it in flash). A Windows VM on the Mac with the adapter
  bridged usually works with Npcap; a borrowed laptop always works.
- Power: the card takes 3.3 to 6 V at 0.6 A. One fused tap off the 5 V
  bus bar (a 2 A blade fuse), into either of its two power inputs.
- Four standoffs in the back cavity, near the bus bars, where the ribbons
  can reach the three chains. Check the card's dimensions on the listing
  before drilling; they are not verified here.

## Step 1: teach the card the panel (Windows, once)

1. Card powered, one panel on its first HUB75 output, Ethernet from the
   card straight to the PC. Nothing in between: no switch.
2. LEDVISION 8.8. Control, Screen Size: 64 by 64.
3. Control, LED Screen Settings, password 168. Sending Device tab: choose
   "Net Card", pick the network card, Detect Receiver Cards. The card
   answers with its firmware version.
4. Receiver Parameters tab. This is the panel's description: module 64
   wide, 64 high, 1/32 scan, driver chip FM6124 (a normal chip), one module
   per chain for now. Load the nearest 64x64 indoor preset if there is one;
   otherwise run the Smart Settings wizard, which lights patterns on the
   panel and asks what you see, and derives scan, decode and polarity from
   the answers. Waveshare publishes no receiver parameters for this panel,
   so the wizard is the expected route. Push the refresh multiplier as high
   as the dialog allows; if it complains, lower DCLK a step. Gamma 2.2.
5. Receiver Mapping tab: one card, 64 by 64.
6. Save to Devices, then Save to Receivers. Unplug the PC; it is not needed
   again until the wall changes shape.

For the nine-panel wall, come back once: chain length 3 on each of three
outputs, Receiver Mapping 192 by 192 with the outputs in the order the
ribbons take. That replaces `[wall] order` and `rotate` in config.toml.

## Step 2: first light from the Pi

1. Card's Ethernet to the Pi's eth0. `sudo ip link set eth0 up`. No IP
   address: the picture goes as raw Ethernet frames to a fixed MAC.
2. In the brain's venv, `pip install colorlightpy` (or clone
   kostaman/LED_Matrix-1). Run its test pattern with sudo. The panel should
   light at the card's refresh.
3. Phone camera, slow motion: no rolling bands.
4. A 16-step grey ramp: every step distinct, including the darkest two.

## Step 3: the brain's new sink

- `brain/sinks/colorlight.py`, a FrameSink like the others. `show()` sends
  one frame header (EtherType 0x0107) and then row packets (0x5500 and
  0x5501, at most 391 bytes of pixels each: a 64-pixel row is one packet, a
  192-pixel row is two), from an AF_PACKET socket bound to eth0. A
  brightness packet (0x0aXX) goes out whenever the panel brightness changes,
  carrying the cap and the three colour multipliers. The measured
  white-balance gains stay in the pipeline for now; they could move into
  those multipliers later.
- `config.toml` on the Pi: `[sink] type = "colorlight"`, `iface = "eth0"`.
- The unit: `AmbientCapabilities=CAP_NET_RAW` in album-art-matrix.service,
  so raw sockets work without root. One sudo.
- Tuning: nearest_colour and temporal_dither off; they exist for the
  bonnet. The preview's bytes go out as they are; the card applies gamma.
- `systemctl disable album-art-renderer`. Everything it needed stays in git.
- Budget: 192 by 192 at 60 frames a second is 384 packets a frame, about
  23,000 packets a second and 53 Mbit/s. Fine for gigabit. If Python's
  per-packet cost shows on the Pi, batch the rows with sendmmsg.

## Step 4: the wall

Three outputs, three panels each, ribbons as today from the card instead of
the bonnet. Reconfigure the card for 192 by 192 (Step 1, last paragraph).
The brain sends whole 192 by 192 frames; the phone's previews do not change.

## Risks, in order of likelihood

- LEDVISION is Windows only. A bridged VM usually passes raw frames; if it
  does not, a borrowed laptop does.
- A wrong decode or polarity in the receiver parameters shows as scrambled
  or dim rows. It is fixed in the same dialog, with the panel in front of
  you, not in code.
- Old card firmware ignores the brightness packet. Wired Watts ships recent
  cards; check the version LEDVISION reports.
- Capacity: a 5A-75B loads 131k pixels (512 by 256); the wall is 37k.
- eth0 belongs to the card. The Pi's network stays on Wi-Fi.

## Sources

Colorlight spec (normal chips, PWM chips, Shixin chips; 16 groups parallel
data): colorlight.net/colorlight-5a-75b-led-receiving-card. Price, v8,
512x256, LEDVISION steps: wiredwatts.com/colorlight-5a-75b and its indoor
P5 setup guide. Protocol (0x0107, 0x5500/0x5501, 0x0aXX, fixed MACs, 60 Hz):
hkubota.wordpress.com, winter project 2022. Senders: github mtlevine0/colorlightpy,
kostaman/LED_Matrix-1, FalconChristmas/fpp ColorLight-5a-75.cpp.
