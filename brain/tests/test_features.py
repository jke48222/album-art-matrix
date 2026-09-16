"""The feature switches, and the rule that a listed switch must do something.

Two of them did not. `note` and `earworm` were in KNOWN, offered in
config.example.toml and returned by GET /features, and nothing anywhere ever
asked `features.on()` for either: a wall with `note = false` still put notes
on the panel, and `earworm = false` was inert while `show = false` quietly
took earworm down with it. Nothing failed, because a switch that is never
consulted breaks nothing. The first test here is the one that would have
said so.

    .venv/bin/python -m pytest brain/tests/test_features.py -q
"""
import os
import pathlib
import re
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.features import KNOWN, Features                       # noqa: E402

BRAIN = pathlib.Path(__file__).resolve().parents[1]


def _asked_switches() -> set[str]:
    """Every name the brain passes to features.on(), read out of the source.

    Source-reading rather than import-and-inspect because a switch is asked
    at the moment its feature acts, which is inside a running wall: threads,
    a microphone, a Pi. The question here is only whether the line exists."""
    asked, call = set(), re.compile(r"""\.on\(\s*["']([a-z_]+)["']\s*\)""")
    table = re.compile(r"""^\s*["']([a-z_]+)["']\s*:""")      # _SWITCHED-style maps
    for py in BRAIN.rglob("*.py"):
        if "tests" in py.parts:
            continue
        text = py.read_text()
        asked |= set(call.findall(text))
        # A route or command table that feeds the name to a switch counts
        # too: control.py's SHOWER_SWITCH and voice.py's _SWITCHED both
        # name the feature in a dict and ask on() with the value.
        if "SWITCHED" in text or "SHOWER_SWITCH" in text:
            for line in text.splitlines():
                m = table.match(line)
                if m:
                    asked.add(m.group(1))
            asked |= set(re.findall(r"""\(\s*["']([a-z_]+)["']\s*,\s*["']""", text))
    return asked


@pytest.mark.parametrize("name", [n for n, _ in KNOWN])
def test_every_known_switch_is_actually_asked(name):
    """A switch nobody asks is a promise the wall does not keep."""
    assert name in _asked_switches(), (
        f'[features] "{name}" is offered in KNOWN and in config.example.toml, '
        f"but nothing in brain/ ever calls features.on({name!r}), so turning "
        f"it off would do nothing. Gate the feature where it acts, or take "
        f"the switch out of KNOWN.")


def test_config_example_offers_exactly_the_known_switches():
    """The commented block in config.example.toml is how anyone finds out a
    switch exists, so it must not drift from KNOWN in either direction."""
    text = (BRAIN.parent / "config.example.toml").read_text()
    # Anchored to a line of its own: other sections mention "[features] x" in
    # their prose, and splitting on the bare word lands in one of those.
    block = re.split(r"^\[features\]$", text, maxsplit=1, flags=re.M)[1]
    block = re.split(r"^\[", block, maxsplit=1, flags=re.M)[0]
    offered = set(re.findall(r"^#\s*([a-z_]+)\s*=", block, re.M))
    assert offered == {n for n, _ in KNOWN}


# ---- the switch itself ------------------------------------------------------

def test_nothing_is_gated_by_default():
    f = Features({})
    assert all(f.on(n) for n, _ in KNOWN)
    assert f.public()["off"] == []


def test_false_is_the_only_thing_that_turns_one_off():
    f = Features({"features": {"note": False, "knock": True, "shelf": 0, "ask": None}})
    assert not f.on("note")
    assert f.on("knock")
    assert f.on("shelf")     # 0 is not False here: only a real false counts
    assert f.on("ask")
    assert f.public()["off"] == ["note"]


def test_a_name_it_has_never_heard_of_is_on():
    """Documented: a switch is for turning a finished thing off, not a hoop
    every new feature has to remember to jump through."""
    f = Features({"features": {}})
    assert f.on("something-built-tomorrow")


def test_it_says_when_the_config_names_a_switch_nobody_has(capsys):
    Features({"features": {"nonsense": False}})
    assert "nonsense" in capsys.readouterr().out


def test_public_describes_every_switch():
    pub = Features({"features": {"games": False}}).public()
    assert {f["name"] for f in pub["features"]} == {n for n, _ in KNOWN}
    assert all(f["what"] for f in pub["features"])
    assert next(f for f in pub["features"] if f["name"] == "games")["on"] is False
