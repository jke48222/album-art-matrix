# The alternates

`alt_model.py` builds one body four ways. Everything below came out of the
questionnaire of 2026-09-07, except the fourth direction, which is mine.

```
/Applications/Blender.app/Contents/MacOS/Blender --background \
    --python design/alt_model.py -- --direction nonet --palette oxblood \
    --out design/renders --face design/face192.png
```

`--direction console|vitrine|instrument|nonet`, `--palette charcoal|oatmeal|oxblood|forest|ink`.

## What was decided

A halo that samples the artwork's own edges and throws them at the wall. A
body that reads at once as laboratory instrument, hi-fi component and
reliquary. Cloth and a machined edge as the two cheap-to-expensive moves. One
real control, a genuinely designed idle, and a second readout. Off, a dark
void and a plain object. A 40 mm instrument lip. The spare tenth panel as the
readout. Charcoal, oatmeal and three saturated colourways. Visual impact wins
a trade-off, with a cheaper fallback named every time.

## The body all four share

609.6 x 729.8 mm, cut from the same 2 x 4 ft plywood sheet. The picture is
480 square with 64.8 mm of cloth above and to the sides and **185 mm below**.

That bottom weighting is not a compromise, it is how a picture framer mats a
print: the lower margin is made deeper so the image does not look like it is
sliding out of the frame. Here it also has a job. The readout is the spare
64x64 panel standing on the front of the board below the aperture, and a
160 mm panel plus clearance is what sets the 185 mm. Anything under 175 and
the panel's top edge shows inside the picture window; that was a real fault
in the first render and it is why the number is what it is.

The face is three layers and no sign standoffs at all:

| | |
|---|---|
| smoked acrylic, 540 square, 3.175 mm | 6.7 mm clear of the LEDs, exactly as the standoffs used to set |
| a 22 mm perimeter surround, board to mask | closes the void the face plate would otherwise float over |
| a fabric-wrapped mask, 3 mm, with the window cut in it | sits on the acrylic, so the picture is 3 mm recessed behind a crisp shadow line |
| an alloy bezel standing in the opening | the machined edge: one bright millimetre doing the work at two metres |

Losing the four sign standoffs saves about $15 and a lot of drilling in
acrylic, and it is why the front reads as one surface instead of a sheet
bolted over a board.

Across the bottom, a 40 mm brushed aluminium band let into the cloth. A
34 mm knob at the left, rotate to dim and press to change mode. A
160 x 30 mm letterbox window at the right showing twelve pixel rows of the
tenth panel as an amber level meter. The band is the only place the object
admits it is equipment.

## One finding that overrode a choice

Both "deep shadow gap" and "flush and floating" were picked. They cannot both
happen. The electronics need the 63.5 mm cavity behind the board whatever the
face does, and the halo needs the body held off the wall to have anything to
wash. True flush mounting gives the light nowhere to go and turns the halo
into a hairline. **All four directions are therefore shadow-gap mounted**, on
four 45 mm pads, with the strip on the outer face of the back panel.

This was found by rendering it wrong first: the halo was originally inside the
closed cavity, sealed in by the back panel, and lit nothing at all.

## The four directions

### 1. Console
One 500 mm window, the picture behind smoked acrylic, the alloy band below.
The most literal reading of the brief and the calmest of the four. Nothing
here is difficult: two rectangles cut in a sheet, cloth stapled round the
back, a strip of aluminium.

*Fallback if too expensive:* skip the aluminium band and paint a strip of the
same 3 mm sheet with metallic paint, or wrap it in aluminium tape. Saves $12.

### 2. Vitrine
The same window pushed 40 mm back, its reveal lined in the same cloth, so you
look down a soft-walled well at the artwork. This is the reliquary register
taken literally, and it is the one that changes how the thing feels rather
than how it looks: the picture stops being on the wall and starts being
inside something.

Costs: 40 mm more depth (161.3 mm against the other three's 121.3), and the
viewing angle narrows, so it
wants to be hung at eye height and seen from in front.

*Fallback:* halve the well to 20 mm. Most of the effect, none of the depth.

### 3. Instrument
The same window with the fixings shown: fourteen alloy screw heads on a
regular grid round the aperture, a small engraved legend at the bottom left.
The laboratory register with nothing hidden. It is the cheapest of the four
to add to, since the ornament is fasteners you were going to use anyway.

*Fallback:* it already is the fallback. Nothing here costs more than screws.

### 4. Nonet (mine)

Nine windows on the 160 mm panel pitch, 152 mm each, with 8 mm of cloth over
every seam. One image assembles across all nine.

**The argument.** Every version of this build so far, mine included, has been
trying to hide that it is nine panels. It cannot be hidden: the shells butt at
0.2 mm and the pixel pitch breaks at every join, so any continuous window
puts a visible fault line across the artwork three times in each direction.
Making the grid explicit converts the one unfixable defect into the subject,
and the 8 mm land lands exactly on the fault.

It has a lineage worth standing in. The polyptych altarpiece is a single image
divided by structure, which is precisely the reliquary register asked for. The
nine-square grid runs through Albers and Agnes Martin. The divided sash window
is the domestic version. And the whole object then sits in the line that runs
from Rams' wall-mounted Braun system, the first of its kind, through
Fukasawa's Muji player, whose entire idea is one honest gesture on a wall.

Off, it is the strongest of the four: nine dark squares in a field of wool.
Nothing about nine squares says screen.

It is also **cheaper than the other three**: nine small apertures in one 3 mm
sheet, one acrylic sheet behind all of them, and no 500 mm span of unsupported
glass. The cost is 1.6 pixels masked at each side of every seam, which is
about 3 percent of the image, and the artwork does not miss them.

*Fallback:* none needed. It is the cheap one.

## The halo

Thirty-six emitters in twelve colour zones, three to an edge, one to each
panel. Each zone is the average of the artwork's own outer strip, lifted and
saturated, because an average is always duller than the picture it came from
and a dull halo just looks like a fault. `halo_colours()` reads the face image
directly, so the renders show the real colours the wall would throw.

Addressable strip, WS2812 or SK6812, about $12 for 2 m. On the outer face of
the back panel, 12 mm in from the edge, washing across the 45 mm the pads hold
open.

*Fallback:* a non-addressable warm white COB strip, about $8. You lose
"extends the picture" and get "fixed warm white", which was the fourth option
on the halo question and is still a good object.

## The tenth panel

The bonnet has three ports and `pi/run_renderer.sh` says every port must carry
the same number of panels, so a tenth cannot chain on. It gets its own driver:
the spare Pico 2 W, which already has HUB75 capability on its PIO and is
currently only a bench colorimeter host.

Two costs to be clear about. **You lose your spare panel**, which is the one
thing standing between you and a dead tile. And it is a second firmware and a
link from the Pi, most simply UART over two wires.

*Fallback:* a four-character 14-segment alphanumeric display, about $10, in
the same window behind the same bezel. Keeps the spare, keeps the hi-fi
language, loses the pixel-for-pixel match with the main picture.

## Parts these add, over the buildable design

| Part | For | About |
|---|---|---|
| Acoustic or speaker grille cloth, 1 yd | the surround | $15 |
| 3 mm ply or ABS sheet, 610 x 730 | the mask | $10 |
| Aluminium flat bar or sheet, 610 x 40 x 3 | the lip | $12 |
| Aluminium angle or trim for the bezel | the machined edge | $10 |
| Rotary encoder with push, plus an alloy knob | the control | $10 |
| Addressable LED strip, 2 m | the halo | $12 |
| 1/4 in plywood panel, 24 x 24 | the back | $13 |
| One more 1 x 3 furring strip | the rails | $3 |
| | | **about $85** |

On top of the core build's $115 without acrylic, that is **about $200**, or
about $235 with the smoked sheet. The cheap-fallback column brings it to
roughly $150.

Nonet needs no bezel angle if the aperture edges are simply painted, which
takes it under $190.

## If these are studies, or if one of them is the build

**As studies.** The plywood, steel and smoked-acrylic design with its three
enclosures stays the plan of record. Nothing in `docs/ASSEMBLY.md` changes.
Every alternate is built on the same board, the same fifteen openings, the
same electronics layout and the same 63.5 mm cavity, so any of them can be
retrofitted later by making a new face: a mask, some cloth, a strip of
aluminium and a knob. The board never comes off the wall.

**As the build.** Three things in the guide change and nothing else does.
Section 1 gains the cloth, the mask sheet, the alloy and the encoder. Section
2 cuts the board 609.6 x 729.8 instead of square and the steel 609.6 x 490.
Section 9 loses the four standoffs entirely and gains the three-layer face.
The wiring, the openings, the tile map, the white balance and the hanging are
untouched.

The retrofit path is the reason to start with the simple one: nothing done
this week is wasted by any of these.

## The verification ledger, additions

| Part | Number | Status | Source |
|---|---|---|---|
| Magnet feet | Adafruit 4631, 16.6 mm long, 12 mm dia, M3 | VERIFIED | product page |
| Magnet protrusion | 10.6 mm | TYPICAL | 16.6 less about 6 mm of thread |
| Plugged ribbon height | under the magnets | VERIFIED | the owner, panels in hand |
| Ports and chain length | three ports, equal panel counts | VERIFIED | `pi/run_renderer.sh` |
| Body | 609.6 x 729.8 mm | DESIGN | set by a 160 mm panel under a 500 window |
| Bottom weighting | 185 mm against 64.8 | DESIGN | framing convention, and the panel |
| Mask | 3 mm, cloth wrapped | LISTING | 1/8 in ply or ABS |
| Lip | 40 mm alloy band | DESIGN | the questionnaire's thin lip |
| Readout window | 160 x 30 mm, 64 x 12 px | DESIGN | a whole panel wide |
| Halo | 36 emitters, 12 colour zones | DESIGN | sampled from the face image |
| Wall pads | 45 mm | DESIGN | what the halo needs to spread |

## What is still unresolved

The Pico's HUB75 output has not been tried on one of these panels, only
established as possible in principle. The cloth is a shader, not a fabric: how
a real weave takes the halo's colour at a grazing angle is not something a
render settles. And the knob's detent count and the idle animation are
software that does not exist yet.
