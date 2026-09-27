#!/usr/bin/env python3
"""Build the S14, D01, D03, D04, D05 gallery from unretouched native app captures."""
import html
import json
from pathlib import Path
import shutil
import sys

from compare_home import Feature, compose

ROOT = Path(__file__).resolve().parents[2]
QA = ROOT / "qa/batch-16"
OUT = QA / "comparisons"
FEATURES = [
    ("pictures", "S14", "Pictures"),
    ("onboarding", "D01", "First run"),
    ("colour", "D03", "True colour"),
    ("panel", "D04", "Panel check"),
    ("guests", "D05", "Guests"),
]
NOTES = {
    "pictures": "Built-in web search is the default. Google is an optional extra for people who already have a search engine, and the page says so.",
    "onboarding": "The first run, captured from the production flow. Without a wall, setup can continue on this phone. Each captured step is listed below.",
    "colour": "The camera measurement previews gains on the wall and only saves when you confirm.",
    "panel": "Test patterns are a temporary display. Leaving the page puts the wall back.",
    "guests": "The phone shows the wall's own frame. The code is laid out at the wall's side, with at least 2 LEDs per module and a lit margin of at least one module.",
}


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


def guest_parity():
    """The Wi-Fi fixture as verify_guest_qr.swift writes it: the wall frame at
    each side and the phone's view of it, with the decode results it recorded."""
    parity = QA / "guests-parity"
    receipt = parity / "validation.json"
    if not receipt.exists():
        return ""
    record = json.loads(receipt.read_text())
    shown = [row for row in record.get("results", [])
             if row.get("fixture") == "wifi" and row.get("side") in (64, 192) and not row.get("refused")
             and row.get("wall_file") and row.get("phone_file")]
    # An older receipt has no rule and no phone views. Leave the section out
    # rather than show the old layout under the new description.
    if "rule" not in record or not shown:
        print("guests-parity is from the old layout. Run verify_guest_qr.swift with qa/batch-16/guests-parity to remake it.", file=sys.stderr)
        return ""
    figures = []
    for row in sorted(shown, key=lambda row: row["side"]):
        side, per = row["side"], row["leds_per_module"]
        for key, label, decoded in (("wall_file", f"Wall frame, {side} x {side} LEDs, {per} LEDs per module", row.get("decoded_at_wall_pixels")),
                                    ("phone_file", f"The phone's view of the {side} frame", row.get("decoded_as_phone"))):
            if not (parity / row[key]).exists():
                continue
            shutil.copy2(parity / row[key], OUT / ("guests-" + row[key]))
            result = "Decoded by Apple Vision." if decoded else "Not decoded by Apple Vision."
            figures.append(f'<figure><img src="guests-{html.escape(row[key], quote=True)}" style="width:240px;image-rendering:pixelated" alt="{html.escape(label)}"><figcaption>{html.escape(label)}. {result}</figcaption></figure>')
    shutil.copy2(receipt, OUT / "guests-parity-validation.json")
    return ('<section><small>MATCHED PHONE AND WALL</small><h2>One guest code, the wall\'s own frame.</h2>'
            '<p>Authored network only. The wall frame at 64 and 192 LEDs, and the phone\'s view of the same frame, each checked with Apple Vision. '
            'The code is laid out at the wall\'s side, with at least 2 LEDs per module and a lit margin of at least one module. '
            'A code that would need smaller modules is refused. Software decoding does not prove a camera can read the LEDs.</p>'
            '<div style="display:flex;gap:24px;align-items:start;flex-wrap:wrap">' + "".join(figures) + '</div>'
            '<p><a href="guests-parity-validation.json">Parity receipt</a></p></section>')


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    sections, rows, states = [], [], []
    for name, unit, title in FEATURES:
        before, after = QA / "before" / name / "room-live.png", QA / "after" / name / "room-live.png"
        rows.append(compose(ROOT, before, after, OUT / f"{name}.png", Feature(unit, title, name), 390))
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
                # Live captures ran a real display session on the QA wall, so
                # the wall's own frame is shown beside the phone.
                frame = folder / (source.stem + "-frame.png")
                wall = ""
                if (folder / "manifest.json").exists() and "session" in json.loads((folder / "manifest.json").read_text()) and frame.exists():
                    shutil.copy2(frame, OUT / (folder.name + "-" + frame.name))
                    wall = f'<figure><img src="{folder.name}-{frame.name}" style="width:320px;image-rendering:pixelated" alt="{html.escape(title)} {html.escape(label)}, true wall frame"><figcaption>The wall frame during this capture, at its real LED size, enlarged.</figcaption></figure>'
                extras.append(f'<details><summary>{html.escape(label.title())}</summary><div style="display:flex;gap:24px;flex-wrap:wrap;align-items:start"><img class="phone" src="{filename}" alt="{html.escape(title)} {html.escape(label)}" loading="lazy">{wall}</div></details>')
        note = f"<p>{html.escape(NOTES[name])}</p>"
        sections.append(f'<section id="{name}"><small>{unit}</small><h2>{title}</h2>{note}<img src="{name}.png" alt="{title}: before left, after right" loading="lazy"><div class="states">' + "".join(extras) + "</div></section>")
    refs = set()
    for path in QA.glob("*references*.json"):
        refs.update(urls(json.loads(path.read_text())))
    references = "".join(f'<li><a href="{html.escape(url, quote=True)}" target="_blank" rel="noreferrer">{html.escape(url.removeprefix("https://"))}</a></li>' for url in sorted(refs))
    receipts = []
    for name in ["validation.json", "wall-deployment.json", "phone-deployment.json", "native-interactions.json"]:
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
    page = '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Tessera Pass 16</title>' + style
    page += '<header><small>TESSERA / PASS 16 / S14, D01, D03, D04, D05</small><h1>Setting up,<br>and checking the wall.</h1><p>Pictures search, the first run, true colour, the panel check and guest codes. The wall checks are temporary: they end when you leave, and the wall goes back to what it was showing.</p><p>Before left, after right. Full native screenshots at equal scale, taken with authored, credential-free data. No screen is cropped or retouched. Open a section to see its other states.</p></header><nav>' + navigation + '<a href="#references">References</a></nav><main>'
    page += "".join(sections)
    page += guest_parity()
    page += '<section id="references"><small>RESEARCH APPLIED IN CODE</small><h2>References</h2><ul>' + references + '</ul></section><footer>' + "".join(receipts) + "</footer></main></html>"
    (OUT / "index.html").write_text(page)
    (OUT / "manifest.json").write_text(json.dumps({"base": "1303f46", "units": [unit for _, unit, _ in FEATURES], "native": rows, "state_captures": states, "references": sorted(refs)}, indent=2) + "\n")
    print(OUT / "index.html")


if __name__ == "__main__":
    main()
