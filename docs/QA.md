# Checking a redesign batch

The checks for a batch run in two stages. Between fixes, rerun only what the
change touches. Before a push, run everything once.

## Between fixes

    .venv/bin/python scripts/qa/affected.py
    .venv/bin/python scripts/qa/affected.py --run

`affected.py` reads the working tree against HEAD (or `--base REF`) and lists:

- the brain tests that import a changed module, directly or through other
  brain modules, or that name a changed file;
- the Swift model runners (`scripts/test_*.py`) that compile a changed file;
- the native UI suites, and for the setup suite the test classes, whose pages
  use a changed file;
- the batch captures whose recorded sources no longer match.

`--run` runs the brain tests and model runners it picked. It prints the UI
suite and capture commands but does not run them.

To recapture only what went stale, rebuild and install the app on the capture
simulator, then run:

    .venv/bin/python scripts/qa/stale_captures.py qa/batch-17
    .venv/bin/python scripts/qa/capture_batch17.py --stale

Each capture records the sha256 of the files its page depends on. The page
map is `qa/deps.json`: core files that every screen uses, one entry per page,
and the pages each UI suite covers. A page lists the files it renders and
the views that route to it. If a new file is used by a page, add it there.
`affected.py` names changed app files that no page claims.

A capture stops before launch if one of its sources is newer than the
installed build. Otherwise the screenshot would show old code under new
hashes.

## Before a push

    .venv/bin/python scripts/qa/affected.py --all --run --with-simulator
    .venv/bin/python scripts/qa/run_ui_suites.py --app <Tessera.app> --sims 3

The first runs every brain test and every Swift model runner, about 4.5 min.
The second runs every native UI suite.

`run_ui_suites.py` boots a pool of iPhone 17 Pro simulators on iOS 26.5
(`scripts/qa/sim_pool.py`) and installs the app on each. It then runs the
seven suites side by side, each on its own fixture port. The setup suite
takes about two thirds of the test time, so it is split into its five test
classes. A failed test runs once more on its own. If it passes then, it is
reported as flaky and does not fail the run, unless `--strict` is given. The
receipt lists every flaky test by name.

Measured on 2026-09-29 (132 tests):

| Setup | Wall time |
|---|---|
| One simulator, one suite after another | about 75 min |
| 2 simulators | 16.7 min |
| 3 simulators | 12.4 to 14.3 min |

Three simulators produced 2 to 5 flaky tests per run, and two produced 1.
Use `--sims 2` when a clean first try matters more than three minutes.
