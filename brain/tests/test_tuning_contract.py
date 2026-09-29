"""What the phone relies on when it counts settings changed from default.

The About page and the Panel tuning page both count knobs whose value is
more than half a step from its default. That only works if every knob has a
default, a positive step, and a default inside its own range, and if bools
travel as 0 to 1 with a step of 1. None of this builds a Tuning, which would
rewrite the pipeline's constants: it reads the registry and the shipped
values as they are.

    .venv/bin/python -m pytest brain/tests/test_tuning_contract.py -q
"""
import json

from brain import tuning
from brain.control import DEFAULTS, _with_ceiling
from brain.tuning import SPECS, _shipped, describe


def test_every_knob_has_a_shipped_value():
    shipped = _shipped({})
    assert {s.name for s in SPECS} <= set(shipped)


def test_every_step_is_positive():
    for s in SPECS:
        assert s.step > 0, s.name


def test_bools_are_zero_to_one_in_steps_of_one():
    for s in SPECS:
        if s.kind == "bool":
            assert (s.lo, s.hi, s.step) == (0, 1, 1), s.name


def test_every_shipped_value_is_inside_its_range():
    shipped = _shipped({})
    for s in SPECS:
        value = float(shipped[s.name])
        assert s.lo <= value <= s.hi, (s.name, value)


def test_values_and_defaults_carry_the_same_keys_over_json():
    """The phone decodes the body, bools as JSON true and false."""
    shipped = _shipped({})
    body = json.loads(json.dumps(_with_ceiling(describe(shipped, shipped),
                                               DEFAULTS["panel_brightness"],
                                               DEFAULTS["panel_brightness"])))
    assert set(body["values"]) == set(body["defaults"])
    assert {k["name"] for k in body["knobs"]} == set(body["values"])
    assert body["knobs"][0]["name"] == "panel_brightness"
    assert body["values"]["panel_brightness"] == body["defaults"]["panel_brightness"] == 160
    for knob in body["knobs"]:
        value = body["values"][knob["name"]]
        if knob["kind"] == "bool":
            assert isinstance(value, bool), knob["name"]
        assert knob["step"] > 0, knob["name"]


def test_the_registry_count_is_the_one_the_pages_expect():
    assert len(tuning.SPECS) == 41
