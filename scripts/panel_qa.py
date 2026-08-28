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
SIZE = 64
DEFAULT_FIFO = os.environ.get("FRAME_FIFO", "/tmp/album-frame.fifo")
DEFAULT_HTTP = "http://album-matrix.local:8788"


# ----------------------------------------------------------------- patterns

def blank(v=0):
    return np.full((SIZE, SIZE, 3), v, np.uint8)


def flat(rgb):
    f = blank()
    f[:, :] = rgb
    return f


def p_id(panel):
    """Panel number plus an up arrow. Photographed first, so every later shot
    in the camera roll is self-labelling and right way up."""
    from brain.art import pixelfont
    f = blank()
    label = "P%02d" % panel
    w = pixelfont.text_width(label, scale=2)
    pixelfont.draw_text(f, label, (SIZE - w) // 2, 34, (255, 200, 60), scale=2)
    for i in range(10):                       # arrow shaft
        f[10 + i, SIZE // 2] = (60, 160, 255)
    for i in range(6):                        # arrow head
        f[10 + i, SIZE // 2 - i:SIZE // 2 + i + 1] = (60, 160, 255)
    return f


def p_checker(step=1):
    f = blank()
    yy, xx = np.mgrid[0:SIZE, 0:SIZE]
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
    f = blank()
    f[:SIZE // 2, :] = (255, 40, 40)
    f[SIZE // 2:, :] = (40, 80, 255)
    return f


def p_border():
    f = blank()
    f[0, :] = f[-1, :] = f[:, 0] = f[:, -1] = (255, 255, 255)
    f[0:3, 0:3] = (255, 0, 0)                 # top left marker
    f[0:2, -2:] = (0, 255, 0)                 # top right marker
    return f


def p_ramp():
    f = blank()
    ramp = np.linspace(0, 255, SIZE).astype(np.uint8)
    third = SIZE // 3
    f[:third, :, 0] = ramp
    f[third:2 * third, :, 1] = ramp
    f[2 * third:, :, 2] = ramp
    return f


def p_walk(axis):
    """One lit line at a time, sweeping the panel. The address-line test: if
    the lines arrive out of order, in blocks, or two at a time, the A to E
    lines are wrong. On this build that is almost always E on IDC pin 4 versus
    pin 8, which is what the bonnet's E switch exists for."""
    out = []
    for i in range(SIZE):
        f = blank()
        if axis == "row":
            f[i, :] = (255, 255, 255)
        else:
            f[:, i] = (255, 255, 255)
        out.append(f)
    return out


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

BY_KEY = {p[0]: p for p in PATTERNS}


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
        img = self.Image.fromarray(frame, "RGB").resize(
            (SIZE * 6, SIZE * 6), self.Image.NEAREST)
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
    tx = make_transport(args)
    only = set(args.only.split(",")) if args.only else None
    results, notes = {}, {}
    print("\npanel %d, %s transport. Ctrl-C saves and stops.\n"
          % (args.panel, tx.name))
    try:
        for i, (key, title, look, build, dwell, photo) in enumerate(PATTERNS, 1):
            if only and key not in only:
                continue
            frames = build(args.panel)
            animated = len(frames) > 1
            while True:
                print("[%2d/%2d] %-9s %s" % (i, len(PATTERNS), key.upper(), title))
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
                    results[key] = "pass"
                    break
                ans = input("        enter=pass  f=fail  r=repeat  n=note  "
                            "s=skip  q=quit > ").strip().lower()
                if ans == "r":
                    continue
                if ans == "q":
                    raise KeyboardInterrupt
                if ans == "s":
                    results[key] = "skip"
                    break
                if ans.startswith("f"):
                    results[key] = "fail"
                    notes[key] = input("        what is wrong: ").strip()
                    break
                if ans.startswith("n"):
                    notes[key] = input("        note: ").strip()
                    results[key] = "pass"
                    break
                results[key] = "pass"
                break
            print()
    except KeyboardInterrupt:
        print("\nstopped early, saving what we have")
    finally:
        tx.close()

    verdict = record(args.panel, tx.name, results, notes, args.serial)
    write_sheet()
    bad = [k for k, v in results.items() if v == "fail"]
    print("panel %d: %s%s" % (args.panel, verdict.upper(),
                              " on " + ", ".join(bad) if bad else ""))
    print("sheet: %s" % os.path.relpath(SHEET, REPO))


def record(panel, transport, results, notes, serial):
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
    verdict = ("fail" if "fail" in merged.values()
               else "pass" if all(merged.get(k[0]) == "pass" for k in PATTERNS)
               else "partial")
    json.dump({
        "panel": panel,
        "serial": serial or prev.get("serial", ""),
        "tested": time.strftime("%Y-%m-%d %H:%M"),
        "transport": transport,
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
    mark = {"pass": "ok", "fail": "FAIL", "skip": "."}
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
        "Line up the ten `binref` photos side by side at the same exposure. "
        "Panels that read brighter or a different white than the rest are a "
        "different brightness bin. Put those in the corners or keep them as "
        "spares, because in the middle of a 3x3 wall a bin mismatch reads as a "
        "visible tile and no software fix touches it.",
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


def show(args):
    if args.pattern not in BY_KEY:
        raise SystemExit("patterns: " + ", ".join(BY_KEY))
    tx = make_transport(args)
    key, title, look, build, dwell, _ = BY_KEY[args.pattern]
    frames = build(args.panel)
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
    for key, title, look, build, dwell, _ in PATTERNS:
        tx.tag, tx.n = key, 0
        frames = build(args.panel)
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
        p.add_argument("--panel", type=int, default=1, help="panel number 1-10")

    s = sub.add_parser("sweep", help="run the full QA sweep on one panel")
    common(s)
    s.add_argument("--auto", action="store_true",
                   help="no prompts, just cycle the patterns for photographing")
    s.add_argument("--dwell", type=float, default=None,
                   help="override seconds per static pattern in --auto")
    s.add_argument("--only", help="comma separated pattern keys")
    s.add_argument("--serial", default="", help="panel serial or batch sticker")
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
    args.func(args)


if __name__ == "__main__":
    main()
