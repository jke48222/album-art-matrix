# The wall, designed

`wall_model.py` builds the wall in Blender from the parts on the bench and
renders it nine ways: hero, front, the bare skin with its openings, a
standoff, the mark, the back, the side, exploded, and in the room. It builds
three backs, `--enclosure open|back|box`, on one unchanged set of electronics. Every number is a constant at the top of the file with
its source beside it. This page is the reasoning.

```
/Applications/Blender.app/Contents/MacOS/Blender --background \
    --python design/wall_model.py -- --out design/renders --face design/face192.png
```

## What it is

A 24 inch square of half inch plywood with a sheet of 22 gauge steel glued to
its face, both painted matte black. The nine panels hold themselves to the
steel with the magnetic feet that ship in their boxes: nothing is drilled
into a panel, and any one of them lifts off with a fingernail. Behind each
panel, at the centre of its cell, one 12 mm opening through steel and
plywood takes that panel's own harness to the back; the three cells of the
right-hand column, where each row's chain starts, get three holes filed
into a 40 x 12 slot for the ribbon plug. Fifteen holes, all under panels,
and nothing crosses the border. The picture lands 480 mm square in the
middle, leaving a 64.8 mm black border that reads as a mat.

A 24 inch sheet of smoked grey acrylic floats in front on four black sign
standoffs, one at each corner. The standoff barrel sets the geometry:
31.75 mm off the steel, less 14.5 mm of panel and 10.6 mm of magnet, leaves
the glass 6.7 mm clear of the LEDs. The feet are Adafruit 4631, 16.6 mm long
with an M3 stud, so a 1 in barrel would have left 0.9 mm and rested the glass
on the panels. Off, the whole thing is a square of black glass.
On, the art is behind it and the panel frames are not visible.

Everything electrical is on the back, in the open: the LRS-350-5 low with
its terminal strip toward the inlet, the two bus bars on one side, nine
inline fuse holders in a block beside them, the Pi 5 with its Active Cooler
and the Triple Bonnet on the other side a hand's width from the three slots,
the inrush limiter, the microphone and the lux sensor. Two blocks of 1 x 3
furring under the cleat and two feet at the bottom hold the board 63.5 mm
off the wall, which is the gap all of that lives in. The left foot is 100 mm
long and carries the mains inlet: the C14 module's cutout goes through its
bottom face, so socket, switch and fuse drawer face the floor, 6 mm inside
the board's edge. The tallest thing back there is a bus bar with its cover
on, at 38.1 mm, so there is 25 mm to spare. A 1 x 2 strip would have left
exactly none.

The supply's fan has the whole room to breathe into, which is the one thing
an open back does better than a sealed box.

The only ornament is the app's seven by seven lattice on the bottom border,
one tile lit, a stencil and a fingertip of grey paint. It costs nothing.

About $150 over what is already on the bench, $115 without the acrylic. The
full list with checked prices, the order of work and the tools it needs is
at the end of [PARTS.md](../PARTS.md).

## Three backs

The board, the panels, the glass and every electrical part are identical in
all three. Only what happens behind the 63.5 mm cavity changes, so any one
can become another later without moving a wire.

| | Depth | What you see | Air |
|---|---|---|---|
| `open` | 111.9 mm | the supply, the bars and the Pi, from behind and from the side | the whole back |
| `back` | 118.2 mm | a closed slab from behind, a 63.5 mm slot from either side | the two open sides, no vents needed |
| `box` | 118.2 mm | closed from every angle | two 340 x 22 slots, low behind the supply's fan and high clear of the cleat, plus 16 mm wall pads |

`open` keeps the blocks and feet. Both covered versions replace them with
full width 1 x 3 rails, top and bottom for `back`, all four sides for `box`,
and a 24 x 24 x 1/4 in plywood panel over them. The cleat moves onto that
panel and screws through into the top rail. In `box` the lux sensor loses its
view of the room, so it moves to the upper slot and looks out through it.

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
| Laser-cut slotted steel | A plain 24 inch sheet with fifteen drilled openings, one behind each panel | The slots existed to pass cables through a plate. A hole at each panel's centre does the same for a step bit's worth of work, and the panel over it hides it. Round the edge was tried first and dropped: a cable crossing the border lies on the visible mat, under the glass |
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
| C14 cutout | 47 x 27.5 mm, through the bottom face of the left foot | TYPICAL | |
| SL22 10005 | 22 mm max dia, 5 mm max thick, 7.8 mm lead pitch, 10 ohm, 5 A | VERIFIED | Ametherm datasheet |
| Mini USB mic | 22.2 x 18.3 x 7.0 mm | VERIFIED | Adafruit 3367 |
| VEML7700 board | 25.5 x 17.7 x 4.6 mm | VERIFIED | Adafruit 4162 |
| OOK cleat | 12 in long, 1.5 in tall, stands 1/8 in off the wall, 1 in hole pitch | LISTING | OOK 533208 dimension images |
| Cleat stock | 1.2 mm stamped aluminium, two hooks | TYPICAL | |
| Plywood board | 24 x 24 in, 1/2 in | LISTING | Home Depot project panel |
| Steel skin | 24 x 24 in, 22 gauge (0.76 mm) | LISTING | Everbilt sheet metal |
| Smoked acrylic | 24 x 24 in, 1/8 in, grey tinted cast | LISTING | Sibe-R / Canal Plastics #2064 |
| Magnet feet | Adafruit 4631: 16.6 mm long, 12 mm dia, M3 stud | VERIFIED | product page, the ones in hand |
| Magnet protrusion | 10.6 mm (16.6 less about 6 mm of thread in the boss) | TYPICAL | the thread engagement is the assumed half; one ruler check settles it |
| Plugged ribbon height | a little under the magnets | VERIFIED | the owner, with the panels in front of him |
| Sign standoffs | 1-1/4 in barrel, black | LISTING | four of them, corners |
| Back panel | 24 x 24 in, 1/4 in plywood | LISTING | Home Depot project panel |
| Vents | two 340 x 22 mm, closed box only | DESIGN | the atelier study's opening size |
| Openings | 15 x 12 mm at the panel centres, the right column's three filed to 40 x 12 slots | DESIGN | a 4-pin harness needs 8 mm; a HUB75 plug is 20.3 x 8.9 |
| Back layout | supply low, bars left, fuse block beside them, Pi mid right, inlet in the left foot | DESIGN | checked against the openings: nothing sits over a hole |
| Furring strip | 1 x 3, 3/4 x 2-1/2 in actual | LISTING | the back gap |
| Pi power without PD | 600 mA USB limit, 1.6 A with `usb_max_current_enable=1`, GPIO feed acknowledged | VERIFIED | Raspberry Pi USB PD white paper |

## What to measure before cutting anything

**The magnetic feet.** Mostly answered: they are Adafruit 4631, 16.6 mm long
with an M3 stud, so what stands proud is 16.6 less whatever the panel's boss
swallows. `MAG_THREAD` assumes 6 mm, giving `MAG_FOOT_H` = 10.6, and the
whole depth stack follows from it. The owner confirms a plugged ribbon stands
a little under the magnets, so the panel rests on its feet, which was the
real risk.

One ruler check still settles the last millimetres: a panel with its feet on
the fridge, measured shell to fridge. 8 to 12 mm keeps the 1-1/4 in
standoffs; under 8 goes back to 1 in, over 13 goes to 1-1/2.

## What is not in the model

The wiring is routed, not dressed: every lead starts on the terminal it
belongs to (the model reads the supply's screws, the bars' M4s and the
bonnet's headers out of the borrowed CAD) and ends at its opening or its
plug, but nobody has bent a real 14 AWG lead around a real bus bar yet, and
a real build would zip tie the fan of drops into looms. The supply's four M4
holes are not modelled; take their positions off the datasheet drawing with
the part in hand. How the steel is bonded to the plywood
(construction adhesive, weighted flat) is a note, not geometry. And the
smoked sheet is a shader, not an optical model: how much of the LED grid it
actually veils depends on the tint you buy, and #2064 grey at about 35
percent transmission is the one the render assumes.

## The other bodies

Three rounds of alternate faces exist, all on this same board, the same fifteen
openings and the same electrical layout. Any of them is a new front on the wall
being built here, not a different wall.

- `ALTERNATES.md` and `alt_model.py`: sleeve, lean, system, splay. Four objects
  with four different answers to where the switch is.
- `SYNTHESIS.md` and `synth_model.py`: alcove, fascia, shutter. Two deliberate
  combinations of the bodies that survived review, and one that argues with
  them. Shutter is the only one whose off state is a different object.

The earlier round, `--direction console|vitrine|instrument|nonet`, is in this
repository's history at `f12ca41`.
