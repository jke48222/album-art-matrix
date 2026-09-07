# Parts ledger

Topology note: there is no backplane PCB in this build. Power runs PSU to bus
bar to fused 14 AWG drops to the panels' own harnesses. Logic runs through the
Adafruit Triple Matrix Bonnet.

## Owned before this round

- Raspberry Pi 5, microSD, Active Cooler, 27 W USB-C supply
- 10x 64x64 P2.5 HUB75 panels (9 for the wall, 1 spare)
- Pico 2 W (spare from a previous project, hosts the colorimeter)

## Ordered 2026-08-30

Amazon, first order:

| Item | Price |
|---|---|
| Plustool ratcheting crimper, AWG 22-10, heat shrink dies | $18.99 |
| RVBOATPAT bus bar pair, 150 A, 1/4 inch studs, 12x M4 each | $16.99 |
| URTOOLS heat gun, 900 W | $14.99 |
| 100x blue 16-14 AWG heat shrink butt connectors | $9.99 |
| OOK French cleat, 100 lb | $15.97 |
| Fgruh 750 pc M3 hex screw kit (screws, nuts, washers, no standoffs) | $9.99 |
| ELEGOO Dupont jumper kit | $6.98 |
| 2x Amazon Basics IEC C13 power cords (one becomes the bench pigtail) | $13.88 |
| Digital multimeter | $9.98 |

Amazon, second order:

| Item | Price |
|---|---|
| Mean Well LRS-350-5, 300 W 5 V (wall supply, S2) | $43.54 |
| Mean Well LRS-50-5, 50 W 5 V (bench supply, S1) | $19.90 |
| Antrader IEC C14 inlet with switch and fuse, 2 pc | $9.99 |
| Nilight 10x inline ATC fuse holders, 14 AWG | $10.10 |
| 25x 10 A ATC blade fuses | $4.99 |
| 2x TCS34725 color sensor breakouts | $8.99 |
| Haerkn 14 AWG 2-core silicone wire, 25 ft | $19.98 |
| 60 W soldering iron kit | $11.99 |
| ALBO 250 pc blue 16-14 AWG heat shrink ring terminal kit | $19.99 |

Adafruit:

| Item | Price |
|---|---|
| Triple LED Matrix Bonnet #6358 | $9.95 |
| Mini USB microphone #3367 (S3 fallback path) | $5.95 |
| VEML7700 lux sensor #4162 (S6 auto-brightness, mount facing the ceiling) | $4.95 |

## Still to buy

Now, cheap, and actually needed before the first pigtail:

- Wire strippers, 10-22 AWG, about $10. Nothing ordered strips wire, and the
  bench pigtail means stripping the cut IEC cord on day one.
- Small pack of red 22-16 AWG rings or forks, about $7. The IEC cord
  conductors are 18 AWG, below the blue 16-14 range everything else covers.
  (Bench workaround: double the stripped conductor over to fatten it into a
  blue barrel.)

Before the wall build (S2):

- SL22 10005 NTC inrush limiter. Mouser 995-SL22-10005, $5.50 plus shipping,
  or a genuine Ametherm listing on Amazon. Sim says 275 A inrush bare, 15.8 A
  with it. Wall box only, the bench supply does not need it.
- Nylon M3 standoffs (Ladinka 580 pc kit or similar, about $9). Measure a
  panel's rear clearance first, then order. Metal standoffs over a panel back
  full of live joints is a short waiting to happen.
- Possibly a second 14 AWG spool. Sketch the layout first, 25 ft covers three
  feed pairs plus nine short drops only if the bus bar sits central.

S3:

- Behringer UCA202 line-in, about $30.

S6, local:

- 3 mm opal acrylic and 3 mm smoked ND acrylic, each cut 480x480 mm.
- Hardwood for the frame, fasteners.
- Optional: assorted heat shrink tubing kit, about $7.

## Verify on arrival

- ALBO kit: count the 1/4 inch rings, the listing is new with thin history.
- Bus bar box: check whether the 24 included terminals are 16-14 AWG rings.
  If so they cover all 18 panel-drop positions.
- Panel boxes: confirm IDC ribbons and 4-pin power harnesses shipped with the
  panels.
- LRS-350-5: inspect for signs of a returned or used unit, commingled
  inventory has shipped dented units to other buyers. Verify both supplies
  read 5.0 to 5.1 V on the multimeter before anything connects to them.

## Corrections carried over from the old list

- The crimper is a ratcheting AWG 22-10 heat shrink type. The previously
  listed SN-48BS is a 26-16 AWG open barrel tool and cannot do this job.
- Per-panel fuses are 10 A. A 64-wide panel at full white draws 7.68 A, so
  the once-considered 7.5 A blows under a white-heavy sleeve.
- Panel standoffs must be nylon, not metal.
- Mean Well on Amazon only through brand-verified listings. A "Generic" LRS-350-5
  listing claiming 73 A is not a real Mean Well and its own spec table
  contradicts its title.

## For the designed wall (design/README.md), 2026-09-07

What the second design adds, and what the original list still owes. Sizes
follow the numbers in `design/wall_model.py`. Nothing here is ordered.

### Structure

| Part | Spec | Why |
|---|---|---|
| Black walnut | four rails 522 x 87 x 16 mm: one 5/8 in x 3-1/2 in board, 8 ft, or two 4 ft | the frame |
| Steel mount plate | 496 x 496 x 1.5 mm (16 ga), eighteen cable slots, cleat holes; laser cut (SendCutSend or a local shop) or a 24 x 24 in 16 ga sheet cut by hand | the panels' magnetic feet hold to it; replaces the PVC board and every standoff |
| Black anodised aluminium flat bar | 1/8 x 1/2 in, one 6 ft length, cut to four at 490 mm | the reveal: stood on edge in the glazing rebate, its 3 mm edge is what shows |
| Back panel | 3 mm black aluminium composite (ACM) or black anodised aluminium, 490 x 490, two 340 x 22 openings; SendCutSend can cut it with the steel | closes the box; the vents are in it |
| Brass flat bar | 1/16 x 1/2 in, 12 in | eight mitre splines, about 20 mm each |
| Brass sheet | 0.016 in, a 20 x 20 mm piece engraved with the 7x7 lattice, plus a 30 x 11 mm badge | the mark on the bottom rail, the badge on the back |
| Countersunk black M3 x 8 screws | 8 | the back panel; the M3 kit has socket heads only |
| Hardwax oil | one small tin (Osmo or Rubio) | the walnut |
| Wall pads | four 30 x 30 x 16 mm blocks, walnut offcuts | hold the back off the wall so the vents breathe |

### Electrical

| Part | Spec | Why |
|---|---|---|
| USB-C to bare wire pigtail | 18 AWG, about 30 cm | feeds the Pi from the +5 V bar through the tenth fuse holder |
| ATC fuse, 3 A | 1 (the 25 on hand are 10 A) | the Pi's drop |
| 14 AWG silicone, second spool | 25 ft | nine drops and three feed pairs need about 38 ft; 25 ft is on hand |
| M4 x 6 mm screws | 4 | the LRS-350-5 bottom holes (3 mm thread depth) |
| M2.5 nylon standoffs and screws | 4 sets, 3 to 5 mm | the Pi's holes are 2.7 mm; M3 does not fit |
| IDC ribbons, 50 cm | 2, only if the 30 cm ones shipped with the panels do not reach from the bonnet to the far rows | the three port runs |
| Wire strippers, 10 to 22 AWG | 1 | still not owned (August note) |
| Red 22 to 16 AWG rings or forks | small pack | the 18 AWG mains conductors (August note) |
| Adhesive zip tie mounts | one pack | dressing the drops to the plate |

### Glazing

| Part | Spec | Why |
|---|---|---|
| Opal acrylic | 3 mm, 492 x 492 | the diffuser |
| Smoked ND acrylic | 3 mm, 492 x 492 | the face: black glass when the wall is off |

### Tools this frame needs that the ledger does not list

A mitre saw or a mitre box, a router with a rabbeting bit or a table saw for
the 4 x 14 mm glazing rebate, a band clamp, a drill with a 3.2 mm bit, a
thin kerf saw or a spline jig for the mitre keys, a jigsaw with a metal
blade if the steel or the ACM is cut by hand.

### No longer needed

The nylon M3 standoff kit, the PVC foam board, and the 27 W USB-C supply as
part of the wall (it stays as the bench supply). The TCS34725 boards remain
calibration tools.

### Measure first

The height of a magnetic foot off a panel back, and the height of the
tallest thing on a panel back, most likely the harness plug. Both go into
`design/wall_model.py` before the steel is ordered.

## The cheap way, 2026-09-07

The walnut design above is the aspiration. This is what gets it hung this
week. The panels' own magnetic feet do the work: one steel skin is the whole
mount, a plywood square behind it takes every screw, the smoked acrylic in
front is the finish. No frame, no reveal, no brass, no laser cutting, no
second wire spool (the bars sit behind the panels, so the drops are short),
and the back is open, so the supply's fan cools itself.

| Part | Spec | About |
|---|---|---|
| Plywood or MDF, 24 x 24 in | 1/2 in project panel, Home Depot | $18 |
| Steel sheet, 24 x 24 in | Everbilt 22 gauge, glued to the plywood front; 16 gauge is $64.20 and only worth it if you skip the plywood | $30 |
| Matte black spray paint | one can, for the steel face and the plywood edges; magnets hold through paint | $6 |
| Smoked acrylic, 24 x 24 x 1/8 in | grey tinted cast acrylic; Walmart lists the Sibe-R sheet at $24.88 | $25 |
| Sign standoffs, 1 x 1 in, black | pack of 4; through the acrylic corners into the plywood | $12 |
| USB-C to bare wire pigtail | 18 to 22 AWG, 2 pin; the Pi's feed from the +5 V bar through the tenth fuse holder | $8 |
| ATC fuses, 5 A | a few; the Pi's drop, the 10 A ones on hand are for panels | $5 |
| M4 x 16 screws and nuts | 4, through the plywood into the supply's bottom holes | $3 |
| 1 x 2 furring strip, 8 ft | two blocks under the cleat and two feet at the bottom corners, so the back hangs 45 mm off the wall over the electronics | $2 |
| | | **about $109** |

Skip the acrylic and it is about $84. Everything else is already on the
bench: the panels, the supply, the bars, ten fuse holders, the wire, the
cleat, the M3 kit, the inlet, zip ties, butt connectors, ring terminals.

### The order of work

1. Home Depot: plywood, steel, paint, furring strip, M4s. Amazon or Walmart:
   acrylic, standoffs, pigtail, fuses.
2. Glue the steel to the plywood (construction adhesive, weight it flat
   overnight), then paint the face and the edges matte black.
3. On the back: the supply low with M4s, the bars in the middle with M3 kit
   screws and nuts through the plywood, the fuse holders zip tied to the
   drops, the Pi on zip ties or foam tape (its holes are 2.7 mm; M3 will
   not fit), the inlet on its flange at the bottom edge. Bond the steel
   skin to the -V bar with one ring terminal under a bar screw.
4. Cables come round the plywood's edge to the front: ribbons along the
   left edge, drops along the bottom. On the front they run inside the
   panels' 12 mm shells, crossing at the seams, exactly as they do on the
   floor now.
5. Panels on by their magnets, in the order the tile map already
   established. Run the tile map once to confirm.
6. Cleat on two furring blocks at the top of the back, two feet at the
   bottom corners, the wall half of the cleat on the wall.
7. Acrylic on the four standoffs, and hang it.

What it looks like: a 24 inch square of black glass floating an inch off a
black plate, the art glowing through it, the 65 mm border reading as a
black mat. From the side, the electronics are visible behind the plate;
a 24 x 24 sheet of black ACM or foam board as a back cover is a $15 add-on
for later, and the walnut frame is the add-on after that.
