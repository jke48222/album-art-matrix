# Assembly: from nine panels on the floor to a wall you can hang

This picks up exactly where you are. Everything before it is done and does not
need repeating. Read section 0 before buying anything, because one measurement
in it decides a part number.

The build is the cheap one: a plywood square with a steel skin, the panels held
on by their own magnets, a sheet of smoked acrylic floating in front. The parts
list and prices are at the end of [PARTS.md](../PARTS.md); the model is
[design/](../design/), and `docs/WALL-BUILD.md` is the earlier runbook whose
first eight steps you have already finished.

---

## 0. Where you are, and the one thing to measure

**Done and proved, 2026-09-06:**

- Nine panels, three chains of three, one per bonnet port, all lit.
- 5.08 V at the farthest panel at a light level, **5.05 V under full white**.
  Your drops and crimps are good; nothing about the wiring needs revisiting.
- Renderer stable at 192x192, brain running at 192, video played end to end,
  56-59 C, never throttled.
- **The tile map is settled**: every chain fills right to left, rows in port
  order. `order = "2 1 0 5 4 3 8 7 6"` is in the Pi's `config.toml` and the
  picture lands the right way round. This is the thing you must not lose in
  the disassembly, and section 3 is about not losing it.

**Not done, because the panels are face down:** the whole visual QA. Dead
pixels, brightness bins, seams, and whether any panel is mounted upside down.
Section 7 is the first time you will see the faces.

**Also outstanding:** the white balance is still an unmeasured guess
(r 1.00, g 0.88, b 0.83 on the Pi). Section 8.

**Before anything else: the Pi is not answering.** It timed out again just now,
the same as it did at 12:17 and 23:45 on the 6th. Power cycle it and check
`ssh wall` works before you start pulling the build apart, because you cannot
verify anything without it. Its journal is volatile, so if it keeps happening,
make it persistent first:

```bash
sudo sed -i 's/^#\?Storage=.*/Storage=persistent/' /etc/systemd/journald.conf && sudo systemctl restart systemd-journald
```

### The measurement that gates the order

Take one panel. Sit it face down on a flat table on its four magnetic feet.
Measure **how far the panel's back stands off the table**. That is the foot
height, and it is the only number in this design nobody has published.

- **3 mm** (assumed): buy **1 inch** standoffs. The glass ends up 7.9 mm off
  the LEDs.
- **5 mm or more**: buy **1-1/4 inch** standoffs instead.

While the panel is in your hand, also measure the tallest thing on its back,
most likely the power plug. If anything back there is taller than 12 mm it
wants a note, because the cables have to run past it under the glass.

---

## 1. Shop

Home Depot, one trip:

- 24 x 24 in plywood or MDF project panel, 1/2 in
- 24 x 24 in steel sheet, 22 gauge (the 16 gauge is twice the price and you
  are gluing it to plywood, so it does not need the stiffness)
- Matte black spray paint, one can, and a small tube of construction adhesive
- 1 x 3 furring strip, 8 ft. **Not 1 x 2**: a 1 x 2 on edge holds the board
  38.1 mm off the wall and a bus bar with its cover on is exactly 38.1 mm tall.
- Four M4 x 16 screws and nuts

Amazon or Walmart:

- 24 x 24 x 1/8 in smoked grey acrylic (#2064 grey, about 35 percent
  transmission, is what the renders assume)
- Four black sign standoffs, the size section 0 decided
- USB-C to bare wire pigtail, 18 to 22 AWG
- A few 5 A ATC blade fuses (your 25 are 10 A, which is the panel size)

Everything else is on the bench. About $109.

**Check on arrival:** the acrylic comes with protective film both sides. Leave
it on until section 9.

---

## 2. Build the board

1. Lay the steel on the plywood, glue side down, adhesive in a grid of dots
   about 100 mm apart plus a bead round the perimeter. Weight it flat
   overnight with books across the whole face, not just the middle.
2. Sand the plywood edges, then paint the steel face and all four edges matte
   black. Two thin coats. The magnets hold through paint.
3. While it dries, mark the back in pencil: **write TOP on the top edge.**
   Every position in section 4 is given as you look at the back with TOP up.
4. Mark the panel grid on the painted face: the picture is 480 mm square and
   centred, so there is a 64.8 mm border all round. Draw the outer 480 square
   and the two lines at 160 and 320 in each direction. You will lay panels to
   these lines, and the magnets let you slide them until the seams are right.

Optional, free, and the only ornament in the design: stencil the app's seven
by seven lattice on the bottom border, centred, 2 mm squares on 3 mm centres,
one tile brighter than the rest. A scrap of card and a fingertip of grey paint.

---

## 3. Label, then strike the floor layout

This is the step that protects the tile map. **Do it with everything powered
down, and do not skip the labels.**

1. Power off at the inlet switch. Shut the Pi down cleanly first
   (`sudo shutdown -h now`), then pull the mains.
2. Before touching a cable, photograph the whole floor layout from directly
   above, and again close up at each row's ribbons.
3. Label with masking tape:
   - **Each panel**, front face, with its tile number 1 to 9 reading across
     from the top left. You established this map; it is the thing you are
     preserving.
   - **Each ribbon**, both ends, with the two tiles it joins ("1-2", "2-3").
   - **The three bonnet ribbons**, with which port and which row.
   - **Each drop pair** at the bus bar end, with its tile number.
   - Note which side of each row the bonnet's ribbon enters. The chains fill
     right to left, so the panel the bonnet feeds is at one end of the row,
     and the Pi has to end up on that side of the board.
4. Now disconnect: ribbons first, then the drops at the bus bar end, leaving
   the panel harnesses attached to their panels.
5. Set the nine panels aside face down, in their tile order, somewhere they
   will not get walked on.

---

## 4. The back

Board face down, TOP up, back toward you. Positions are approximate; what
matters is that the cables reach and nothing sits proud of 63.5 mm.

- **Pi 5 with cooler and bonnet:** top corner, on the side your bonnet ribbons
  reach (section 3, step 3). About 90 mm in from that edge and 120 mm down.
  Its mounting holes are 2.7 mm so M3 will not fit: use M2.5 nylon standoffs
  if you have them, otherwise two zip ties through drilled holes, or foam
  tape. The tallest stack in the build is the Pi plus riser plus bonnet plus
  the IDC shrouds, about 36 mm, which is why the gap is 63.5.
- **Bus bars:** the opposite side from the Pi, centred vertically, about
  120 mm in from that edge, positive above negative. M3 screws and nuts
  through the plywood.
- **Nine fuse holders:** the middle of the board, in a three by three, zip
  tied so each sits near the drop it feeds.
- **Supply:** across the bottom, roughly centred, 40 mm up from the edge.
  Four M4 x 16 through the plywood into its bottom holes, which take 3 mm of
  thread. Its fan faces out into the room.
- **Inlet:** bottom corner, on the bus bar side, screwed to the plywood
  through its flange. The SL22 goes in series on the hot line between the
  inlet and the supply's L terminal.

Then the wiring, which is the same wiring you already have, re-terminated:

1. Supply to bars: three 14 AWG pairs, one from each of the supply's three
   +V/-V terminal pairs.
2. Nine drops: bar to fuse holder to panel harness, fused on the positive
   side. Keep the tile labels on.
3. **One bond you did not need before:** a ring terminal from the steel skin
   to the negative bar. Drill a small hole through the steel and plywood near
   a corner of the border, bolt through it, and run 18 AWG to a bar screw. The
   skin is a big conductive plate touching every panel's frame; tie it to
   ground once, and only once.
4. The Pi's feed: the tenth fuse holder with a **5 A** fuse, from the positive
   bar to the USB-C pigtail. Nothing else goes in the Pi's USB-C port.
5. Mains: inlet L through the SL22 to the supply's L, N straight to N, earth
   to FG. No exposed copper, cover on, tug test.

**Do not power up yet.** The panels are not on.

---

## 5. The front

1. Panels on, by their magnets, working to the pencil lines. Tile 1 top left,
   reading across. Slide them until the seams are even; the gap between two
   panels should look like the gap between two pixels.
2. Cables round the edge. Each drop comes from the back, around the bottom
   edge, and forward to its panel's plug. The ribbons run panel to panel
   inside the 12 mm rear shells, exactly as they did on the floor, crossing
   at the seams. The three bonnet ribbons come round the side edge.
3. Zip tie every run to the back so nothing hangs where the glass will sit,
   and nothing pulls on a connector.
4. Check the depth: put a straight edge across the panel faces. Nothing should
   stand higher than the panels except the cables under the shells.

---

## 6. First power up on the board

Every panel is powered, so the chain will behave. Supply on first, then the Pi.

```bash
ssh wall
sudo systemctl stop album-art-matrix          # one writer on the pipe at a time
cd ~/album-art-matrix
.venv/bin/python scripts/panel_qa.py show tilemap --wall 3x3
```

Nine numbers, reading 1 to 9 left to right, top to bottom, arrows pointing up.

- **They read correctly:** nothing to change. The order in `config.toml` still
  matches the wiring, which is what the labels were for.
- **A number is upside down or sideways:** that panel is mounted the wrong way
  round. Lift it off, turn it, put it back. This is the first time you can see
  this, and it is why the magnets are worth having.
- **They are in the wrong order:** you have swapped two ribbons. Fix the
  cable, not the config.

Ctrl-C when you are satisfied, then `gridlines` to align:

```bash
.venv/bin/python scripts/panel_qa.py show gridlines --wall 3x3
```

An amber line down every seam and a blue cross through the middle. Slide
panels until the lines are straight. Then Ctrl-C.

---

## 7. The visual QA, at last

The QA sheet has been empty since August because nobody could see the panels.
Now you can. Eighteen patterns, a prompt after each, about fifteen minutes.

```bash
.venv/bin/python scripts/panel_qa.py sweep --wall 3x3 \
    --panel 1,2,3,4,5,6,7,8,9 --tile 1
```

Enter passes, `f` fails and asks which tile and what is wrong, `n` adds a
note, `r` repeats, `s` skips. Verdicts land in `qa/panel-NN.json` and
`qa/QA-SHEET.md` rebuilds itself.

What you are looking for, in the order the sweep shows it:

| Pattern | Look for |
|---|---|
| `black` | any pixel that glows. Stuck sub-pixel, and it glows forever |
| `red` `green` `blue` | dead dots; and red must read RED, not blue |
| `white25` | the best dead-pixel hunt of the set: faults hide in bright fields |
| `gray50` | blotches or crawling texture (that is dither and bit depth, not the panel) |
| `checker1` | smearing sideways is ghosting, usually ribbon length |
| `hlines` `vlines` | a missing stripe is a driver; a dead column is a shift register and that panel becomes the spare |
| `rowwalk` `colwalk` | out of order, in blocks, or two at a time means address lines. The bonnet's E switch is for exactly this |
| `halves` | swapped halves is R1/G1/B1 crossed with R2/G2/B2; interleaved is a scan mismatch |
| `border` | missing edge pixels show as a dark seam between panels |
| `ramp` | hard steps are banding: gamma and bit depth, not the panel |
| `tilemap` | which panel is where, and which way up |
| `onebyone` | each tile alone. A dark tile is its fuse, its drop or its ribbon |
| `bins` | **photograph this one.** All nine at 50 percent in one frame. A panel from a different production bin reads brighter or a different white than its neighbours, no software fixes it, and it goes in a corner or becomes the spare |
| `gridlines` | seams and straightness |

If `bins` shows a mismatched panel and you still have the spare, this is the
moment to swap it: the magnets mean it costs two minutes.

---

## 8. White balance, the last calibration

Everything the wall shows goes through these three numbers and they have never
been measured. This is the difference between album art and cyan mush.

**Restore the two settings the tuning session left at zero first**, or you will
be calibrating against a ghost:

```bash
echo 1000 > ~/album-art-matrix/addr-settle-ns    # the bottom-row ghost fix
echo 180 > ~/album-art-matrix/panel-brightness   # 160 to 200 for nine panels
sudo systemctl restart album-art-renderer
```

Then measure. The full procedure is `scripts/WB-PROCEDURE.md`; in short: wire
the TCS34725 to the spare Pico 2 W, warm the panels for ten minutes at working
brightness, show full white with no balance applied
(`python scripts/show_white.py --sink pi`), hold the sensor flat against the
face shaded from the room, and read the suggested gains off the REPL. Put the
settled numbers in the Pi's `config.toml` under `[whitebalance]` and restart
the brain.

**Do not use the app's Calibrate flow for this.** It multiplies each new
measurement onto the previous multipliers and it measures full white at full
brightness, which clips a phone sensor; that combination is what gave the wall
its orange cast in the first place. If you have no sensor, the eyeball
fallback at the bottom of the procedure is better than the app.

---

## 9. Glass

1. Peel the film from the back face of the acrylic only.
2. Mark and drill the four standoff holes, 30 mm in from each corner. Slow
   speed, no pressure, a scrap block underneath. Acrylic chips if you rush.
3. Screw the standoff barrels to the board through the border. They land on
   the black steel, clear of every panel.
4. Rest the acrylic on the barrels, fit the caps, snug only.
5. Peel the front film last, after the board is on the wall.

The barrel sets the optics: 25.4 mm off the steel, less the panel and its
feet, leaves the glass about 8 mm clear of the LEDs.

---

## 10. Hang it

1. Two blocks of 1 x 3, 120 mm long, screwed to the back under the top edge,
   2-1/2 in face standing off the wall. The frame half of the cleat goes on
   them, level.
2. Two feet of the same strip at the bottom corners, so the board sits square
   and does not rock.
3. The wall half of the cleat on the wall, into studs if you can find them.
   The finished thing is about 6 kg.
4. Dress the mains cord down from the bottom corner.
5. Lift it on. The 63.5 mm gap is what the supply's fan breathes through, so
   do not stuff anything into it.

---

## 11. Leave it running

```bash
sudo systemctl start album-art-matrix
journalctl -u album-art-matrix -n 5 --no-pager     # wall 3x3 of 64px = 192x192
```

Play something. Then check it survives a reboot, which is the only test that
matters for a thing on a wall:

```bash
sudo reboot
```

Wait ninety seconds, then confirm both services came back and the picture is
on. If the brain did not start, it exited cleanly at some point and the unit
is `Restart=on-failure`; `systemctl enable` it if it is not already.

Rebuild the phone app against the wall's real size when you have a minute:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project tessera/Tessera.xcodeproj -scheme Tessera \
  -destination 'platform=iOS,id=17BC0590-3932-52E0-A544-F4E27375D28F' \
  -derivedDataPath build-device -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration build
xcrun devicectl device install app --device 17BC0590-3932-52E0-A544-F4E27375D28F \
  build-device/Build/Products/Debug-iphoneos/Tessera.app
```

---

## The traps, in one place

Everything below cost real time to find. None of it is obvious.

- **Never move a HUB75 ribbon with the panels powered.** 3.3 V logic against a
  5 V rail; hot plugging kills panels and bonnets together.
- **An unpowered panel breaks the one before it.** Its input diodes clamp the
  shared address lines, and the panel upstream scans a single row. If a panel
  shows only its top row, suspect its neighbour's power before the panel. A
  dim red glow on an unpowered panel is it being fed through the ribbon.
- **Two writers on the frame pipe is garbage.** The brain and `panel_qa.py`
  both write to `/tmp/album-frame.fifo`; running both interleaves frames.
  Always `sudo systemctl stop album-art-matrix` before QA.
- **`pkill -f "[b]rain.main"` exits it cleanly**, and the unit only restarts on
  failure, so it stays down until you start it. That is a feature during QA
  and a surprise afterwards.
- **Always bracket the pattern in a pkill**: `pkill -9 -f "[a]rt_display"`.
  Without the bracket it matches the ssh command's own line, kills your shell
  first, and can leave two renderers running. Check with
  `pgrep -fc "[a]rt_display"` and expect 1.
- **The Pi owns its `config.toml`.** `deploy.sh` seeds it once and never
  touches it again. Never rsync the Mac's copy over it: that is what flipped
  `[sink] type` back to preview and left the wall dark for an evening.
- **`sudo` needs your password on this Pi**, and `sudo -n` is refused, so any
  service start or stop is yours to type.
- **The bonnet's STEMMA QT port shares SDA and SCL with matrix port 3.** With
  three chains running, that I2C bus is taken, so the VEML7700 lux sensor
  cannot sit on it. It needs a software I2C bus on spare GPIOs, or it waits.
- **Full white on all nine is about 69 A** against the supply's 60. It never
  happens with album art; it happens with test patterns. Keep `white100`
  short and leave the cap at 160 to 200.

## The commands, in one place

```bash
# state
cat ~/album-art-matrix/wall                      # the shape: 3x3
systemctl is-active album-art-matrix album-art-renderer
pgrep -fc "[a]rt_display"                        # must be 1
curl -s localhost:8788/health

# QA (brain stopped first)
sudo systemctl stop album-art-matrix
.venv/bin/python scripts/panel_qa.py show tilemap --wall 3x3
.venv/bin/python scripts/panel_qa.py show gridlines --wall 3x3
.venv/bin/python scripts/panel_qa.py sweep --wall 3x3 --panel 1,2,3,4,5,6,7,8,9 --tile 1
.venv/bin/python scripts/panel_qa.py sheet       # rebuild QA-SHEET.md

# panel tuning (read at renderer launch)
echo 180  > ~/album-art-matrix/panel-brightness  # 1-254
echo 1000 > ~/album-art-matrix/addr-settle-ns    # bottom-row ghost
sudo systemctl restart album-art-renderer

# back to normal
sudo systemctl start album-art-matrix
```
