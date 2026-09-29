#!/usr/bin/env python3
"""Batch 17 capture driver. Simulator 656AFBBD only, fixture port 65368 only.

Usage: capture_batch17.py [--list] [--exact] [--stale] [--allow-older-build] [substring ...]
Runs every "after" case whose name contains one of the substrings (all when
none). The "before" case is kept as it is and only runs when named with
--before.

--stale runs only the case folders scripts/qa/stale_captures.py reports as
stale (a recorded source file changed) or unknown (no sources recorded), so
a fix to one page recaptures that page's cases and nothing else:

    .venv/bin/python scripts/qa/stale_captures.py qa/batch-17
    .venv/bin/python scripts/qa/capture_batch17.py --stale

Every "after" capture records "sources": {path: sha256} for the core files
and its page's files in qa/deps.json, the page taken from the case name
(health-warm is health, widgets-page is widgets). Before captures come from
the old build, so they record none. A case stops before it launches when any
of those files is newer than the installed build, since the screenshot would
show the old code under the new hashes: rebuild and install first.
--allow-older-build captures anyway (for a file touched but not changed);
the capture then names the late files and stale_captures.py counts it stale.

Final-build revision (2026-09-29): folds in retake1.py and retake2.py, follows
the fixture changes in serve_setup.py (dropped and refused offline modes,
striped occupier, still health, black frame while off) and capture_home.py
(pinned widget snapshots recorded as "fixture"), and adds the cases the
fixers asked for.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.request import Request, urlopen

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
QA = ROOT / "qa/batch-17"
SCRATCH = Path(os.environ.get("TMPDIR", "/tmp")) / "tessera-batch17-captures"
SCRATCH.mkdir(parents=True, exist_ok=True)
SIM = "656AFBBD-1ED1-4828-9692-59467A1E70E1"
assert SIM != "9108AFCE-E437-42FF-A946-C41349BE6540"
BUNDLE = "com.jalenedusei.tessera"
PY = "/Users/jalenedusei/fun-project/album-art-matrix/.venv/bin/python"
PORT = 65368
assert PORT != 65367
FIX = f"127.0.0.1:{PORT}"
os.environ["DEVELOPER_DIR"] = "/Applications/Xcode-beta.app/Contents/Developer"
sys.path.insert(0, str(ROOT / "scripts/qa"))
from capture_home import app_identity  # noqa: E402
from stale_captures import check_batch, deps, keys_for_case, newer_than, sources_record  # noqa: E402

AX5 = "accessibility-extra-extra-extra-large"
DYLIB = "Tessera.debug.dylib"


def sh(*args, capture=False, check=True, timeout=120):
    r = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
    if check and r.returncode != 0:
        raise RuntimeError(f"{args}: {r.stderr.strip()}")
    return r.stdout.strip()


def installed_app():
    return Path(sh("xcrun", "simctl", "get_app_container", SIM, BUNDLE, "app"))


def identity():
    return app_identity(installed_app(), "Installed simulator bundle, resolved by simctl get_app_container")


def case_keys(case):
    """The qa/deps.json page keys for a case folder name. A case no page
    claims is an error, so a new page family cannot slip in unrecorded."""
    keys = keys_for_case(case, deps())
    if not keys:
        raise RuntimeError(f"no page in qa/deps.json claims case {case!r}; add its page or an alias")
    return keys


# Set by --allow-older-build: capture even when a source is newer than the
# installed build. Such a capture records the late files and counts as stale.
ALLOW_OLDER = False


def case_sources(root, case):
    """The sources record for an after capture, or nothing for a before one
    (those show the old build, not the files here).

    A source edited after the installed build was made means the capture
    would show the old code under the new hashes, so it stops the run unless
    --allow-older-build is given."""
    if root != "after":
        return {}
    record = sources_record(case_keys(case))
    app = installed_app()
    built = (app / app_identity(app, "")["production_code_file"]).stat().st_mtime
    late = newer_than(list(record["sources"]), built)
    if late and not ALLOW_OLDER:
        raise RuntimeError(f"{case}: {len(late)} sources are newer than the installed build "
                           f"({', '.join(late[:3])}); rebuild and install, or pass --allow-older-build")
    if late:
        record["sources_newer_than_build"] = late
    return record


# ---------------------------------------------------------------- fixture

class Fixture:
    def __init__(self):
        self.proc = None
        self.side = None
        self.log = None

    def start(self, side=64):
        if self.proc and self.side == side and self.proc.poll() is None:
            # A refusal closes the port for a while: wait for it to open again.
            self.wait_answering()
            return
        self.stop()
        self.log = open(SCRATCH / f"serve_setup-17final-{side}.log", "a")
        self.proc = subprocess.Popen([PY, "scripts/qa/serve_setup.py", "--port", str(PORT), "--side", str(side),
                                      "--hostname", "qa-wall"], cwd=ROOT, stdout=self.log, stderr=self.log)
        self.side = side
        for _ in range(100):
            try:
                self.status()
                return
            except Exception:
                time.sleep(0.2)
        raise RuntimeError("serve_setup did not start")

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.proc = None

    def post(self, path, body):
        req = Request(f"http://{FIX}{path}", data=json.dumps(body).encode(), method="POST",
                      headers={"Content-Type": "application/json"})
        with urlopen(req, timeout=10) as r:
            return json.load(r)

    def status(self):
        with urlopen(f"http://{FIX}/qa/status", timeout=10) as r:
            return json.load(r)

    def status_or_none(self):
        try:
            return self.status()
        except Exception:
            return None

    def wait_answering(self, timeout=150):
        t = time.time()
        while time.time() - t < timeout:
            s = self.status_or_none()
            if s is not None:
                return s
            time.sleep(0.5)
        raise RuntimeError("the fixture did not answer again")

    def frame(self):
        with urlopen(f"http://{FIX}/frame.raw", timeout=10) as r:
            return r.read()


FIXTURE = Fixture()


def terminate():
    sh("xcrun", "simctl", "terminate", SIM, BUNDLE, check=False)


def content_size(large):
    sh("xcrun", "simctl", "ui", SIM, "content_size", AX5 if large else "large")


def launch(args):
    sh("xcrun", "simctl", "launch", "--terminate-running-process", SIM, BUNDLE, *args)


def screenshot(path):
    sh("xcrun", "simctl", "io", SIM, "screenshot", str(path))


def base(intro="none", design="room", host=True):
    a = ["-nointro", "-onboarded", "YES", "-intro.sting.migrated", "YES", "-intro.style", intro,
         "-design", design, "-reporter.host", "", "-reporter.background", "NO", "-live.enabled", "NO"]
    if host:
        a += ["-wall.host", FIX]
    return a


def stamp_identity(data, ident):
    data["installed_app_identity"] = ident
    data["tessera_debug_dylib_sha256"] = ident["files_sha256"].get(DYLIB)


def merge_manifest(folder: Path, entry: dict):
    path = folder / "manifest.json"
    data = json.loads(path.read_text()) if path.exists() else {}
    data.setdefault("simulator", SIM)
    data.setdefault("bundle", BUNDLE)
    caps = {c.get("state") or c.get("image"): c for c in data.get("captures", [])}
    caps[entry["state"]] = entry
    data["captures"] = list(caps.values())
    data["captured_at"] = datetime.now(timezone.utc).isoformat()
    stamp_identity(data, entry.get("installed_app_identity") or identity())
    path.write_text(json.dumps(data, indent=2) + "\n")


def wait_gets(path="/state", n=1, timeout=25):
    t = time.time()
    while time.time() - t < timeout:
        s = FIXTURE.status()
        if s["gets"].get(path, 0) >= n:
            return True
        time.sleep(0.15)
    return False


def serve_case(root, case, variant="room-live", args=(), host=True, intro="none", design="room",
               phase="connected", side=64, pre=(), post=(), settle=5.0, wait_live=True, large=None,
               note=None):
    """A capture against serve_setup.py on 65368. pre/post are lists of
    ("post", path, body) | ("sleep", s) | ("wait", path, n) | ("health_reads", n) | ("tuning_loaded",)."""
    folder = QA / root / case
    # Before anything launches, so a case no page claims, or an unrebuilt
    # app, stops here rather than after a new screenshot replaced the old one.
    sources = case_sources(root, case)
    folder.mkdir(parents=True, exist_ok=True)
    large = variant.endswith("large") if large is None else large
    FIXTURE.start(side)
    terminate()
    content_size(large)
    calls = []
    FIXTURE.post("/qa/reset", {"phase": phase})
    calls.append({"when": "before launch", "post": "/qa/reset", "body": {"phase": phase}})

    def run(steps, when):
        for step in steps:
            kind = step[0]
            if kind == "post":
                FIXTURE.post(step[1], step[2])
                calls.append({"when": when, "post": step[1], "body": step[2]})
            elif kind == "sleep":
                time.sleep(step[1])
                calls.append({"when": when, "sleep_s": step[1]})
            elif kind == "wait":
                ok = wait_gets(step[1], step[2])
                calls.append({"when": when, "waited_for_gets": {step[1]: step[2]}, "reached": ok})
            elif kind == "health_reads":
                t = time.time()
                while time.time() - t < 20 and FIXTURE.status()["health_reads"] < step[1]:
                    time.sleep(0.2)
                calls.append({"when": when, "waited_for_health_reads": step[1]})
            elif kind == "wait_more":
                # The next GET of this path after this point.
                start = FIXTURE.status()["gets"].get(step[1], 0)
                ok = wait_gets(step[1], start + 1)
                calls.append({"when": when, "waited_for_next_get": step[1], "after": start, "reached": ok})
            elif kind == "tuning_loaded":
                ok = wait_gets("/tuning", 1)
                time.sleep(0.8)
                calls.append({"when": when, "waited_for_gets": {"/tuning": 1}, "reached": ok})

    run(pre, "before launch")
    launch_args = base(intro, design, host) + list(args)
    t0 = time.time()
    launch(launch_args)
    live = wait_gets("/state", 1) if wait_live else None
    early = None
    if wait_live:
        time.sleep(0.6)
        try:
            early = FIXTURE.frame() if FIXTURE.status()["available"] else None
        except Exception:
            early = None
    run(post, "after first GET /state" if wait_live else "after launch")
    time.sleep(settle)
    image = folder / f"{variant}.png"
    screenshot(image)
    shot_at = time.time() - t0
    status = FIXTURE.status_or_none()
    port_closed = status is None
    if port_closed:
        # POST /qa/available as refused: nothing listened at the screenshot.
        status = FIXTURE.wait_answering()
    frame = None
    # The fixture's frame only means something when the app reads this fixture.
    reads_fixture = status["gets"].get("/state", 0) > 0
    if reads_fixture and not port_closed and status["available"] and not status.get("phase") == "offline":
        try:
            frame = FIXTURE.frame()
        except Exception:
            frame = None
    frame = frame or early if reads_fixture else None
    ident = identity()
    entry = {"state": variant, "image": image.name, "case": case, "fixture": "scripts/qa/serve_setup.py",
             "fixture_port": PORT, "side": side, "phase": phase,
             "launch_arguments": launch_args, "fixture_calls": calls,
             "app_reached_fixture": live, "screenshot_after_launch_s": round(shot_at, 2),
             "dynamic_type": "AX5" if large else "large",
             "qa_status": {k: status.get(k) for k in ("gets", "check_gets", "health_reads", "health_preset",
                                                      "available", "unavailable_as", "delay_s", "phase",
                                                      "hostname", "session", "tuning", "frame", "requests")},
             "installed_app_identity": ident,
             "tessera_debug_dylib_sha256": ident["files_sha256"].get(DYLIB),
             "captured_at": datetime.now(timezone.utc).isoformat(),
             **sources}
    if port_closed:
        entry["qa_status_note"] = ("The fixture's port was closed at the screenshot (POST /qa/available as refused), "
                                   "so qa_status was read after it opened again.")
    if note:
        entry["note"] = note
    if frame:
        s = int(round((len(frame) // 3) ** 0.5))
        Image.frombytes("RGB", (s, s), frame).save(folder / f"{variant}-frame.png")
        entry["frame"] = f"{variant}-frame.png"
        entry["frame_source"] = "GET /frame.raw on the fixture" + (" (final)" if frame is not early else " (right after the first /state, before later fixture calls)")
    merge_manifest(folder, entry)
    content_size(False)
    print(image, f"live={live}", flush=True)


def home_case(root, case, states, args=(), setup="ready", intro="none", settle=5.0, extra=(), rename=None, keys=None):
    """A capture through capture_home.py, which binds its own port. keys are
    the qa/deps.json pages to record, taken from the case name unless given
    (home_extra captures under a scratch name for a real case)."""
    folder = QA / root / case
    cmd = [PY, "scripts/qa/capture_home.py", "--simulator", SIM, "--output", str(folder),
           "--intro-style", intro, "--settle", str(settle), "--states", *states]
    if keys is None and root == "after":
        keys = case_keys(case)
    if keys:
        cmd += ["--deps", ",".join(keys)]
        if ALLOW_OLDER:
            cmd += ["--allow-older-build"]
    if setup:
        cmd += ["--setup-state", setup]
    cmd += list(extra)
    cmd += [f"--launch-argument={a}" for a in args]
    terminate()
    r = subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True, timeout=600)
    if r.returncode != 0:
        print("FAILED", case, r.stderr[-1500:], flush=True)
        return
    print(r.stdout.strip(), flush=True)
    mpath = folder / "manifest.json"
    m = json.loads(mpath.read_text())
    if rename:
        for old, new in rename.items():
            for suffix in (".png", "-frame.png"):
                src = folder / f"{old}{suffix}"
                if src.exists():
                    src.replace(folder / f"{new}{suffix}")
            for c in m["captures"]:
                if c["state"] == old:
                    c["captured_as"] = old
                    c["state"] = new
                    c["image"] = f"{new}.png"
                    c["frame"] = f"{new}-frame.png"
    stamp_identity(m, m["installed_app_identity"])
    mpath.write_text(json.dumps(m, indent=2) + "\n")


def home_extra(root, case, state, newname, args=(), setup="ready", intro="none", settle=5.0, extra=(), note=None):
    """One more capture_home image in an existing case folder, under a new
    name, without touching what is already there."""
    tmp = SCRATCH / "tmp-home"
    shutil.rmtree(tmp, ignore_errors=True)
    home_case(str(tmp.parent), tmp.name, [state], args=args, setup=setup, intro=intro, settle=settle, extra=extra,
              keys=case_keys(case) if root == "after" else [])
    folder = QA / root / case
    folder.mkdir(parents=True, exist_ok=True)
    m = json.loads((tmp / "manifest.json").read_text())
    # A pinned widget snapshot is recorded as "fixture"/"fixture-large".
    entry = next(c for c in m["captures"] if c["image"] == f"{state}.png")
    for suffix in (".png", "-frame.png"):
        if (tmp / f"{state}{suffix}").exists():
            shutil.move(tmp / f"{state}{suffix}", folder / f"{newname}{suffix}")
    entry.update({"captured_as": entry["state"], "state": newname, "image": f"{newname}.png",
                  "frame": f"{newname}-frame.png" if entry.get("frame") else None,
                  "fixture": "scripts/qa/capture_home.py (own port)"})
    if note:
        entry["note"] = note
    for f in tmp.glob("fixture-*.json"):
        if not (folder / f.name).exists():
            shutil.move(f, folder / f.name)
    merge_manifest(folder, entry)
    shutil.rmtree(tmp, ignore_errors=True)
    print(folder / f"{newname}.png", flush=True)


# ---------------------------------------------------------------- cases

H = ["-settings", "-settings-page", "health"]
C = ["-settings", "-settings-page", "addresses", "-connection-reset"]
A = ["-settings", "-settings-page", "about"]
D = ["-settings", "-settings-page", "design"]
T = ["-settings", "-settings-page", "about", "-about-page", "tuning"]
W = ["-settings", "-settings-page", "widgets"]
PRESETS = ["warm", "hot", "slowed", "slowed-earlier", "undervolt", "undervolt-earlier", "panels-off",
           "panels-starting", "stalled", "memory-low", "memory-critical", "storage-low", "animating",
           "unpaced", "still", "behind", "collecting", "mac", "legacy", "several"]
CHECKS = ["passed", "cellular", "noNetwork", "denied", "deniedName", "notFound", "numericGone", "refused",
          "notTessera", "http", "blocked", "slow", "running"]
OFF_SILENT = [("post", "/qa/available", {"enabled": False, "as": "silent"}), ("sleep", 10)]
AWAY_BEFORE = [("post", "/qa/available", {"enabled": False})]
# The pairings documented on ScriptedProbe (tessera/Tessera/ConnectionProbe.swift),
# so a scripted check never reads beside a live loopback wall that disagrees with it.
PAIRED = "Paired as documented on ScriptedProbe: "
CHECK_SETUP = {
    "denied": dict(args=["-seed-wall-host", "192.168.1.40:8788"], host=False, wait_live=False, settle=16,
                   note=PAIRED + "-seed-wall-host 192.168.1.40:8788."),
    "deniedName": dict(args=["-seed-wall-host", "qa-wall.local:8788"], host=False, wait_live=False, settle=16,
                       note=PAIRED + "-seed-wall-host qa-wall.local:8788, so the rows show a name."),
    "blocked": dict(args=["-seed-wall-host", "album-matrix.lan:8788"], host=False, wait_live=False, settle=16,
                    note=PAIRED + "-seed-wall-host album-matrix.lan:8788."),
    "noNetwork": dict(pre=AWAY_BEFORE, wait_live=False, settle=16,
                      note=PAIRED + "the fixture unavailable (POST /qa/available {enabled: false}) before launch."),
    "notFound": dict(pre=AWAY_BEFORE, wait_live=False, settle=16,
                     note=PAIRED + "the fixture unavailable (POST /qa/available {enabled: false}) before launch."),
    "refused": dict(pre=AWAY_BEFORE, wait_live=False, settle=16,
                    note=PAIRED + "the fixture unavailable (POST /qa/available {enabled: false}) before launch."),
    "http": dict(post=[("post", "/qa/available", {"enabled": False, "as": "http"}), ("sleep", 10)], settle=1,
                 note="Live first, then /qa/available {enabled: false, as: http} 10 s before the screenshot (hero 'Wall not ready')."),
    "numericGone": dict(args=["-seed-wall-host", "192.168.1.40:8788", "-seed-wall-name", "qa-wall", "-connection-scroll", "check"],
                        host=False, wait_live=False, settle=20),
}


def check_case(c):
    s = CHECK_SETUP.get(c, dict(settle=9))
    variants = ["room-live", "room-large"] if c == "denied" else ["room-live"]
    away = c in ("denied", "deniedName", "blocked", "noNetwork", "notFound", "refused")
    if c == "http":
        # The hero (Wall not ready) first, then the check's rows.
        variants = ["room-live", "room-live-check"]
    for v in variants:
        # Away from the wall the hero and What to try push the check below the
        # first screen, so those scroll to it (numericGone carries its own).
        extra = ["-connection-scroll", "check"] if (v in ("room-large", "room-live-check") or away) else []
        serve_case("after", f"connection-check-{c}", v, args=C + ["-connection-check-fixture", c] + s.get("args", []) + extra,
                   host=s.get("host", True), wait_live=s.get("wait_live", True), pre=s.get("pre", ()),
                   post=s.get("post", ()), settle=s["settle"] + (1 if v == "room-large" else 0), note=s.get("note"))


def cases(include_before=False):
    L = []

    def add(name, fn):
        L.append((name, fn))

    if include_before:
        # before, network path for health (the old page on the production /health body). Kept as it is.
        add("before/health-network-steady", lambda: serve_case("before", "health-network-steady", args=H,
            pre=[("post", "/qa/health", {"preset": "steady"})], post=[("health_reads", 1)], settle=4))

    # ---- D06 health
    add("after/health:main", lambda: home_case("after", "health", ["room-live", "room-large"],
        args=H + ["-health-fixture", "steady"]))
    add("after/health:offline", lambda: serve_case("after", "health", "room-offline", args=H,
        pre=[("post", "/qa/health", {"preset": "steady"})],
        post=[("health_reads", 1), ("sleep", 2), ("post", "/qa/available", {"enabled": False, "as": "http"}), ("sleep", 9)],
        settle=1, note="Live with the steady reading, then the wall stops answering (503), so the page is offline with its last reading."))
    for p in PRESETS:
        states = ["room-live", "room-large"] if p == "several" else ["room-live"]
        add(f"after/health-{p}", lambda p=p, states=states: home_case("after", f"health-{p}", states,
            args=H + ["-health-fixture", p]))
    for p in ["stale", "unreadable", "loading"]:
        add(f"after/health-{p}", lambda p=p: home_case("after", f"health-{p}", ["room-live"], args=H + ["-health-fixture", p]))
    for link in ["offline", "searching", "standin", "standin-auto"]:
        add(f"after/health-{link}", lambda link=link: home_case("after", f"health-{link}", ["room-live"],
            args=H + ["-health-link", link]))
    add("after/health-offline-last-reading", lambda: home_case("after", "health-offline-last-reading", ["room-live"],
        args=H + ["-health-link", "offline", "-health-fixture", "steady"]))
    EXPLAIN = H + ["-health-fixture", "steady", "-health-explain", "all"]
    add("after/health-explain-all", lambda: (
        home_case("after", "health-explain-all", ["room-live", "room-large"], args=EXPLAIN),
        home_extra("after", "health-explain-all", "room-large", "room-large-checks", args=EXPLAIN + ["-health-scroll", "checks"],
                   note="AX5, every explanation open, scrolled to the checks (-health-scroll checks)."),
        home_extra("after", "health-explain-all", "room-large", "room-large-footnote", args=EXPLAIN + ["-health-scroll", "footnote"],
                   note="AX5, every explanation open, scrolled to the footnote (-health-scroll footnote).")))
    add("after/health-others-open", lambda: home_case("after", "health-others-open", ["room-live"],
        args=H + ["-health-fixture", "warm", "-health-others-open"]))
    add("after/health-footnote", lambda: home_case("after", "health-footnote", ["room-live"],
        args=H + ["-health-fixture", "steady", "-health-scroll", "footnote"]))
    for p in ["steady", "undervolt", "fail"]:
        add(f"after/health-network-{p}", lambda p=p: serve_case("after", f"health-network-{p}", args=H,
            pre=[("post", "/qa/health", {"preset": p})], post=[("health_reads", 1)], settle=4,
            note="The fixture wall shows its still clock face, so the served /health reads a still wall (fps_age_s at least 1800)."))
    add("after/health-landing", lambda: serve_case("after", "health-landing", args=["-settings"],
        pre=[("post", "/qa/health", {"preset": "steady"})], post=[("health_reads", 1)], settle=4))

    # ---- D07 connection
    add("after/connection:main", lambda: (serve_case("after", "connection", "room-live", args=C),
                                          serve_case("after", "connection", "room-large", args=C, settle=5),
                                          serve_case("after", "connection", "room-offline", args=C, post=OFF_SILENT, settle=1)))
    add("after/connection-192", lambda: serve_case("after", "connection-192", args=C, side=192))
    add("after/connection-checked", lambda: serve_case("after", "connection-checked", args=C + ["-connection-check", "auto"], settle=9))
    for c in CHECKS:
        add(f"after/connection-check-{c}", lambda c=c: check_case(c))
    add("after/connection-check-passed-not-connected", lambda: serve_case("after", "connection-check-passed-not-connected",
        args=C + ["-connection-check-fixture", "passed", "-connection-phone-only"], settle=12))
    add("after/connection-offline", lambda: (serve_case("after", "connection-offline", "room-live", args=C, post=OFF_SILENT, settle=1),
                                             serve_case("after", "connection-offline", "room-large", args=C, post=OFF_SILENT, settle=1)))
    for how in ["dropped", "refused", "http"]:
        body = {"enabled": False, "as": how}
        if how == "refused":
            body["seconds"] = 30
        note = {"dropped": "Live, then every connection is accepted and reset at once (the app sees -1005).",
                "refused": "Live, then nothing listens on the port for 30 s (the app sees -1004); the screenshot is inside that window.",
                "http": "Live, then every read answers 503."}[how]
        add(f"after/connection-offline-reason-{how}", lambda how=how, body=body, note=note: serve_case("after", f"connection-offline-reason-{how}",
            args=C, post=[("post", "/qa/available", body), ("sleep", 10)], settle=1, note=note))
    add("after/connection-offline-queue", lambda: (serve_case("after", "connection-offline-queue", "room-live", args=C + ["-connection-queue"], post=OFF_SILENT, settle=2),
                                                   serve_case("after", "connection-offline-queue", "room-large", args=C + ["-connection-queue"], post=OFF_SILENT, settle=2)))
    add("after/connection-offline-queue-discard", lambda: serve_case("after", "connection-offline-queue-discard",
        args=C + ["-connection-queue", "-connection-confirm-discard"], post=OFF_SILENT, settle=5))
    for d in ["sent", "partial", "refused"]:
        name = {"sent": "delivered", "partial": "delivery-partial", "refused": "delivery-refused"}[d]
        # A queue seeded with -connection-delivery is held until the page's own
        # Send now (WallLink.debugHoldsQueue), so every delivery case settles the same.
        add(f"after/connection-{name}", lambda d=d, name=name: serve_case("after", f"connection-{name}",
            args=C + ["-connection-delivery", d], settle=6))
    add("after/connection-delivery-partial-discard", lambda: serve_case("after", "connection-delivery-partial-discard",
        args=C + ["-connection-delivery", "partial", "-connection-confirm-discard"], settle=7))
    add("after/connection-phone-only", lambda: serve_case("after", "connection-phone-only", args=C + ["-connection-phone-only"], settle=5))
    add("after/connection-standin-auto", lambda: serve_case("after", "connection-standin-auto",
        args=C + ["-seed-wall-host", "127.0.0.1:9"], host=False, wait_live=False, settle=14))
    add("after/connection-searching", lambda: serve_case("after", "connection-searching", args=C + ["-connection-look"],
        pre=[("post", "/qa/delay", {"seconds": 2.5})], settle=1.2))
    add("after/connection-address-saved", lambda: serve_case("after", "connection-address-saved",
        args=C + ["-seed-wall-host", FIX, "-connection-save", f"localhost:{PORT}", "-connection-scroll", "address"], host=False,
        pre=[("post", "/qa/delay", {"seconds": 2.5})], settle=3.6))
    for e, text in [("invalid", "bad host!"), ("preview", "192.168.1.40"), ("blocked", "album-matrix.lan")]:
        variants = ["room-live", "room-large"] if e == "invalid" else ["room-live"]
        add(f"after/connection-edit-{e}", lambda text=text, e=e, variants=variants: [serve_case("after", f"connection-edit-{e}", v,
            args=C + ["-connection-edit", text], settle=5) for v in variants])
    add("after/connection-ip-suggestion", lambda: serve_case("after", "connection-ip-suggestion",
        args=C + ["-seed-wall-host", "192.168.1.40:8788", "-seed-wall-name", "qa-wall", "-connection-scroll", "address"],
        host=False, wait_live=False, settle=12))
    add("after/connection-glow-64", lambda: serve_case("after", "connection-glow-64", args=C + ["-connection-glow"], settle=5))
    add("after/connection-glow-192", lambda: serve_case("after", "connection-glow-192", args=C + ["-connection-glow"], side=192, settle=5))
    add("after/connection-glow-occupied", lambda: serve_case("after", "connection-glow-occupied", args=C + ["-connection-glow"],
        pre=[("post", "/qa/occupy", {"purpose": "panel"})], settle=5,
        note="Another phone's panel check holds the wall with its own stripes before launch."))
    for h in ["sample", "clear"]:
        name = "recent" if h == "sample" else "recent-empty"
        add(f"after/connection-{name}", lambda h=h, name=name: serve_case("after", f"connection-{name}",
            args=C + ["-connection-history", h, "-connection-scroll", "recent"], settle=8))
    add("after/connection-related", lambda: serve_case("after", "connection-related", args=C + ["-connection-scroll", "related"], settle=5))
    add("after/connection-lights-off", lambda: serve_case("after", "connection-lights-off", args=C,
        pre=[("post", "/state", {"mode": "off"})], settle=5,
        note="The fixture's own POST /state {mode: off} before launch, so the wall is live with its lights off; GET /frame.raw is black while off."))

    # ---- D08 about and App design
    TROW = A + ["-about-state", "credits"]
    OPEN = A + ["-about-state", "confirm"]
    ONOTE = "-about-state confirm only to scroll the openings list into view"
    add("after/about:main", lambda: (
        home_case("after", "about", ["room-live", "room-large", "room-offline"], args=A, setup="about", intro="sting", settle=6),
        home_extra("after", "about", "room-live", "room-live-tuning-row", args=TROW, setup="about", intro="sting", settle=10)))
    for s in ["about-tuned", "about-notuning", "about-badtuning"]:
        add(f"after/{s}", lambda s=s: (home_case("after", s, ["room-live"], args=A, setup=s, intro="sting", settle=10),
                                       home_extra("after", s, "room-live", "room-live-tuning-row", args=TROW, setup=s, intro="sting", settle=10)))
    add("after/about-slow", lambda: (home_case("after", "about-slow", ["room-live"], args=A, setup="about-slow", intro="sting", settle=10),
                                     home_extra("after", "about-slow", "room-live", "room-live-tuning-row", args=TROW, setup="about-slow", intro="sting", settle=10)))
    add("after/about-reading", lambda: (serve_case("after", "about-reading", args=A, intro="sting", phase="tuning-slow", settle=1.0),
                                        serve_case("after", "about-reading", "room-live-tuning-row", args=TROW, intro="sting", phase="tuning-slow", settle=1.0)))
    add("after/about-confirm", lambda: home_case("after", "about-confirm", ["room-live", "room-large"], args=A + ["-about-reset", "-about-state", "confirm"], setup="about", intro="sting", settle=12))
    for s in ["copied", "details", "credits"]:
        add(f"after/about-{s}", lambda s=s: home_case("after", f"about-{s}", ["room-live"], args=A + ["-about-state", s], setup="about", intro="sting"))
    add("after/about-reduced", lambda: (home_case("after", "about-reduced", ["room-live"], args=A + ["-reduce-motion"], setup="about", intro="sting"),
                                        home_extra("after", "about-reduced", "room-live", "room-live-openings", args=OPEN + ["-reduce-motion"], setup="about", intro="sting", note=ONOTE)))
    add("after/about-standin", lambda: serve_case("after", "about-standin", args=A + ["-stand-in"], intro="sting", wait_live=False, settle=12))
    add("after/about-searching", lambda: home_case("after", "about-searching", ["room-live"], args=A + ["-about-state", "look"], setup="about", intro="sting",
        settle=8, extra=["--delay-after-first", "/state=10"]))
    add("after/about-never-connected", lambda: home_case("after", "about-never-connected", ["room-live"], args=A + ["-about-state", "never"], setup="about", intro="sting"))
    add("after/about-standin-auto", lambda: serve_case("after", "about-standin-auto", args=A + ["-seed-wall-host", "127.0.0.1:9", "-connection-reset"],
        intro="sting", host=False, wait_live=False, settle=14))
    add("after/about-192", lambda: home_case("after", "about-192", ["room-live"], args=A, setup="about", intro="sting", extra=["--wall-side", "192"]))
    add("after/about-panel-film", lambda: (home_case("after", "about-panel-film", ["classic-live"], args=A, setup="about", intro="film"),
                                           home_extra("after", "about-panel-film", "classic-live", "classic-live-openings", args=OPEN, setup="about", intro="film", note=ONOTE)))
    add("after/about-ipod-mark", lambda: (home_case("after", "about-ipod-mark", ["ipod-live"], args=A, setup="about", intro="mark"),
                                          home_extra("after", "about-ipod-mark", "ipod-live", "ipod-live-openings", args=OPEN, setup="about", intro="mark", note=ONOTE)))
    add("after/design:main", lambda: home_case("after", "design", ["room-live", "room-large", "room-offline", "classic-live", "ipod-live"], args=D, settle=12))
    add("after/design-preview", lambda: home_case("after", "design-preview", ["room-live", "room-large"], args=D + ["-design-pick", "ipod"], settle=8))
    add("after/design-committed", lambda: home_case("after", "design-committed", ["ipod-live"], args=D + ["-design-notice"], settle=8))
    add("after/design-off", lambda: home_case("after", "design-off", ["classic-off"], args=D, settle=8))
    add("after/design-standin", lambda: serve_case("after", "design-standin", args=D + ["-stand-in"], wait_live=False, settle=8))
    add("after/design-homes", lambda: home_case("after", "design-homes", ["classic-live", "ipod-live", "room-live"], args=[], settle=6))

    # ---- D09 tuning
    add("after/tuning:main", lambda: (serve_case("after", "tuning", "room-live", args=T, post=[("tuning_loaded",)], settle=3),
                                      serve_case("after", "tuning", "room-large", args=T, post=[("tuning_loaded",)], settle=3),
                                      serve_case("after", "tuning", "room-offline", args=T,
                                                 post=[("tuning_loaded",), ("post", "/qa/reset", {"phase": "offline"}), ("sleep", 10)], settle=1)))
    add("after/tuning-192", lambda: serve_case("after", "tuning-192", args=T, side=192, post=[("tuning_loaded",)], settle=3))
    add("after/tuning-changed", lambda: [serve_case("after", "tuning-changed", v, args=T, phase="tuning-changed", post=[("tuning_loaded",)], settle=3) for v in ("room-live", "room-large")])
    for knob in ["bit_depth", "black_point", "panel_type", "gain_b"]:
        add(f"after/tuning-changed:{knob}", lambda knob=knob: serve_case("after", "tuning-changed", f"room-large-{knob}",
            args=T + ["-tuning-knob", knob], phase="tuning-changed", post=[("tuning_loaded",)], settle=4, large=True,
            note=f"AX5 with -tuning-knob {knob}" + (", for Measured correction" if knob == "gain_b" else "") + "."))
    add("after/tuning-listening", lambda: [serve_case("after", "tuning-listening", v, args=T + ["-tuning-tab", "listening"], post=[("tuning_loaded",)], settle=6) for v in ("room-live", "room-large")])
    add("after/tuning-loading", lambda: serve_case("after", "tuning-loading", args=T, phase="tuning-slow",
        post=[("wait", "/tuning", 1)], settle=1.0, note="GET /tuning is held 3 s; the screenshot is 1 s into the first read."))
    add("after/tuning-standin-auto", lambda: serve_case("after", "tuning-standin-auto", args=T, phase="offline", wait_live=False, settle=12,
        note="Cold launch while every read answers 503. The app enters the automatic stand-in (No wall connected), not offline."))
    add("after/tuning-offline", lambda: serve_case("after", "tuning-offline", args=T, phase="tuning-failing",
        post=[("wait", "/tuning", 1), ("sleep", 1.5), ("post", "/qa/available", {"enabled": False, "as": "http"}), ("sleep", 10)],
        settle=1, note="GET /tuning answers 500 so no knob is ever read, then every read answers 503: offline, never read."))
    add("after/tuning-stale", lambda: serve_case("after", "tuning-stale", args=T,
        post=[("tuning_loaded",), ("post", "/qa/reset", {"phase": "offline"}), ("sleep", 10)], settle=1))
    add("after/tuning-stale-live", lambda: serve_case("after", "tuning-stale-live", args=T,
        post=[("tuning_loaded",), ("post", "/qa/reset", {"phase": "tuning-failing"}), ("sleep", 14)], settle=1,
        note="Read once, then GET /tuning answers 500 while /state keeps answering."))
    add("after/tuning-standin", lambda: serve_case("after", "tuning-standin", args=T + ["-stand-in"], settle=5))
    add("after/tuning-unsupported", lambda: serve_case("after", "tuning-unsupported", args=T, phase="tuning-unsupported", settle=4))
    add("after/tuning-error", lambda: serve_case("after", "tuning-error", args=T, phase="tuning-failing", settle=5))
    add("after/tuning-pattern-64", lambda: serve_case("after", "tuning-pattern-64", args=T + ["-tuning-state", "pattern"], settle=6))
    add("after/tuning-pattern-192", lambda: serve_case("after", "tuning-pattern-192", args=T + ["-tuning-state", "pattern"], side=192, settle=6))
    add("after/tuning-pattern-grid", lambda: serve_case("after", "tuning-pattern-grid", args=T + ["-tuning-state", "pattern", "-tuning-pattern", "grid"], settle=6))
    add("after/tuning-pattern-finished", lambda: serve_case("after", "tuning-pattern-finished", args=T + ["-tuning-state", "finished"], settle=7))
    add("after/tuning-occupied", lambda: serve_case("after", "tuning-occupied", args=T + ["-tuning-state", "pattern"],
        pre=[("post", "/qa/occupy", {"purpose": "panel"})], settle=6,
        note="Another phone's panel check holds the wall with its own stripes before launch."))
    add("after/tuning-restarting", lambda: serve_case("after", "tuning-restarting", args=T + ["-tuning-send", "bit_depth=48"], settle=5))
    add("after/tuning-back", lambda: serve_case("after", "tuning-back", args=T + ["-tuning-send", "bit_depth=48"],
        post=[("tuning_loaded",), ("sleep", 4), ("post", "/qa/renderer", {"state": "running"})], settle=1.5))
    for r in ["stalled", "stopped", "absent"]:
        add(f"after/tuning-{r}", lambda r=r: serve_case("after", f"tuning-{r}", args=T,
            post=[("tuning_loaded",), ("post", "/qa/renderer", {"state": r}), ("wait_more", "/tuning"), ("sleep", 1.5)], settle=1,
            note="The screenshot follows the page's next GET /tuning after the renderer change."))
    add("after/tuning-absent:scrolled", lambda: serve_case("after", "tuning-absent", "room-live-scrolled", args=T + ["-tuning-scrolled"],
        post=[("tuning_loaded",), ("post", "/qa/renderer", {"state": "absent"}), ("wait_more", "/tuning"), ("sleep", 1.5)], settle=1,
        note="-tuning-scrolled so the Panel drive group, where the absent note sits, is in view"))
    add("after/tuning-refused", lambda: (serve_case("after", "tuning-refused", args=T + ["-tuning-send", "temporal_dither=0"],
                                                    pre=[("post", "/qa/reject", {"enabled": True})], settle=6),
                                         serve_case("after", "tuning-refused", "room-live-row", args=T + ["-tuning-send", "temporal_dither=0", "-tuning-knob", "temporal_dither"],
                                                    pre=[("post", "/qa/reject", {"enabled": True})], settle=7,
                                                    note="-tuning-knob temporal_dither so the refused row and its problem line are in view")))
    add("after/tuning-inactive", lambda: serve_case("after", "tuning-inactive", args=T + ["-tuning-knob", "nearest_colour"], settle=5))
    add("after/tuning-row", lambda: serve_case("after", "tuning-row", args=T + ["-tuning-knob", "black_point"], phase="tuning-changed", settle=5))
    add("after/tuning-scrolled", lambda: serve_case("after", "tuning-scrolled", args=T + ["-tuning-scrolled"], settle=5))
    add("after/tuning-reset-confirm", lambda: serve_case("after", "tuning-reset-confirm", args=T + ["-tuning-state", "reset-confirm"], phase="tuning-changed", settle=5))
    add("after/tuning-reset-done", lambda: serve_case("after", "tuning-reset-done", args=T + ["-tuning-state", "reset-done"], phase="tuning-changed", settle=6))

    # ---- E01 widgets page
    add("after/widgets-page:main", lambda: home_case("after", "widgets-page", ["room-live", "room-large", "room-offline"], args=W))
    for fx in ["music", "music-long", "lamp", "stale", "stale-days", "outdated", "queued", "preview", "off", "panel-check",
               "missing", "unreadable", "away", "idle-dark", "timer", "clock", "connection-check"]:
        name = "widgets-current" if fx == "music" else f"widgets-{fx}"
        add(f"after/{name}", lambda fx=fx, name=name: home_case("after", name, ["room-live", "room-large"], args=W + ["-widget-snapshot", fx], settle=8))
    for inst in ["none", "both"]:
        add(f"after/widgets-installed-{inst}", lambda inst=inst: home_case("after", f"widgets-installed-{inst}", ["room-live"],
            args=W + ["-widget-installed", inst], settle=10))
    return L


def stale_folders():
    """The after case folders whose captures are stale or unknown, and the
    ones among them no case here writes (so they are named, not skipped)."""
    result = check_batch(QA)
    folders = {name for name in result["stale"] + result["unknown"] if name.startswith("after/")}
    written = {name.split(":")[0] for name, _ in cases()}
    return folders, sorted(folders - written)


def main():
    global ALLOW_OLDER
    argv = sys.argv[1:]
    ALLOW_OLDER = "--allow-older-build" in argv
    L = cases(include_before="--before" in argv)
    stale = None
    if "--stale" in argv:
        stale, orphans = stale_folders()
        print(f"STALE {len(stale)} case folders: {', '.join(sorted(stale)) or 'none'}", flush=True)
        for folder in orphans:
            print(f"NOT HERE {folder}: stale, but no case in this driver writes it", flush=True)
    if "--list" in argv:
        for n, _ in L:
            if stale is None or n.split(":")[0] in stale:
                print(n)
        return
    wanted = [a for a in argv if not a.startswith("--")]
    exact = "--exact" in argv
    try:
        for name, fn in L:
            # A case entry is named after its folder ("after/health:offline"
            # writes after/health), so a stale folder reruns every entry that
            # writes it and the folder ends up from one build.
            if stale is not None and name.split(":")[0] not in stale:
                continue
            if wanted and not any((w == name) if exact else (w in name) for w in wanted):
                continue
            print("CASE", name, flush=True)
            try:
                fn()
            except subprocess.TimeoutExpired as error:
                print("ABORT (simulator not answering)", name, repr(error), flush=True)
                break
            except Exception as error:  # keep going, report at the end
                print("ERROR", name, repr(error), flush=True)
    finally:
        FIXTURE.stop()
        content_size(False)


if __name__ == "__main__":
    main()
