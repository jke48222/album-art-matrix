#!/usr/bin/env python3
"""Say what a change needs rerun: brain tests, Swift model runners, native UI
suites and batch captures, and nothing else.

The changed files are the working tree (staged, unstaged and untracked)
against --base, HEAD by default. With --head, they are the difference
between two commits instead, which is how to ask what a past change would
have needed:

    .venv/bin/python scripts/qa/affected.py
    .venv/bin/python scripts/qa/affected.py --base origin/main
    .venv/bin/python scripts/qa/affected.py --base 171f1ae --head f36b741
    .venv/bin/python scripts/qa/affected.py --run
    .venv/bin/python scripts/qa/affected.py --json
    .venv/bin/python scripts/qa/affected.py --all --run --with-simulator

What it selects, and why:
  brain tests    a test that imports or names a changed brain module, or a
                 module that imports one (brain's own imports are followed,
                 so a change to art/pipeline.py selects the tests of
                 display_session.py too; --direct turns that off for a
                 quicker, looser pass). A data file counts as the modules
                 that name it. A deleted or renamed module still selects the
                 tests that import its old name. A test that names any
                 changed file (test_tuning.py reads TuningStore.swift,
                 test_health.py reads health_fixtures.json) is selected, and
                 so is a test that imports a changed test. Every test runs
                 when a file in brain_tests_core (qa/deps.json: control.py,
                 main.py, the conftest) changed.
  model runners  scripts/test_*.py whose compiled Swift files (the .swift
                 names in the runner, deleted ones included), its own
                 .swift, or a runner it imports changed.
  UI suites      a suite whose pages (qa/deps.json "suites") include a page
                 with a changed file, or whose own harness changed; the
                 test classes that cover those pages when the suite names
                 them, the whole suite when core changed.
  captures       in the working tree, the cases scripts/qa/stale_captures.py
                 finds stale or unknown by hashing; between two commits,
                 the cases whose recorded sources include a changed file.
                 Only batch folders that record sources are read, plus any
                 named with --batch.

--run runs the brain tests and model runners it selected, side by side
(with --json, their progress goes to stderr so stdout stays JSON),
against the files in the working tree (with --head too). Runners that need
a simulator (they call simctl) are left out unless --with-simulator is
given, and every runner writes its JSON to a scratch folder, never over the
evidence in qa/. UI suites and captures are listed with their commands but
never run from here.

The selection is static: a brain module reached only through an object
another module is handed (control.py's routes get their stores from
main.py) is not seen, and a Swift file counts as a whole. It is for the
loop between fixes; run the whole brain suite and the full native pass
once before the batch is signed off.
"""
from __future__ import annotations

import argparse
import ast
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from stale_captures import ROOT, case_folders, check_batch, deps, files_for, keys_for_case, page_files, records

TESTS = ROOT / "brain/tests"
RUNNERS = ROOT / "scripts"


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, check=True, text=True, capture_output=True).stdout


def changed_files(base: str, head: str | None) -> list[str]:
    """Paths that differ. --no-renames lists a moved file under both names,
    so the old path's dependants are found as well as the new one's."""
    if head:
        return sorted(set(git("diff", "--name-only", "--no-renames", base, head).split()))
    tracked = git("diff", "--name-only", "--no-renames", base).split()
    untracked = git("ls-files", "--others", "--exclude-standard").split()
    return sorted(set(tracked) | set(untracked))


def matches(path: str, entries) -> bool:
    """A path is in a list when it is an entry, or under an entry ending in /."""
    return any(path == e or (e.endswith("/") and path.startswith(e)) for e in entries)


# ---------------------------------------------------------------- brain tests

def module_of(path: str) -> str | None:
    """brain/art/pipeline.py is brain.art.pipeline; a package's __init__.py is the package."""
    if not path.startswith("brain/") or not path.endswith(".py"):
        return None
    parts = path[:-3].split("/")
    if parts[-1] == "__init__":
        parts = parts[:-1]
    return ".".join(parts)


def brain_sources() -> dict[str, Path]:
    """Every brain module that is not a test, by dotted name."""
    found = {}
    for path in (ROOT / "brain").rglob("*.py"):
        rel = path.relative_to(ROOT).as_posix()
        if rel.startswith("brain/tests/"):
            continue
        found[module_of(rel)] = path
    return found


def imported(path: Path, name: str, known: set[str]) -> set[str]:
    """The brain modules a file imports anywhere in it (tests and the brain
    import inside functions a lot), with relative imports resolved and the
    parent packages that importing a submodule runs."""
    try:
        tree = ast.parse(path.read_text(), filename=str(path))
    except SyntaxError:
        return set()
    package = name if path.name == "__init__.py" else name.rpartition(".")[0]
    out = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            out.update(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            if node.level:
                anchor = package.split(".")
                anchor = anchor[:len(anchor) - (node.level - 1)] if node.level > 1 else anchor
                base = ".".join(anchor + ([node.module] if node.module else []))
            else:
                base = node.module or ""
            out.add(base)
            # "from brain import control" imports the module brain.control.
            out.update(f"{base}.{alias.name}" for alias in node.names)
    result = set()
    for module in out:
        parts = module.split(".")
        for i in range(2, len(parts) + 1):
            candidate = ".".join(parts[:i])
            if candidate in known:
                result.add(candidate)
    return result


NAMED = re.compile(r"\bbrain[./]((?:[A-Za-z_]\w*[./]?)+)")


def named(text: str, known: set[str]) -> set[str]:
    """Brain modules a file names in text: monkeypatch targets like
    "brain.control._HOSTNAME", or paths like brain/tuning.py."""
    out = set()
    for match in NAMED.finditer(text):
        parts = re.split(r"[./]", "brain." + match.group(1).rstrip("./"))
        if parts[-1] == "py":
            parts = parts[:-1]
        for i in range(len(parts), 1, -1):
            candidate = ".".join(parts[:i])
            if candidate in known:
                out.add(candidate)
                break
    return out


def select_brain_tests(changed: list[str], data: dict, transitive: bool) -> dict:
    sources = brain_sources()
    # A module that was deleted or renamed away is not on disk, but tests
    # that still import its old name are exactly the ones that now break.
    gone = {m for path in changed if (m := module_of(path)) and m not in sources
            and not path.startswith("brain/tests/")}
    known = set(sources) | {"brain"} | gone
    tests = sorted(TESTS.glob("test_*.py"))
    test_modules = {f"brain.tests.{t.stem}": t for t in tests}
    known_all = known | set(test_modules)
    core = [path for path in changed if path in data["brain_tests_core"]]
    if core:
        return {"everything": True, "because": core, "tests": [t.relative_to(ROOT).as_posix() for t in tests]}
    touched = {m for path in changed if (m := module_of(path)) in sources} | gone
    # A data file (word lists, fonts, the sting film) stands for the modules
    # that name it, whether it was edited or deleted.
    for path in changed:
        if path.startswith("brain/") and not path.endswith(".py") and not path.startswith("brain/tests/"):
            base = Path(path).name
            touched.update(m for m, p in sources.items() if base in p.read_text())
    if transitive and touched:
        importers = {}
        for module, path in sources.items():
            for dep in imported(path, module, known):
                importers.setdefault(dep, set()).add(module)
        stack = list(touched)
        while stack:
            for parent in importers.get(stack.pop(), ()):
                if parent not in touched:
                    touched.add(parent)
                    stack.append(parent)
    changed_tests = {f"brain.tests.{Path(p).stem}" for p in changed
                     if p.startswith("brain/tests/test_") and p.endswith(".py")}
    # Files outside brain/ that a test may read (Swift copy it checks against,
    # QA fixtures), looked for by path and by file name.
    outside = [p for p in changed if not p.startswith("brain/") and Path(p).name != "__init__.py"]
    selected, why = [], {}
    for name, path in test_modules.items():
        reasons = []
        if name in changed_tests:
            reasons.append("the test changed")
        text = path.read_text()
        uses = imported(path, name, known_all) | named(text, known)
        reasons += sorted(m for m in uses & touched)
        reasons += sorted(f"imports {m}" for m in uses & changed_tests if m != name)
        reasons += sorted(f"names {p}" for p in outside if p in text or Path(p).name in text)
        if reasons:
            rel = path.relative_to(ROOT).as_posix()
            selected.append(rel)
            why[rel] = reasons
    return {"everything": False, "touched": sorted(touched), "tests": sorted(selected), "why": why}


# ---------------------------------------------------------------- model runners

SWIFT_NAME = re.compile(r"[\w./-]+\.swift")


def runner_inputs(runner: Path) -> dict:
    """The files a Swift model runner compiles, from the .swift names in it.

    A bare name ("WallLink.swift") is looked for in the app, then Shared,
    then scripts. A name that matches nothing is a scratch file the runner
    writes itself (main.swift, Checks.swift), or a file that was deleted;
    "names" keeps every one so a deleted input still selects its runner.
    """
    text = runner.read_text()
    files = {runner.relative_to(ROOT).as_posix()}
    names = set(SWIFT_NAME.findall(text))
    for name in names:
        for base in ("", "tessera/", "tessera/Tessera/", "tessera/Shared/", "scripts/"):
            if (ROOT / base / name).is_file():
                files.add((Path(base) / name).as_posix())
                break
    patterns = []
    if "glob('*.swift')" in text or 'glob("*.swift")' in text:
        patterns.append("tessera/Tessera/*.swift")
    for other in re.findall(r"^from (test_\w+) import", text, re.M):
        files.add(f"scripts/{other}.py")
    return {"files": sorted(files), "patterns": patterns, "names": sorted(Path(n).name for n in names),
            "simulator": "simctl" in text, "json": bool(re.search(r"""["']--json["']""", text))}


def select_runners(changed: list[str]) -> list[dict]:
    chosen = []
    for runner in sorted(RUNNERS.glob("test_*.py")):
        inputs = runner_inputs(runner)
        hits = [p for p in changed if p in inputs["files"]
                or any(Path(p).match(pattern) and p.count("/") == pattern.count("/") for pattern in inputs["patterns"])
                or (p.endswith(".swift") and not (ROOT / p).exists() and Path(p).name in inputs["names"])]
        if hits:
            chosen.append({"runner": runner.relative_to(ROOT).as_posix(), "because": hits,
                           "simulator": inputs["simulator"], "json": inputs["json"]})
    return chosen


# ---------------------------------------------------------------- UI suites

def affected_pages(changed: list[str], data: dict) -> tuple[list[str], dict]:
    core = [p for p in changed if matches(p, data["core"])]
    pages = {}
    for key in data["pages"]:
        hits = [p for p in changed if matches(p, page_files(key, data))]
        if hits:
            pages[key] = hits
    return core, pages


def select_suites(changed: list[str], data: dict, core: list[str], pages: dict) -> list[dict]:
    chosen = []
    for suite, spec in data["suites"].items():
        harness = [p for p in changed if matches(p, spec["files"])]
        hit_pages = sorted(set(spec["pages"]) & set(pages))
        if not (core or harness or hit_pages):
            continue
        classes = spec.get("classes", {})
        # A changed test file is its own class (HealthInteractionTests.swift
        # holds HealthInteractionTests); any other harness change is shared.
        own = {c for c in classes for p in harness if Path(p).stem == c.split("/")[-1]}
        shared = [p for p in harness if not any(Path(p).stem == c.split("/")[-1] for c in classes)]
        covered = {page for c in classes for page in classes[c]}
        whole = bool(core or shared or not classes or any(page not in covered for page in hit_pages))
        picked = [] if whole else sorted(own | {c for c, keys in classes.items() if set(keys) & set(hit_pages)})
        because = (["core: " + ", ".join(core[:3])] if core else []) + \
                  [f"page {page}" for page in hit_pages] + [f"harness {p}" for p in harness]
        chosen.append({"suite": suite, "whole": whole, "classes": picked, "because": because})
    return chosen


# ---------------------------------------------------------------- captures

def batches(named: list[str]) -> list[Path]:
    """Batch folders that record sources somewhere, plus any named."""
    found = []
    for batch in sorted((ROOT / "qa").glob("batch-*")):
        rel = batch.relative_to(ROOT).as_posix()
        if rel in named or batch.name in named:
            found.append(batch)
            continue
        for folder in case_folders(batch):
            if '"sources"' in (folder / "manifest.json").read_text():
                found.append(batch)
                break
    return found


def select_captures(changed: list[str], data: dict, named: list[str], working_tree: bool) -> dict:
    out = {}
    for batch in batches(named):
        rel = batch.relative_to(ROOT).as_posix()
        if working_tree:
            result = check_batch(batch, data)
            out[rel] = {"stale": result["stale"], "unknown": result["unknown"], "by": "hash"}
            continue
        hit = []
        for folder in case_folders(batch):
            name = folder.relative_to(batch).as_posix()
            if name.startswith("before/"):
                continue
            manifest = json.loads((folder / "manifest.json").read_text())
            depends = set()
            for record in records(manifest):
                depends.update(record.get("sources", {}))
                if isinstance(record.get("source_keys"), list):
                    depends.update(files_for(record["source_keys"], data))
            if not depends:
                keys = keys_for_case(folder.name, data)
                depends = set(files_for(keys, data)) if keys else set()
            if any(matches(p, depends) for p in changed):
                hit.append(name)
        out[rel] = {"stale": hit, "unknown": [], "by": "path"}
    return out


# ---------------------------------------------------------------- report

def uncovered(changed: list[str], data: dict, tests: dict, runners: list[dict]) -> list[str]:
    """App and brain files that no page, runner or test claims."""
    known = set(data["core"])
    for key in data["pages"]:
        known.update(page_files(key, data))
    runner_files = {f for r in RUNNERS.glob("test_*.py") for f in runner_inputs(r)["files"]}
    touched = set(tests.get("touched", []))
    out = []
    for path in changed:
        # App sources, build settings and the brain. The project file,
        # Info.plist and the app's entitlements are core in qa/deps.json; the
        # extensions' plists and entitlements are not, so they are named
        # here. Tools and design files draw no screen, and brain tests are
        # selected on their own.
        app = path.startswith(("tessera/Tessera/", "tessera/Shared/", "tessera/TesseraWidgets/", "tessera/TesseraShare/",
                               "tessera/Tessera.xcodeproj/")) or \
            (path.startswith("tessera/") and path.count("/") == 1 and path.endswith((".plist", ".entitlements")))
        if not (app or path.startswith("brain/")) or path.startswith("brain/tests/"):
            continue
        if matches(path, known) or path in runner_files:
            continue
        if module_of(path) in touched or tests.get("everything"):
            continue
        if path.startswith("brain/") and not path.endswith(".py"):
            continue
        out.append(path)
    return out


def run(tests: dict, runners: list[dict], with_simulator: bool, out=sys.stdout) -> int:
    """The brain tests and the runners at once: pytest mostly waits on
    sockets and timers, the runners mostly compile, so they overlap well.
    Progress goes to out (stderr under --json)."""
    env = dict(os.environ)
    env.setdefault("DEVELOPER_DIR", "/Applications/Xcode-beta.app/Contents/Developer")
    scratch = Path(tempfile.mkdtemp(prefix="tessera-affected-"))
    jobs = []
    if tests["tests"]:
        target = ["brain/tests"] if tests["everything"] else tests["tests"]
        jobs.append(("brain tests", [sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider", *target]))
    for r in runners:
        if r["simulator"] and not with_simulator:
            print(f"skipped {r['runner']}: it needs a simulator (--with-simulator)", file=out)
            continue
        command = [sys.executable, r["runner"]]
        if r["json"]:
            command += ["--json", str(scratch / (Path(r["runner"]).stem + ".json"))]
        if "test_media.py" in r["runner"] or "test_record_render.py" in r["runner"]:
            command += ["--output", str(scratch / Path(r["runner"]).stem)]
        jobs.append((r["runner"], command))

    def one(job):
        label, command = job
        done = subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True)
        return label, done

    failed = 0
    with ThreadPoolExecutor(max_workers=4) as pool:
        for label, done in pool.map(one, jobs):
            last = (done.stdout.strip().splitlines() or [""])[-1]
            print(f"{'ok  ' if done.returncode == 0 else 'FAIL'} {label}: {last}", file=out, flush=True)
            if done.returncode:
                failed += 1
                print((done.stdout + done.stderr)[-2000:], file=out)
    print(f"{len(jobs) - failed} of {len(jobs)} passed; runner JSON in {scratch}", file=out)
    return 1 if failed else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", default="HEAD", help="compare against this commit (default HEAD)")
    parser.add_argument("--head", help="compare --base with this commit instead of the working tree")
    parser.add_argument("--batch", action="append", default=[], help="also check this batch folder's captures")
    parser.add_argument("--direct", action="store_true",
                        help="select brain tests by direct imports only, without following brain's own imports "
                             "(quicker, and misses tests broken through a module in between)")
    parser.add_argument("--json", action="store_true", help="print the selection as JSON")
    parser.add_argument("--verbose", action="store_true", help="name every capture case, not counts per page")
    parser.add_argument("--run", action="store_true", help="run the selected brain tests and model runners")
    parser.add_argument("--all", action="store_true",
                        help="select every brain test and model runner, whatever changed (the check before a push)")
    parser.add_argument("--with-simulator", action="store_true", help="with --run, also run runners that need a simulator")
    args = parser.parse_args()

    data = deps()
    changed = changed_files(args.base, args.head)
    tests = select_brain_tests(changed, data, not args.direct)
    runners = select_runners(changed)
    if args.all:
        tests = {"everything": True, "because": ["--all"],
                 "tests": sorted(t.relative_to(ROOT).as_posix() for t in TESTS.glob("test_*.py"))}
        runners = [{"runner": r.relative_to(ROOT).as_posix(), "because": ["--all"],
                    **{k: v for k, v in runner_inputs(r).items() if k in ("simulator", "json")}}
                   for r in sorted(RUNNERS.glob("test_*.py"))]
    core, pages = affected_pages(changed, data)
    suites = select_suites(changed, data, core, pages)
    captures = select_captures(changed, data, args.batch, working_tree=not args.head)
    harness = [p for p in changed if matches(p, data["qa_harness"])]
    loose = uncovered(changed, data, tests, runners)

    if args.json:
        print(json.dumps({"base": args.base, "head": args.head or "working tree", "changed": changed,
                          "brain_tests": tests, "model_runners": runners, "core": core, "pages": pages,
                          "ui_suites": suites, "captures": captures, "qa_harness_changed": harness,
                          "uncovered": loose}, indent=2))
        return run(tests, runners, args.with_simulator, out=sys.stderr) if args.run else 0

    against = f"{args.base}..{args.head}" if args.head else f"working tree against {args.base}"
    print(f"{len(changed)} changed files ({against})")
    total = len(list(TESTS.glob("test_*.py")))
    if tests["everything"]:
        print(f"\nBrain tests: all {total}, because of {', '.join(tests['because'])}")
    else:
        print(f"\nBrain tests: {len(tests['tests'])} of {total}")
        for test in tests["tests"]:
            print(f"  {test}  ({', '.join(tests['why'][test])})")
    print(f"\nModel runners: {len(runners)} of {len(list(RUNNERS.glob('test_*.py')))}")
    for r in runners:
        print(f"  {r['runner']}{'  [simulator]' if r['simulator'] else ''}  ({', '.join(r['because'][:3])})")
    print(f"\nUI suites: {len(suites)} of {len(data['suites'])}"
          + (f" (core changed: {', '.join(core[:4])})" if core else ""))
    for s in suites:
        # A receipt per run, outside qa/, so a partial run never replaces
        # the batch's full native-interactions receipt.
        stem = Path(s["suite"]).stem
        if s["whole"]:
            print(f'  scripts/qa/{s["suite"]} --app <Tessera.app> --output "$TMPDIR/{stem}.json"'
                  f"  ({'; '.join(s['because'][:4])})")
        for c in s["classes"]:
            pages = data["suites"][s["suite"]]["classes"][c]
            because = [b for b in s["because"] if b.removeprefix("page ") in pages or c.split("/")[-1] in b]
            print(f'  scripts/qa/{s["suite"]} --app <Tessera.app> --only-testing {c} '
                  f'--output "$TMPDIR/{stem}-{c.split("/")[-1]}.json"  ({"; ".join(because[:4])})')
    for batch, found in captures.items():
        label = "stale or unknown by hash" if found["by"] == "hash" else "depend on a changed file"
        cases = found["stale"] + found["unknown"]
        print(f"\nCaptures in {batch}: {len(cases)} cases {label}")
        # A long list reads better as counts per page; --verbose names them.
        if len(cases) > 12 and not args.verbose:
            groups = {}
            for name in cases:
                keys = keys_for_case(name, data) or ["no page"]
                groups.setdefault(f"{name.split('/')[0]}/{keys[0]}", []).append(name)
            print("  " + ", ".join(f"{group} {len(names)}" for group, names in sorted(groups.items())))
        else:
            for name in cases:
                print(f"  {name}")
        if cases and batch.endswith("batch-17"):
            print("  rerun: .venv/bin/python scripts/qa/capture_batch17.py --stale" if found["by"] == "hash" else
                  "  (between commits this is a forecast; stale_captures.py hashes the files you have)")
    if harness:
        print(f"\nQA harness changed ({', '.join(harness)}): captures do not record it, so recapture "
              "what uses it if its output changed.")
    if loose:
        print(f"\nNo page, runner or brain test covers these ({len(loose)}): {', '.join(loose)}")
        print("  Check them by hand, or add them to a page in qa/deps.json if a captured screen shows them.")
    return run(tests, runners, args.with_simulator) if args.run else 0


if __name__ == "__main__":
    sys.exit(main())
