"""Check that every batch 17 capture is current and complete.

A case passes when every capture in it records its sources and none of those
files has changed since (scripts/qa/stale_captures.py), so a recapture of
one page after a fix is enough; the cases no longer have to come from one
build. Each case's build (the installed debug dylib's sha256) is listed, and
a capture with no build recorded fails. Images, wall frames and manifest
entries must agree, as before.

    .venv/bin/python scripts/qa/verify_batch17.py
    .venv/bin/python scripts/qa/verify_batch17.py --trimmed
    .venv/bin/python scripts/qa/verify_batch17.py --json qa/batch-17/capture-builds.json

--trimmed is for the repository copy, which keeps every manifest and wall
frame but only the main screen of each page (see qa/batch-17/README.md):
screenshots left out are counted, not failed.
"""
import argparse
import json
import sys
from pathlib import Path

from stale_captures import check_batch, short

BATCH = Path(__file__).resolve().parents[2] / "qa/batch-17"
A = BATCH / "after"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--trimmed", action="store_true", help="accept screenshots left out of the repository")
    parser.add_argument("--json", type=Path, help="also write each case's status and builds here")
    args = parser.parse_args()

    currency = check_batch(BATCH)
    bad, left_out, total, folders = [], 0, 0, 0
    builds = {}
    # widgets holds render_widgets.py's renders, checked by that script.
    for folder in sorted(p for p in A.iterdir() if p.is_dir() and p.name != "widgets"):
        folders += 1
        mp = folder / "manifest.json"
        if not mp.exists():
            bad.append(f"{folder.name}: no manifest")
            continue
        m = json.loads(mp.read_text())
        case = currency["cases"].get(f"after/{folder.name}", {})
        if case.get("status") == "stale":
            for capture in case["captures"]:
                for kind in ("changed", "missing", "unrecorded", "older_build"):
                    for path in capture.get(kind, []):
                        bad.append(f"{folder.name}/{capture['capture']}: stale, {kind} {path}")
        elif case.get("status") == "unknown":
            bad.append(f"{folder.name}: " + case.get("note", "a capture records no sources"))
        images = {c["image"] for c in m["captures"]}
        for c, result in zip(m["captures"], case.get("captures", [])):
            total += 1
            if result.get("build"):
                builds.setdefault(result["build"], []).append(f"{folder.name}/{c['image']}")
            else:
                bad.append(f"{folder.name}/{c['image']}: no build recorded")
            if not (folder / c["image"]).exists():
                if args.trimmed:
                    left_out += 1
                else:
                    bad.append(f"{folder.name}/{c['image']}: image missing")
            if c.get("frame") and not (folder / c["frame"]).exists():
                bad.append(f"{folder.name}/{c['frame']}: frame missing")
        for png in folder.glob("*.png"):
            if png.stem.endswith("-frame"):
                continue
            if png.name not in images:
                bad.append(f"{folder.name}/{png.name}: not in manifest")
    vouched = sum(1 for c in currency["cases"].values() for r in c.get("captures", []) if r.get("backfilled"))
    print(f"{folders} folders, {total} captures, {len(bad)} problems"
          + (f", {left_out} screenshots left out of this copy" if args.trimmed else ""))
    if vouched:
        print(f"{vouched} captures have sources vouched by stale_captures.py --backfill, not recorded when taken")
    for build, where in sorted(builds.items(), key=lambda kv: -len(kv[1])):
        cases = sorted({w.split("/")[0] for w in where})
        print(f"build {short(build)}: {len(where)} captures in {len(cases)} cases")
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps({name: {"status": c["status"], "builds": c["builds"]}
                                         for name, c in currency["cases"].items()}, indent=2) + "\n")
    print("\n".join(bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
