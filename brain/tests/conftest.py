"""Keeps the tests off the real wall's files.

brain/control.py and brain/tuning.py name their state files as module
constants under ~/.config/album-art-matrix. Anything that builds a
ControlState reads control.json, and the first apply() writes it, so a test
run on this machine would quietly overwrite the state the wall came back with
and append to its journal. The fixture below is autouse: every test in this
directory gets tmp paths whether it asks or not, because the failure mode is
silent and the file is the owner's.

    .venv/bin/python -m pytest brain/tests -q
"""
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))


@pytest.fixture(autouse=True)
def _never_the_real_config(tmp_path, monkeypatch):
    """Point every on-disk path the brain keeps state in at tmp_path."""
    from brain import control

    monkeypatch.setattr(control, "STATE_PATH", str(tmp_path / "control.json"))
    monkeypatch.setattr(control, "JOURNAL_PATH", str(tmp_path / "journal.jsonl"))

    # tuning.py and services.py keep their own files beside those two, both
    # under the name PATH.
    for mod, leaf in (("brain.tuning", "tuning.json"), ("brain.services", "services.json")):
        m = __import__(mod, fromlist=["x"])
        monkeypatch.setattr(m, "PATH", str(tmp_path / leaf))
    yield


def pytest_configure(config):
    config.addinivalue_line(
        "markers",
        "features(**switches): build the ControlState with these [features] "
        "switches, e.g. @pytest.mark.features(note=False)")
