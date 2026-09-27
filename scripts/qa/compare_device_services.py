#!/usr/bin/env python3
"""Build the S09–S13 gallery from unretouched native app captures."""
import html
import json
from pathlib import Path
import shutil

from compare_home import Feature, compose

ROOT = Path(__file__).resolve().parents[2]
QA = ROOT / "qa/batch-15"
OUT = QA / "comparisons"
FEATURES = [
    ("posters", "S09", "Posters"),
    ("images", "S10", "Images"),
    ("airplay", "S11", "AirPlay"),
    ("mac", "S12", "Your Mac"),
    ("homekit", "S13", "Apple Home"),
]


def urls(value):
    result = set()
    if isinstance(value, dict):
        for key, child in value.items():
            if key in ("url", "mobbin_url") and isinstance(child, str) and child.startswith("https://"):
                result.add(child)
            result.update(urls(child))
    elif isinstance(value, list):
        for child in value:
            result.update(urls(child))
    return result


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    sections, rows, states = [], [], []
    for name, unit, title in FEATURES:
        before, after = QA / "before" / name / "room-live.png", QA / "after" / name / "room-live.png"
        rows.append(compose(ROOT, before, after, OUT / f"{name}.png", Feature(unit, title, name), 390))
        note = "<p>The original Mac setup shared the Addresses page. It now has one dedicated connection flow.</p>" if name == "mac" else ""
        extras = []
        for folder in sorted((QA / "after").iterdir()):
            if folder.name != name and not folder.name.startswith(name + "-"):
                continue
            for source in sorted(folder.glob("room-*.png")):
                if source.stem.endswith("-frame") or (folder.name == name and source.stem == "room-live"):
                    continue
                filename = folder.name + "-" + source.name
                shutil.copy2(source, OUT / filename)
                label = (folder.name.removeprefix(name).strip("-") or source.stem.removeprefix("room-")).replace("-", " ")
                states.append(filename)
                extras.append(f'<details><summary>{html.escape(label.title())}</summary><img class="phone" src="{filename}" alt="{html.escape(title)} {html.escape(label)}" loading="lazy"></details>')
        sections.append(f'<section id="{name}"><small>{unit}</small><h2>{title}</h2>{note}<img src="{name}.png" alt="{title}: before left, after right" loading="lazy"><div class="states">'+"".join(extras)+"</div></section>")
    refs = set()
    for path in QA.glob("references*.json"):
        refs.update(urls(json.loads(path.read_text())))
    references = "".join(f'<li><a href="{html.escape(url, quote=True)}" target="_blank" rel="noreferrer">{html.escape(url.removeprefix("https://"))}</a></li>' for url in sorted(refs))
    receipts = []
    for name in ["validation.json", "live-services.json", "wall-deployment.json", "phone-deployment.json", "native-interactions.json"]:
        if (QA / name).exists():
            shutil.copy2(QA / name, OUT / name)
            receipts.append(f'<a href="{name}">{name}</a>')
    navigation = "".join(f'<a href="#{name}">{title}</a>' for name, _, title in FEATURES)
    style = """<style>
    :root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;background:#171513;color:#efe8dc;font:16px system-ui}
    header,main{max-width:1050px;margin:auto;padding:42px 24px}small{color:#dcc69a;letter-spacing:2px;font:11px monospace}
    h1{font-size:clamp(40px,6vw,72px);line-height:1.02;letter-spacing:-2px;font-weight:550;max-width:750px}
    h2{font-size:32px;font-weight:550;letter-spacing:-1px}p,li{color:#b6aaa0;line-height:1.7}p{max-width:740px}
    a{color:inherit;overflow-wrap:anywhere}nav{position:sticky;top:0;z-index:2;display:flex;gap:12px;overflow:auto;padding:16px 24px;background:#211e1af5;border-block:1px solid #ffffff15}
    nav a{flex:none;text-decoration:none;padding:8px 16px;border-radius:8px;background:#ffffff09}
    section{padding:24px 0 42px;border-bottom:1px solid #ffffff20;scroll-margin-top:90px}img{display:block;width:100%;height:auto;margin-top:24px}
    .phone{max-width:420px;margin:24px auto}.states{margin-top:20px}summary{padding:18px 0;cursor:pointer;color:#dcc69a}li{padding:6px 0;font-size:13px}
    footer{display:flex;gap:20px;flex-wrap:wrap;padding:30px 0;font-size:13px}a:focus-visible,summary:focus-visible{outline:2px solid #dcc69a;outline-offset:5px}
    </style>"""
    page = '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Tessera · Pass 15</title>' + style
    page += '<header><small>TESSERA / PASS 15 / S09 · S10 · S11 · S12 · S13</small><h1>More ways in.<br>One room, connected.</h1><p>Five native service flows, each with one place to set up, a truthful status, and a way forward when something needs attention.</p><p>Before left, after right. Full native screenshots at equal scale. These captures use authored, credential-free service data; no screen is cropped or retouched.</p></header><nav>' + navigation + '<a href="#references">References</a></nav><main>'
    page += "".join(sections)
    page += '<section><small>DEPLOYED ON YOUR WALL</small><h2>The same room, better connections.</h2><p>The managed wall runtime and iPhone app are updated. The original wall display mode was preserved. HomeKit uses the same QR modules and composition on phone and wall; its checks below use an authored setup code. The real pairing code was never captured. Receiver, image and poster settings use actual service status, with no paid generation during QA.</p></section>'
    for size in (64, 192, 512):
        source = QA / "homekit-parity" / f"homekit-{size}.png"
        shutil.copy2(source, OUT / source.name)
    page += '<section><small>MATCHED PHONE / WALL COMPOSITION</small><h2>One pairing code, every scale.</h2><p>Authored test URI only. True 64, 192 and 512 pixel output from the production encoder. All are decoded with Apple Vision. The phone uses the same module matrix and quiet zone.</p><div style="display:flex;gap:24px;align-items:start;flex-wrap:wrap">' + ''.join(f'<figure><img src="homekit-{size}.png" style="width:{min(size,320)}px;image-rendering:pixelated" alt="Authored HomeKit QR at {size} pixels"><figcaption>{size} × {size}</figcaption></figure>' for size in (64,192,512)) + '</div></section>'
    page += '<section id="references"><small>RESEARCH APPLIED IN CODE</small><h2>References</h2><ul>' + references + '</ul></section><footer>' + "".join(receipts) + '</footer></main></html>'
    (OUT / "index.html").write_text(page)
    (OUT / "manifest.json").write_text(json.dumps({"base": "84bbf20", "units": [unit for _, unit, _ in FEATURES], "native": rows, "state_captures": states, "references": sorted(refs)}, indent=2) + "\n")
    print(OUT / "index.html")


if __name__ == "__main__":
    main()
