# The wall, designed

`wall_model.py` builds the finished wall in Blender from the parts on the
bench and renders it six ways. Every number is a constant at the top of the
file with its source beside it. This page is the reasoning.

```
/Applications/Blender.app/Contents/MacOS/Blender --background \
    --python design/wall_model.py -- --out design/renders --face design/face192.png
```

## What it is

A black walnut shadow box, 522 mm square and 87 mm deep, with a 16 mm face.
Inside the wood, a 3 mm black anodised aluminium reveal frames a 484 mm
window, two millimetres past the LEDs on every side so the panel frames never
show. The glass is 3 mm opal and 3 mm smoked ND acrylic, 492 mm square,
sitting 4 mm under the reveal, and the wood stands 5 mm proud of it: a shadow
line, so the picture reads as set into the object rather than stuck on it.

The mitres are keyed with brass splines, two per corner, which show as thin
brass lines across the outer faces. The app's seven by seven lattice is
inlaid in brass on the bottom rail with one tile lit. Both are the only
ornament, and both are structural or meaningful: the splines hold the
corners, the lattice is the mark the app carries.

Behind the panels, a 1.5 mm galvanised steel plate. The panels hold
themselves to it with the magnetic feet that ship in their boxes, so nothing
is drilled into a panel and any one of them lifts off by hand for service.
The plate has generous slots behind each panel's connector zone for the
ribbons and the power leads. Behind the plate, a 40 mm cavity holds the
LRS-350-5 along the bottom, the Pi 5 with its Active Cooler on a stacking
header with the Triple Bonnet above it, the two bus bars, nine inline fuse
holders, the SL22 inrush limiter, the microphone and the lux sensor.

The back is a 3 mm black anodised aluminium panel on eight countersunk
screws, inset 12 mm to leave a plenum, with two guarded 340 x 22 mm openings
in it, one low and one high. Four 16 mm pads hold the back off the wall so
those openings work: the supply has its own fan (the datasheet's fan curve:
on above 50 C, off below 40 C) and this gives it somewhere to breathe. The
rails taper 6 mm toward the wall so the box reads thinner from the side than
it is. The OOK cleat hangs it. A brass badge on the back carries the name
and number.

One mains cord. The C14 module with its switch and fuse sits in the bottom
rail. The Pi takes its 5 V from the same rail as the panels, through a fused
pigtail into its USB-C port, with `usb_max_current_enable=1` in config.txt.
The LRS-350-5 trims from 4.5 to 5.5 V, so 5.1 V is available to everything.
The 27 W USB-C brick is not part of the wall.

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

## What changed from the first design, and why

| Was | Now | Because |
|---|---|---|
| Nylon standoffs, panels screwed to a PVC plate | Magnetic feet on a steel plate | The manual says four magnetic feet ship with each panel. Their positions do not need verifying because the plate is continuous, and nothing gets drilled |
| 28 mm rails, 95 mm deep | 16 mm rails, 87 mm deep | A slim face with visible depth reads as a gallery box; a wide face reads as a picture frame |
| Wood straight to acrylic | Black aluminium reveal, glass recessed 5 mm | The reveal hides the panel frames and gives the picture an edge; the recess gives the wood a shadow line |
| Sealed box | Vented back panel, plenum, wall pads, fan-cooled supply | The supply has a fan. A sealed walnut box would cook it |
| Two mains devices | One cord | The Pi is fed from the 5 V rail; the white paper says the GPIO or a non-negotiating USB-C supply is a supported way to power it |
| A shelf and turntable in the scene | Just the wall | Asked for |

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
| Pi power without PD | 600 mA USB limit, 1.6 A with `usb_max_current_enable=1`, GPIO feed acknowledged | VERIFIED | Raspberry Pi USB PD white paper |

## What to measure before cutting anything

Two numbers decide the depth and neither is on paper: how tall the magnetic
feet stand off the panel back, and how far the tallest thing on a panel's
back (the harness plug, most likely) stands off it. A ruler on one panel
gives both. `MAG_FOOT_H` and the slot sizes are the constants to change.

## What is not in the model

The wiring is suggested, not routed: the drops run where they would, the
ribbons run where they would, but nobody has bent a real 14 AWG lead around
a real bus bar yet. The Pi's USB-C pigtail exists as a line. The vent slot
count is a guess at the airflow the supply's fan needs; nobody has measured
the cavity's temperature.
