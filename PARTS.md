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
