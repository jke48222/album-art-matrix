# Building the wall, without the frame

> **Steps 1 to 8 of this page were finished on 2026-09-06.** Nine panels are
> lit, the tile map is settled and the wiring is proved. To carry on from
> there, go to **[ASSEMBLY.md](ASSEMBLY.md)**, which takes it from the floor
> to the wall. This page is kept as the record of how the wiring was arrived
> at and what each check was for.


Nine panels, one Pi, one supply, no wood. The frame and the acrylic are a
later job and they change nothing electrical: what gets built here is the
whole wall lying face up on the floor, proved, calibrated and running. When
the timber arrives, the panels come off the floor and go onto it in the same
order, and the only file that changes is the one that says which panel is
where, if it changes at all.

Read the two rules first. Everything else is a sequence.

**Never plug or unplug a HUB75 ribbon with the panels powered.** The data
lines sit at 3.3 V against a 5 V rail; hot plugging is the single most
common way to kill a panel and a bonnet at the same time.

**The mains side is wired once, unplugged, and checked before it is ever
plugged in.** Black to L, white to N, green to earth, no copper outside a
terminal, cover on, tug test every wire.

---

## 0. What has to be true before you start

- Ten panels, QA'd (below). Nine good ones go on the wall.
- Pi 5 running, `ssh wall` answers, renderer and brain both come back after a
  reboot.
- LRS-350-5 (5 V, 60 A) for the wall. The LRS-50-5 stays the bench supply.
- Bus bar pair, ten inline fuse holders, 10 A blade fuses, 14 AWG silicone,
  ring and fork terminals, the ratcheting crimper, the multimeter.
- C14 inlet with switch and fuse, and the SL22 10005 inrush limiter.

---

## 1. The supply, on its own

Nothing connected to the output yet.

1. Cut a C13 cord, strip it, crimp rings. Black to **L**, white to **N**,
   green to **earth**. If the rings are 16-14 AWG and the cord is 18 AWG,
   double the stripped conductor over on itself to fill the barrel.
2. Put the **SL22 10005 in series on the hot line** between the inlet and the
   supply's L terminal. One limiter covers the whole build.
3. Terminal cover on. Tug every wire. Look for stray strands.
4. Plug in, switch on, and meter **+V to -V**: it should read 5.0 to 5.1 V.
   The trim pot moves it. Set it to **5.1 V** with nothing connected: the
   wall's own drops will pull it down under load.
5. Switch off. Unplug. Wait for the LED to die.

If it reads anything but around 5 V, stop. Nothing downstream is worth
risking on a supply that is not right.

---

## 2. Bus bars and drops

The supply feeds two bus bars, and the bars feed nine panels. That is the
whole topology: no panel is fed from another panel, and no panel is fed from
the Pi.

1. **Supply to bars.** Use every +V/-V pair on the terminal block (the
   LRS-350 has three), one 14 AWG pair each, all landing on the bars. A
   single 14 AWG pair cannot carry the wall: three shorten the path and
   share the current. Keep the pairs the same length.
2. **Nine drops.** Each panel gets its own pair from the bars: **fused on the
   positive side, 10 A**, straight through on the negative. Ring terminals at
   the bar, whatever the panel's harness wants at the other end. Keep them as
   equal in length as the layout allows: a long drop is a dim corner.
3. **Label every drop** at the bar end with the tile number it feeds. The one
   thing that is genuinely painful to work out later is which fuse is which
   panel.
4. **One ground point.** The Pi's ground and the panel grounds meet at the
   supply's -V bar and nowhere else. A weak or split ground is the number one
   cause of random glitching pixels, and it looks exactly like a bad panel.

Fuses last. Leave the holders empty until the wiring is checked.

---

## 3. QA the panels, in threes

First light proved one panel. The other nine are unknown, and every fault
worth finding is unfixable once the wall is assembled. The QA tool tests
whatever shape is plugged in, so the panels get proved in the arrangement
they will live in: **a chain of three at a time**, which tests the chain as
well as the panels and takes three runs instead of ten.

This comes after the supply because three panels at full white is about
23 A and the bench supply is rated 10 A. On a chain the sweep drops
`white100` for `onebyone`, which lights one panel at a time, and drops
`binref` for `bins`, which compares brightness bins in one photograph
instead of ten. On one panel it runs exactly what it always ran.

Cable the first chain (step 4 has the ribbon rules), fuse those three drops,
and leave the rest of the holders empty. On the Pi, with the brain stopped
so two things are not writing frames:

```bash
sudo systemctl stop album-art-matrix
echo 3x1 > ~/album-art-matrix/wall        # one port, three panels
sudo systemctl restart album-art-renderer
cd ~/album-art-matrix && .venv/bin/python scripts/panel_qa.py sweep \
    --wall 3x1 --panel 1,2,3 --tile 1 --serial "<sticker>,<sticker>,<sticker>"
```

Name all three panels: the run tests them together, so the verdict is
recorded against all three, and a failure asks which tile it was in. Tile 1
is the leftmost.

Eighteen patterns, a prompt after each: enter passes, `f` fails and asks
which tile and what is wrong, `n` adds a note, `r` repeats, `s` skips.
Verdicts land in `qa/panel-NN.json` and `qa/QA-SHEET.md` rebuilds itself.

What each panel has to survive:

| Look for | Means |
|---|---|
| a pixel glowing on `black` | stuck sub-pixel, and it will glow forever |
| dots missing on `red`/`green`/`blue`/`white25` | dead sub-pixel |
| red reading as blue | R and B swapped: ribbon or a BGR panel |
| blocks or doubles on `rowwalk` | address lines wrong. Flip the bonnet's E switch and run it again |
| jumps on `colwalk` | clock and latch |
| a dead column on `vlines` | shift register. Not repairable: that panel is the spare |
| smearing on `checker1` | ghosting, usually ribbon length |
| interleaved halves on `halves` | scan rate mismatch |
| a tile lighter or cooler on `bins` | a different production bin. Corner or spare |

Then swap the ribbons and drops to the next three, `--panel 4,5,6`, and
again for 7, 8, 9, and once more on its own for the spare (`--wall 1x1
--panel 10`, which brings back `white100` and `binref`). Photograph
`tilemap`, `bins`, `halves` and `ramp` each round: those are the four that
get argued about later.

Nine good panels are needed. Ten were bought. One failure is survivable, two
means talk to the seller while the window is open.

---

## 4. Data

Panels lie face up in a 3x3 on the floor, in reading order, all the same way
up. The silkscreen arrow on each board points **INPUT to OUTPUT**: data flows
with the arrow.

- Bonnet **port 1** to the first panel's INPUT, its OUTPUT to the next
  panel's INPUT, and again. Three panels on port 1.
- Same for port 2 and port 3.
- Every port carries the same number of panels. The library clocks all three
  together and cannot do a short chain.
- Dress the ribbons so nothing pulls on a connector, and leave slack at every
  panel: this layout is going to move.

Which end of a row the first panel lands on is a property of the wiring, not
of the software, and you find it out by looking (step 6). Do not spend time
guessing it now.

---

## 5. First light, one chain at a time

Bring the wall up in three steps. Each step is a smaller thing to debug than
the whole wall, and the cost of a step is one line and a restart.

**Chains, with the brain stopped.** A strip is not square and the brain only
draws squares (it says so and exits if asked), so bring-up runs the renderer
and the QA tool alone. No config edit at all: the shape is one file.

```bash
ssh wall
sudo systemctl stop album-art-matrix
echo 3x1 > ~/album-art-matrix/wall && sudo systemctl restart album-art-renderer
cd ~/album-art-matrix && .venv/bin/python scripts/panel_qa.py sweep \
    --wall 3x1 --only tilemap,onebyone,gridlines,white25 --auto --dwell 6
```

Fuses in one at a time, supply on before the Pi. Then `3x2`, then `3x3`,
running the same four patterns each time. Nothing new is being trusted at
any step: three more panels, and the same look.

**When all nine are lit,** make it the wall and put the brain back:

```bash
echo 3x3 > ~/album-art-matrix/wall
sed -i 's/^width = 64/width = 192/; s/^height = 64/height = 192/' ~/album-art-matrix/config.toml
printf '\n[wall]\ntile = 64\ncols = 3\nrows = 3\n' >> ~/album-art-matrix/config.toml
sudo systemctl restart album-art-renderer
sudo systemctl start album-art-matrix
journalctl -u album-art-matrix -n 5 --no-pager     # wall 3x3 of 64px = 192x192
```

The Pi owns its `config.toml` and `deploy.sh` never overwrites it, so this
edit survives every deploy. `[panel]` and `~/album-art-matrix/wall` must
agree: the brain prints what it believes at startup.

---

## 6. Which panel is where

```bash
.venv/bin/python scripts/panel_qa.py show tilemap --wall 3x3
```

Every tile shows its number and an arrow at its top edge. Read them off the
wall.

**With the wall face down** (which is where it lives until there is a frame
to hang it on) the numbers are unreadable, and the map still comes out of
the edge glow. Light one tile at a time, full white, three seconds each,
with two seconds of dark to mark the start of a cycle, and note which panel
glows at each step. Nine observations, one pass, no faces needed. The tool
that walks them is `panel_qa.py`; the brain must be stopped for it, because
two writers on the frame pipe interleave and the wall shows a mix of both.

**Measured on this wall, 2026-09-06:** every chain fills RIGHT TO LEFT, rows
in the right order. Canvas tile 1 lit the top right panel, 2 the top middle,
3 the top left, and the same across the middle and bottom rows. That is
`order = "2 1 0 5 4 3 8 7 6"`, which is in the Pi's config.toml. Verified by
pushing a frame lit only in the picture's top left corner and watching the
top left panel come up.

Note that `panel_qa.py` writes straight to the renderer and does NOT apply
that order: its tile numbers are the renderer's, which is what you want
while you are still working the mapping out. The brain applies the order,
so anything the wall shows for itself is already the right way round.

If the numbers come back wrong:

- **Numbers in the wrong order:** the chain fills the other way. Write the
  order into the Pi's `config.toml` rather than moving ribbons:
  `[wall] order = "2 1 0 5 4 3 8 7 6"` for chains that fill right to left.
  Tile 0 is top left and they read across.
- **A number upside down or sideways:** that panel is mounted the other way
  round. `[wall] rotate = "0 0 0 180 180 180 0 0 0"`, degrees clockwise, one
  per tile.
- **A tile dark:** its fuse, its drop, or its ribbon. Not its order.

Restart the brain after either edit. Run `tilemap` again and the numbers read
1 to 9, left to right, top to bottom.

Then `gridlines` for alignment: an amber line down every seam and a blue
cross through the middle. Slide the panels until the lines are straight and
the seams are even. That is the geometry the frame will have to hold, so it
is worth doing properly even on the floor.

---

## 7. Power, measured rather than assumed

Nine panels at full white is about 69 A, and the supply is rated 60 A. That
number never happens with album art, but it can happen with a test pattern,
so the wall is run with a cap and the cap is checked rather than trusted.

1. `onebyone` lights one panel at a time. While a tile is lit, meter **that
   panel's own terminals**: below about 4.8 V under load means the drop is
   too thin, too long, or a bad crimp.
2. Then `white100` on the whole wall for a few seconds only, with a clamp
   meter on the supply feed if you have one. If the picture goes pink at the
   far corner, or the supply ticks, cut the cap and improve the feed.
3. The cap lives in `~/album-art-matrix/panel-brightness` (1 to 254) and is
   read at renderer launch. **160 to 200 for a nine panel wall.** The
   settle time added for the row ghost costs about a fifth of the light,
   which is why 200 looks like the old 160.

Album art on nine panels sits nowhere near the limit. A full white test
pattern does, and that is the one to keep short.

---

## 8. The phone

Tessera draws and reads at the wall's own size, and it learns that size from
the wall's `/state`. Rebuild and install it once the wall reports 192:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project tessera/Tessera.xcodeproj -scheme Tessera \
  -destination 'platform=iOS,id=17BC0590-3932-52E0-A544-F4E27375D28F' \
  -derivedDataPath build-device -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration build
xcrun devicectl device install app --device 17BC0590-3932-52E0-A544-F4E27375D28F \
  build-device/Build/Products/Debug-iphoneos/Tessera.app
```

The phone must be unlocked. Studio then draws on a 192 square, the hero shows
all 36,864 emitters, and a drawing kept from the 64 pixel days is blown up by
threes rather than refused.

---

## 9. What is left for the frame

The frame itself now has a design: [design/README.md](../design/README.md)
and the renders beside it. Two things in it change the steps above. The
panels ship with four magnetic feet each, so the plan is a steel plate and
no standoffs, which makes step 2's sheet a 1.5 mm steel one and step 3
unnecessary. And the supply has a fan, so the box is vented.

Nothing electrical. The wall works on the floor and it will work on timber.
When the wood arrives:

- 3 mm opal acrylic and 3 mm smoked ND, each cut 480 x 480 mm.
- **Nylon** M3 standoffs, never metal: the back of a panel is a field of live
  joints.
- Measure a panel's rear clearance before ordering standoff lengths.
- The French cleat carries the weight; the frame only holds the panels flat.

The panels come off the floor in the same order they went down. If the tile
map still reads 1 to 9 afterwards, no file changes at all.

---

## When something is wrong

| What you see | Where to look |
|---|---|
| One tile dark | fuse, drop, ribbon, in that order |
| One tile scrambled, others fine | that panel's ribbon, or the panel |
| A whole row dark | that port's ribbon at the bonnet |
| Tiles in the wrong places | `[wall] order`, not the wiring, if every tile lights |
| Colours off across the whole wall | white balance, `scripts/WB-PROCEDURE.md` |
| Random glitching pixels | ground. One point, at the supply |
| Wall dark and the renderer running | `[sink] type` in the Pi's config.toml. Never rsync the Mac's config over it |
| Two renderers fighting | `pkill -9 -f "[a]rt_display"`, then `pgrep -fc "[a]rt_display"` must be 1 |
