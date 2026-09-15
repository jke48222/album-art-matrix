# Three more, out of the eight

Twenty-eight bodies had been drawn for this wall across six studies. Eight were
kept: Wall III, Wall VI box, ChatGPT's Index and Soft Monument, Splay, Case,
Strap and Shutter. This round comes out of what those eight have in common, and
out of what the twenty that were cut do not.

```
/Applications/Blender.app/Contents/MacOS/Blender --background \
    --python design/round5_model.py -- --design offset \
    --out design/renders --face design/face192.png
```

`--design offset|cove|ply|section`.

## What the eight actually say

Less about style than they look. Read against the twenty that were cut, they
are four rules and one instruction.

| The rule | What it is read from |
|---|---|
| **Symmetric and centred.** | Lintel and Slip were cut and Index and Soft Monument kept; Sleeve's offset card, Lean's foot and System's two boxes all went. Nothing asymmetric survived. |
| **Closed, and resolved from behind.** | Both fully enclosed bodies were kept, Wall VI box and Case. Wall VI open and Wall VI back were cut, and so was every design with the machine in the open. |
| **One precise bright edge.** | All eight have it: Wall III's anodised reveal, Index's graphite line, Case's reveal standing 3 mm proud, Strap's brass ring, Shutter's bezel. |
| **A silhouette that is not a plain extruded box.** | Strap's 50 mm corners, Soft Monument's octagon, Splay's funnel, Shutter's leaves. |
| **A border inside a rounded body is a parallel curve of it.** | Not read from anything. Given as an instruction when Strap was redrawn, and it is the one rule here that came from outside the drawings. |

Two more things the cuts say, and they matter more than the list above.
**Alcove and Fascia were both cut and Shutter was kept**, so the round of
deliberate combinations failed and the round with one argument did not.
Nothing here combines. And **Vitrine was cut while Splay and Shutter were
kept**, which are its two descendants: the recess as an idea survives where it
does something, and not where it is only a recess.

So each of the first three takes one thing the eight have and finishes it. One
is about geometry, one about light, one about material. The fourth does not
come from the eight at all: it was asked for separately, it has no radius
anywhere, and it is drawn from the canon instead.

| | Envelope | From the wall | Materials | The switch |
|---|---|---|---|---|
| Offset | 560 sq, 50 mm corners | 146 mm | satin aluminium, black anodised | underside, right, 165 mm off centre |
| Cove | 676 sq, 130 mm corners | 136 mm | bone lacquer, black anodised | under the bottom, facing the floor |
| Ply | 580 sq, 50 mm corners | 152 mm | 18 mm birch, sprayed matte black, oiled edges, brass | underside, right, 165 mm off centre |
| Section | 580 sq, square corners | 142 mm | clear anodised aluminium, off-white lacquer | underside, right, 165 mm off centre |

## The one rule, written down

`concentric(outer, radius, width) = radius - (outer - width) / 2`

A border `width` across an object of size `outer` and corner `radius` shrinks
the radius by half the difference. Every arc in the three rounded objects is struck
from the same centre, which is what makes a set of borders read as one line
rather than as frames stacked inside each other. It is also just true:
offsetting a rounded rectangle inward by d lowers its radius by exactly d, and
offsetting outward raises it by exactly d. The cove is built on the second half
of that fact.

## 1. Offset

**Satin aluminium, 50 mm corners, and a stepped mount of four rings.**
560 mm square, 146 mm from the wall including the pads.

Index argued that this should read as a piece of audio equipment and get there
through seams and proportion rather than features, and that it should keep a
substantial housing instead of pretending nine panels are a thin LCD. Case put
one bright anodised edge 3 mm proud of the glass. Strap said the borders are
parallel curves. Offset is those three taken to the end: instead of one bright
edge there are four, each 9 mm of face and 2 mm of rise, alternating bare alloy
and anodised black, climbing 8 mm from the body to the picture.

The radii run 50, 41, 32, 23 at the steps' outer edges and 41, 32, 23, 18 at
their openings, all from one centre 230 mm out on each axis. Nothing on the
object is a straight run into a corner.

**The finding that changed it.** The first version used 3 mm of rise and 6 mm
of face and every step sat in the shadow of the one in front, so the
alternation stopped reading and the mount was a black stack. Wider and
shallower fixed it: at 9 and 2 the bare alloy catches the room and the
anodised does not, which is the whole point of alternating them.

**Off, it is the best of the three.** A stepped aluminium square with a dark
centre, which is a real object rather than a screen that happens to be off.

**Tradeoffs.** Four laser-cut plates is four chances to be a millimetre out,
and a stepped mount collects dust in four corners rather than one. The
anodising is the cost: two of the four plates have to be finished by someone
else, or sprayed and accepted as paint.

## 2. Cove

**One continuous concave fillet, from the picture back to the plaster.**
676 mm square, 136 mm from the wall, 90 mm of cove.

Splay was the boldest thing in round two and the only one of its four that was
kept. Its argument: the surround should be pale rather than black, so the
artwork floods it with its own colour and the object blooms in whatever is
playing, and the slope cuts the off-axis glare that is the one real optical
fault of a flat smoked sheet. Its costs were four flat trapezoids meeting at
four hard corners, and 196 mm of depth.

A cove is that idea with the corners taken out. The section is a quarter circle
of 90 mm swept around a rounded rectangle: the throat is 496 mm at a 40 mm
corner, and at the wall the same curve has grown to 676 mm at 130. Because
offsetting a rounded rectangle outward by d raises its radius by exactly d,
every ring of that sweep is a parallel curve of the one before it and the
surface is exact rather than fudged at the corners.

What it buys is that **the object has no edge between the picture and the
wall**. It does not stop, it fades. The only line on it is Index's, a 3 mm
anodised reveal at the throat where the cove begins.

**Tradeoffs.** It is the widest of the three and the one that most wants a
smooth painted finish, which means filler and a long sanding session: a cove
shows every wave. Its bloom is only as good as what is playing, and against a
cover with a white field the flood is white. And it is the only one here whose
surround is bright enough to compete with the picture in a dark room.

## 3. Ply

**Eighteen millimetres of birch, routed, and nothing else.**
580 mm square, 152 mm from the wall.

Wall VI box is the object that is actually going to be built, and it is the
only one of the eight that costs about $150 rather than $250. Ply keeps its
carcass, its enclosure and most of its price, and spends the difference on one
detail. A cutter through birch plywood exposes seven laminations as a fine
striped arc, so the 50 mm corner and the aperture are routed, the face is
sprayed matte black, and the routed edges are left raw and oiled. The only
ornament on the object is the part the tool made.

**The aperture is a bevel, not a wall.** Cut square, the laminations only show
on the outer edge, and from the front the object is a black frame with a gold
line, which is Strap. Flared 26 mm over the sheet's 18, they become a striped
bevel around the picture, seen head on, and the object has something no other
one in this family has.

One 3 mm brass line lies on the face at the aperture, and the app's
seven-by-seven lattice is in brass on the bottom border, one tile lit, which is
Wall III's mark, and the same rear halo as everything else: that was asked for
across the whole set.

**Tradeoffs.** Routing a 50 mm radius through 18 mm birch wants a template and
a bearing-guided bit, and any tear-out is permanent and visible, because the
edge is the finish. Birch plies are not all pale: a void or a dark core in the
sheet shows. Buy the good plywood.

## 4. Section

**One extruded aluminium section, mitred four times, around a white plate.**
580 mm square, 142 mm from the wall, and not one radius on it.

The other three are round. This one is drawn from the canon rather than from
the eight: the objects that keep being collected and keep being copied.

- **Braun LE1**, Dieter Rams, 1959. A flat panel in a slim anodised frame with
  a pale face set into it, where the relationship between the frame and what it
  holds is the entire design. This is the direct parent.
- **[Vitsoe 606](https://www.vitsoe.com/us/606)**, Rams, 1960, in production
  ever since and in three museum collections. Its rule: the fixing is neither
  hidden nor decorated, it is the smallest correct part.
- **[Braun SK4](https://www.moma.org/collection/works/2649)**, Rams and
  Gugelot, 1956, MoMA. A metal body and a plain face need no third idea.
- **[Wall-mounted CD player](https://collections.vam.ac.uk/item/O1227135/)**,
  Naoto Fukasawa for Muji, 1999, V&A. One honest gesture and nothing else to
  press.
- And behind all four, Rams' tenth rule: good design is as little design as
  possible.

These are museum-collected designs rather than any single prize, and that is
the honest claim: MoMA holds the SK4, the V&A holds the player, and the 606 has
outlived every award it won.

**What that gives, exactly.** A 22 mm face of clear anodised aluminium in a
120 mm deep section, mitred at each corner with a hairline joint and no
fastener anywhere on the front. Set into it 2 mm back, an off-white lacquered
plate with a 487 mm square hole. Standing in that hole a 1.5 mm black anodised
bezel, and behind it the whole 480 mm picture, uncropped, as Index insisted.
No mark and no knob. The rear halo stays, because it is on every design now.

**Why it belongs on that wall in particular.** Every other body in this
catalogue is black, walnut, bone or bare metal, and the room has a black cubby
unit below it and an off-white wall behind. A black object extends the
furniture upward; a walnut one argues with the black. This one is made of the
two things already standing on that unit: the white deck and the white
speakers, and the brushed aluminium of the lamp. It joins the equipment rather
than the furniture, which is what makes it read as hung on the wall rather than
stacked on the shelf.

**Tradeoffs.** An off-white lacquered plate is the least forgiving surface in
this catalogue: it shows dust, it shows fingerprints at the aperture, and it
shows any wave in the substrate under a raking window. Four mitres in anodised
extrusion have to be cut on a good saw and cannot be filled, because filler
does not anodise. And with no mark and nothing on the face, everything rests on the
proportion: 480 in 580, a 22 mm face and a 26 mm margin, and if those are wrong
there is nothing else on the object to look at.

**Fallback.** A sprayed aluminium angle instead of a proper extruded section
saves about $30 and loses the 120 mm side, which is most of the object.

## Money

Planning allowances, not quotes, on the same basis as the earlier rounds. The
core build is about $150 with the smoked sheet; less the four sign standoffs
that none of these use, about $135.

| | Core | Adds | About |
|---|---|---|---|
| Offset | $135 | aluminium sheet and angle $45, four cut plates $48, anodising or enamel $18, halo strip $12, back panel $13, furring $3 | **$274** |
| Cove | $135 | cove stock $28, filler and bone lacquer $26, reveal angle $10, halo strip $12, back panel $13, furring $3 | **$227** |
| Ply | $135 | 18 mm birch panel $34, oil and matte black $14, brass angle and mark $16, back panel $13, furring $3 | **$215** |
| Section | $135 | anodised extrusion, four cuts $58, lacquered plate $26, black bezel angle $10, back panel $13, furring $3 | **$245** |

Taking the fallback at every step: Offset about $232 with sprayed plates rather
than anodised; Cove about $205 with a plain painted MDF cove; Ply about $199
without the brass; Section about $215 on angle rather than section.

Ply is the cheap one and it is still $215, which is $65 over the object it is
based on. That is the honest number and it should be a decision rather than a
drift: the brass, the second panel and the routing are what the difference
buys.

## The ledger, additions

| Part | Number | Status | Source |
|---|---|---|---|
| Concentric radius | `r - (outer - width) / 2` | VERIFIED | the definition of a parallel curve |
| Step face and rise | 9 mm and 2 mm | DESIGN | 6 and 3 put every step in shadow |
| Offset envelope | 560 sq, R50, 146 from the wall | DESIGN | Index's honest depth, Strap's corner |
| Cove section | quarter circle, 90 mm | DESIGN | the shallowest that clears the 63.5 mm bay |
| Cove throat and rim | 496 at R40, 676 at R130 | VERIFIED | the offset raises the radius by exactly d |
| Bevel flare | 26 mm over 18 mm of sheet, about 55 degrees | DESIGN | what makes the plies visible head on |
| Birch laminations | 7 in 18 mm | TYPICAL | 18 mm birch ply is usually 13 plies; 7 is the render's simplification and the visible count is what matters |
| Wall pads | 16 mm | DESIGN | the boxed enclosure's number, not the synthesis round's 30 |
| Vents | two 340 x 22 mm | DESIGN | the atelier study's opening, unchanged |
| Steel and glazing outlines | rounded to the body's family | DESIGN | a square sheet behind a rounded aperture shows four dark corners |
| Section face and depth | 22 mm and 120 mm | DESIGN | the LE1's proportion of frame to panel, at this size |
| Section proportion | 480 in 580: 22 of frame, 26 of margin, 1.5 of reveal | DESIGN | the only thing the object has |
| Mitre | 45 degrees, four, no fastener on the face | DESIGN | one section cut four times |

## Three faults the renders found

1. **The alternation stopped reading.** Offset's steps at 3 mm of rise and 6 of
   face were each in the shadow of the one in front, so four rings rendered as
   one black stack. 2 and 9 fixed it.
2. **Four dark corners in the throat.** Cove's smoked sheet and steel skin were
   square boxes behind a rounded 496 mm throat, so their corners showed as dark
   chevrons in the opening. Both are rounded rectangles of the same family now.
3. **Ply looked like Strap.** With a straight-walled aperture the plies were
   only on the outer edge, and from the front the object was a black frame with
   a gold line, which already exists. Flaring the aperture into a bevel put the
   stripe where you actually look.

## What a render cannot settle

Whether a routed birch edge is clean enough to be the finish, which depends on
the sheet and the bit and is answered by one test cut, not by a picture.
Whether a 90 mm cove can be made smooth enough in wood and filler that it reads
as a surface rather than as bodywork. Whether the alternation in Offset holds
in a real room, where the bare alloy has something to reflect and the render's
studio does not. And, as before, none of these has been weighed, powered,
measured for heat or hung.
