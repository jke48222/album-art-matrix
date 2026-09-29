#!/usr/bin/env python3
"""Build the D06, D07, D08, D09, E01 gallery from unretouched native captures."""
import html
import json
from pathlib import Path
import shutil

from compare_home import Feature, compose

ROOT = Path(__file__).resolve().parents[2]
QA = ROOT / "qa/batch-17"
OUT = QA / "comparisons"
# (unit, title, after case, before case or None, note)
FEATURES = [
    ("D06", "Wall health", "health", "health",
     "A plain verdict first, then what needs attention, then the parts that are fine. Power and heat are told apart, and every reading says how old it is."),
    ("D07", "Connection", "connection", "addresses",
     "The address, a step-by-step check of the path to the wall, and what was waiting to be sent while it was away."),
    ("D08", "About", "about", "about",
     "Version, the openings and the way into panel tuning. The design choice moved to its own page."),
    ("D08", "App design", "design", None,
     "Room, Panel or iPod, each shown as it looks, and chosen with one tap."),
    ("D09", "Panel tuning", "tuning", None,
     "Every number that decides what the LEDs do, grouped, with its default marked and test patterns shown on the wall."),
    ("E01", "Home Screen", "widgets-page", None,
     "What the widgets show and how to add them. The widgets draw the wall's own frame and say when it is not current."),
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


def states_for(case):
    extras = []
    for folder in sorted((QA / "after").iterdir()):
        if not folder.is_dir() or folder.name == "widgets":
            continue
        if folder.name != case and not folder.name.startswith(case + "-"):
            continue
        for source in sorted(folder.glob("room-*.png")):
            if source.stem.endswith("-frame") or (folder.name == case and source.stem == "room-live"):
                continue
            name = folder.name + "-" + source.name
            shutil.copy2(source, OUT / name)
            label = (folder.name.removeprefix(case).strip("-") or source.stem.removeprefix("room-")).replace("-", " ")
            if folder.name != case and source.stem != "room-live":
                label += ", " + source.stem.removeprefix("room-")
            frame = folder / (source.stem + "-frame.png")
            wall = ""
            manifest = folder / "manifest.json"
            live = manifest.exists() and "session" in manifest.read_text()
            if live and frame.exists():
                shutil.copy2(frame, OUT / (folder.name + "-" + frame.name))
                wall = (f'<figure><img src="{folder.name}-{frame.name}" style="width:320px;image-rendering:pixelated" '
                        f'alt="true wall frame"><figcaption>The wall frame during this capture, enlarged.</figcaption></figure>')
            extras.append(f'<details><summary>{html.escape(label[:1].upper() + label[1:])}</summary>'
                          f'<div style="display:flex;gap:24px;flex-wrap:wrap;align-items:start">'
                          f'<img class="phone" src="{name}" alt="{html.escape(label)}" loading="lazy">{wall}</div></details>')
    return extras


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    sections, rows = [], []
    for unit, title, case, before_case, note in FEATURES:
        after = QA / "after" / case / "room-live.png"
        anchor = case
        if before_case:
            before = QA / "before" / before_case / "room-live.png"
            rows.append(compose(ROOT, before, after, OUT / f"{case}.png", Feature(unit, title, case), 390))
            lead = f'<img src="{case}.png" alt="{html.escape(title)}: before left, after right" loading="lazy">'
        else:
            shutil.copy2(after, OUT / f"{case}.png")
            lead = f'<img class="phone" src="{case}.png" alt="{html.escape(title)}, new page" loading="lazy">'
        sections.append(f'<section id="{anchor}"><small>{unit}{"" if before_case else ", NEW PAGE"}</small><h2>{html.escape(title)}</h2>'
                        f'<p>{html.escape(note)}</p>{lead}<div class="states">' + "".join(states_for(case)) + "</div></section>")
    widgets = QA / "after/widgets"
    if widgets.exists():
        for name in ("contact-sheet.png", "true-64.png", "true-192.png"):
            if (widgets / name).exists():
                shutil.copy2(widgets / name, OUT / f"widgets-{name}")
        receipt = json.loads((widgets / "receipt.json").read_text()) if (widgets / "receipt.json").exists() else {}
        summary = receipt.get("summary") or receipt.get("result") or ""
        sections.append('<section id="widgets"><small>E01, THE WIDGETS THEMSELVES</small><h2>Small and medium, every state.</h2>'
                        '<p>Rendered by the app\'s own widget views at each phone width and text size, from authored fixtures. '
                        'The small widget is the wall with nothing on it until the picture is not current.</p>'
                        f'<img src="widgets-contact-sheet.png" alt="Widget contact sheet" loading="lazy">'
                        '<div style="display:flex;gap:24px;flex-wrap:wrap">'
                        '<figure><img src="widgets-true-64.png" style="width:320px;image-rendering:pixelated" alt="True 64 frame"><figcaption>The frame the widget draws, 64 wall</figcaption></figure>'
                        '<figure><img src="widgets-true-192.png" style="width:320px;image-rendering:pixelated" alt="True 192 frame"><figcaption>The same, 192 wall</figcaption></figure></div>'
                        + (f'<p>{html.escape(str(summary))}</p>' if summary else "") + "</section>")
    refs = set()
    for path in QA.glob("*references*.json"):
        refs.update(urls(json.loads(path.read_text())))
    references = "".join(f'<li><a href="{html.escape(u, quote=True)}" target="_blank" rel="noreferrer">{html.escape(u.removeprefix("https://"))}</a></li>' for u in sorted(refs))
    receipts = []
    for name in ["validation.json", "wall-deployment.json", "phone-deployment.json", "native-interactions.json"]:
        if (QA / name).exists():
            shutil.copy2(QA / name, OUT / name)
            receipts.append(f'<a href="{name}">{name}</a>')
    navigation = "".join(f'<a href="#{case}">{html.escape(title)}</a>' for _, title, case, _, _ in FEATURES) + '<a href="#widgets">Widgets</a>'
    style = """<style>
    :root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;background:#171513;color:#efe8dc;font:16px system-ui}
    header,main{max-width:1050px;margin:auto;padding:42px 24px}small{color:#dcc69a;letter-spacing:2px;font:11px monospace}
    h1{font-size:clamp(40px,6vw,72px);line-height:1.02;letter-spacing:-2px;font-weight:550;max-width:750px}
    h2{font-size:32px;font-weight:550;letter-spacing:-1px}p,li{color:#b6aaa0;line-height:1.7}p{max-width:740px}
    a{color:inherit;overflow-wrap:anywhere}nav{position:sticky;top:0;z-index:2;display:flex;gap:12px;overflow:auto;padding:16px 24px;background:#211e1af5;border-block:1px solid #ffffff15}
    nav a{flex:none;text-decoration:none;padding:8px 16px;border-radius:8px;background:#ffffff09}
    section{padding:24px 0 42px;border-bottom:1px solid #ffffff20;scroll-margin-top:90px}img{display:block;width:100%;height:auto;margin-top:24px}
    .phone{max-width:420px;margin:24px auto}.states{margin-top:20px}summary{padding:14px 0;cursor:pointer;color:#dcc69a}li{padding:6px 0;font-size:13px}
    footer{display:flex;gap:20px;flex-wrap:wrap;padding:30px 0;font-size:13px}a:focus-visible,summary:focus-visible{outline:2px solid #dcc69a;outline-offset:5px}
    </style>"""
    page = ('<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Tessera Pass 17</title>' + style
            + '<header><small>TESSERA / PASS 17 / D06, D07, D08, D09, E01</small><h1>The wall,<br>looked after.</h1>'
            '<p>How the wall is doing, how the phone reaches it, what the app is, the panel\'s own numbers, and the wall on the Home Screen.</p>'
            '<p>Before left, after right where a page existed. Full native screenshots at equal scale, from authored, credential-free data. '
            'Open a section to see its other states.</p></header><nav>' + navigation + '<a href="#references">References</a></nav><main>'
            + "".join(sections)
            + '<section id="references"><small>RESEARCH APPLIED IN CODE</small><h2>References</h2><ul>' + references + "</ul></section><footer>"
            + "".join(receipts) + "</footer></main></html>")
    (OUT / "index.html").write_text(page)
    (OUT / "manifest.json").write_text(json.dumps({"units": ["D06", "D07", "D08", "D09", "E01"], "native": rows, "references": sorted(refs)}, indent=2) + "\n")
    print(OUT / "index.html")


if __name__ == "__main__":
    main()
