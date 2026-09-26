#!/usr/bin/env python3
"""Compose real native comparisons and exact-resolution production puzzle proofs."""
from __future__ import annotations

import hashlib
import html
import json
from pathlib import Path
import shutil
from datetime import datetime, timezone

from PIL import Image, ImageDraw
from compare_home import Feature, compose, load_font

ROOT = Path(__file__).resolve().parents[2]
BATCH = ROOT / "qa/batch-09"
OUT = BATCH / "comparisons"
FEATURES = [("teach", "F08", "Teach the wall"), ("shelf", "F09", "The shelf"),
            ("games", "G00", "Games"), ("wordle", "G01", "Wordle"), ("sudoku", "G02", "Sudoku")]
PUZZLES = [("wordle-playing", "A word taking shape"), ("wordle-won", "A word found"),
           ("wordle-lost", "The answer, revealed"), ("sudoku-playing", "Every number has a place"),
           ("sudoku-error", "A mistake you can recover from"), ("sudoku-notes", "A little room to think"),
           ("sudoku-won", "The completed grid")]


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def copy(source: Path, name: str | None = None) -> str:
    destination = OUT / (name or source.name)
    shutil.copy2(source, destination)
    return destination.name


def pixel_pair(name: str, side: int) -> dict:
    paths = [BATCH / "puzzles" / f"{name}-{version}-{side}.png" for version in ("before", "after")]
    images = [Image.open(path).convert("RGB") for path in paths]
    if any(image.size != (side, side) for image in images):
        raise ValueError(f"{name}: expected actual {side}×{side} renderer output")
    factor = max(1, 384 // side)
    display = side * factor
    margin, gap, top = 16, 24, 50
    canvas = Image.new("RGB", (display*2+margin*2+gap, display+top+margin), "#0B0A09")
    draw = ImageDraw.Draw(canvas)
    font = load_font(ROOT, "MartianMono-Regular.ttf", 12)
    for index, (image, label) in enumerate(zip(images, ("BEFORE", "AFTER"))):
        x = margin + index*(display+gap)
        draw.text((x, 17), f"{label} · {side} × {side}", font=font, fill="#AAA390" if index == 0 else "#BDD6B4")
        canvas.paste(image.resize((display, display), Image.Resampling.NEAREST), (x, top))
        copy(paths[index])
    output = OUT / f"{name}-{side}-comparison.png"
    canvas.save(output, optimize=True)
    return {"case":name,"native_side":side,"integer_scale":factor,"processing":"Identical integer enlargement with nearest-neighbor sampling; no smoothing or retouching.",
            "before":paths[0].name,"after":paths[1].name,"before_sha256":digest(paths[0]),"after_sha256":digest(paths[1]),"output":output.name,"output_sha256":digest(output)}


def urls(value):
    found = set()
    if isinstance(value, dict):
        for key, item in value.items():
            if key in {"url", "mobbin_url"} and isinstance(item, str) and item.startswith("https://"):
                found.add(item)
            else:
                found.update(urls(item))
    elif isinstance(value, list):
        for item in value:
            found.update(urls(item))
    return found


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    native, sections, extra_states, pixel_rows, pixel_sections = [], [], [], [], []
    for name, unit, title in FEATURES:
        before, after = BATCH / "before" / name / "room-live.png", BATCH / "after" / name / "room-live.png"
        native.append(compose(ROOT, before, after, OUT/f"{name}.png", Feature(unit, title, name), 390))
        extras = [f'<a href="{name}.png" target="_blank">Full before / after ↗</a>']
        for state, label in [("room-large", "Largest accessibility text"), ("room-offline", "Wall offline")]:
            source = BATCH / "after" / name / f"{state}.png"
            if source.exists():
                target = copy(source, f"{name}-{state}.png")
                extras.append(f'<a href="{target}" target="_blank">{label} ↗</a>')
        sections.append(f'<section id="{name}"><small>{unit}</small><h2>{html.escape(title)}</h2><div class="links">'+"".join(extras)+f'</div><img loading="lazy" src="{name}.png" alt="{html.escape(title)}: before left, after right, complete native screens at identical scale"></section>')
    for case, title in PUZZLES:
        parts = []
        for side in (64, 192, 512):
            row = pixel_pair(case, side)
            pixel_rows.append(row)
            parts.append(f'<details {"open" if side == 64 else ""}><summary>{side} × {side} native RGB pixels</summary><div class="links"><a href="{row["before"]}" target="_blank">Original before ↗</a><a href="{row["after"]}" target="_blank">Original after ↗</a></div><img class="pixels" loading="lazy" src="{row["output"]}" alt="{html.escape(title)} at true {side}-pixel resolution, before and after"></details>')
        note = 'Pencil marks are new in this pass. The baseline has the same selected cell, without pencil-mark support.' if case == "sudoku-notes" else 'Production Python renders at matched puzzle state. The phone places its controls outside this shared board.'
        pixel_sections.append(f'<section><small>PRODUCTION WALL RENDERER</small><h2>{html.escape(title)}</h2><p>{note}</p>'+"".join(parts)+"</section>")
    motion = BATCH / "puzzles/wordle-reveal.gif"
    if motion.exists():
        target = copy(motion)
        pixel_sections.append(f'<section><small>WORDLE / CURRENT MOTION</small><h2>One letter at a time.</h2><p>The current production reveal, rendered at 192 × 192 and enlarged with nearest-neighbor sampling. This animation shows the new renderer.</p><details><summary>Play the three-second letter reveal</summary><img class="motion pixels" loading="lazy" src="{target}" alt="The current Wordle renderer revealing a guess one letter at a time"></details></section>')
    for directory in sorted((BATCH / "after").iterdir()):
        if not directory.is_dir() or directory.name in {name for name, _, _ in FEATURES}:
            continue
        source = directory / "room-live.png"
        if not source.exists():
            continue
        target = copy(source, f"state-{directory.name}.png")
        title = html.escape(directory.name.replace("-", " ").title())
        extra_states.append(f'<details><summary>{title}</summary><img class="phone" loading="lazy" src="{target}" alt="{title}: actual native capture using controlled fixture data"></details>')
    references = set()
    for source in BATCH.glob("references-*.json"):
        references.update(urls(json.loads(source.read_text())))
    reference_links = ''.join(f'<li><a href="{html.escape(url,quote=True)}" target="_blank" rel="noreferrer">{html.escape(url.replace("https://", ""))} ↗</a></li>' for url in sorted(references))
    deployment = "Deployment receipts are recorded beside this gallery."
    validation_path = BATCH / "validation.json"
    validation = json.loads(validation_path.read_text()) if validation_path.exists() else None
    if isinstance(validation, dict):
        explicit = validation.get("deployment_summary")
        if not isinstance(explicit, str) and isinstance(validation.get("deployment"), dict):
            explicit = validation["deployment"].get("summary")
        if isinstance(explicit, str) and explicit.strip():
            deployment = explicit.strip()
    receipts = []
    for filename, label in [("validation.json", "Validation"), ("wall-deployment.json", "Wall deployment"), ("phone-deployment.json", "Phone deployment")]:
        source = BATCH / filename
        if source.exists():
            copy(source)
            receipts.append(f'<a href="{filename}" target="_blank">{label} receipt ↗</a>')
    nav = ''.join(f'<a href="#{name}">{html.escape(title)}</a>' for name, _, title in FEATURES)
    style = '''<style>:root{color-scheme:dark}*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:#0b0a09;color:#eae4d8;font:16px system-ui}header,main{max-width:1100px;margin:auto;padding:42px 28px}small{font:11px monospace;letter-spacing:2px;color:#bdd6b4}h1{font-size:clamp(36px,6vw,68px);font-weight:550;letter-spacing:-2.5px;line-height:1.03;margin:20px 0}p{max-width:770px;color:#aaa390;line-height:1.65}nav{position:sticky;top:0;z-index:2;display:flex;overflow:auto;gap:8px;padding:14px max(18px,calc((100vw - 1044px)/2));background:#141210f5;backdrop-filter:blur(16px);border-block:1px solid #ffffff13}a{color:inherit}nav a{flex:none;border:1px solid #ffffff26;border-radius:10px;padding:12px;text-decoration:none;font-size:13px}a:hover,a:focus{color:#bdd6b4}a:focus-visible,summary:focus-visible{outline:2px solid #bdd6b4;outline-offset:5px}.links{display:flex;gap:16px;flex-wrap:wrap;font-size:13px;line-height:1.6}section{scroll-margin-top:90px;padding:18px 0 36px;border-bottom:1px solid #ffffff19;margin-bottom:24px}h2{font-size:30px;letter-spacing:-.8px;font-weight:550;margin:10px 0}img{display:block;width:100%;height:auto;margin:24px 0 0}summary{padding:18px 0;cursor:pointer;color:#c7cfbd}.phone{max-width:420px;margin:20px auto 40px}.pixels{image-rendering:pixelated}.motion{max-width:384px;margin:24px auto}footer,li{color:#aaa390;font-size:13px;line-height:1.7;padding:8px 0}li a{overflow-wrap:anywhere}.scope{padding:20px 24px;background:#141210;border-left:2px solid #bdd6b4;margin-top:28px}@media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}}</style>'''
    state_section = '<section id="states"><small>NATIVE STATES</small><h2>Progress, results and recovery.</h2>'+''.join(extra_states)+'</section>' if extra_states else ''
    page = '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Tessera · Pass 09</title>'+style+'''<header><small>TESSERA / PASS 09 / F08 · F09 · G00 · G01 · G02</small><h1>Your music.<br>A little play.</h1><p>A personal song library, a record shelf, and a clearer way into games. Wordle and Sudoku share their boards with the wall, with room to think and feedback that makes the next move clear.</p><div class="scope"><p>Actual native app screens: before on the left, after on the right. Each pair uses the same scale and preserves the complete screenshot. Songs, artwork, collection data and game records are authored fixtures.</p><p>These captures verify rendering and API states. They do not certify touch interaction, real listening, or the physical LEDs’ colour.</p></div></header><nav aria-label="Comparison sections">'''+nav+'<a href="#pixels">Wall pixels</a>'+('<a href="#states">More states</a>' if extra_states else '')+'<a href="#references">References</a></nav><main>'+''.join(sections)+'<div id="pixels">'+''.join(pixel_sections)+'</div>'+state_section+'<section id="references"><small>RESEARCH APPLIED IN CODE</small><h2>References</h2><ul>'+reference_links+'</ul></section><footer><p>The app is production Swift; the puzzle frames are production Python output at true 64, 192 and 512 pixel resolutions. RGB comparisons use equal integer enlargement without smoothing. The phone’s input controls sit outside the shared board.</p><p>'+html.escape(deployment)+'</p><div class="links">'+''.join(receipts)+'</div></footer></main></html>'
    (OUT / "index.html").write_text(page)
    manifest = {"base":"8bdda75","generated_at":datetime.now(timezone.utc).isoformat(),
                "units":[unit for _,unit,_ in FEATURES],"processing":"Complete native screenshots scaled equally, not retouched. Before left, after right.",
                "scope":"Rendering and fixture API states; no touch, spoken-recognition or physical LED certification.",
                "comparisons":native,"pixel_comparisons":pixel_rows,"puzzle_manifest":"../puzzles/manifest.json",
                "motion":"wordle-reveal.gif" if motion.exists() else None,"extra_native_states":len(extra_states),
                "deployment_note":deployment,"validation_present":validation is not None,"references":sorted(references)}
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2)+"\n")
    print(OUT / "index.html")


if __name__ == "__main__":
    main()
