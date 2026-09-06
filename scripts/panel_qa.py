#!/usr/bin/env python3
"""Panel intake QA. Prove every panel before it goes on the wall.

Ten panels bought as one batch, and the faults that matter are the ones that
cannot be fixed after the wall is assembled: a dead sub-pixel, an address line
that scrambles the scan, a panel from a different brightness bin that reads as
a visible tile in a 3x3 grid. All of it shows up in about a minute per panel
against the right flat fields, and none of it shows up against album art.

Run it per panel, swap the ribbon, run it again. Verdicts land in qa/ and
qa/QA-SHEET.md is the one page worth keeping.

  # on the Pi, brain stopped, renderer running. Raw pixels, nothing applied.
  python3 scripts/panel_qa.py sweep --panel 1

  # from the Mac while the brain runs the wall. Convenient, but the frames
  # come out white balanced, so colour and uniformity calls are relative.
  python3 scripts/panel_qa.py sweep --panel 1 --to http://album-matrix.local:8788

  # no hardware at all. Writes every pattern as a PNG to look the tool over.
  python3 scripts/panel_qa.py patterns --out qa_preview

  python3 scripts/panel_qa.py show rowwalk      # hold one pattern, no logging
  python3 scripts/panel_qa.py sheet             # rebuild QA-SHEET.md from qa/
"""
import argparse
import base64
import errno
import json
import os
import sys
import time
import urllib.error
import urllib.request

import numpy as np

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)

QA_DIR = os.path.join(REPO, "qa")
SHEET = os.path.join(QA_DIR, "QA-SHEET.md")
TILE = 64


class Geom:
    """The shape being tested: one panel, a chain, or the whole wall.

    Panels are quicker to prove in the arrangement they will live in than
    one at a time on the bench: the same flat fields find a dead pixel or a
    scrambled scan whether one panel is lit or nine, and testing a chain
    also tests the chain. What only a wall can show is here too, in the
    patterns that need neighbours: the seams, the brightness bins side by
    side in ONE photograph, and which panel is standing where.
    """

    def __init__(self, cols=1, rows=1, tile=TILE):
        self.cols, self.rows, self.tile = int(cols), int(rows), int(tile)
        self.w, self.h = self.cols * self.tile, self.rows * self.tile

    @property
    def tiles(self):
        return self.cols * self.rows

    def box(self, i):
        """Top-left corner of tile i, in reading order."""
        r, c = divmod(i, self.cols)
        return r * self.tile, c * self.tile

    def __str__(self):
        if self.tiles == 1:
            return "one panel"
        return f"{self.cols}x{self.rows} panels, {self.w}x{self.h}"


G = Geom()          # set from the command line before any pattern is built
DEFAULT_FIFO = os.environ.get("FRAME_FIFO", "/tmp/album-frame.fifo")
DEFAULT_HTTP = "http://album-matrix.local:8788"


# ----------------------------------------------------------------- patterns

def blank(v=0):
    return np.full((G.h, G.w, 3), v, np.uint8)


def flat(rgb):
    f = blank()
    f[:, :] = rgb
    return f


def p_id(panel):
    """A label in every tile, and an arrow pointing at its top edge.

    On one panel this is the panel's own number, photographed first so every
    later shot in the camera roll is self-labelling and the right way up. On
    a wall it is the TILE MAP: tile 1 is top left and they read across, so
    the picture says which physical panel the renderer thinks is where. If
    the numbers come back in the wrong order, either move the ribbons or
    write the order into config.toml's [wall]; either is a two minute job
    now and a dismantled wall later.
    """
    from brain.art import pixelfont
    f = blank()
    for i in range(G.tiles):
        y0, x0 = G.box(i)
        label = "P%02d" % panel if G.tiles == 1 else "%d" % (i + 1)
        w = pixelfont.text_width(label, scale=2)
        pixelfont.draw_text(f, label, x0 + (G.tile - w) // 2, y0 + 34,
                            (255, 200, 60), scale=2)
        mid = x0 + G.tile // 2
        for k in range(10):                       # arrow shaft
            f[y0 + 10 + k, mid] = (60, 160, 255)
        for k in range(6):                        # arrow head
            f[y0 + 10 + k, mid - k:mid + k + 1] = (60, 160, 255)
    return f


def p_checker(step=1):
    f = blank()
    yy, xx = np.mgrid[0:G.h, 0:G.w]
    on = ((yy // step) + (xx // step)) % 2 == 0
    f[on] = (255, 255, 255)
    return f


def p_lines(axis):
    f = blank()
    if axis == "h":
        f[::2, :] = (255, 255, 255)
    else:
        f[:, ::2] = (255, 255, 255)
    return f


def p_halves():
    """Top red, bottom blue, PER PANEL: the halves are a property of one
    panel's two-scan wiring, so on a wall every tile has to show its own."""
    f = blank()
    for i in range(G.tiles):
        y0, x0 = G.box(i)
        f[y0:y0 + G.tile // 2, x0:x0 + G.tile] = (255, 40, 40)
        f[y0 + G.tile // 2:y0 + G.tile, x0:x0 + G.tile] = (40, 80, 255)
    return f


def p_border():
    """One pixel round every tile, with corner marks. Butted together, this
    is also the seam test: the gap between two panels should look like the
    gap between two pixels, and any tile whose edge column is dead shows as
    a dark line down the middle of the wall."""
    f = blank()
    for i in range(G.tiles):
        y0, x0 = G.box(i)
        y1, x1 = y0 + G.tile - 1, x0 + G.tile - 1
        f[y0, x0:x1 + 1] = f[y1, x0:x1 + 1] = (255, 255, 255)
        f[y0:y1 + 1, x0] = f[y0:y1 + 1, x1] = (255, 255, 255)
        f[y0:y0 + 3, x0:x0 + 3] = (255, 0, 0)             # top left marker
        f[y0:y0 + 2, x1 - 1:x1 + 1] = (0, 255, 0)         # top right marker
    return f


def p_ramp():
    f = blank()
    ramp = np.linspace(0, 255, G.w).astype(np.uint8)
    third = G.h // 3
    f[:third, :, 0] = ramp
    f[third:2 * third, :, 1] = ramp
    f[2 * third:, :, 2] = ramp
    return f


def p_walk(axis):
    """One lit line at a time, sweeping the wall. The address-line test: if
    the lines arrive out of order, in blocks, or two at a time, the A to E
    lines are wrong. On this build that is almost always E on IDC pin 4 versus
    pin 8, which is what the bonnet's E switch exists for. On a wall the line
    crosses every panel of a row at once, so a panel that scans differently
    from its neighbours is obvious rather than a memory of the last test."""
    out = []
    for i in range(G.h if axis == "row" else G.w):
        f = blank()
        if axis == "row":
            f[i, :] = (255, 255, 255)
        else:
            f[:, i] = (255, 255, 255)
        out.append(f)
    return out


def p_onebyone():
    """Each panel alone, full white, in tile order. Three things at once:
    which panel is in which slot, whether any drop is fused or loose (a tile
    that stays dark), and the load one panel at a time, which is the only
    way to meter a drop without the supply carrying the whole wall."""
    out = []
    for i in range(G.tiles):
        f = blank()
        y0, x0 = G.box(i)
        f[y0:y0 + G.tile, x0:x0 + G.tile] = (255, 255, 255)
        out.append(f)
    return out


def p_bins():
    """Every tile at 50 percent in one frame. The brightness bin check that
    used to need ten photographs at the same exposure is now one photograph:
    a panel from another bin reads as a lighter or cooler square in the grid.
    Bins cannot be fixed in software, so a mismatch goes to a corner."""
    return flat((128, 128, 128))


def p_gridlines():
    """A cross through the middle of the wall and a line down every seam.
    Straightness is the alignment check with nothing to mount to yet: lay
    the panels out, light this, and slide them until the lines are lines."""
    f = blank()
    f[G.h // 2, :] = (40, 90, 255)
    f[:, G.w // 2] = (40, 90, 255)
    for c in range(1, G.cols):
        f[:, c * G.tile - 1] = f[:, c * G.tile] = (255, 180, 40)
    for r in range(1, G.rows):
        f[r * G.tile - 1, :] = f[r * G.tile, :] = (255, 180, 40)
    return f


PATTERNS = [
    # key, title, what to look for, frames, dwell seconds, photograph it
    ("id", "panel label",
     "the panel number, right way up, arrow pointing at the top edge. If it is "
     "upside down or mirrored, note the ribbon orientation now",
     lambda panel: [p_id(panel)], 3, True),

    ("black", "all off",
     "true black. Any pixel that glows is stuck on. Look across the panel at a "
     "low angle in a dark room",
     lambda panel: [blank()], 6, False),

    ("red", "full red",
     "even red, no black dots, and it must actually read RED. If it looks blue "
     "the ribbon has R and B swapped or the panel is BGR",
     lambda panel: [flat((255, 0, 0))], 5, False),

    ("green", "full green",
     "even green, no dead dots",
     lambda panel: [flat((0, 255, 0))], 5, False),

    ("blue", "full blue",
     "even blue, no dead dots",
     lambda panel: [flat((0, 0, 255))], 5, False),

    ("white25", "white at 25 percent",
     "dead pixels hide in bright fields and show in dim ones. This is the best "
     "dead-pixel hunt of the set",
     lambda panel: [flat((64, 64, 64))], 8, False),

    ("binref", "white at 50 percent, brightness reference",
     "photograph this one with FIXED camera settings, same distance and same "
     "exposure for all ten panels. This photo is how brightness bins get "
     "compared later, and a mismatched bin is a visible tile on the wall",
     lambda panel: [flat((128, 128, 128))], 10, True),

    ("white100", "full white, load test",
     "hold this one. Meter the panel's own screw terminals with the DMM: below "
     "about 4.8 V means the supply or the wire gauge is undersized. Watch for "
     "the field going pink or dim at the far corner, which is the same problem",
     lambda panel: [flat((255, 255, 255))], 20, False),

    ("gray50", "flat mid grey",
     "smooth grey. Blotches or a crawling texture means the BCM and dither "
     "settings need a look, not the panel",
     lambda panel: [flat((128, 128, 128))], 6, False),

    ("checker1", "one pixel checkerboard",
     "crisp alternating pixels. Smearing sideways is ghosting, usually ribbon "
     "length or termination. Whole blocks wrong is an address fault",
     lambda panel: [p_checker(1)], 8, False),

    ("hlines", "alternating rows",
     "even horizontal stripes. A missing or doubled stripe is a row driver "
     "fault",
     lambda panel: [p_lines("h")], 6, False),

    ("vlines", "alternating columns",
     "even vertical stripes. A dead column is a shift register fault and is not "
     "repairable, that panel becomes the spare",
     lambda panel: [p_lines("v")], 6, False),

    ("rowwalk", "single row sweep",
     "one row at a time, top to bottom, in order, one at a time. Out of order, "
     "in 16 row blocks, or two rows at once means the address lines are wrong. "
     "Flip the bonnet E switch and run it again",
     lambda panel: p_walk("row"), 0.06, False),

    ("colwalk", "single column sweep",
     "one column at a time, left to right, in order. Jumps or doubles point at "
     "the clock and latch lines",
     lambda panel: p_walk("col"), 0.06, False),

    ("halves", "top red, bottom blue",
     "top half red, bottom half blue. Swapped halves means R1/G1/B1 and "
     "R2/G2/B2 are crossed in the ribbon. Interleaved halves is the classic "
     "scan-rate mismatch",
     lambda panel: [p_halves()], 6, True),

    ("border", "edge and corners",
     "a one pixel border all the way round with no gaps, red square at top "
     "left, green at top right. Missing edge pixels show up as a dark seam once "
     "panels are butted together",
     lambda panel: [p_border()], 6, False),

    ("ramp", "channel gradients",
     "three smooth ramps, red green blue, each fading black to full. Hard steps "
     "are banding, which is a gamma and bit depth setting, not the panel",
     lambda panel: [p_ramp()], 8, True),
]

# Only meaningful once panels sit next to each other. Appended to the sweep
# when the shape has more than one tile.
WALL_PATTERNS = [
    ("tilemap", "which panel is where",
     "a number in every tile, reading across from the top left, and an arrow "
     "at each tile's top edge. Photograph it. Wrong order means the chain runs "
     "the other way: move the ribbons, or set [wall] order in config.toml. An "
     "upside down number means that panel's ribbon comes in from the other "
     "side, which [wall] rotate fixes",
     lambda panel: [p_id(panel)], 12, True),

    ("onebyone", "one panel at a time",
     "each tile alone in full white, in order. A tile that never lights has a "
     "dead drop or a blown fuse. This is also when to meter that panel's own "
     "screw terminals: below about 4.8 V under load is undersized wire or a "
     "supply that cannot hold up",
     lambda panel: p_onebyone(), 4, False),

    ("bins", "brightness bins, side by side",
     "all tiles at 50 percent in one photograph. A panel from a different "
     "production bin reads brighter or a different white than its neighbours. "
     "No software fixes it, so a mismatched panel goes to a corner or becomes "
     "the spare",
     lambda panel: [p_bins()], 12, True),

    ("gridlines", "seams and straightness",
     "a blue cross through the middle of the wall and an amber line down every "
     "seam. With nothing to mount to yet this is the alignment tool: slide the "
     "panels until the lines are straight and the seams are even",
     lambda panel: [p_gridlines()], 15, True),
]

BY_KEY = {p[0]: p for p in PATTERNS + WALL_PATTERNS}


# Three of the single panel patterns have better answers once panels sit
# next to each other, and one of them is a hazard: full white on three
# chained panels is about 23 A, and the bench supply is rated 10 A.
# `onebyone` does that load test a panel at a time, `bins` does the
# brightness bin comparison in one photograph instead of ten, and `tilemap`
# is what `id` becomes when there is more than one tile to label.
SUPERSEDED = {"white100": "onebyone", "binref": "bins", "id": "tilemap"}


def sequence():
    """What this shape gets tested with."""
    if G.tiles == 1:
        return PATTERNS
    return [p for p in PATTERNS if p[0] not in SUPERSEDED] + WALL_PATTERNS


# --------------------------------------------------------------- transports

class FifoTransport:
    """Straight to the renderer's named pipe. What you send is what lights up:
    no white balance, no brightness scaling, no brain in the way. Requires the
    brain stopped so the two are not both writing frames."""

    name = "fifo"

    def __init__(self, path=DEFAULT_FIFO):
        self.path = path
        if not os.path.exists(path):
            raise SystemExit(
                "no fifo at %s. Start pi/run_renderer.sh first, or pass "
                "--to http://album-matrix.local:8788" % path)

    def send(self, frame):
        try:
            fd = os.open(self.path, os.O_WRONLY | os.O_NONBLOCK)
        except OSError as exc:
            if exc.errno in (errno.ENXIO, errno.ENOENT):
                raise SystemExit(
                    "renderer is not listening on %s. Start "
                    "pi/run_renderer.sh" % self.path)
            raise
        with os.fdopen(fd, "wb") as fh:
            fh.write(frame.tobytes())

    def close(self):
        self.send(blank())


class HttpTransport:
    """Through the brain's control API. Works from anywhere on the network,
    but frames get the white balance gains and the brightness multiplier
    applied on the way out, so treat colour and uniformity calls as relative.
    Brightness is forced to 1.0 for the run and the previous state is put back
    at the end."""

    name = "http"

    def __init__(self, base):
        self.base = base.rstrip("/")
        self.prev = None
        try:
            self.prev = self._get("/state")
        except Exception as exc:
            raise SystemExit("cannot reach the wall at %s (%s)" % (self.base, exc))
        self._post("/state", {"brightness": 1.0, "finish": "clean"})

    def _get(self, path):
        with urllib.request.urlopen(self.base + path, timeout=5) as r:
            return json.loads(r.read())

    def _post(self, path, obj):
        req = urllib.request.Request(
            self.base + path, data=json.dumps(obj).encode(),
            headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=8) as r:
            return json.loads(r.read())

    def send(self, frame):
        self._post("/frame", {"px": base64.b64encode(frame.tobytes()).decode()})

    def close(self):
        if not self.prev:
            return
        restore = {k: self.prev[k] for k in ("mode", "brightness", "finish")
                   if k in self.prev}
        try:
            self._post("/state", restore)
        except Exception:
            pass


class PreviewTransport:
    """No hardware. Writes each frame as a scaled PNG so the patterns can be
    checked before any panel is wired."""

    name = "preview"

    def __init__(self, out_dir):
        from PIL import Image
        self.Image = Image
        self.out = out_dir
        os.makedirs(out_dir, exist_ok=True)
        self.n = 0
        self.tag = "frame"

    def send(self, frame):
        k = max(1, 384 // max(G.w, G.h))
        img = self.Image.fromarray(frame, "RGB").resize(
            (G.w * k, G.h * k), self.Image.NEAREST)
        img.save(os.path.join(self.out, "%s-%03d.png" % (self.tag, self.n)))
        self.n += 1

    def close(self):
        pass


def make_transport(args):
    to = args.to
    if to is None:
        to = "fifo" if os.path.exists(DEFAULT_FIFO) else DEFAULT_HTTP
    if to == "fifo":
        return FifoTransport()
    if to.startswith("http"):
        return HttpTransport(to)
    if to == "preview":
        return PreviewTransport(getattr(args, "out", None) or "qa_preview")
    raise SystemExit("--to takes fifo, preview, or a http://host:port")


# -------------------------------------------------------------------- sweep

def play(tx, frames, dwell, loops=1):
    """Animations step at dwell. A static pattern is sent once and simply
    stays lit, so the caller decides how long to look at it."""
    if len(frames) == 1:
        tx.send(frames[0])
        return
    for _ in range(loops):
        for f in frames:
            tx.send(f)
            time.sleep(dwell)


def sweep(args):
    """One run per shape. A chain of three is three panels tested together,
    so the verdict is recorded against all of them, and a failure asks which
    tile it was in: a sheet that says a panel passed when only its neighbour
    was looked at is worse than no sheet."""
    tx = make_transport(args)
    only = set(args.only.split(",")) if args.only else None
    panels = [int(v) for v in str(args.panel).replace(",", " ").split()]
    first_tile = getattr(args, "tile", None) or 1
    # panel -> tile, in the order given, left to right from the first tile
    tiles = {pn: first_tile + i for i, pn in enumerate(panels)}
    if len(panels) > G.tiles:
        raise SystemExit("%d panels named but the shape is %d tiles"
                         % (len(panels), G.tiles))
    results = {pn: {} for pn in panels}
    notes = {pn: {} for pn in panels}
    serials = [v.strip() for v in (args.serial or "").split(",")]

    def mark(key, verdict, note="", only_panels=None):
        for pn in panels:
            results[pn][key] = (verdict if only_panels is None or pn in only_panels
                                else "pass")
            if note and (only_panels is None or pn in only_panels):
                notes[pn][key] = note

    def which(prompt):
        """Tile numbers a fault was in, or every panel when nothing is named."""
        raw = input(prompt).strip()
        if not raw:
            return None
        want = {int(v) for v in raw.replace(",", " ").split() if v.isdigit()}
        named = [pn for pn in panels if tiles[pn] in want]
        return named or None

    print("\npanel%s %s, %s, %s transport. Ctrl-C saves and stops.\n"
          % ("s" if len(panels) > 1 else "",
             ", ".join(str(pn) for pn in panels), G, tx.name))
    if len(panels) > 1:
        print("        tiles: %s\n"
              % ", ".join("%d = panel %d" % (tiles[pn], pn) for pn in panels))
    try:
        seq = sequence()
        for i, (key, title, look, build, dwell, photo) in enumerate(seq, 1):
            if only and key not in only:
                continue
            frames = build(panels[0])
            animated = len(frames) > 1
            while True:
                print("[%2d/%2d] %-9s %s" % (i, len(seq), key.upper(), title))
                print("        look for: %s" % look)
                if photo:
                    print("        photograph this one")
                if isinstance(tx, PreviewTransport):
                    tx.tag, tx.n = key, 0
                play(tx, frames, dwell, loops=2 if animated else 1)
                if args.auto or isinstance(tx, PreviewTransport):
                    if not animated:
                        time.sleep(dwell if getattr(args, "dwell", None) is None
                                   else args.dwell)
                    # Nobody looked, so nothing passed. The pattern was shown,
                    # and the sheet says so, but the verdict stays partial
                    # until a person runs the prompted sweep.
                    mark(key, "unjudged")
                    break
                ans = input("        enter=pass  f=fail  r=repeat  n=note  "
                            "s=skip  q=quit > ").strip().lower()
                if ans == "r":
                    continue
                if ans == "q":
                    raise KeyboardInterrupt
                if ans == "s":
                    mark(key, "skip")
                    break
                if ans.startswith("f"):
                    bad = which("        which tile, blank = all: ") \
                        if len(panels) > 1 else None
                    mark(key, "fail", input("        what is wrong: ").strip(), bad)
                    break
                if ans.startswith("n"):
                    where = which("        which tile, blank = all: ") \
                        if len(panels) > 1 else None
                    note = input("        note: ").strip()
                    mark(key, "pass")
                    for pn in (where or panels):
                        notes[pn][key] = note
                    break
                mark(key, "pass")
                break
            print()
    except KeyboardInterrupt:
        print("\nstopped early, saving what we have")
    finally:
        tx.close()

    for i, pn in enumerate(panels):
        serial = serials[i] if i < len(serials) else ""
        verdict = record(pn, tx.name, results[pn], notes[pn], serial,
                         tile=tiles[pn])
        bad = [k for k, v in results[pn].items() if v == "fail"]
        print("panel %d: %s%s" % (pn, verdict.upper(),
                                  " on " + ", ".join(bad) if bad else ""))
    write_sheet()
    print("sheet: %s" % os.path.relpath(SHEET, REPO))


def record(panel, transport, results, notes, serial, tile=None):
    os.makedirs(QA_DIR, exist_ok=True)
    path = os.path.join(QA_DIR, "panel-%02d.json" % panel)
    prev = {}
    if os.path.exists(path):
        try:
            prev = json.load(open(path))
        except json.JSONDecodeError:
            prev = {}
    merged = dict(prev.get("results", {}))
    merged.update(results)
    merged_notes = dict(prev.get("notes", {}))
    merged_notes.update(notes)
    # pass means every pattern ran and passed. Anything not yet run leaves the
    # panel partial, so a half-tested panel never reads as cleared on the sheet.
    # A panel proved in a chain never ran white100 or binref, and never will:
    # what replaced them is in the same file. Judge against the union.
    ran = {k[0] for k in PATTERNS + WALL_PATTERNS}
    needed = [k for k in ran if k not in SUPERSEDED
              or merged.get(SUPERSEDED[k]) is None]
    verdict = ("fail" if "fail" in merged.values()
               else "pass" if all(merged.get(k) == "pass" for k in needed)
               else "partial")
    json.dump({
        "panel": panel,
        "serial": serial or prev.get("serial", ""),
        "tested": time.strftime("%Y-%m-%d %H:%M"),
        "transport": transport,
        # What was lit at the time. A panel proved in a chain of three was
        # proved with its neighbours, and the sheet should say so rather
        # than reading as though each one went on the bench alone.
        "shape": f"{G.cols}x{G.rows}",
        "tile": prev.get("tile") if tile is None else tile,
        "results": merged,
        "notes": merged_notes,
        "verdict": verdict,
    }, open(path, "w"), indent=2)
    return verdict


def write_sheet():
    os.makedirs(QA_DIR, exist_ok=True)
    panels = []
    for name in sorted(os.listdir(QA_DIR)):
        if name.startswith("panel-") and name.endswith(".json"):
            try:
                panels.append(json.load(open(os.path.join(QA_DIR, name))))
            except json.JSONDecodeError:
                continue
    keys = [p[0] for p in PATTERNS]
    wall_keys = [p[0] for p in WALL_PATTERNS]
    mark = {"pass": "ok", "fail": "FAIL", "skip": ".", "unjudged": "seen"}
    lines = [
        "# Panel QA sheet",
        "",
        "Generated by `scripts/panel_qa.py`. One row per panel, one column per "
        "pattern. FAIL is a panel that does not go on the wall.",
        "",
        "| panel | serial | verdict | " + " | ".join(keys) + " |",
        "|---|---|---|" + "---|" * len(keys),
    ]
    for p in panels:
        row = [mark.get(p["results"].get(k, "skip"), ".") for k in keys]
        lines.append("| %d | %s | **%s** | %s |"
                     % (p["panel"], p.get("serial", "") or "",
                        p["verdict"].upper(), " | ".join(row)))
    walled = [p for p in panels
              if any(p["results"].get(k) for k in wall_keys)]
    if walled:
        lines += [
            "",
            "## On the wall",
            "",
            "The patterns that need neighbours: which panel is standing "
            "where, each drop under load on its own, the brightness bins in "
            "one photograph, and the seams.",
            "",
            "| panel | tile | shape | " + " | ".join(wall_keys) + " |",
            "|---|---|---|" + "---|" * len(wall_keys),
        ]
        for p in walled:
            lines.append("| %d | %s | %s | %s |" % (
                p["panel"], p.get("tile") or "", p.get("shape", "") or "",
                " | ".join(mark.get(p["results"].get(k, "skip"), ".")
                           for k in wall_keys)))
    intakes = [p for p in panels if p.get("intake")]
    if intakes:
        cols = [k for k, _, _ in INTAKE if k != "serial"]
        lines += [
            "",
            "## Intake, the no-power pass",
            "",
            "Differences down a column are what matter. A driver chip or an "
            "outline that does not match the others is a panel from a different "
            "batch, and that is a conversation with the seller, not a fix.",
            "",
            "| panel | " + " | ".join(cols) + " |",
            "|---|" + "---|" * len(cols),
        ]
        for p in intakes:
            lines.append("| %d | %s |" % (
                p["panel"],
                " | ".join(str(p["intake"].get(c, "") or "") for c in cols)))
    notes = [(p["panel"], k, v) for p in panels
             for k, v in sorted(p.get("notes", {}).items()) if v]
    if notes:
        lines += ["", "## Notes", ""]
        lines += ["- panel %d, %s: %s" % n for n in notes]
    lines += [
        "",
        "## Batch check, do this once all ten are through",
        "",
        "On the wall the `bins` pattern does this in one photograph: every "
        "tile at 50 percent, side by side, one exposure. Panel by panel on "
        "the bench it is the ten `binref` photos instead, which only compare "
        "if the camera settings and the distance never moved. Either way, a "
        "panel that reads brighter or a different white than the rest is from "
        "another production bin: put it in a corner or keep it as the spare, "
        "because in the middle of a 3x3 wall that reads as a visible tile and "
        "no software fix touches it.",
        "",
        "Nine good panels are needed for the wall. Ten were bought. One failure "
        "is survivable, two means talk to the seller while the window is open.",
        "",
    ]
    open(SHEET, "w").write("\n".join(lines))


# ------------------------------------------------------------------- intake

# The no-power pass. Every one of these is a fact you can only cheaply collect
# while the panels are loose on a table and the return window is open, and most
# of them decide something downstream: the frame, the acrylic cut, the ribbon
# routing, or whether a panel is the wrong part entirely.
INTAKE = [
    ("serial", "serial or batch sticker (blank if none)", ""),
    ("driver", "driver chip marking on the back, exactly as printed", ""),
    ("width_mm", "outline width in mm", "160 expected. Three of these make the "
     "480mm wall, so a few mm out moves the frame and the acrylic cut"),
    ("height_mm", "outline height in mm", "160 expected"),
    ("depth_mm", "depth from panel face to the deepest thing on the back, mm",
     "sets how deep the frame box has to be"),
    ("hole_thread", "mounting hole thread, e.g. M3", "the M3 assortment assumes this"),
    ("hole_pattern", "mounting hole positions, e.g. 4 corners inset 8mm", ""),
    ("ribbon_cm", "length of the supplied data ribbon in cm", "30 expected. If a "
     "centre-mounted board cannot reach the far panels, longer ones get ordered "
     "in the same order as everything else"),
    ("power_lead", "power lead supplied, e.g. 4-pin to spade", ""),
    ("damage", "any visible damage, bent pins, scuffed LEDs, blank if clean", ""),
]


def intake(args):
    """Record the physical facts about one panel. No power required."""
    path = os.path.join(QA_DIR, "panel-%02d.json" % args.panel)
    prev = {}
    if os.path.exists(path):
        try:
            prev = json.load(open(path))
        except json.JSONDecodeError:
            prev = {}
    have = dict(prev.get("intake", {}))
    print("\npanel %d intake. Enter keeps the value in brackets.\n" % args.panel)
    for key, prompt, why in INTAKE:
        if why:
            print("  (%s)" % why)
        cur = have.get(key, "")
        ans = input("  %s [%s]: " % (prompt, cur)).strip()
        have[key] = ans if ans else cur
    os.makedirs(QA_DIR, exist_ok=True)
    prev.update({
        "panel": args.panel,
        "intake": have,
        "intake_done": time.strftime("%Y-%m-%d %H:%M"),
    })
    prev.setdefault("results", {})
    prev.setdefault("notes", {})
    prev.setdefault("verdict", "partial")
    if have.get("serial"):
        prev["serial"] = have["serial"]
    json.dump(prev, open(path, "w"), indent=2)
    write_sheet()
    print("\nsaved. %s" % os.path.relpath(SHEET, REPO))


def _one_panel(args):
    """--panel takes a list for a chain; the callers that draw a single
    picture want the first of them."""
    raw = str(getattr(args, "panel", "1")).replace(",", " ").split()
    return int(raw[0]) if raw else 1


def show(args):
    if args.pattern not in BY_KEY:
        raise SystemExit("patterns: " + ", ".join(BY_KEY))
    tx = make_transport(args)
    key, title, look, build, dwell, _ = BY_KEY[args.pattern]
    frames = build(_one_panel(args))
    print("%s: %s\nlook for: %s\nCtrl-C to stop." % (key, title, look))
    try:
        if len(frames) == 1:
            tx.send(frames[0])
            while True:
                time.sleep(1)
        else:
            while True:
                play(tx, frames, dwell)
    except KeyboardInterrupt:
        tx.close()


def patterns(args):
    args.to = "preview"
    tx = make_transport(args)
    total = 0
    for key, title, look, build, dwell, _ in sequence():
        tx.tag, tx.n = key, 0
        frames = build(_one_panel(args))
        for f in (frames if len(frames) == 1 else frames[::16]):
            tx.send(f)
        total += tx.n
    print("wrote %d PNGs to %s" % (total, args.out))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p):
        p.add_argument("--to", help="fifo | preview | http://host:port "
                                    "(default: fifo if present, else the wall)")
        p.add_argument("--panel", default="1",
                       help="panel number, or a comma list for a chain "
                            "(1,2,3) in tile order")
        p.add_argument("--wall", default="1x1",
                       help="what is lit: COLSxROWS panels (1x1, 3x1, 3x3). "
                            "Must match ~/album-art-matrix/wall on the Pi")
        p.add_argument("--tile", type=int, default=None,
                       help="the tile the FIRST named panel is standing in, "
                            "1 up, reading across from the top left")

    s = sub.add_parser("sweep", help="run the full QA sweep on one panel")
    common(s)
    s.add_argument("--auto", action="store_true",
                   help="no prompts, just cycle the patterns for photographing; "
                        "records them as seen, not passed")
    s.add_argument("--dwell", type=float, default=None,
                   help="override seconds per static pattern in --auto")
    s.add_argument("--only", help="comma separated pattern keys")
    s.add_argument("--serial", default="",
                   help="panel serial or batch sticker; a comma list when "
                        "several panels are named")
    s.set_defaults(func=sweep)

    s = sub.add_parser("intake", help="record a panel's physical facts, no power")
    s.add_argument("--panel", type=int, default=1, help="panel number 1-10")
    s.set_defaults(func=intake)

    s = sub.add_parser("show", help="hold one pattern until Ctrl-C")
    common(s)
    s.add_argument("pattern")
    s.set_defaults(func=show)

    s = sub.add_parser("patterns", help="write the patterns out as PNGs")
    common(s)
    s.add_argument("--out", default="qa_preview")
    s.set_defaults(func=patterns)

    s = sub.add_parser("sheet", help="rebuild QA-SHEET.md from qa/*.json")
    s.set_defaults(func=lambda a: (write_sheet(),
                                   print("wrote %s" % os.path.relpath(SHEET, REPO))))

    args = ap.parse_args()
    shape = getattr(args, "wall", "1x1")
    try:
        cols, rows = (int(v) for v in shape.lower().split("x"))
        if not (1 <= cols <= 8 and 1 <= rows <= 3):
            raise ValueError
    except ValueError:
        raise SystemExit("--wall takes COLSxROWS, e.g. 3x1 or 3x3 "
                         "(up to three rows: the bonnet has three ports)")
    global G
    G = Geom(cols, rows)
    if (cols * TILE) % 32:
        raise SystemExit("the renderer needs a width that is a multiple of 32")
    args.func(args)


if __name__ == "__main__":
    main()
