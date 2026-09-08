# Four objects

Not four finishes on one body. Each of these is a different thing to have on a
wall, with its own silhouette, its own material logic, and its own answer to
where your hand goes to switch it on.

```
/Applications/Blender.app/Contents/MacOS/Blender --background \
    --python design/alt_model.py -- --design splay --out design/renders \
    --face design/face192.png
```

`--design sleeve|lean|system|splay`, `--cloth charcoal|oatmeal|oxblood|forest|ink`.

## What they all share, and what they no longer have

Nine panels, 480 mm square. The supply, two bus bars, nine fuse holders and
the Pi, which have to hide somewhere. Smoked acrylic 6.7 mm off the LEDs. A
halo of 36 emitters in 12 colour zones, each the average of the artwork's own
outer strip, so the wall carries the record's colour rather than mood
lighting.

**Gone:** the knob, the tenth panel, the letterbox readout, the Pico that
would have driven it, and the 185 mm bottom border that only existed to make
room for that panel. The spare panel goes back to being a spare, which is the
one thing standing between you and a dead tile.

**New in all four:** the C14 module with its switch and fuse is placed where a
hand already goes, and it is different in every one. That was the brief and it
is the detail that most changes how each object is used.

| | Envelope | Depth | The switch |
|---|---|---|---|
| Sleeve | 544 x 566 | 129 mm | in the open top edge, reached the way you lift out a record |
| Lean | 600 x 640 | 132 mm | in the right end of the foot, under the hand that steadies it |
| System | 640 x 900 | 77 mm | on the module's front panel, like an amplifier |
| Splay | 660 x 660 | 196 mm | under the bottom rim, felt for rather than seen |

## 1. Sleeve

An oversized record jacket. A 544 mm card, art nearly edge to edge the way a
jacket is printed, overhanging a slightly smaller body so it reads as card
rather than box. It stops 34 mm short of the top, and the object is open along
that edge exactly as a sleeve is: you can see the inner card standing proud of
it, the way a record stands proud of its jacket.

**The mains module sits in that opening.** Switching the wall on means
reaching into the sleeve. That is the only gesture the object asks for, and it
is the one Fukasawa's pull-cord player argues for: a thing on a wall should
have one honest action, and it should be the action the form already suggests.

Cheapest of the four to build: two rectangles cut in a card, cloth wrapped
round the back, and nothing on the face at all.

## 2. Lean

It does not hang. A slab tipped back eight degrees, standing in a solid cast
foot on a sideboard. No cleat, no wall fixing, no holes in anyone's plaster,
and it moves rooms in ten seconds.

Wrapped all round in one cloth, back included, because this one is furniture
and furniture is one material. The foot is a dark cast block, deliberately not
the same thing as the slab: it reads as something the slab was set into rather
than something built onto it.

**The switch is in the foot's right end**, where your hand already goes to
steady the thing when you move it.

The cost is honest: it takes up sideboard depth, and a leaning object is a
leaning object, so it wants a surface it can stay on.

## 3. System

Two pieces, after Rams' [606](https://www.vitsoe.com/us/606) — a small number
of simple components hung on a wall and rearranged at will, in production
since 1960 and in three museum collections.

Because the machine moved out of the picture, **the picture becomes a 77 mm
plate instead of a 129 mm box.** That is the whole argument. Everything heavy
sits in a separate 640 x 180 module below: vented, alloy-faced, with the
supply, the bars, the fuses and the Pi inside and a real front-panel switch at
the right end. The umbilical between them is shown, not hidden, because in a
system the connection is part of the design.

It is the only one of the four you can change your mind about later. Move the
plate, keep the module. Add a second plate. Put the module on a shelf instead.

## 4. Splay

A funnel. 660 mm square at the rim, narrowing 78 mm back to a 500 mm opening,
so you look down four pale sloping walls at the picture.

The walls are the point. They are bone, not black, so **the artwork floods
them with its own colour** and the object blooms in whatever is playing: the
halo idea turned inward, where you can actually see it, instead of a glow on
the plaster behind. Off, it is a faceted block with a dark square in it, and
it reads as sculpture rather than as a screen that happens to be off.

It also does something useful. The funnel cuts off-axis glare, which is the
one real optical fault of a flat sheet of smoked acrylic in a lit room.

Deepest of the four at 196 mm, and the boldest. It is also four trapezoids of
plywood and a can of paint.

**The switch is under the bottom rim**, facing down: invisible from any normal
angle, found by feel in one second.

## Which is which

- **Sleeve** if the object should be about records.
- **Lean** if you do not want to drill the wall, or you want it to move.
- **System** if you want the picture as thin as it can be, and you like that
  the machine is honest about being a machine.
- **Splay** if you want the one that people ask about. It is mine.

## Parts these add, over the buildable design

| Part | For | About |
|---|---|---|
| Acoustic or speaker grille cloth, 1 yd | sleeve, lean | $15 |
| 3 mm ply or ABS sheet | the front card or plate | $10 |
| Aluminium angle or trim | the bezel in the opening | $10 |
| Addressable LED strip, 2 m | the halo | $12 |
| 1/4 in plywood panel, 24 x 24 | the back | $13 |
| One more 1 x 3 furring strip | the rails | $3 |

About **$63** over the core build, so roughly **$180**, or $150 taking the
cheaper option at every step. Removing the knob, the encoder and the tenth
panel's driver took about $20 off the previous scheme and removed a firmware.

Per design, on top of that: splay wants four trapezoids and a litre of bone
paint (about $12); lean wants a foot, either a cast block or a laminated
offcut (about $10) and no cleat at all, which it gets back; system wants a
second small carcass and a length of braided sleeving (about $18).

## If these are studies, or if one of them is the build

**As studies.** The plywood, steel and smoked-acrylic design with its three
enclosures stays the plan of record. Nothing in `docs/ASSEMBLY.md` changes.

**As the build.** All four use the same nine panels on the same steel with the
same fifteen openings and the same electrical layout. What changes is the
carcass around them, and in one case where the carcass is. Sleeve and lean and
splay leave the wiring untouched; system moves the supply, the bars and the Pi
into a second box, which lengthens nine drops and three ribbons into one
umbilical and is the only one that needs the electrical section rewritten.

## The ledger, additions

| Part | Number | Status | Source |
|---|---|---|---|
| Magnet feet | Adafruit 4631, 16.6 mm, M3 | VERIFIED | product page |
| Magnet protrusion | 10.6 mm | TYPICAL | 16.6 less about 6 mm of thread |
| Ports and chain length | three ports, equal counts | VERIFIED | `pi/run_renderer.sh` |
| C14 module | approx 50 x 30 x 30, switch and fuse | LISTING | Antrader |
| Sleeve card | 544 x 532 x 11, 34 mm opening | DESIGN | jacket proportion |
| Lean tilt | 8 degrees | DESIGN | enough to read as leaning, not enough to slide |
| System module | 640 x 180 x 95 | DESIGN | set by the supply's 215 x 115 |
| Splay funnel | 660 rim to 500 opening over 78 mm | DESIGN | about 48 degrees |
| Halo | 36 emitters, 12 zones, 45 mm off the wall | DESIGN | sampled from the face image |

## What a render cannot settle

The cloth is a shader. How a real weave takes the halo's colour at a grazing
angle is not something this answers. The splay's bloom depends on how much
light nine panels actually throw sideways at 160 nits, which wants a
photograph, not a render. And the lean's foot has to be heavy enough that the
slab cannot walk off a sideboard, which is a question about mass and not
about shape.
