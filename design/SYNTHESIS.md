# Three more objects

Two of them are deliberate combinations of the six bodies that survived review.
The third is not a combination of anything.

```
/Applications/Blender.app/Contents/MacOS/Blender --background \
    --python design/synth_model.py -- --design alcove \
    --out design/renders --face design/face192.png
```

`--design alcove|fascia|shutter`, `--state closed|half|open` (shutter only),
`--cloth charcoal|oatmeal|oxblood|forest|ink|chalk`.

## What was kept, and from where

Six objects were liked. They have less in common than they look, and the useful
exercise was separating what each one actually contributes from what it merely
happens to be made of.

| From | The idea worth keeping | Where it went |
|---|---|---|
| **Index** (ChatGPT) | tight seams and a narrow graphite reveal, so the bright image is separated from the body by one dark line and one bright one | the bezel in all three; in Fascia the reveal becomes a real 12 mm depth rather than a drawn edge |
| **Soft Monument** (ChatGPT) | the silhouette refuses to be a plain extruded box | Alcove's rails taper toward the wall and its well splays; Fascia's cheeks rake back |
| **Console** (mine) | bottom-weighted mat, and one alloy band that admits the object is equipment | Alcove's band, Fascia's rail |
| **Vitrine** (mine) | the picture is *inside* something rather than on the wall | Alcove's 40 mm well, splayed |
| **Boxed enclosure** (mine) | resolved from every angle: closed, vented, held off the wall | the plinth behind all three |
| **First walnut frame** (mine) | mitred hardwood, and the material doing the work | Alcove's frame, Fascia's cheeks, Shutter's whole case |

Three things were dropped on purpose. The **tenth-panel readout** stays dropped:
it costs the spare panel, which is the one thing standing between a dead tile
and a dead wall. The **sign standoffs** stay dropped: the glass sits in the
bezel's rebate, which saves about $15 and a lot of drilling in acrylic. And
Vitrine's **straight-sided well** is gone in favour of a splayed one, for
reasons below.

## The knob can come back, and here is why

Console had a knob and the second round removed it. Removing it was right for
the reason given at the time and wrong for the reason assumed.

The Triple Bonnet uses every GPIO on the header except pins 27 and 28
(ID_SD/ID_SC, GPIO0 and GPIO1), and `docs/ASSEMBLY.md` already spends those on
the VEML7700. So a rotary encoder on plain GPIO is genuinely impossible, and
that is not fixable by rearranging anything.

An **I2C** encoder is a different question. Adafruit 5880 is the seesaw rotary
encoder breakout with the encoder already fitted, $7.95, default address 0x36,
jumper-selectable to 0x3D. The VEML7700 is 0x10. Two devices, one bus, the same
two pins, no second microcontroller, no second firmware, and nothing taken from
the spare panel. The seesaw counts the pulses and debounces the push itself, so
the Pi polls a register rather than servicing interrupts.

That is the whole argument for Console's control returning and Console's
readout not.

## What all three share

Nine panels, 480 mm square, on their own magnets on the same steel skin, with
the same fifteen openings and the same electrical layout. Behind that, a closed
plywood plinth that is **deliberately narrower than the face**: 46 mm in on
every side, so from any oblique angle you see the frame and not the box.

`alt_model`'s carcass ran its rails at the board's own outline, and the first
render of Alcove showed exactly what that costs. From the hero angle the black
body stood past the walnut's edge as a slab and the object stopped resolving.
The plinth is now a shadow gap, which is what the questionnaire asked for and
what the object wanted anyway.

The plinth is vented (two 340 x 22 slots, low behind the supply's fan and high)
and stands on four **30 mm pads**. The pads are not decoration. The halo lives
on the outer face of the back panel and needs a gap to wash; the boxed
enclosure's 16 mm was chosen for a box that had no halo, and 30 is what puts
light on the plaster in the side render.

## 1. Alcove

**Walnut, and the picture at the bottom of a splayed wool well.**
644 x 716 mm, 193 mm from the wall including the pads.

Vitrine's recess is the strongest single idea in the six, because it is the only
one that changes what the object *is* rather than what it looks like. The
picture stops being on the wall and starts being inside something. Around it:
the first walnut frame's mitred body, tapered 6 mm toward the wall; Index's
bright edge at the throat; Console's bottom weighting and its band; and the
boxed enclosure's closed, vented, padded back.

**The splay.** Vitrine's well was straight-sided, and that has a real optical
cost: at any angle off axis the near wall shadows a strip `d·tan θ` wide off the
far side of the picture, so at 40 mm deep and 20 degrees off you lose 15 mm,
about six pixels. Splaying the walls 11.3 degrees opens the mouth from 496 to
512 and gives back the first 11 degrees free, with everything beyond it reduced.
It costs 16 mm of width and one bevel on four strips.

It also does something the straight well did not: the walls shade the glass from
room light, which is the same job the smoked tint does, so the well and the tint
are not both working at full strength on the same problem.

**Where the hand goes.** The band is 34 mm of satin alloy let into the wool
across the bottom mat, standing 1 mm proud, with the knob at its left. The C14
module is in the underside of the bottom walnut rail, to the right. A hand
reaching under the frame for the switch passes the band on the way.

**Tradeoffs.** The deepest of the three, and the well narrows the useful viewing
cone even splayed, so it wants hanging at eye height. It is also the most
expensive, and the cost is the walnut.

**Fallback.** Walnut-veneered plywood rails or stained poplar instead of solid
walnut saves about $37 and changes the side view, not the front. Painting the
bezel instead of buying alloy angle saves $12 and loses the one bright edge,
which is the wrong economy to make.

## 2. Fascia

**One sheet of glass over everything, and the machine behind it.**
648 x 702 mm, 156 mm from the wall including the pads.

Index's argument is that this should read as a piece of audio equipment and get
there through seams and proportion rather than features. So: a single glazed
face edge to edge, a wool field behind it with the picture let into a 12 mm
graphite reveal, a satin alloy case holding the glass, and black walnut cheeks.

The cheeks are after the **Braun SK4** (Rams and Gugelot, 1956), where a metal
body with wooden side panels and a transparent lid was the whole material
argument, and where the acrylic lid existed because the sheet-metal one
rattled. Soft Monument's chamfer becomes the cheeks' 29 mm rake back to the
wall, so a 156 mm body reads thinner than it is. Console's band becomes the
40 mm alloy rail below the glass, carrying the knob on its face and the C14 on
its underside: one horizontal element for everything the hand does.

**The finding that changed it.** The first version used the project's usual
smoked grey, about 35 percent transmission. Over a lit picture that is right.
Over a wool field it is not: the oatmeal rendered as pure black and the entire
point of a single glazed face went with it. Two changes fixed it. The glazing
is a **light smoke**, nearer picture glazing than sunglasses, and the field is
**chalk**, a colourway none of the earlier palettes carried, because charcoal,
oatmeal, oxblood, forest and ink all go to black next to a 480 mm panel at full
white.

**Its best state is off.** Every other object in this family is a duller version
of itself when the music stops. Fascia is a pale wool mat under glass in an
alloy case with walnut cheeks, with a dark square where the picture is. It looks
like a frame, which is what Index was reaching for and could not get to while
the front was a hole in a mat.

**Tradeoffs.** Lighter glazing means the LED grid is more visible when off and
the picture gets less contrast help. The 14 mm air gap between the LEDs and the
glass gives about 3 pixels of parallax at 30 degrees off axis. And a full-face
sheet of acrylic is a mirror: this is the design most sensitive to what is
opposite it in the room.

**Fallback.** Walnut-veneered ply cheeks save about $25. A plain alloy angle
instead of a formed rail saves $15 and makes the rail a line rather than a
volume.

## 3. Shutter

**A walnut case with two shoji leaves that fold across the picture, and opening
them is the switch.**
680 x 760 closed, 1320 mm wide open, 178 mm from the wall closed.

This is not a combination. It is the one argument none of the six make.

**The lineage.** A winged altarpiece has a weekday side and a feast-day side:
shut through Lent and ordinary time, opened for feasts, and Pacher's St Wolfgang
has three states because it has two layers of wing. The Lenten veil, the German
*Hungertuch*, is the same instinct with no picture at all, a cloth hung across
the chancel to give what the sources call a fast of the eyes, not removed until
the Passion reading. Bang and Olufsen's Beovision Harmony is the living version:
wood and aluminium covers that fold away as the screen rises, and that conceal
it whenever it is off or only playing music.

**What it does that the others cannot.** Every other object here has an off
state that is a dimmer version of the on state. This one has an off state that
is a **different object**. Closed, the album is behind laminated washi on an
80 mm kumiko grid, and what reaches the room is the record's colour without the
record's picture: Noguchi's argument for Akari, light as the sculpture rather
than light on a thing. Folded back, it is nine panels and a bright edge. Half
open, it is both, which is the altarpiece's Sunday.

**The paper is doing real work.** A washi screen over an LED matrix is a
diffuser, and diffusing is the traditional answer to exactly this problem. The
rest of the project rejected opal acrylic on the grounds that the grid is the
point, and that is still true, but here the diffusion is a **state** rather than
a permanent filter. You choose which one you want by moving your hand.

**The lattice registers to the panels.** Kumiko on an 80 mm grid, exactly half
the 160 mm panel pitch, so bars land at 80 (both seams), 160 (mid panel) and 240
(the picture's edge), in both axes. The seams that Nonet argued could not be
hidden are, closed, under a bar.

**The gesture is the control.** Fukasawa's rule for the Muji player is that a
thing on a wall should ask for one honest action and it should be the action the
form already suggests. You open it to look at it. Both meeting stiles carry a
magnet; a reed switch behind the mat reads whether they are together. Closed
puts the wall in lantern mode, open puts the picture up. The mains switch stays
where a hand goes, under the bottom rail, because a door is not a disconnect.

The reed cannot go on GPIO for the same reason the knob cannot. It goes to a
small I2C expander on the sensors' bus, at an address clear of 0x10 and 0x36.
If that is one part too many, the fallback costs nothing: no reed at all, and
lantern mode is chosen in the app or on a schedule.

**Tradeoffs, and the big one.** Open, it claims **1320 mm of wall**. Four
bi-folding leaves were built first because they cut that to about 1000, and they
were wrong: a folding pair needs its own stile on both sides of every joint, so
four leaves put three 36 mm bands of solid walnut across a 640 mm face and the
thing read as a window grille rather than a screen. Two leaves put one joint
down the middle, which is what an altarpiece has anyway.

It is also the most joinery. A kumiko lattice is 18 half-lapped pieces per leaf,
and it is the only one of the three that a bad afternoon can ruin.

**Fallback.** A cheaper laminated shoji paper, or a translucent polypropylene
sheet, instead of the branded laminated washi, saves about $30 and costs the
fibre. Butt hinges instead of a piano hinge save $12 and put the load on three
points.

## Money

Every figure is a planning allowance, not a quote. The core build is about $150
with the smoked sheet, from the checked prices of 7 September.

| | Core, less standoffs | Adds | About |
|---|---|---|---|
| Alcove | $135 | walnut $55, wool $15, mat sheet $10, bezel angle $12, band $12, encoder and knob $14, halo strip $12, back panel $13, furring $3, oil $12 | **$293** |
| Fascia | $135 | walnut cheeks $35, wool $15, field sheet $10, alloy case and rail $30, encoder and knob $14, halo strip $12, back panel $13, furring $3, oil $10 | **$277** |
| Shutter | $135 | case walnut $22, leaf walnut and kumiko $22, laminated washi $45, hinges $20, catches $6, reed and expander $10, wool $15, mat sheet $10, bezel angle $12, halo strip $12, back panel $13, furring $3, oil $10 | **$335** |

Taking the fallback at every step: Alcove about $245, Fascia about $237, Shutter
about $293.

These are all above the $150 to $200 the earlier rounds targeted, and the reason
is hardwood in all three and paper in one. That is a real change of bracket and
it should be a decision, not a drift.

## The ledger, additions

| Part | Number | Status | Source |
|---|---|---|---|
| Free header pins | 27 and 28 only, ID_SD/ID_SC, GPIO0/1, I2C0 | VERIFIED | Adafruit board file, read in `docs/ASSEMBLY.md` |
| I2C encoder | Adafruit 5880, 25.6 x 25.3 x 4.6 mm, $7.95, seesaw, 0x36 to 0x3D | LISTING | Adafruit product page |
| Lux sensor address | 0x10 | VERIFIED | VEML7700 datasheet |
| Well splay | 496 throat to 512 mouth over 40 mm, 11.3 degrees | DESIGN | `d·tan θ` for the clipped strip |
| Bezel | 484 opening, 6 mm face, alloy angle | DESIGN | 2 mm past the LEDs, and wide enough to lap the sheet |
| Glass | 492 square | DESIGN | the bezel has to cover its edge |
| Wall pads | 30 mm | DESIGN | what put halo light on the plaster |
| Walnut rail | 22 x 95 mm, mitred, 6 mm rear taper | DESIGN | `wall_model_walnut.py` |
| Cheek rake | 29 mm over 130 mm of depth | DESIGN | 12.6 degrees |
| Light smoke | about 70 percent, against the usual 35 | DESIGN | found by rendering the field black |
| Chalk cloth | 0.560, 0.535, 0.480 | DESIGN | a new colourway; the five existing ones all crush |
| Well lining | flat tone, no wave bands | DESIGN | the weave aliases at a grazing angle |
| Kumiko | 6 x 7 mm bars on an 80 mm grid | TYPICAL | slender is what real kumiko is |
| Leaf stile | 18 x 22 mm | TYPICAL | shoji stiles are 2-1/4 x 1-3/8 in at door scale |
| Laminated washi | washi faced both sides in resin, cleanable, flame-rated in Japan, sheets 36 x 72 in | LISTING | Warlon, via Washi Arts |
| Leaf | 320 x 740 x 22 mm, two of them | DESIGN | two panels wide each |
| Open width | 1320 mm | DESIGN | 680 plus two 320 leaves |

## Six faults the renders found

Worth writing down, because five of them were invisible in the numbers.

1. **Mitre wings.** The rear taper pulled each rail's outer face in by 6 mm but
   not its length, so the 45 degree joint stopped closing and every corner grew
   a small tab. A tapered mitre has to shorten in two directions.
2. **A louvre in the well.** The acrylic was 508 square inside a 496 throat, and
   the exposed 6 mm margin, seen at a grazing angle, showed a stack of
   total-internal-reflection ghosts of the LED grid. The bezel now laps its edge.
3. **A second louvre, different cause.** The wool's weave is two crossed wave
   bands at 3.85 mm, and face on that is right: sub-pixel, it averages into
   texture. Foreshortened onto the well's splayed walls it aliased into nine
   soft flutes. Zeroing the relief did not fix it, because the same bands drive
   the colour ramp as well as the bump. The lining is now a flat tone with fine
   noise, which is what a stretched lining is anyway.
4. **The body standing past the frame.** Described above. The plinth is 46 mm in
   on every side now.
5. **The field going black.** Fascia's whole premise failed at the project's
   usual tint, and both the glazing and the cloth had to change.
6. **Four leaves reading as a grille.** Described above. Two leaves, one joint.

## What a render cannot settle

The paper is a translucent shader, not a measurement. How much of a 480 mm panel
at working brightness actually arrives through laminated washi at 20 mm, and
whether the closed state is a lantern or a dim grey rectangle, wants one sheet
of the real material held in front of one lit panel. That test costs a sample
sheet and ten minutes, and it decides whether Shutter is a design or a nice
drawing.

The splay's benefit is geometry and holds. The wool's behaviour under a grazing
halo does not: the lining is a shader twice over now. Alcove's walnut is four
mitres in hardwood at 22 mm, which is thin enough that a bad cut shows. And no
one has weighed any of these: the cleat rating and the anti-lift restraint are
still physical work, unchanged from `docs/ASSEMBLY.md`.

## Sources

- [Winged altarpiece](https://en.wikipedia.org/wiki/Winged_altarpiece) and the
  feast-day and weekday sides. Pacher's St Wolfgang altarpiece has three states.
- [Lenten veil](https://en.wikipedia.org/wiki/Lenten_veil), the *Hungertuch*,
  noted in Germany from the ninth century, hiding the altar entirely until the
  Passion reading.
- [Beovision Harmony](https://www.bang-olufsen.com/en/int/televisions/beovision-harmony),
  Bang and Olufsen. Wood and aluminium covers conceal the screen when it is off
  or playing music, and fan out when it is raised.
- [Wall-mounted CD player](https://collections.vam.ac.uk/item/O1227135/),
  Naoto Fukasawa for Muji, 1999, V&A. One gesture, and it is the gesture the
  form already suggests.
- [Akari light sculptures](https://www.noguchi.org/isamu-noguchi/digital-features/the-history-of-akari-light-sculptures/),
  Isamu Noguchi, Gifu, from 1951. Washi over a frame, and the name means light
  as illumination.
- [Radio-Phonograph SK 4](https://www.moma.org/collection/works/2649),
  Dieter Rams and Hans Gugelot for Braun, 1956, MoMA. Metal body, wooden cheeks,
  acrylic lid.
- [Warlon laminated washi](https://www.washiarts.com/natural-papers/warlon),
  washi faced both sides in resin, sold as the durable shoji paper, cleanable
  and flame-rated in Japan.
- [Shoji specifications](https://portlandshojiscreen.com/about/specifications/),
  Portland Shoji Screen, for stile section and kumiko practice.
- [I2C QT Rotary Encoder](https://www.adafruit.com/product/4991) and
  [the version with the encoder fitted](https://www.adafruit.com/product/5880),
  Adafruit, seesaw, 0x36 to 0x3D on three jumpers.
- [606 Universal Shelving System](https://www.vitsoe.com/us/606), Dieter Rams
  for Vitsoe, carried over from the earlier round for Fascia's rail.
