#!/usr/bin/env python3
"""Compose native comparisons and exact-resolution production party-game proofs."""
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
BATCH = ROOT / "qa/batch-12"
OUT = BATCH / "comparisons"
FEATURES = [("heardle", "G13", "Heardle"), ("twentyq", "G14", "Twenty Questions"),
            ("quiz", "G15", "Pub Quiz"), ("pictionary", "G16", "AI Pictionary"), ("pong", "G17", "Pong")]
STAGES = {name: ['playing', 'won'] for name,_,_ in FEATURES}
STAGES['heardle'] += ['ready','lost']
STAGES['twentyq'] += ['loading','error']
STAGES['quiz'] += ['answer']
STAGES['pictionary'] += ['loading','error','lost']
STAGES['pong'] += ['ready']
PUZZLES = [(f"{name}-{stage}", f"{title} · {stage}") for name,_,title in FEATURES for stage in STAGES[name]]


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
        note = 'Production Python renders at matched game state. The phone places its controls outside this shared board.'
        pixel_sections.append(f'<section><small>PRODUCTION WALL RENDERER</small><h2>{html.escape(title)}</h2><p>{note}</p>'+"".join(parts)+"</section>")
    motion_files = []
    for name, title in [('twentyq','Twenty Questions'),('quiz','Pub Quiz')]:
        source=BATCH/'puzzles'/f'{name}-question-motion.gif'
        if source.exists():
            target=copy(source)
            motion_files.append(target)
            pixel_sections.append(f'<section><small>TRUE64-PIXEL MOTION</small><h2>{title}: read the complete question.</h2><details><summary>Show nineteen seconds of the actual wall renderer</summary><img class="pixels" style="max-width:384px" src="{target}" alt="Complete question revealed over time without dropping words"></details></section>')
    for directory in sorted((BATCH / "after").iterdir()):
        if not directory.is_dir() or directory.name in {name for name, _, _ in FEATURES}:
            continue
        source = directory / "room-live.png"
        if not source.exists():
            continue
        target = copy(source, f"state-{directory.name}.png")
        title = html.escape(directory.name.replace("-", " ").title())
        extra_states.append(f'<details><summary>{title}</summary><img class="phone" loading="lazy" src="{target}" alt="{title}: actual native capture using controlled fixture data"></details>')
    hardware_sections=[]
    for name, unit, title in FEATURES:
        inputs=[BATCH / 'hardware' / version / (name+'-live.png') for version in ('before','after')]
        if not all(path.exists() for path in inputs):
            if inputs[1].exists():
                filename=copy(inputs[1],name+'-hardware-after.png')
                detail=BATCH/'hardware/after'/(name+'-detail.png')
                detail_name=copy(detail,name+'-hardware-detail.png') if detail.exists() else filename
                hardware_sections.append(f'<details><summary>{html.escape(title)}: live configured provider</summary><p>After deployment, using the configured provider on the wall. The before comparison above uses a deterministic provider fixture.</p><img class="pixels" src="{filename}" style="max-width:384px" alt="Live64-pixel managed wall capture"><a href="{detail_name}" target="_blank">Full512-pixel composition ↗</a></details>')
            continue
        pair=Image.new('RGB',(816,442),'#0B0A09');draw=ImageDraw.Draw(pair)
        for x,version,path in zip((16,416),('BEFORE','AFTER'),inputs):
            actual=Image.open(path).convert('RGB')
            assert actual.size==(64,64)
            draw.text((x,14),version+' / LIVE WALL RGB',fill='#eae4d8')
            pair.paste(actual.resize((384,384),Image.Resampling.NEAREST),(x,42))
        filename=name+'-hardware.png';pair.save(OUT/filename)
        hardware_sections.append(f'<details><summary>{html.escape(title)}: captured from your wall runtime</summary><img class="pixels" src="{filename}" alt="Live managed wall RGB capture before and after"></details>')
    references = set()
    for source in BATCH.glob("*references*.json"):
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
    for filename, label in [("validation.json", "Validation"), ("wall-deployment.json", "Wall deployment"), ("phone-deployment.json", "Phone deployment"), ("native-interactions.json", "Native interaction tests"), ("native-recovery.json", "Artwork recovery test")]:
        source = BATCH / filename
        if source.exists():
            copy(source)
            receipts.append(f'<a href="{filename}" target="_blank">{label} receipt ↗</a>')
    nav = ''.join(f'<a href="#{name}">{html.escape(title)}</a>' for name, _, title in FEATURES)
    style = '''<style>:root{color-scheme:dark}*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:#0b0a09;color:#eae4d8;font:16px system-ui}header,main{max-width:1100px;margin:auto;padding:42px 28px}small{font:11px monospace;letter-spacing:2px;color:#bdd6b4}h1{font-size:clamp(36px,6vw,68px);font-weight:550;letter-spacing:-2.5px;line-height:1.03;margin:20px 0}p{max-width:770px;color:#aaa390;line-height:1.65}nav{position:sticky;top:0;z-index:2;display:flex;overflow:auto;gap:8px;padding:14px max(18px,calc((100vw - 1044px)/2));background:#141210f5;backdrop-filter:blur(16px);border-block:1px solid #ffffff13}a{color:inherit}nav a{flex:none;border:1px solid #ffffff26;border-radius:10px;padding:12px;text-decoration:none;font-size:13px}a:hover,a:focus{color:#bdd6b4}a:focus-visible,summary:focus-visible{outline:2px solid #bdd6b4;outline-offset:5px}.links{display:flex;gap:16px;flex-wrap:wrap;font-size:13px;line-height:1.6}section{scroll-margin-top:90px;padding:18px 0 36px;border-bottom:1px solid #ffffff19;margin-bottom:24px}h2{font-size:30px;letter-spacing:-.8px;font-weight:550;margin:10px 0}img{display:block;width:100%;height:auto;margin:24px 0 0}summary{padding:18px 0;cursor:pointer;color:#c7cfbd}.phone{max-width:420px;margin:20px auto 40px}.pixels{image-rendering:pixelated}.motion{max-width:384px;margin:24px auto}footer,li{color:#aaa390;font-size:13px;line-height:1.7;padding:8px 0}li a{overflow-wrap:anywhere}.scope{padding:20px 24px;background:#141210;border-left:2px solid #bdd6b4;margin-top:28px}@media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}}</style>'''
    state_section = '<section id="states"><small>NATIVE STATES</small><h2>Progress, results and recovery.</h2>'+''.join(extra_states)+'</section>' if extra_states else ''
    page = '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Tessera · Pass 12</title>'+style+'''<header><small>TESSERA / PASS 12 / G13 · G14 · G15 · G16 · G17</small><h1>A little competition.<br>A lot of character.</h1><p>Five games for ears, minds and quick hands. A listening deck, twenty questions, a pub quiz, an illustrated guessing game and a luminous Pong court share their compositions with the wall.</p><div class="scope"><p>Actual native app screens: before on the left, after on the right. Each pair uses the same scale and preserves the complete screenshot. Games use deterministic production puzzle fixtures and real moves.</p><p>Separate XCUITest runs verify native taps, typing, playback receipts and touch steering against production rules. These captures show visual states; real listening and physical LED colour still need an in-room check.</p></div></header><nav aria-label="Comparison sections">'''+nav+'<a href="#pixels">Wall pixels</a>'+('<a href="#states">More states</a>' if extra_states else '')+'<a href="#references">References</a></nav><main>'+''.join(sections)+'<div id="pixels">'+''.join(pixel_sections)+'</div>'+state_section+('<section id="hardware"><small>YOUR WALL / MANAGED SERVICE</small><h2>Running on the wall.</h2><p>Raw RGB frames captured from the real managed wall service after actual moves. The wall returned to Off after each round. These captures verify the runtime; physical LED colour still needs an in-room check.</p>'+''.join(hardware_sections)+'</section>' if hardware_sections else '')+'<section id="references"><small>RESEARCH APPLIED IN CODE</small><h2>References</h2><ul>'+reference_links+'</ul></section><footer><p>The app is production Swift; the puzzle frames are production Python output at true 64, 192 and 512 pixel resolutions. RGB comparisons use equal integer enlargement without smoothing. The phone’s input controls sit outside the shared board.</p><p>'+html.escape(deployment)+'</p><div class="links">'+''.join(receipts)+'</div></footer></main></html>'
    (OUT / "index.html").write_text(page)
    manifest = {"base":"8251028","generated_at":datetime.now(timezone.utc).isoformat(),
                "units":[unit for _,unit,_ in FEATURES],"processing":"Complete native screenshots scaled equally, not retouched. Before left, after right.",
                "scope":"Rendering and fixture API states. The native-interactions receipt verifies simulator touch input and audio clip timing. No spoken-recognition or physical LED certification.",
                "comparisons":native,"pixel_comparisons":pixel_rows,"puzzle_manifest":"../puzzles/manifest.json",
                "motion":motion_files,"extra_native_states":len(extra_states),
                "deployment_note":deployment,"validation_present":validation is not None,"references":sorted(references)}
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2)+"\n")
    print(OUT / "index.html")


if __name__ == "__main__":
    main()
