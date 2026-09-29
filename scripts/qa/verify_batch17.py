"""Check that every after folder comes from the final build."""
import json
import sys
from pathlib import Path

A = Path(__file__).resolve().parents[2] / "qa/batch-17/after"
WANT = "2f3a4b07b0a596831ae698ce0a28264b57236a80b48802adb356c3b4eff483d2"
bad, total, folders = [], 0, 0
for folder in sorted(p for p in A.iterdir() if p.is_dir() and p.name != "widgets"):
    folders += 1
    mp = folder / "manifest.json"
    if not mp.exists():
        bad.append(f"{folder.name}: no manifest")
        continue
    m = json.loads(mp.read_text())
    if m.get("tessera_debug_dylib_sha256") != WANT:
        bad.append(f"{folder.name}: top-level dylib {m.get('tessera_debug_dylib_sha256')}")
    if m.get("installed_app_identity", {}).get("files_sha256", {}).get("Tessera.debug.dylib") != WANT:
        bad.append(f"{folder.name}: top-level installed identity differs")
    images = {c["image"] for c in m["captures"]}
    for c in m["captures"]:
        total += 1
        got = c.get("installed_app_identity", {}).get("files_sha256", {}).get("Tessera.debug.dylib")
        if got != WANT:
            bad.append(f"{folder.name}/{c['image']}: dylib {got}")
        if not (folder / c["image"]).exists():
            bad.append(f"{folder.name}/{c['image']}: image missing")
        if c.get("frame") and not (folder / c["frame"]).exists():
            bad.append(f"{folder.name}/{c['frame']}: frame missing")
    for png in folder.glob("*.png"):
        if png.stem.endswith("-frame"):
            continue
        if png.name not in images:
            bad.append(f"{folder.name}/{png.name}: not in manifest")
print(f"{folders} folders, {total} captures, {len(bad)} problems")
print("\n".join(bad))
sys.exit(1 if bad else 0)
