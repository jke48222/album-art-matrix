#!/usr/bin/env python3
"""Render every Home Screen widget state from the installed app, and check the evidence.

The app's DEBUG harness (-widget-render, tessera/Tessera/WidgetRenderHarness.swift)
draws the widget's own views for every fixture, both sizes, the 375, 393 and
440 phone classes and five text sizes, and writes PNGs and manifest.json (last)
to Library/Caches/widget-renders. This script launches it, collects the
output and checks:

- each fixture frame is the bytes Python makes (capture_home.artwork(64) and
  artwork(192), the lamp and check fills, the dark frame, and the clock,
  timer and weather faces drawn with the harness's three by five digits),
  by sha256
- every guests-cover PNG is byte-identical to music's: the guest-code fixture
  is built from a guests /state body through the production WallFacts
  mapping, so this proves the mapping, not the fixture
- the accessibility5 PNG of every render equals its accessibility2 PNG (the
  views cap type there), and every small widget's accessibility PNGs equal
  its xxxLarge PNG (its one label stops growing there, so it never draws
  smaller at a larger text size)
- nothing the widget says is cut: the harness lays out the chip, the status
  line and each key's word at the smallest scale the views allow
  (WidgetType), and records whether each fits without a word broken
  mid-word
- the medium widget's words are the view's own: the harness measures each
  of MediumWordsFit.order as ViewThatFits does, takes the first that fits
  the room above the keys, and proves by pixels that the widget's words
  drawn in that room are that block (words_match_view), and that a choice
  passed over draws other pixels (words_proof_discriminates). The words
  drawn must fit the room (words_fit) at their own height, with nothing
  squeezed or cut (words_whole), and a title that is not a song must be
  whole there (title_fits). Whether a subtitle is drawn at all is read off
  the view too, and must agree with the text the harness says is shown
  (subtitle_model_matches)
- a song's title and any subtitle may be shortened, but only after a whole
  word: every title and subtitle shown must be the whole text or a
  whole-word prefix and an ellipsis, and must fit its lines. The title
  wins over the artist: an artist is shown only beside a title that is
  whole or takes its two lines (title_before_artist), a song title of three
  words or fewer is whole at every size, and a shortened artist keeps a
  word of four or more letters ("The..." is left out instead)
- a subtitle the reading keeps (a timer's time left, a place, a hint, a
  dimmed picture's age, what the wall is changing to) is never the thing
  the medium widget drops: it is shown with the title or in its place,
  whole, or for a timer as its time alone
- the two sizes explain a dimmed picture the same way: where the medium
  widget's status is a queued change or a change the wall is making, its
  subtitle is the small widget's label
- no reading string holds an em dash, en dash, semicolon, middot, the
  multiplication sign or "asleep"

It writes contact sheets, one per group of fixtures and phone class
(contact-<group>-<class>.png, the small and medium widget at each text size,
composited on the page ground with the harness mask kept), contact-sheet.png
(every fixture on the 393 class), true-64.png and true-192.png (the frames as
the wall is sent them, nearest neighbour) and receipt.json.
The rounded corner in the renders is the harness's mask, not the system's.
"""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

from zoneinfo import ZoneInfo

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/qa"))
from capture_home import app_identity, artwork  # noqa: E402

SIMULATOR = "9108AFCE-E437-42FF-A946-C41349BE6540"
BUNDLE = "com.jalenedusei.tessera"
BANNED = ["\u2014", "\u2013", ";", "\u00b7", "\u00d7"]
TYPES = ["large", "xxxLarge", "accessibility1", "accessibility2", "accessibility5"]
PHONES = ["375", "393", "440"]
# What the harness records for each render. title_fits is left out for a
# song, whose title may end after a whole word, and title_words_fit and
# title_before_artist cover it instead.
FITS = ["chip_fits", "status_fits", "key_fits", "title_fits", "title_words_fit", "subtitle_fits",
        "words_fit", "words_whole", "words_match_view", "words_proof_discriminates", "title_before_artist",
        "subtitle_model_matches"]
ELLIPSIS = "\u2026"
GROUND = (21, 21, 19)
GROUPS = {
    "music": ["music", "music-long", "music-under-lamp", "guests-cover", "wall192"],
    "faces": ["lamp", "weather", "clock", "timer", "timer-done", "panel-check", "connection-check"],
    "dark": ["idle-dark", "away", "off", "missing", "unreadable"],
    "dated": ["stale", "stale-days", "outdated", "queued", "preview"],
}

# WidgetRenderHarness's three by five digits, dot for dot.
GLYPHS = {
    "0": ["111", "101", "101", "101", "111"], "1": ["010", "110", "010", "010", "111"],
    "2": ["111", "001", "111", "100", "111"], "3": ["111", "001", "111", "001", "111"],
    "4": ["101", "101", "111", "001", "001"], "5": ["111", "100", "111", "001", "111"],
    "6": ["111", "100", "111", "101", "111"], "7": ["111", "001", "001", "001", "001"],
    "8": ["111", "101", "111", "101", "111"], "9": ["111", "101", "111", "001", "111"],
    ":": ["0", "1", "0", "1", "0"], "o": ["111", "101", "111", "000", "000"],
}


def draw(px: bytearray, text: str, scale: int, colour, x=None, y=None, side=64):
    rows = [GLYPHS[c] for c in text if c in GLYPHS]
    units = sum(len(g[0]) for g in rows) + max(0, len(rows) - 1)
    left = (side - units * scale) // 2 if x is None else x
    top = (side - 5 * scale) // 2 if y is None else y
    for glyph in rows:
        for gy, row in enumerate(glyph):
            for gx, dot in enumerate(row):
                if dot != "1":
                    continue
                for dy in range(scale):
                    for dx in range(scale):
                        px0, py0 = left + gx * scale + dx, top + gy * scale + dy
                        if 0 <= px0 < side and 0 <= py0 < side:
                            o = (py0 * side + px0) * 3
                            px[o:o + 3] = bytes(colour)
        left += (len(glyph[0]) + 1) * scale


def clock64(now: int) -> bytes:
    # The clock fixture froze 30 s before now, in the harness's time zone.
    t = datetime.fromtimestamp(now - 30, ZoneInfo("Europe/London"))
    px = bytearray(64 * 64 * 3)
    draw(px, f"{t.hour}:{t.minute:02d}", 3, (235, 228, 216))
    return bytes(px)


def timer64(seconds: int) -> bytes:
    px = bytearray(64 * 64 * 3)
    draw(px, f"{seconds // 60}:{seconds % 60:02d}", 3, (229, 163, 67))
    return bytes(px)


def weather64() -> bytes:
    px = bytearray()
    for y in range(64):
        for x in range(64):
            px += bytes((236, 174, 64) if (x - 20) ** 2 + (y - 20) ** 2 <= 90 else (10, 18, 34))
    draw(px, "14o", 3, (235, 228, 216), x=25, y=40)
    return bytes(px)


def frames(now: int) -> dict:
    return {
        "artwork64": artwork(64),
        "artwork192": artwork(192),
        "lamp64": bytes((229, 163, 67)) * 64 * 64,
        "check64": bytes((191, 191, 191)) * 64 * 64,
        "dark64": bytes(64 * 64 * 3),
        "clock64": clock64(now),
        "timer64": timer64(282),
        "timerdone64": timer64(0),
        "weather64": weather64(),
    }


def whole_words(shown, full) -> bool:
    """The whole text, or its first words and an ellipsis, never part of one."""
    if shown is None or shown == full:
        return True
    # A timer's "4:12 left" may shorten to "4:12", with no ellipsis.
    head = (shown[:-1] if shown.endswith(ELLIPSIS) else shown).split()
    words = full.split()
    if not head or len(head) > len(words) or head[:-1] != words[:len(head) - 1]:
        return False
    original, last = words[len(head) - 1], head[-1]
    return original.startswith(last) and not any(c.isalnum() for c in original[len(last):])


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def nearest(px: bytes, side: int, k: int) -> Image.Image:
    return Image.frombytes("RGB", (side, side), px).resize((side * k, side * k), Image.NEAREST)


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, text=True, capture_output=True, **kw)


def collect(app: Path, simulator: str, now: int, timeout: float) -> Path:
    run(["xcrun", "simctl", "install", simulator, str(app.resolve())])
    container = Path(run(["xcrun", "simctl", "get_app_container", simulator, BUNDLE, "data"]).stdout.strip())
    renders = container / "Library/Caches/widget-renders"
    shutil.rmtree(renders, ignore_errors=True)
    env = {"SIMCTL_CHILD_TZ": "Europe/London"}
    run(["xcrun", "simctl", "launch", "--terminate-running-process", simulator, BUNDLE,
         "-widget-render", "all", "-widget-now", str(now), "-nointro",
         "-AppleLocale", "en_GB", "-AppleLanguages", "(en-GB)"], env={**os.environ, **env})
    manifest = renders / "manifest.json"
    deadline = time.time() + timeout
    while not manifest.exists():
        if time.time() > deadline:
            raise TimeoutError(f"No manifest after {timeout:.0f} s at {manifest}")
        time.sleep(1)
    time.sleep(0.5)
    return renders


def label_font(size: int):
    for path in ("/System/Library/Fonts/SFNSMono.ttf", "/System/Library/Fonts/Menlo.ttc",
                 "/System/Library/Fonts/Helvetica.ttc"):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    try:
        return ImageFont.load_default(size=size)
    except TypeError:
        return ImageFont.load_default()


def contact_sheet(manifest: dict, folder: Path, out: Path, fixtures: list, phones: list) -> None:
    """Fixtures as rows, the small then the medium widget at each text size as
    columns, at points. The renders' transparent corners are the harness mask,
    so they are composited on the sheet's own ground, not on black."""
    renders = manifest["renders"]
    fixtures = [f for f in fixtures if f in manifest["fixtures"]]
    columns = [(family, phone, kind) for phone in phones for family in ("small", "medium") for kind in TYPES]
    scale = 1 / 3            # back to points
    pad, label_w, head_h = 14, 190, 64
    widths, heights = [], []
    for family, phone, _ in columns:
        sample = next((r for r in renders if r["family"] == family and r["class"] == phone), None)
        widths.append(int(sample["size_pt"][0]) if sample else 170)
        heights.append(int(sample["size_pt"][1]) if sample else 170)
    row_h = max(heights or [170]) + pad
    sheet = Image.new("RGBA", (label_w + sum(widths) + pad * len(widths), head_h + row_h * len(fixtures)), GROUND + (255,))
    pen = ImageDraw.Draw(sheet)
    big, small = label_font(18), label_font(15)
    x = label_w
    for (family, phone, kind), w in zip(columns, widths):
        pen.text((x, 8), f"{family} {phone}", fill=(203, 196, 181), font=big)
        pen.text((x, 34), kind, fill=(150, 144, 127), font=small)
        x += w + pad
    for row, fixture in enumerate(fixtures):
        y = head_h + row * row_h
        pen.text((12, y + 8), fixture, fill=(234, 228, 216), font=big)
        x = label_w
        for (family, phone, kind), w in zip(columns, widths):
            match = next((r for r in renders if r["fixture"] == fixture and r["family"] == family
                          and r["class"] == phone and r["dynamic_type"] == kind), None)
            if match:
                img = Image.open(folder / match["png"]).convert("RGBA")
                img = img.resize((int(img.width * scale), int(img.height * scale)), Image.LANCZOS)
                sheet.alpha_composite(img, (x, y))
            x += w + pad
    sheet.convert("RGB").save(out)


def verify(manifest: dict, folder: Path) -> list:
    checks = []

    def check(name, passed, detail=""):
        checks.append({"name": name, "passed": bool(passed), **({"detail": detail} if detail and not passed else {})})

    made = frames(int(manifest["now"]))
    for entry in manifest["frames"]:
        source = entry["source"]
        if source == "none":
            check(f"{entry['fixture']}: no frame", "sha256" not in entry)
            continue
        check(f"{entry['fixture']}: frame is Python's {source}", entry.get("sha256") == sha(made[source]),
              f"{entry.get('sha256')} != {sha(made[source])}")

    renders = manifest["renders"]
    by_key = {(r["fixture"], r["family"], r["class"], r["dynamic_type"]): r for r in renders}
    music = {k[1:]: v for k, v in by_key.items() if k[0] == "music"}
    guests = {k[1:]: v for k, v in by_key.items() if k[0] == "guests-cover"}
    check("guests-cover renders every cell music does", set(music) == set(guests) and len(music) > 0)
    for cell, render in guests.items():
        if cell in music:
            same = (folder / render["png"]).read_bytes() == (folder / music[cell]["png"]).read_bytes()
            check(f"guests-cover {'-'.join(cell)} is byte-identical to music", same)
        for key in ("status", "chip", "title", "subtitle", "accessibility"):
            words = (render.get(key) or "").lower()
            check(f"guests-cover {'-'.join(cell)} {key} never names the code",
                  "guest" not in words and "wi-fi" not in words and "code" not in words)

    for (fixture, family, phone, kind), render in by_key.items():
        if kind != "accessibility5":
            continue
        ax2 = by_key.get((fixture, family, phone, "accessibility2"))
        check(f"{fixture} {family} {phone}: AX5 equals AX2", ax2 is not None
              and (folder / render["png"]).read_bytes() == (folder / ax2["png"]).read_bytes())
    check("the harness saw AX5 equal AX2 everywhere", manifest.get("ax5_matches_ax2") is True)
    for (fixture, family, phone, kind), render in by_key.items():
        if family != "small" or not kind.startswith("accessibility"):
            continue
        capped = by_key.get((fixture, family, phone, "xxxLarge"))
        check(f"{fixture} small {phone}: {kind} equals xxxLarge", capped is not None
              and (folder / render["png"]).read_bytes() == (folder / capped["png"]).read_bytes())
    for render in renders:
        if render["fixture"] in ("queued", "outdated") and render["family"] == "medium":
            check(f"{render['fixture']} medium {render['class']} {render['dynamic_type']}: the subtitle is the small label",
                  render.get("subtitle") == render.get("chip") and render.get("keeps_subtitle") is True,
                  f"{render.get('subtitle')!r} beside a small label of {render.get('chip')!r}")

    def fit_detail(render, key):
        if key == "chip_fits":
            return render.get("chip")
        if key == "status_fits":
            return render.get("status")
        if key == "key_fits":
            return f"cut: {render.get('key_cut')}"
        if key == "title_words_fit":
            return f"{render.get('title')!r}: a word is wider than the column at every step"
        if key == "subtitle_fits":
            return f"{render.get('subtitle_text')!r} is wider than the column"
        if key == "words_match_view":
            return f"the widget drew something other than {render.get('words_layout')!r}"
        if key == "words_proof_discriminates":
            return "the first choice, passed over, drew the same pixels as the one taken"
        if key == "words_whole":
            return (f"{render.get('words_layout')!r} drew {render.get('words_drawn_pt')} pt of its "
                    f"{render.get('words_pt')} pt: something in it was squeezed or cut")
        if key == "subtitle_model_matches":
            return f"the view {'drew' if render.get('subtitle_drawn') else 'left out'} {render.get('subtitle')!r}"
        if key == "title_before_artist":
            return f"{render.get('title_text')!r} on {render.get('title_lines')} line(s) beside {render.get('subtitle_text')!r}"
        return (f"{render.get('title')!r}: {render.get('words_layout')} needs {render.get('words_drawn_pt')} pt "
                f"of {render.get('words_room_pt')} pt")

    for render in renders:
        for key in FITS:
            if key in render:
                check(f"{render['fixture']} {render['family']} {render['class']} {render['dynamic_type']}: {key}",
                      render[key], fit_detail(render, key))
        # What a medium widget sets is whole, or ends after a whole word.
        for key, full in (("title_text", render.get("title")), ("title_text_one_line", render.get("title")),
                          ("subtitle_text", render.get("subtitle"))):
            if key in render and render[key] is not None:
                check(f"{render['fixture']} {render['family']} {render['class']} {render['dynamic_type']}: "
                      f"{key} ends after a whole word", whole_words(render[key], full), repr(render[key]))
        cell = f"{render['fixture']} {render['family']} {render['class']} {render['dynamic_type']}"
        if render["family"] == "medium":
            check(f"{cell}: the words the widget draws are known", "words_layout" in render and "words_match_view" in render)
        if render["family"] == "medium" and render.get("keeps_subtitle"):
            check(f"{cell}: the subtitle it keeps is shown",
                  render.get("subtitle_layout") in ("with title", "promoted"),
                  f"{render.get('subtitle')!r}: {render.get('words_layout')}")
            full, shown = render.get("subtitle") or "", render.get("subtitle_text")
            whole = shown == full or (render.get("timed") and full.split() and shown == full.split()[0])
            check(f"{cell}: the subtitle it keeps is whole", whole, f"{shown!r} of {full!r}")
        if render["family"] == "medium" and render.get("title_is_song"):
            title = render.get("title") or ""
            if len(title.split()) <= 3:
                check(f"{cell}: a short song title is whole", render.get("title_text") == title,
                      f"{render.get('title_text')!r}: {render.get('words_layout')}")
        shown = render.get("subtitle_text")
        if render["family"] == "medium" and shown and shown != render.get("subtitle") and shown.endswith(ELLIPSIS):
            telling = any(sum(c.isalnum() for c in word) >= 4 for word in shown[:-1].split())
            check(f"{cell}: a shortened subtitle keeps a telling word", telling, repr(shown))
        # Every render's strings, not only the last one's.
        for key in ("status", "chip", "title", "subtitle", "accessibility"):
            text = render.get(key) or ""
            bad = [b for b in BANNED if b in text] + (["asleep"] if "asleep" in text.lower() else [])
            if bad:
                check(f"{render['fixture']} {key} copy", False, f"{text!r} holds {bad}")
    for fixture in manifest["fixtures"]:
        mediums = [r for r in renders if r["fixture"] == fixture and r["family"] == "medium"]
        # The title's words are measured at the size the view draws them,
        # not at the smallest it could shrink to.
        check(f"{fixture}: the title is measured at the step it is drawn at",
              bool(mediums) and all("title_scale" in r for r in mediums))
        if mediums and not mediums[0].get("title_is_song"):
            check(f"{fixture}: the title is checked against its room",
                  all("title_fits" in r for r in mediums))
    check("every reading string passes the copy lint",
          not any(c["name"].endswith(" copy") for c in checks))
    for render in renders:
        png = folder / render["png"]
        if sha(png.read_bytes()) != render["sha256"]:
            check(f"{render['png']} matches its manifest sha256", False)
    return checks


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--app", type=Path, required=True)
    p.add_argument("--out", type=Path, default=ROOT / "qa/batch-17/after/widgets")
    p.add_argument("--simulator", default=SIMULATOR)
    p.add_argument("--now", type=int, default=1790000000)
    p.add_argument("--timeout", type=float, default=600)
    a = p.parse_args()
    renders = collect(a.app, a.simulator, a.now, a.timeout)
    out = a.out
    shutil.rmtree(out / "renders", ignore_errors=True)
    out.mkdir(parents=True, exist_ok=True)
    shutil.copytree(renders, out / "renders")
    manifest = json.loads((out / "renders/manifest.json").read_text())
    checks = verify(manifest, out / "renders")
    for stale in out.glob("contact-*.png"):
        stale.unlink()
    for group, fixtures in GROUPS.items():
        for phone in PHONES:
            contact_sheet(manifest, out / "renders", out / f"contact-{group}-{phone}.png", fixtures, [phone])
    contact_sheet(manifest, out / "renders", out / "contact-sheet.png", manifest["fixtures"], ["393"])
    made = frames(a.now)
    nearest(made["artwork64"], 64, 8).save(out / "true-64.png")
    nearest(made["artwork192"], 192, 3).save(out / "true-192.png")
    failed = [c for c in checks if not c["passed"]]
    receipt = {
        "passed": not failed,
        "checks": len(checks),
        "failed": failed,
        "renders": len(manifest["renders"]),
        "fixtures": manifest["fixtures"],
        "now": manifest["now"], "timezone": manifest["timezone"], "locale": manifest["locale"],
        "mask": manifest["mask"],
        "app": app_identity(a.app, str(a.app.resolve())),
        "scope": "Software renders of the widget's own SwiftUI views at scale 3 in the app process. "
                 "Tinted, Clear and StandBy appearances and the system's own mask are not certified here, "
                 "and software previews do not certify LED colour.",
    }
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    (out / "checks.json").write_text(json.dumps(checks, indent=2) + "\n")
    print(json.dumps({"passed": receipt["passed"], "checks": len(checks), "failed": len(failed),
                      "renders": receipt["renders"], "out": str(out)}))
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
