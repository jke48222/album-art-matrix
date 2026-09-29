#!/usr/bin/env python3
"""List the captures in a batch folder that no longer match the source.

Every capture that records "sources" ({path: sha256} for the core files plus
its page's files, from qa/deps.json) is checked by hashing those files again.
A capture is stale when any of them changed or is gone, when qa/deps.json
now lists a file for its pages that it never recorded, or when it was taken
with --allow-older-build from a build older than some of those files. A capture that records
no sources is unknown: nothing says what it was built from, so it is treated
like a stale one and recaptured. Cases under before/ are baselines of the old
build and are never stale.

    .venv/bin/python scripts/qa/stale_captures.py qa/batch-17
    .venv/bin/python scripts/qa/stale_captures.py qa/batch-17 --json

--backfill records sources for captures that have none, from the files as
they are now, without recapturing. It is for evidence taken before sources
were recorded. It refuses unless it can stand behind the claim: none of
those files may differ from HEAD in the working tree, and none may have
changed in a commit after the one that last committed the case's manifest.

    .venv/bin/python scripts/qa/stale_captures.py qa/batch-17 --backfill

The helpers here (deps, keys_for_case, sources_record, check_batch) are
shared with capture_home.py, capture_batch17.py, verify_batch17.py and
affected.py, so all of them read qa/deps.json the same way.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
DEPS = ROOT / "qa/deps.json"


# ---------------------------------------------------------------- deps.json

def deps(path: Path = DEPS) -> dict:
    return json.loads(path.read_text())


def page_files(key: str, data: dict, seen: set | None = None) -> list[str]:
    """One page's entries, with page:KEY entries replaced by that page's own."""
    seen = set() if seen is None else seen
    if key in seen:
        return []
    seen.add(key)
    files = []
    for entry in data["pages"][key]:
        if entry.startswith("page:"):
            files += page_files(entry[len("page:"):], data, seen)
        else:
            files.append(entry)
    return files


def files_for(keys: list[str], data: dict) -> list[str]:
    """Core plus the pages named, each path once, sorted so records compare."""
    files = set(data["core"])
    for key in keys:
        files.update(page_files(key, data))
    return sorted(files)


def keys_for_case(name: str, data: dict) -> list[str]:
    """The page keys a case folder belongs to, from its name.

    The longest page key (or alias) that is the whole name or the name's
    start followed by "-" wins, so "health-network-steady" is health and
    "widgets-page" is widgets. An empty list means no page claims it.
    """
    name = Path(name).name
    candidates = {key: key for key in data["pages"]}
    candidates.update(data.get("aliases", {}))
    best = None
    for prefix in candidates:
        if name == prefix or name.startswith(prefix + "-"):
            if best is None or len(prefix) > len(best):
                best = prefix
    return [candidates[best]] if best else []


# ---------------------------------------------------------------- hashing

_HASHES: dict[str, str | None] = {}


def hash_path(rel: str, root: Path = ROOT) -> str | None:
    """sha256 of a file, or of a folder's files and names; None when gone.

    A folder (an entry ending in /) is hashed as one: every file under it,
    by relative path and content, so adding, removing or editing any of
    them changes the folder's hash. Finder's .DS_Store files are skipped.
    """
    key = f"{root}::{rel}"
    if key in _HASHES:
        return _HASHES[key]
    path = root / rel
    digest = None
    if rel.endswith("/"):
        if path.is_dir():
            outer = hashlib.sha256()
            for item in sorted(p for p in path.rglob("*") if p.is_file() and p.name != ".DS_Store"):
                with item.open("rb") as handle:
                    inner = hashlib.file_digest(handle, "sha256").hexdigest()
                outer.update(f"{item.relative_to(path).as_posix()}\0{inner}\n".encode())
            digest = outer.hexdigest()
    elif path.is_file():
        with path.open("rb") as handle:
            digest = hashlib.file_digest(handle, "sha256").hexdigest()
    _HASHES[key] = digest
    return digest


def sources_record(keys: list[str], data: dict | None = None) -> dict:
    """What a capture stores: the page keys and {path: sha256} for them.

    A listed file that does not exist is an error in qa/deps.json, not
    something to record, so it stops the capture before it starts.
    """
    data = data or deps()
    unknown = [key for key in keys if key not in data["pages"]]
    if unknown:
        raise ValueError(f"not a page in qa/deps.json: {', '.join(unknown)}")
    files = files_for(keys, data)
    hashes = {path: hash_path(path) for path in files}
    missing = [path for path, digest in hashes.items() if digest is None]
    if missing:
        raise FileNotFoundError(f"qa/deps.json lists files that do not exist: {', '.join(missing)}")
    return {"source_keys": list(keys), "sources": hashes}


def newer_than(files: list[str], moment: float) -> list[str]:
    """Sources edited after the installed build was made (by modification time).

    The capture drivers refuse to capture when any are found, which catches
    editing a page and capturing before rebuilding. A checkout or a touch
    with no real change trips it too; rebuilding clears it.
    """
    late = []
    for rel in files:
        path = ROOT / rel
        if path.is_file() and path.stat().st_mtime > moment:
            late.append(rel)
    return late


# ---------------------------------------------------------------- checking

def records(manifest: dict) -> list[dict]:
    """The capture entries in a manifest. A manifest with no captures list
    (a receipt, like panel-running-64) is one record on its own."""
    captures = manifest.get("captures")
    return captures if isinstance(captures, list) else [manifest]


def build_of(record: dict, manifest: dict) -> str | None:
    """The production code hash the capture came from (the debug dylib when
    there is one), from the capture's own identity or the manifest's."""
    identity = record.get("installed_app_identity") or manifest.get("installed_app_identity") or {}
    files = identity.get("files_sha256", {})
    name = identity.get("production_code_file")
    return files.get(name) if name else (files.get("Tessera.debug.dylib") or files.get("Tessera"))


def case_folders(batch: Path) -> list[Path]:
    """Folders that hold a case manifest: batch/<side>/<case>/manifest.json,
    or batch/<case>/manifest.json in the first batches, which had no sides.

    Deeper manifests (after/widgets/renders, from render_widgets.py) belong
    to other tools and are left out.
    """
    return sorted(p.parent for pattern in ("*/manifest.json", "*/*/manifest.json") for p in batch.glob(pattern))


def check_record(record: dict, data: dict) -> dict:
    """Current, stale or unknown for one capture, with the reasons."""
    sources = record.get("sources")
    if not isinstance(sources, dict) or not sources:
        return {"status": "unknown"}
    changed = [path for path, digest in sources.items() if hash_path(path) not in (digest, None)]
    missing = [path for path in sources if hash_path(path) is None]
    unrecorded = []
    keys = record.get("source_keys")
    if isinstance(keys, list) and all(key in data["pages"] for key in keys):
        unrecorded = [path for path in files_for(keys, data) if path not in sources]
    # Taken with --allow-older-build: these files were newer than the build,
    # so the screenshot may not show them.
    older_build = record.get("sources_newer_than_build") or []
    stale = bool(changed or missing or unrecorded or older_build)
    result = {"status": "stale" if stale else "current"}
    if record.get("sources_backfilled"):
        result["backfilled"] = True
    if older_build:
        result["older_build"] = list(older_build)
    if changed:
        result["changed"] = changed
    if missing:
        result["missing"] = missing
    if unrecorded:
        result["unrecorded"] = unrecorded
    return result


def check_batch(batch: Path, data: dict | None = None) -> dict:
    """Every case in a batch folder, with its status and each capture's build."""
    data = data or deps()
    cases = {}
    for folder in case_folders(batch):
        name = folder.relative_to(batch).as_posix()
        manifest = json.loads((folder / "manifest.json").read_text())
        keys = keys_for_case(folder.name, data)
        if name.startswith("before/"):
            cases[name] = {"status": "baseline", "keys": keys,
                           "builds": sorted({b for r in records(manifest) if (b := build_of(r, manifest))})}
            continue
        captures = []
        for record in records(manifest):
            result = check_record(record, data)
            result["capture"] = record.get("image") or record.get("state") or "manifest"
            result["build"] = build_of(record, manifest)
            captures.append(result)
        statuses = {c["status"] for c in captures}
        status = "stale" if "stale" in statuses else "unknown" if "unknown" in statuses else "current"
        entry = {"status": status, "keys": keys, "captures": captures,
                 "builds": sorted({c["build"] for c in captures if c["build"]})}
        if not keys:
            entry["note"] = "no page in qa/deps.json claims this case"
        cases[name] = entry
    summary = {status: sorted(n for n, c in cases.items() if c["status"] == status)
               for status in ("current", "stale", "unknown", "baseline")}
    try:
        shown = batch.relative_to(ROOT).as_posix()
    except ValueError:
        shown = str(batch)
    return {"batch": shown, "cases": cases, **summary}


# ---------------------------------------------------------------- backfill

def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, check=True, text=True, capture_output=True).stdout


def backfill(batch: Path, data: dict) -> int:
    """Record current sources in captures that have none, where that is true.

    Refuses everything when the working tree differs from HEAD in any of the
    files it would vouch for. Refuses a case when its sources changed in a
    commit after its manifest was last committed, since the captures then
    show older code than the files do now.
    """
    plan = []
    for folder in case_folders(batch):
        name = folder.relative_to(batch).as_posix()
        if name.startswith("before/"):
            continue
        manifest_path = folder / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        needs = [r for r in records(manifest) if not r.get("sources")]
        if not needs:
            continue
        keys = keys_for_case(folder.name, data)
        plan.append((name, manifest_path, manifest, keys))
    if not plan:
        print("Nothing to backfill: every capture records its sources.")
        return 0
    vouched = sorted({path for _, _, _, keys in plan if keys for path in files_for(keys, data)})
    dirty = git("status", "--porcelain", "--untracked-files=all", "--", *vouched).strip()
    if dirty:
        print("Refused: the working tree differs from HEAD in files the backfill would vouch for:")
        print(dirty)
        return 1
    head = git("rev-parse", "HEAD").strip()
    now = datetime.now(timezone.utc).isoformat()
    written, refused = 0, []
    for name, manifest_path, manifest, keys in plan:
        if not keys:
            refused.append((name, "no page in qa/deps.json claims this case"))
            continue
        rel = manifest_path.relative_to(ROOT).as_posix()
        if git("status", "--porcelain", "--", rel).strip():
            refused.append((name, "the manifest has uncommitted changes, so its captures may be newer than any commit"))
            continue
        committed = git("log", "-1", "--format=%H", "--", rel).strip()
        if not committed:
            refused.append((name, "the manifest was never committed"))
            continue
        files = files_for(keys, data)
        later = git("diff", "--name-only", committed, head, "--", *files).split()
        if later:
            refused.append((name, f"changed after {committed[:7]} committed it: {', '.join(later[:4])}"
                                  + (f" and {len(later) - 4} more" if len(later) > 4 else "")))
            continue
        record = sources_record(keys, data)
        for capture in records(manifest):
            if not capture.get("sources"):
                capture.update(record)
                capture["sources_backfilled"] = {"at": now, "head": head, "manifest_commit": committed}
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
        written += 1
    print(f"Backfilled {written} case manifests at {head[:7]}.")
    if refused:
        print(f"Refused {len(refused)}:")
        for name, why in refused:
            print(f"  {name}: {why}")
    return 0


# ---------------------------------------------------------------- report

def short(build: str | None) -> str:
    return build[:12] if build else "none"


def report(result: dict) -> None:
    cases = result["cases"]
    backfilled = [n for n in result["current"] if any(c.get("backfilled") for c in cases[n]["captures"])]
    print(f"{result['batch']}: {len(cases)} cases: {len(result['current'])} current "
          f"({len(backfilled)} of them vouched by --backfill, not recorded at capture), "
          f"{len(result['stale'])} stale, {len(result['unknown'])} unknown, "
          f"{len(result['baseline'])} baseline")
    for name in result["stale"]:
        reasons = set()
        for capture in cases[name]["captures"]:
            for kind in ("changed", "missing", "unrecorded", "older_build"):
                reasons.update(f"{kind.replace('_', ' ')} {path}" for path in capture.get(kind, []))
        stale = [c["capture"] for c in cases[name]["captures"] if c["status"] != "current"]
        print(f"  stale    {name} ({', '.join(stale)}): {'; '.join(sorted(reasons)) or 'no sources for some captures'}")
    for name in result["unknown"]:
        note = cases[name].get("note", "no sources recorded")
        print(f"  unknown  {name}: {note}")
    builds = {}
    for name, case in cases.items():
        for build in case["builds"]:
            builds.setdefault(build, []).append(name)
    print("builds: " + ", ".join(f"{short(b)} ({len(n)} cases)" for b, n in sorted(builds.items(), key=lambda kv: -len(kv[1]))))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("batch", type=Path, help="a batch folder, for example qa/batch-17")
    parser.add_argument("--json", action="store_true", help="print the whole result as JSON")
    parser.add_argument("--backfill", action="store_true",
                        help="record current sources in captures that have none (one-off; see above)")
    args = parser.parse_args()
    batch = args.batch if args.batch.is_absolute() else (Path.cwd() / args.batch)
    batch = batch.resolve()
    if not batch.is_dir():
        parser.error(f"{args.batch} is not a folder")
    data = deps()
    if args.backfill:
        return backfill(batch, data)
    result = check_batch(batch, data)
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        report(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
