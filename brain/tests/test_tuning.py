"""The tuning store: its copy, what it reports, and the renderer's restart.

Every Tuning here writes its launch-flag files and tuning.json under
tmp_path, and finds and kills a fake art_display (conftest.py), so none of
this reaches the real renderer or its files.

    .venv/bin/python -m pytest brain/tests/test_tuning.py -q
"""
import re
import threading
import time
from types import SimpleNamespace

import pytest

from brain import tuning
from brain.art import pipeline
from brain.tuning import BUSY, GROUPS, SPECS, Tuning


class Renderer:
    """The sink's status(), held still: attached or not, how many times one
    has attached, how long since it went away."""

    def __init__(self, attached=True, connects=1, detached_s=None):
        self.attached, self.connects, self.detached_s = attached, connects, detached_s

    def __call__(self):
        return {"attached": self.attached, "connects": self.connects,
                "detached_s": None if self.attached else self.detached_s,
                "pending_s": None}


class Clock:
    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t


@pytest.fixture
def clock(monkeypatch):
    c = Clock()
    monkeypatch.setattr(tuning, "_clock", c)
    return c


def ears(**parts):
    """An ear with every part the store can configure, less the ones named
    None."""
    def nothing(**_):
        return None
    ear = SimpleNamespace(configure=nothing, knocks=SimpleNamespace(configure=nothing),
                          library=SimpleNamespace(configure=nothing), _library_kept=None,
                          teacher=SimpleNamespace(configure=nothing),
                          voice=SimpleNamespace(configure=nothing, wake=None, transcriber=None))
    for name, value in parts.items():
        setattr(ear, name, value)
    return ear


# ---- the copy -----------------------------------------------------------------

GROUP_KEYS = {key for key, *_ in GROUPS}
NAMES_KEPT = {"Discogs", "Shazam", "iTunes", "Claude"}
FORBIDDEN = (";", "—", "–", "·", "×")


def test_every_knob_has_label_unit_applies_and_a_known_group():
    assert len(SPECS) == 41
    for spec in SPECS:
        assert spec.label and spec.note, spec.name
        assert spec.unit is None or spec.unit.strip() == spec.unit != "", spec.name
        assert spec.applies in tuning.APPLIES, spec.name
        assert spec.group in GROUP_KEYS, spec.name
        # a launch flag shows once the renderer is back, nothing else does
        assert (spec.applies == "restart") == spec.restart, spec.name
        if spec.group in ("Hearing", "Voice"):
            assert spec.applies == "listening", spec.name


def test_copy_follows_house_rules():
    texts = [s.label for s in SPECS] + [s.note for s in SPECS]
    texts += [t for _, title, summary, _, _ in GROUPS for t in (title, summary)]
    texts += list(tuning.NEEDS.values())
    texts += [tuning.NO_MIC, tuning.NO_VOICE, tuning.NO_KNOCKS, tuning.NO_LIBRARY, BUSY]
    for text in texts:
        for mark in FORBIDDEN:
            assert mark not in text, (mark, text)
    for spec in SPECS:
        words = spec.label.split()
        assert words[0][0].isupper(), spec.label
        for word in words[1:]:
            assert word in NAMES_KEPT or word == word.lower(), spec.label
    # the wall is a thing, not someone
    for text in texts:
        assert not re.search(r"\bthe wall('s)? (listens|keeps|hears|thinks|wants|knows)\b",
                             text, re.I), text


def test_groups_cover_every_knob_and_have_a_tab():
    used = {s.group for s in SPECS}
    assert used == GROUP_KEYS
    for key, title, summary, tab, pattern in GROUPS:
        assert tab in ("picture", "listening"), key
        assert title and summary
        if tab == "listening":
            assert pattern is None, key
        else:
            assert pattern in ("wall", "greys", "darkSteps", "darkColours", "bars", "grid"), key


def test_groups_match_the_apps_built_in_copy():
    """TuningGroup.builtIn in the app carries the same copy, for a brain too
    old to send its groups, so a new brain and an old one read the same."""
    from pathlib import Path
    swift = (Path(__file__).resolve().parents[2] / "tessera/Tessera/TuningStore.swift").read_text()
    for key, title, summary, tab, pattern in GROUPS:
        assert f'TuningGroup(key: "{key}", title: "{title}", summary: "{summary}"' in swift, key


def test_panel_copy_reads_plainly():
    notes = {s.name: s for s in SPECS}
    # a plain number, not "0.20 step"
    assert notes["dither_min"].unit is None
    panel = next(summary for key, _, summary, *_ in GROUPS if key == "Panel")
    assert "Restarts panel badge" in panel and "blank it" not in panel
    # the two dark end cuts say how they differ: per colour everywhere, or a
    # whole pixel on pictures only
    assert "Each colour" in notes["black_point"].note
    assert "everything the wall shows" in notes["black_point"].note
    assert "whole pixel" in notes["pic_black"].note
    assert "Only album art, video and the test patterns" in notes["pic_black"].note
    assert notes["black_point"].note != notes["pic_black"].note


def test_public_keeps_the_fields_older_apps_read():
    t = Tuning({})
    body = t.public()
    assert set(body["values"]) == set(body["defaults"]) == {s.name for s in SPECS}
    for knob in body["knobs"]:
        assert {"name", "group", "kind", "min", "max", "step", "restart", "note"} <= set(knob)
        assert {"label", "unit", "applies"} <= set(knob)
    assert isinstance(body["restarting"], bool)
    assert [g["key"] for g in body["groups"]] == [key for key, *_ in GROUPS]
    # public() hands out copies: a caller adding to them changes nothing here
    body["defaults"]["extra"] = 1
    assert "extra" not in t.defaults


def test_specs_still_unpack_by_position_for_older_fixtures():
    keys = ["name", "group", "kind", "min", "max", "step", "restart", "note"]
    knob = dict(zip(keys, SPECS[0]))
    assert knob["name"] == "bit_depth" and knob["restart"] is True


# ---- inactive knobs ---------------------------------------------------------------

def test_nearest_colour_is_inactive_while_time_dithering():
    t = Tuning({})
    t.update({"temporal_dither": True})
    assert t.public()["inactive"]["nearest_colour"].startswith("Not used while time dithering")
    assert "dither_min" not in t.public()["inactive"]


def test_dither_min_is_inactive_without_time_dithering():
    t = Tuning({})
    t.update({"temporal_dither": False})
    inactive = t.public()["inactive"]
    assert inactive["dither_min"] == "Used only when Time dithering is on."
    assert "nearest_colour" not in inactive


def test_hearing_knobs_are_inactive_without_ears():
    inactive = Tuning({}).public()["inactive"]
    for spec in SPECS:
        if spec.group in ("Hearing", "Voice"):
            assert inactive[spec.name] == "This wall has no microphone.", spec.name


def test_voice_knobs_are_inactive_without_a_voice():
    t = Tuning({})
    t.ears = ears(voice=None)
    inactive = t.public()["inactive"]
    for name in ("wake", "wake_threshold", "speech_base"):
        assert inactive[name] == "Voice is not set up on this wall."
    assert "listen_for" not in inactive


def test_knock_knobs_are_inactive_without_a_knock_ear():
    t = Tuning({})
    t.ears = ears(knocks=None)
    t.update({"knock": False})
    inactive = t.public()["inactive"]
    # one reason each, the stronger one first
    for name in ("knock", "knock_sensitivity", "whistle"):
        assert inactive[name] == "Knocks and whistles are off on this wall."


def test_dependent_knobs_name_the_switch_they_need():
    t = Tuning({})
    t.ears = ears()
    t.update({"knock": False, "teach": False, "wake": False})
    inactive = t.public()["inactive"]
    assert inactive["knock_sensitivity"] == "Used only when Two knocks is on."
    assert inactive["teach_by_ear"] == inactive["teach_match_score"] == \
        "Used only when Song library first is on."
    assert inactive["wake_threshold"] == "Used only when Wake word is on."
    assert "teach" not in inactive and "knock" not in inactive


def test_no_library_outranks_the_teach_switch():
    t = Tuning({})
    t.ears = ears(library=None, _library_kept=None)
    t.update({"teach": False})
    inactive = t.public()["inactive"]
    for name in ("teach", "teach_by_ear", "teach_match_score"):
        assert inactive[name] == "The song library is off on this wall."


def test_a_live_ear_with_everything_on_leaves_the_listening_knobs_active():
    t = Tuning({})
    t.ears = ears()
    inactive = t.public()["inactive"]
    assert not any(s.name in inactive for s in SPECS if s.group in ("Hearing", "Voice"))


# ---- the renderer --------------------------------------------------------------------

def test_renderer_states(clock, renderer_process):
    t = Tuning({})
    assert t.public()["renderer"] == {"state": "absent", "down_s": None}
    r = Renderer()
    t.renderer = r
    assert t.renderer_state()["state"] == "running"
    renderer_process.pids = [4242]
    t.restart_renderer()
    r.attached, r.detached_s = False, 0.4
    assert t.renderer_state() == {"state": "restarting", "down_s": 0.0}
    assert t.public()["restarting"] is True
    clock.t += 3
    r.attached, r.connects = True, r.connects + 1          # it came back
    assert t.renderer_state() == {"state": "running", "down_s": None}
    assert t.public()["restarting"] is False
    t.restart_renderer()
    r.attached, r.detached_s = False, 0.2
    assert t.renderer_state()["state"] == "restarting"
    clock.t += 21                                          # and did not come back
    assert t.renderer_state() == {"state": "stalled", "down_s": 21.0}
    t._restart = None                                      # no restart asked for
    r.detached_s = 3.0
    assert t.renderer_state() == {"state": "starting", "down_s": 3.0}
    r.detached_s = 16.0
    assert t.renderer_state() == {"state": "stopped", "down_s": 16.0}


def test_restart_knob_is_refused_while_restarting_and_nothing_changes(clock, renderer_process, tmp_path):
    t = Tuning({})
    r = Renderer()
    t.renderer = r
    renderer_process.pids = [4242]
    t.update({"bit_depth": 48})
    assert renderer_process.kills == [4242]
    r.attached, r.detached_s = False, 0.5
    saved = (tmp_path / "bit-depth").read_text()
    with pytest.raises(RuntimeError, match="still restarting"):
        t.update({"bit_depth": 32, "black_point": 9})
    assert t.get("bit_depth") == 48 and t.get("black_point") == 0
    assert (tmp_path / "bit-depth").read_text() == saved
    assert renderer_process.kills == [4242]


def test_the_same_restart_value_again_is_not_a_change(clock, renderer_process):
    t = Tuning({})
    r = Renderer()
    t.renderer = r
    renderer_process.pids = [4242]
    t.update({"bit_depth": 48})
    r.attached = False
    changed, rejected, restart = t.update({"bit_depth": 48})
    assert changed == {} and restart is False


def test_live_knob_is_still_accepted_while_restarting(clock, renderer_process):
    t = Tuning({})
    r = Renderer()
    t.renderer = r
    renderer_process.pids = [4242]
    t.update({"panel_type": 3})
    r.attached, r.detached_s = False, 0.5
    changed, rejected, restart = t.update({"gain_r": 0.9})
    assert changed == {"gain_r": 0.9} and not restart and not rejected


def test_reset_and_restart_are_refused_while_restarting(clock, renderer_process):
    t = Tuning({})
    r = Renderer()
    t.renderer = r
    renderer_process.pids = [4242]
    t.update({"black_point": 7})
    t.restart_renderer()
    r.attached = False
    with pytest.raises(RuntimeError):
        t.restart_renderer()
    with pytest.raises(RuntimeError):
        t.reset()
    assert t.get("black_point") == 7 and renderer_process.kills == [4242]


def test_a_renderer_starting_after_boot_holds_launch_flags_too(renderer_process):
    t = Tuning({})
    t.renderer = Renderer(attached=False, connects=0, detached_s=4.0)
    with pytest.raises(RuntimeError):
        t.update({"temporal_dither": False})
    t.renderer = Renderer(attached=False, connects=0, detached_s=40.0)   # stopped
    assert t.update({"temporal_dither": False})[2] is True


def test_restart_is_recorded_only_when_a_renderer_was_found(clock, renderer_process):
    t = Tuning({})
    t.renderer = Renderer()
    assert t.restart_renderer() == "the renderer was not running"
    assert t._restart is None and renderer_process.kills == []
    assert t.renderer_state()["state"] == "running"


def test_restart_with_no_renderer_clears_the_marker_and_reports_stopped(clock, renderer_process):
    """systemd gave up: the renderer is gone and a restart finds nothing to
    kill. The old marker must not keep the state at stalled forever."""
    t = Tuning({})
    r = Renderer()
    t.renderer = r
    renderer_process.pids = [4242]
    t.restart_renderer()
    r.attached, r.detached_s = False, 30.0
    clock.t += 30
    assert t.renderer_state()["state"] == "stalled"
    renderer_process.pids = []
    assert t.restart_renderer() == "the renderer was not running"
    assert t.renderer_state() == {"state": "stopped", "down_s": 30.0}


def test_the_guard_lets_only_one_of_two_racing_restarts_through(clock, renderer_process, monkeypatch):
    t = Tuning({})
    r = Renderer()
    t.renderer = r
    renderer_process.pids = [4242]

    def slow_find():
        time.sleep(0.2)                      # a slow pgrep widens the window
        return [4242]

    monkeypatch.setattr(tuning, "find_renderer", slow_find)
    outcomes = []

    def change(value):
        try:
            t.update({"bit_depth": value})
            outcomes.append("ok")
        except RuntimeError:
            outcomes.append("busy")

    threads = [threading.Thread(target=change, args=(v,)) for v in (32, 48)]
    for th in threads:
        th.start()
    for th in threads:
        th.join(5)
    assert sorted(outcomes) == ["busy", "ok"]
    assert renderer_process.kills == [4242]


def test_launch_flag_files_are_written_under_ROOT(tmp_path):
    t = Tuning({})
    t.update({"panel_type": 5, "temporal_dither": False})
    assert (tmp_path / "panel-type").read_text() == "5"
    assert (tmp_path / "temporal-dither").read_text() == "0"
    assert tuning.ROOT == str(tmp_path)


def test_a_live_knob_leaves_the_launch_flag_files_alone(tmp_path):
    t = Tuning({})
    flag = tmp_path / "bit-depth"
    flag.write_text("sentinel")
    t.update({"black_point": 5})
    assert flag.read_text() == "sentinel"
    t.update({"dither": 0.4})                  # a file knob: all six rewritten
    assert flag.read_text() == "64"


def test_video_tone_target_reaches_the_player():
    t = Tuning({})
    t.video = SimpleNamespace(tone_target=112, unsharp_radius=None, unsharp_percent=None)
    t.update({"video_tone_target": 80})
    assert t.video.tone_target == 80


def test_defaults_do_not_drift_after_a_tuned_store():
    """apply() writes the pipeline's constants, and _shipped used to read them
    back as the defaults. A store built after a tuned one kept its tuning as
    the default."""
    first = Tuning({})
    first.update({"black_point": 12, "low_red": 0.8})
    assert pipeline.BLACK_POINT == 12
    second = Tuning({})
    assert second.defaults["black_point"] == 0
    assert second.defaults["low_red"] == 1.0


def test_describe_matches_public_without_building_a_store():
    t = Tuning({})
    t.renderer = Renderer()
    built = t.public()
    described = tuning.describe(t.values, t.defaults, renderer={"state": "running", "down_s": None})
    assert described == built
