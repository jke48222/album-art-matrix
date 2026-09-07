# The wall, designed

`wall_model.py` builds the wall in Blender from the parts on the bench and
renders it six ways. Every number is a constant at the top of the file with
its source beside it. This page is the reasoning.

```
/Applications/Blender.app/Contents/MacOS/Blender --background \
    --python design/wall_model.py -- --out design/renders --face design/face192.png
```

## What it is

A 24 inch square of half inch plywood with a sheet of 22 gauge steel glued to
its face, both painted matte black. The nine panels hold themselves to the
steel with the magnetic feet that ship in their boxes: nothing is drilled
into a panel, and any one of them lifts off with a fingernail. The picture
lands 480 mm square in the middle, leaving a 64.8 mm black border that reads
as a mat.

A 24 inch sheet of smoked grey acrylic floats an inch in front on four black
sign standoffs, one at each corner. The standoff barrel sets the geometry:
25.4 mm off the steel, less 17.5 mm of panel and magnet, leaves the glass
7.9 mm clear of the LEDs. Off, the whole thing is a square of black glass.
On, the art is behind it and the panel frames are not visible.

Everything electrical is on the back, in the open: the LRS-350-5 low, the
two bus bars, nine inline fuse holders, the Pi 5 with its Active Cooler and
the Triple Bonnet, the inlet, the inrush limiter, the microphone and the lux
sensor. Two blocks of 1 x 3 furring under the cleat and two feet at the
bottom corners hold the board 63.5 mm off the wall, which is the gap all of
that lives in. The tallest thing back there is a bus bar with its cover on,
at 38.1 mm, so there is 25 mm to spare. A 1 x 2 strip would have left
exactly none.

The supply's fan has the whole room to breathe into, which is the one thing
an open back does better than a sealed box.

The only ornament is the app's seven by seven lattice on the bottom border,
one tile lit, a stencil and a fingertip of grey paint. It costs nothing.

About $109 over what is already on the bench. The full list, with the order
of work, is at the end of [PARTS.md](../PARTS.md).

## The upgrade path

`wall_model_walnut.py` is the same wall in a black walnut shadow box with a
black anodised reveal, brass keyed mitres, opal and smoked glazing and a
vented aluminium back. It is about four times the money and a weekend of
joinery. This carcass is what it would be built around: the steel plate, the
magnets and the electronics layout do not change, so nothing done now is
wasted if the frame happens later.

## What was taken from the atelier study

`design/atelier-v2` is a second, independent design study of the same wall
(a sculpted graphite aluminium shell with a bronze perimeter, 536 square and
116 deep). Its shell is a cast or machined part and this wall is built in
wood, so the shell itself was not adopted. What was:

- **Manufacturer CAD.** Its Pi 5 is Raspberry Pi's own STEP and its bonnet
  is Adafruit's own 3MF. Both are appended straight out of
  `Tessera-Atelier.blend` into this model, along with its reconstruction of
  the LRS-350-5 (fan cutout, label, nine terminals), its bus bars from the
  seller's dimension image, and its labelled fuse holders.
- **The official panel drawing.** Waveshare's DWG for the P2.5 64x64 gives a
  rear shell of 159.8 mm, 12 mm deep, with eight M3 points at (45, 73) and
  (73, 45) from centre. The panel backs here are those ribbed shells now,
  and the magnetic feet sit on four of the eight points.
- **Corrected numbers.** The bus bar is 5.4 x 0.9 x 1.5 in, not the 3 x 2.3
  in bar of a sibling listing; the SL22 is 5 mm thick; the cleat is 1.5 in
  tall and stands 1/8 in off the wall.
- **Air.** Its vents are two guarded 340 x 22 mm openings in a removable rear
  cover, and it holds the whole body 16 mm off the wall on spacers so the
  rear can breathe. Both replaced the slots milled in this design's rails.
- **The taper.** Its shell narrows toward the wall so the body reads thinner
  than it is. The walnut rails now taper 6 mm on the outer face toward the
  back, which is one pass on a table saw.

Not adopted: it keeps the 27 W USB-C brick as a second mains device; this
design feeds the Pi from the 5 V rail on the white paper's authority.

## What changed, and why

| Was | Now | Because |
|---|---|---|
| Nylon standoffs, panels screwed to a PVC plate | Magnetic feet on a steel skin | The manual says four magnetic feet ship with each panel. Nothing gets drilled and any panel lifts off |
| A walnut shadow box, brass, an anodised reveal, a vented back | A painted plywood square and four sign standoffs | About a quarter of the money and a day instead of a weekend. The walnut version is kept as the upgrade path |
| Laser-cut slotted steel | A plain 24 inch sheet, cables round the edge | The slots existed to pass cables through a plate; going round the edge is free and the panels' own 12 mm shells hide the runs on the front |
| Opal plus smoked acrylic | Smoked only | Two sheets was $50 and the opal's job, hiding the LED grid, is not wanted here: the grid is the point |
| Sealed box | Open back | The supply has a fan and now has a room to breathe into |
| Two mains devices | One cord | The Pi is fed from the 5 V rail; the white paper says a non-negotiating supply is a supported way to power it |

## The verification ledger

VERIFIED is a datasheet, a drawing, a board file or the manual. LISTING is a
retailer's page. TYPICAL is the usual number for that kind of part, not
checked against the one in the box. DESIGN is a decision.

| Part | Number | Status | Source |
|---|---|---|---|
| Panel outline | 160 x 160 mm | VERIFIED | Waveshare wiki, manual |
| Panel thickness | 14.5 mm | VERIFIED | Waveshare manual drawing 3.1 (manuals.plus mirror) |
| Panel weight | 100 g | VERIFIED | manual: 3.53 oz |
| Magnetic feet | 4 per panel | VERIFIED | manual, in the box |
| Magnetic foot height | 3 mm | TYPICAL | not stated anywhere found |
| Panel rear shell | 159.8 mm, 12 mm deep, eight M3 points at (45, 73) and (73, 45) | VERIFIED | Waveshare P2_5 64x64 DWG, official GitHub, extracted in the atelier study |
| Panel connector positions | representative | UNVERIFIED | two HUB75 and a VH4 header are documented, their positions are not |
| LRS-350-5 | 215 x 115 x 30 mm, 0.76 kg | VERIFIED | Mean Well datasheet |
| LRS-350-5 terminals | L, N, FG, -V x3, +V x3 | VERIFIED | datasheet pin assignment |
| LRS-350-5 trim | 4.5 to 5.5 V | VERIFIED | datasheet |
| LRS-350-5 cooling | fan, on above 50 C | VERIFIED | datasheet fan curve |
| LRS-350-5 mounting | 4 x M4 both sides (L=5), 4 x M4 bottom (L=3) | VERIFIED | datasheet |
| Pi 5 board | 85 x 56 mm, holes 58 x 49 on 3.5 mm insets, dia 2.7; the model is the official STEP | VERIFIED | Raspberry Pi mechanical drawing and CAD |
| Active Cooler | 63.5 x 42.5 x 13.7 mm | VERIFIED | product brief and mechanical drawing |
| Triple Bonnet PCB | 65.0 x 30.7 mm; the model is the official 3MF | VERIFIED | Eagle board file and Adafruit CAD |
| Bonnet connectors | three 2x8 shrouded IDC, one JST SH 4 | VERIFIED | Eagle board file, element positions |
| Bonnet power | none on board, cannot power the Pi | VERIFIED | Learn guide |
| Bonnet STEMMA QT | present, shares SDA/SCL with port 3 | VERIFIED | Learn guide pinouts |
| Stacking header pins | 12 mm | LISTING | Frienda |
| Header body height | 8.5 mm | TYPICAL | |
| Bus bar | 5.4 x 0.9 x 1.5 in, 12 x M4 at 0.4 in, 1/4 in stud, copper plate 3.8 in, holes 4.7 in apart | LISTING | RVBOATPAT dimension image |
| Fuse holder leads and fuse | 12 in, 14 AWG, ATC 19.1 x 18.5 x 5.1 | VERIFIED | nilight.com |
| Fuse holder body | 36 x 14 x 14 mm | TYPICAL | |
| C14 module | approx 50 x 30 x 30 mm, holes 67 mm apart, 5 x 20 fuse | LISTING | Antrader |
| C14 cutout | 47 x 27.5 mm | TYPICAL | |
| SL22 10005 | 22 mm max dia, 5 mm max thick, 7.8 mm lead pitch, 10 ohm, 5 A | VERIFIED | Ametherm datasheet |
| Mini USB mic | 22.2 x 18.3 x 7.0 mm | VERIFIED | Adafruit 3367 |
| VEML7700 board | 25.5 x 17.7 x 4.6 mm | VERIFIED | Adafruit 4162 |
| OOK cleat | 12 in long, 1.5 in tall, stands 1/8 in off the wall, 1 in hole pitch | LISTING | OOK 533208 dimension images |
| Plywood board | 24 x 24 in, 1/2 in | LISTING | Home Depot project panel |
| Steel skin | 24 x 24 in, 22 gauge (0.76 mm) | LISTING | Everbilt sheet metal |
| Smoked acrylic | 24 x 24 in, 1/8 in, grey tinted cast | LISTING | Sibe-R / Canal Plastics #2064 |
| Sign standoffs | 1 x 1 in barrel, black | LISTING | four of them, corners |
| Furring strip | 1 x 3, 3/4 x 2-1/2 in actual | LISTING | the back gap |
| Pi power without PD | 600 mA USB limit, 1.6 A with `usb_max_current_enable=1`, GPIO feed acknowledged | VERIFIED | Raspberry Pi USB PD white paper |

## What to measure before cutting anything

**The magnetic feet.** How far they stand a panel off a flat surface is the
one number this design rests on and nobody has published it. Three
millimetres is assumed. It sets how far the glass floats over the LEDs
(`MAG_FOOT_H`, and `AIR_GAP` follows from it), and if the feet turn out to
be 5 mm the standoffs want to be 1-1/4 in rather than 1 in.

A ruler on one panel, two minutes, before anything is ordered.

## What is not in the model

The wiring is suggested, not routed: the drops and ribbons run where they
would, round the board's edge and then inside the panels' own 12 mm shells,
but nobody has bent a real 14 AWG lead around a real bus bar yet. The Pi's
USB-C pigtail exists as a line. How the steel is bonded to the plywood
(construction adhesive, weighted flat) is a note, not geometry. And the
smoked sheet is a shader, not an optical model: how much of the LED grid it
actually veils depends on the tint you buy, and #2064 grey at about 35
percent transmission is the one the render assumes.
