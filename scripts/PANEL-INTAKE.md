# Panel intake, the no-power pass

Ten panels, one batch, and a return window that is open now and will not be
open later. Everything here is done with the panels loose on a table. No Pi, no
bonnet, no supply. It exists because the expensive mistakes on this build are
the ones you find after nine panels are screwed into a frame.

Budget about 45 minutes for all ten.

## What you need

A tape measure or calipers, a phone camera, good light, and somewhere to put
the boxes back in order. Keep every box and every bag until the wall is
finished.

## 1. Inventory before anything else

Open all ten. Count what is in each box: panel, data ribbon, power lead. Ten of
each, and note any box that is short. The Pi Hut listing promised a 30cm 16-pin
cable and a power lead per panel.

Also check the parcel paperwork for a duty or VAT invoice. These shipped from
the UK and are China origin, which was the open cost risk on this order.

## 2. Photograph every sticker

Batch and QC stickers, before they get scuffed or peeled. This is the only
proof of same-batch you will ever have, and it is the first thing a seller asks
for.

## 3. Read the driver chip on every panel

Look at the ICs on the back and read the part number off them. Write it down
per panel, exactly as printed.

This is the one that can end the day. The order was placed specifically for
conventional drivers. If any panel reads **ICN2053, ICN2153, or MBI515x** it is
the wrong part, it will not work with the planned software, and it goes back.
FM6124, FM6126A or SM16xxx class is what you want. This batch reads **FM6124HJ**
(confirmed 2026-08-26), a plain conventional driver that needs no special
initialisation. FM6126A would have needed an init sequence flag in the renderer,
which is why the distinction was worth checking.

All ten must match. A single odd panel out is a different batch.

## 4. Measure one panel properly, then spot check the rest

- Outline width and height. 160mm each way is the expectation. Three of them
  side by side is what makes the 480mm wall, so a few mm of error moves the
  frame, the acrylic cut and the mounting plan.
- Depth from the panel face to the deepest thing on the back. This sets how
  deep the frame box has to be.
- Mounting holes: thread size and where they sit. The M3 assortment on the
  parts list assumes M3.
- Where the INPUT and OUTPUT connectors and the power terminals sit. Note
  which edge each is on, because that is what decides ribbon routing and which
  way each panel gets rotated in the grid.

Then butt two panels together and look at the seam. The gap you see is the gap
the finished wall will have, and it is what the diffuser layer has to hide.

## 5. Check the ribbon actually reaches

Lay out the 3x3 on the floor or a table, 480mm square. Put the Pi where it will
live behind the wall. Now check that a 30cm ribbon gets from there to the first
panel of each of the three chains, and from each panel to the next.

If it does not reach, longer ribbons go into the same order as the bonnet and
the supply, not a separate one later.

## 6. Record it

```
python3 scripts/panel_qa.py intake --panel 1
```

Once per panel. It writes `qa/panel-NN.json` and rebuilds `qa/QA-SHEET.md`,
which puts every panel in one table. Read that table down the columns rather
than across the rows. A value that differs from the other nine is the finding.

## What is not in this pass

Everything electrical. Dead pixels, stuck pixels, address line faults,
brightness bins and the load test all need the panel lit, and that is the sweep
in `pi/PI-SETUP.md` section 5, once the bonnet and the 5V supply arrive.

Do not skip ahead and power a panel off something improvised. One 64x64 P2.5
pulls about 4 A at full white, panel power never goes through the Pi, and
HUB75 does not tolerate hot plugging.
