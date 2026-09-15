#!/usr/bin/env python3
"""The Record sting, final: flat, one idea, elastic, then still. White on
pure black.

The unlit lattice fades up from the centre. The disc builds along its own
groove, outer rim to spindle, every tile popping in with overshoot while
the whole disc spins down from a fast start and locks into the grid with a
small settle. The mark builds at frame centre, then slides left as its name
arrives: the word is revealed left to right by a feathered wipe with a
slight settle in the same direction, nothing else. A faint white halo comes
up under the disc, and it holds.

    python3 tessera/Tools/record_sting.py [frames dir] [--mode wipe|resolve|playback|eq] [--4k]
    python3 tessera/Tools/record_sting.py [frames dir] --options      # the three name ideas

writes tessera/Design/Logos/record/sting/: record-sting.html (the page),
render.html (the frame the video is shot from), record-sting-1080p.mp4,
record-sting-4k.mp4, start.png and end.png (the pinned frames for a
reference-driven render), storyboard.png. The videos are the page's own
CSS animation stepped a frame at a time through Chrome, so they never
drift from the page.
"""
import math
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import logos  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Design", "Logos", "record", "sting")
BLACK, GHOST, WHITE = "#000000", "#1E1E1E", "#FFFFFF"
FPS, DUR = 30, 5.0
WORD = dict(font="Technor-Bold.otf", text="TESSERA", size=58, tracking=5.5)
CELL = 100 / logos.RECORD_N


def num(v):
    return logos.num(v)


def rasterise_word(text_left, pitch):
    """The word as the wall would show it: sample the crisp letterforms on a
    grid of `pitch` units (half the lattice cell) and size each tile by the
    coverage under it, the same rule the disc uses. Rendered through Chrome
    so the sampling is of the real outlines."""
    from PIL import Image
    from playwright.sync_api import sync_playwright
    text, tw = logos.wordmark(WORD, WHITE, text_left, 60, "")
    W = int(math.ceil(text_left + tw + 12))
    K = 8                                              # pixels per unit
    html = (f'<meta charset="utf-8"><style>html,body{{margin:0;background:#000}}</style>'
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} 120" width="{W * K}" height="{120 * K}">{text}</svg>')
    tmp = os.path.join(tempfile.gettempdir(), "tessera-word.html")
    png = os.path.join(tempfile.gettempdir(), "tessera-word.png")
    with open(tmp, "w") as fh:
        fh.write(html)
    with sync_playwright() as pw:
        try:
            browser = pw.chromium.launch(channel="chrome")
        except Exception:
            browser = pw.chromium.launch(executable_path="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        page = browser.new_page(viewport={"width": W * K, "height": 120 * K})
        page.goto("file://" + tmp)
        page.screenshot(path=png)
        browser.close()
    im = Image.open(png).convert("L")
    cells = []
    x0 = 10 + round((text_left - 10) / pitch) * pitch
    cols = int(math.ceil((text_left + tw - x0) / pitch)) + 1
    for row in range(int(120 / pitch)):
        for col in range(cols):
            x, y = x0 + col * pitch, 10 + row * pitch - 10 + (10 % pitch)
            y = row * pitch + (10 % pitch)
            box = (int(x * K), int(y * K), int((x + pitch) * K), int((y + pitch) * K))
            if box[2] > im.width or box[3] > im.height:
                continue
            crop = im.crop(box)
            cov = sum(crop.getdata()) / (255.0 * crop.width * crop.height)
            if cov > 0.08:
                cells.append((x + pitch / 2, y + pitch / 2, pitch * 0.86 * math.sqrt(cov), col))
    return cells, tw


def text_block(mode, text_left):
    """The name's arrival, one of four ideas. Returns (defs, body, right edge)."""
    text, tw = logos.wordmark(WORD, WHITE, text_left, 60, "")
    ww = tw + 80
    if mode == "wipe":
        defs = (f'<linearGradient id="wg" x1="0" x2="1" y1="0" y2="0"><stop offset="0" stop-color="#fff"/>'
                f'<stop offset="{num(1 - 40 / ww)}" stop-color="#fff"/><stop offset="1" stop-color="#000"/></linearGradient>'
                f'<mask id="wipe" maskUnits="userSpaceOnUse" x="0" y="0" width="2000" height="120">'
                f'<rect class="wiper" x="{num(text_left - 40)}" y="0" width="{num(ww)}" height="120" fill="url(#wg)" style="--ww:{num(ww)}px"/></mask>')
        return defs, f'<g mask="url(#wipe)"><g class="word">{text}</g></g>', text_left + tw
    if mode == "resolve":
        cells, _ = rasterise_word(text_left, CELL / 2)
        cols = max(c[3] for c in cells) + 1
        tiles = "".join(f'<rect class="m" x="{num(cx - s / 2)}" y="{num(cy - s / 2)}" width="{num(s)}" height="{num(s)}" rx=".7" '
                        f'fill="{WHITE}" style="--d:{1.42 + col / cols * 0.42:.3f}s;--e:{1.95 + col / cols * 0.22:.3f}s"/>'
                        for cx, cy, s, col in cells)
        # each crisp letter switches on as the mosaic under it resolves, in column order
        letters = text
        for i in range(7):
            letters = letters.replace(f'class="ch" style="--i:{i}"', f'class="ch" style="--i:{i};--e:{1.97 + i / 7 * 0.22:.3f}s"', 1)
        return "", f'<g class="mosaic">{tiles}</g><g class="crisp">{letters}</g>', text_left + tw
    if mode == "playback":
        # the groove leaves the disc and runs along the baseline; letters rise out of it as it passes
        f = logos.face(WORD["font"])
        paths, w_, b = f.layout(WORD["text"], WORD["size"], WORD.get("tracking", 0.0))
        base_y = 60 + (b[3] - b[1]) / 2                # the baseline sits at the bottom of the box
        x_start, x_end = 112, text_left + tw + 6
        length = x_end - x_start
        letters = text
        for i in range(7):
            letters = letters.replace(f'class="ch" style="--i:{i}"', f'class="ch" style="--i:{i}"', 1)
        return ("", f'<line class="groove" x1="{x_start}" y1="{num(base_y)}" x2="{num(x_end)}" y2="{num(base_y)}" '
                    f'stroke="{WHITE}" stroke-width="1.2" stroke-linecap="round" style="--len:{num(length)}"/>'
                    f'<g class="word" style="--tl:{num(text_left)};--tr:{num(text_left + tw)}">{letters}</g>', text_left + tw)
    if mode == "eq":
        amps = [1.32, 0.86, 1.18, 0.74, 1.24, 0.9, 1.1]
        letters = text
        for i in range(7):
            letters = letters.replace(f'class="ch" style="--i:{i}"', f'class="ch" style="--i:{i};--a:{amps[i]}"', 1)
        return "", f'<g class="word">{letters}</g>', text_left + tw
    raise ValueError(mode)


def sting_svg(mode="wipe"):
    lattice, lit = logos.record_cells()
    # the groove: outer ring first, clockwise, then the next ring in
    rings = 4
    lit = sorted(lit, key=lambda t: -(round(t[3] / logos.RECORD_R * rings) - t[4]))
    text_left = 138
    tdefs, tbody, right = text_block(mode, text_left)
    w = right + 12
    shift = (w / 2 - 60) / w * 100          # the mark builds at frame centre, then slides left for the name
    mx = lattice[0][2]
    parts = [f'<svg class="sting" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {num(w)} 120" style="--shift:{shift:.2f}%">',
             '<defs>',
             f'<radialGradient id="h" cx="60" cy="60" r="62" gradientUnits="userSpaceOnUse">'
             f'<stop offset="0" stop-color="{WHITE}" stop-opacity=".26"/>'
             f'<stop offset=".55" stop-color="{WHITE}" stop-opacity=".07"/>'
             f'<stop offset="1" stop-color="{WHITE}" stop-opacity="0"/></radialGradient>',
             tdefs,
             '</defs>',
             '<circle class="halo" cx="60" cy="60" r="62" fill="url(#h)"/>',
             '<g class="lattice">']
    for cx, cy, s, d in lattice:
        parts.append(f'<rect x="{num(cx + 10 - s / 2)}" y="{num(cy + 10 - s / 2)}" width="{num(s)}" height="{num(s)}" '
                     f'rx="1.1" fill="{GHOST}" style="--d:{0.02 + d * 0.055:.3f}s"/>')
    parts.append('</g><g class="disc">')
    for i, (cx, cy, s, r, ang) in enumerate(lit):
        parts.append(f'<rect class="t" x="{num(cx + 10 - s / 2)}" y="{num(cy + 10 - s / 2)}" width="{num(s)}" '
                     f'height="{num(s)}" rx="{num(min(1.1, s * 0.12))}" fill="{WHITE}" style="--d:{0.15 + i * 0.0155:.3f}s"/>')
    parts.append('</g>')
    parts.append(f'{tbody}</svg>')
    return "".join(parts)


CSS = f"""
.sting .lattice rect,.sting .disc .t,.sting .halo{{transform-box:fill-box;transform-origin:50% 50%}}
.sting .disc{{transform-box:view-box;transform-origin:60px 60px}}
.sting{{transform-origin:50% 50%}}
@keyframes pull{{0%{{transform:translateX(var(--shift)) scale(1.06);animation-timing-function:cubic-bezier(.2,.7,.2,1)}}
  62%{{transform:translateX(var(--shift)) scale(1.01);animation-timing-function:cubic-bezier(.2,.9,.2,1)}}100%{{transform:translateX(0) scale(1)}}}}
@keyframes fade{{from{{opacity:0}}to{{opacity:1}}}}
@keyframes spin{{0%{{transform:rotate(200deg) scale(.9);animation-timing-function:cubic-bezier(.05,.7,.1,1)}}
  84%{{transform:rotate(0deg) scale(1.03);animation-timing-function:ease-in-out}}100%{{transform:rotate(0deg) scale(1)}}}}
@keyframes pop{{0%{{transform:scale(0);opacity:0}}30%{{opacity:1}}100%{{transform:scale(1);opacity:1}}}}
@keyframes glow{{from{{opacity:0;transform:scale(.4)}}to{{opacity:1;transform:scale(1)}}}}
@keyframes wipe{{from{{transform:translateX(calc(-1 * var(--ww)))}}to{{transform:none}}}}
@keyframes settle{{from{{transform:translateX(-16px)}}to{{transform:none}}}}
.run .sting{{animation:pull 2.2s both}}
.run .lattice rect{{animation:fade .3s ease-out both var(--d)}}
.run .disc{{animation:spin 1.45s both .15s}}
.run .disc .t{{animation:pop .5s cubic-bezier(.25,1.7,.4,1) both var(--d)}}
.run .halo{{animation:glow 1.1s ease-out both 1.4s}}
@media (prefers-reduced-motion:reduce){{.run *{{animation:none!important}}}}
"""

MODE_CSS = {
    "wipe": """
.run .wiper{animation:wipe .62s cubic-bezier(.3,.5,.15,1) both 1.42s}
.run .word{animation:settle .8s cubic-bezier(.16,1,.3,1) both 1.42s}
""",
    # the wall's pixels become the type
    "resolve": """
.sting .mosaic .m{transform-box:fill-box;transform-origin:50% 50%}
@keyframes mpop{0%{transform:scale(0)}100%{transform:scale(1)}}
@keyframes mgo{0%{transform:scale(1);opacity:1}100%{transform:scale(0);opacity:0}}
@keyframes crisp{0%{opacity:0}100%{opacity:1}}
.run .mosaic .m{animation:mpop .32s cubic-bezier(.2,1.5,.4,1) both var(--d),mgo .18s ease-in forwards var(--e)}
.sting .crisp .ch{opacity:1}
.run .crisp .ch{animation:crisp .04s steps(1,end) both var(--e)}
""",
    # the record plays the name: the groove runs out along the baseline and the letters rise from it
    "playback": """
.sting .groove{stroke-dasharray:var(--len);stroke-dashoffset:0}
.sting .word .ch{transform-box:fill-box;transform-origin:50% 100%}
@keyframes draw{0%{stroke-dashoffset:var(--len)}100%{stroke-dashoffset:0}}
@keyframes lift{0%{transform:scaleY(.04);opacity:.35}60%{opacity:1}100%{transform:scaleY(1);opacity:1}}
@keyframes gone{0%{opacity:1}100%{opacity:0}}
.run .groove{animation:draw .6s cubic-bezier(.4,0,.2,1) both 1.4s,gone .5s ease-out forwards 2.35s}
.run .word .ch{animation:lift .42s cubic-bezier(.2,1.35,.3,1) both calc(1.47s + var(--i) * .068s)}
""",
    # the name jumps to the beat like a meter, then settles
    "eq": """
.sting .word .ch{transform-box:fill-box;transform-origin:50% 100%}
@keyframes meter{0%{transform:scaleY(0);opacity:0}18%{transform:scaleY(var(--a));opacity:1}42%{transform:scaleY(.55)}
  66%{transform:scaleY(1.12)}84%{transform:scaleY(.94)}100%{transform:scaleY(1);opacity:1}}
.run .word .ch{animation:meter .85s cubic-bezier(.3,.2,.2,1) both calc(1.45s + var(--i) * .05s)}
""",
}



def page_html(svg, mode="wipe"):
    return f"""<title>Tessera Record Sting</title>
<style>
body{{margin:0;background:{BLACK};color:#8A8A8A;min-height:100vh;display:flex;flex-direction:column;
  align-items:center;justify-content:center;font-family:"Switzer","Helvetica Neue",Arial,sans-serif;-webkit-font-smoothing:antialiased}}
.stage{{width:min(72vw,1180px);cursor:pointer;outline:none;padding:12vh 0 4vh}}
.stage:focus-visible{{box-shadow:0 0 0 2px {WHITE}}}
.stage svg{{width:100%;height:auto;display:block}}
p{{font-size:12px;letter-spacing:.1em;text-transform:uppercase;margin:0 0 6vh;opacity:.7}}
{CSS}{MODE_CSS[mode]}
</style>
<div class="stage run" tabindex="0" role="button" aria-label="Replay">{svg}</div>
<p>Record · click to replay</p>
<script>
(function(){{
  var s=document.querySelector('.stage');
  function play(){{s.classList.remove('run');void s.offsetWidth;s.classList.add('run');}}
  s.addEventListener('click',play);
  s.addEventListener('keydown',function(e){{if(e.key==='Enter'||e.key===' '){{e.preventDefault();play();}}}});
  if(!matchMedia('(prefers-reduced-motion: reduce)').matches) setInterval(play,7000);
}})();
</script>
"""


def render_html(svg, mode="wipe"):
    return f"""<meta charset="utf-8"><title>render</title><style>
html,body{{margin:0;background:{BLACK};width:1920px;height:1080px;overflow:hidden}}
.stage{{position:absolute;inset:0;display:flex;align-items:center;justify-content:center}}
.stage svg{{width:1240px;height:auto;display:block}}
{CSS}{MODE_CSS[mode]}</style><div class="stage run">{svg}</div>"""


OPTIONS = [("resolve", "A · Resolve", "The name arrives the way the wall would show it: as tiles on the lattice pitch, popping in "
                                    "left to right, sized by coverage like the disc. Then the mosaic snaps to the crisp letterforms, "
                                    "column by column, the wall's pixels becoming the type."),
           ("playback", "B · Playback", "The record plays the name. Its groove runs out of the disc along the baseline, and each letter "
                                      "rises out of the line as it passes, with a small overshoot, like a needle finding the signal. "
                                      "The groove fades once the word stands."),
           ("eq", "C · Meter", "The name hits the beat. As the disc locks, the letters jump like a meter, each to its own height, "
                              "and settle in three bounces to the lockup. Ties the name to the thud of the lock.")]


def options_html(svgs):
    blocks = "".join(f"""
<section>
  <h2>{title}</h2>
  <div class="stage run" tabindex="0" role="button" aria-label="Replay {title}">{svg}</div>
  <p>{desc}</p>
</section>""" for (mode, title, desc), svg in zip(OPTIONS, svgs))
    css = CSS + "".join(MODE_CSS[m] for m, _, _ in OPTIONS)
    return f"""<title>Tessera Name Options</title>
<style>
body{{margin:0;background:{BLACK};color:#9A9A9A;font-family:"Switzer","Helvetica Neue",Arial,sans-serif;-webkit-font-smoothing:antialiased}}
main{{width:min(72vw,1180px);margin:0 auto;padding:8vh 0 10vh}}
section{{padding:5vh 0 6vh;border-bottom:1px solid #1A1A1A}}
h2{{font-size:12px;letter-spacing:.14em;text-transform:uppercase;font-weight:500;margin:0 0 18px;color:#6E6E6E}}
p{{font-size:14px;line-height:1.55;max-width:62ch;margin:18px 0 0}}
.stage{{cursor:pointer;outline:none}}
.stage:focus-visible{{box-shadow:0 0 0 2px {WHITE}}}
.stage svg{{width:100%;height:auto;display:block}}
{css}
</style>
<main>{blocks}</main>
<script>
(function(){{
  var stages=[].slice.call(document.querySelectorAll('.stage'));
  function play(s){{s.classList.remove('run');void s.offsetWidth;s.classList.add('run');}}
  stages.forEach(function(s){{
    s.addEventListener('click',function(){{play(s)}});
    s.addEventListener('keydown',function(e){{if(e.key==='Enter'||e.key===' '){{e.preventDefault();play(s);}}}});
  }});
  if(!matchMedia('(prefers-reduced-motion: reduce)').matches) setInterval(function(){{stages.forEach(play)}},7000);
}})();
</script>
"""


def video(render_path, frames_dir, scale, mp4_path):
    from playwright.sync_api import sync_playwright
    os.makedirs(frames_dir, exist_ok=True)
    total = int(DUR * FPS)
    with sync_playwright() as pw:
        try:
            browser = pw.chromium.launch(channel="chrome")
        except Exception:
            browser = pw.chromium.launch(executable_path="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        page = browser.new_page(viewport={"width": 1920, "height": 1080}, device_scale_factor=scale)
        page.goto("file://" + os.path.abspath(render_path))
        for f in range(total):
            page.evaluate("t => document.getAnimations().forEach(a => { a.pause(); a.currentTime = t; })", f / FPS * 1000)
            page.screenshot(path=os.path.join(frames_dir, f"{f:04d}.png"))
        browser.close()
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-framerate", str(FPS), "-i", os.path.join(frames_dir, "%04d.png"),
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "15", "-preset", "slow", "-movflags", "+faststart", mp4_path], check=True)


def storyboard(frames_dir, path):
    from PIL import Image
    T = [0.2, 0.45, 0.7, 0.95, 1.2, 1.5, 1.8, 2.6]
    W, H = 450, 253
    board = Image.new("RGB", (W * len(T), H), (0, 0, 0))
    for c, t in enumerate(T):
        im = Image.open(os.path.join(frames_dir, f"{int(t * FPS):04d}.png")).convert("RGB")
        board.paste(im.resize((W, H), Image.LANCZOS), (c * W, 0))
    board.save(path)


def main():
    from PIL import Image
    os.makedirs(OUT, exist_ok=True)
    argv = [a for a in sys.argv[1:] if not a.startswith("--")]
    frames = argv[0] if argv else tempfile.mkdtemp(prefix="record-sting-")
    if "--options" in sys.argv:
        # the three name ideas, side by side, previews only
        opt = os.path.join(OUT, "options")
        os.makedirs(opt, exist_ok=True)
        svgs = [sting_svg(m) for m, _, _ in OPTIONS]
        with open(os.path.join(opt, "name-options.html"), "w") as fh:
            fh.write(options_html(svgs))
        for (m, _, _), svg in zip(OPTIONS, svgs):
            render = os.path.join(opt, f"render-{m}.html")
            with open(render, "w") as fh:
                fh.write(render_html(svg, m))
            video(render, os.path.join(frames, m), 1, os.path.join(opt, f"preview-{m}.mp4"))
        print("wrote", opt)
        return
    mode = sys.argv[sys.argv.index("--mode") + 1] if "--mode" in sys.argv else "wipe"
    svg = sting_svg(mode)
    page = os.path.join(OUT, "record-sting.html")
    render = os.path.join(OUT, "render.html")
    with open(page, "w") as fh:
        fh.write(page_html(svg, mode))
    with open(render, "w") as fh:
        fh.write(render_html(svg, mode))
    video(render, os.path.join(frames, "hd"), 1, os.path.join(OUT, "record-sting-1080p.mp4"))
    storyboard(os.path.join(frames, "hd"), os.path.join(OUT, "storyboard.png"))
    last = int(DUR * FPS) - 1
    Image.open(os.path.join(frames, "hd", f"{last:04d}.png")).convert("RGB").save(os.path.join(OUT, "end.png"))
    Image.new("RGB", (1920, 1080), (0, 0, 0)).save(os.path.join(OUT, "start.png"))
    if "--4k" in sys.argv:
        video(render, os.path.join(frames, "uhd"), 2, os.path.join(OUT, "record-sting-4k.mp4"))
    print("wrote", OUT)


if __name__ == "__main__":
    main()
