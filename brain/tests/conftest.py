"""Keeps the tests off the real wall's files, its renderer and each other.

brain/control.py and brain/tuning.py name their state files as module
constants under ~/.config/album-art-matrix. Anything that builds a
ControlState reads control.json, and the first apply() writes it, so a test
run on this machine would quietly overwrite the state the wall came back with
and append to its journal. The fixture below is autouse: every test in this
directory gets tmp paths whether it asks or not, because the failure mode is
silent and the file is the owner's.

The same goes for the renderer's launch-flag files under ~/album-art-matrix
(both modules write there, as ROOT) and for the renderer itself: a restart
knob makes tuning.py look for art_display and SIGKILL it. That lookup and
that kill are replaced with a recorder for every test, so no test can signal
a real renderer. A test that needs one to be found asks for the
renderer_process fixture and sets its pids.

Tuning.apply also writes art/pipeline.py's module constants, and pytest runs
every test in one process, so those are put back after each test.

    .venv/bin/python -m pytest brain/tests -q
"""
import os
import sys
from types import SimpleNamespace

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

_PIPELINE_GLOBALS = ("BLACK_POINT", "PIC_BLACK", "PIC_FLOOR", "PIC_KNEE", "LOW_END",
                     "LOW_FULL", "LOW_RED", "LOW_BLUE", "NEAREST_COLOUR", "BIT_DEPTH",
                     "PANEL_CAP")


@pytest.fixture(autouse=True)
def _never_the_real_config(tmp_path, monkeypatch):
    """Point every on-disk path the brain keeps state in at tmp_path."""
    from brain import control

    monkeypatch.setattr(control, "STATE_PATH", str(tmp_path / "control.json"))
    monkeypatch.setattr(control, "JOURNAL_PATH", str(tmp_path / "journal.jsonl"))
    monkeypatch.setattr(control, "ROOT", str(tmp_path))

    # tuning.py and services.py keep their own files beside those two, both
    # under the name PATH.
    for mod, leaf in (("brain.tuning", "tuning.json"), ("brain.services", "services.json")):
        m = __import__(mod, fromlist=["x"])
        monkeypatch.setattr(m, "PATH", str(tmp_path / leaf))
    from brain import tuning
    monkeypatch.setattr(tuning, "ROOT", str(tmp_path))
    yield


@pytest.fixture(autouse=True)
def renderer_process(monkeypatch):
    """No test finds or kills a real art_display. pids is what the lookup
    answers (none, unless a test says), kills lists every pid signalled."""
    from brain import tuning

    fake = SimpleNamespace(pids=[], kills=[], looked=0)

    def find():
        fake.looked += 1
        return list(fake.pids)

    monkeypatch.setattr(tuning, "find_renderer", find)
    monkeypatch.setattr(tuning, "stop_renderer", fake.kills.append)
    return fake


@pytest.fixture(autouse=True)
def _pipeline_put_back():
    """Tuning.apply rewrites these module constants. Put them back, so one
    test's tuning is not the next test's default."""
    from brain.art import pipeline

    saved = {name: getattr(pipeline, name) for name in _PIPELINE_GLOBALS}
    yield
    for name, value in saved.items():
        setattr(pipeline, name, value)


def pytest_configure(config):
    config.addinivalue_line(
        "markers",
        "features(**switches): build the ControlState with these [features] "
        "switches, e.g. @pytest.mark.features(note=False)")
