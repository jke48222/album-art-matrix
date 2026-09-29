"""GET /health: what the phone's Wall health page reads off the computer.

The page is read-only and polls every ten seconds, so everything here has to
be cheap and has to answer. Each reader is pointed at a fixture file or a
fake process, the throttle bits are decoded one by one (power and heat must
not be confused, and older phones must read the old two flags unchanged),
and the frame counts are driven with an injected clock.

    .venv/bin/python -m pytest brain/tests/test_health.py -q
"""
import subprocess
import time

import pytest

from brain import control
from brain.control import ControlState, _throttle_detail
from brain.main import _FrameTee


@pytest.fixture(autouse=True)
def fresh_caches(monkeypatch):
    """The throttle and yt-dlp answers are kept at module level. Each test
    starts with neither."""
    monkeypatch.setattr(control, "_THROTTLED", [None, None])
    monkeypatch.setattr(control, "_YTDLP", [None, None])


# ---- the throttle bits -------------------------------------------------------

def test_no_bits_is_all_clear():
    detail = _throttle_detail(0)
    assert detail["raw"] == "0x0"
    assert not any(v for k, v in detail.items() if k != "raw")


def test_low_power_now_and_earlier_is_told_apart_from_heat():
    detail = _throttle_detail(0x50005)
    assert detail["undervolt_now"] and detail["throttled_now"]
    assert detail["undervolt_ever"] and detail["throttled_ever"]
    assert detail["now"] and detail["ever"]
    assert not detail["capped_now"] and not detail["capped_ever"]
    assert not detail["soft_temp_now"] and not detail["soft_temp_ever"]


def test_the_soft_temperature_limit_leaves_the_old_flags_as_they_were():
    """now and ever mean the low three bits and their since-boot copies, as
    they always did. The soft limit is bit 3, so an older phone still reads
    no throttling while a newer one sees the heat."""
    detail = _throttle_detail(0x80008)
    assert detail["soft_temp_now"] and detail["soft_temp_ever"]
    assert detail["now"] is False and detail["ever"] is False


def test_no_vcgencmd_is_none_and_is_not_asked_again_at_once(monkeypatch):
    calls = []

    def run(*args, **kwargs):
        calls.append(args[0])
        raise FileNotFoundError("vcgencmd")

    monkeypatch.setattr(control.subprocess, "run", run)
    assert control._read_throttled(now=1000.0) is None
    assert control._read_throttled(now=1003.0) is None
    assert len(calls) == 1
    assert control._read_throttled(now=1006.0) is None
    assert len(calls) == 2


def test_vcgencmd_answer_is_decoded(monkeypatch):
    monkeypatch.setattr(control.subprocess, "run", lambda *a, **k: subprocess.CompletedProcess(
        a[0], 0, stdout="throttled=0x50005\n", stderr=""))
    assert control._read_throttled(now=1.0)["undervolt_now"] is True


# ---- the other readers --------------------------------------------------------

def test_temperature_comes_from_the_thermal_zone(tmp_path, monkeypatch):
    zone = tmp_path / "temp"
    zone.write_text("54231\n")
    monkeypatch.setattr(control, "THERMAL_PATH", str(zone))
    assert control._read_temp() == 54.2
    monkeypatch.setattr(control, "THERMAL_PATH", str(tmp_path / "missing"))
    assert control._read_temp() is None


def test_memory_is_total_and_available_in_mb(tmp_path, monkeypatch):
    info = tmp_path / "meminfo"
    info.write_text("MemTotal:        1013760 kB\nMemFree:          90000 kB\n"
                    "MemAvailable:     421888 kB\nBuffers:          1000 kB\n")
    monkeypatch.setattr(control, "MEMINFO_PATH", str(info))
    assert control._read_memory() == {"total_mb": 990, "available_mb": 412}
    info.write_text("MemTotal:        1013760 kB\nMemFree:          90000 kB\n")
    assert control._read_memory() is None
    monkeypatch.setattr(control, "MEMINFO_PATH", str(tmp_path / "missing"))
    assert control._read_memory() is None


def test_computer_uptime_is_the_first_field(tmp_path, monkeypatch):
    up = tmp_path / "uptime"
    up.write_text("12345.67 890.12\n")
    monkeypatch.setattr(control, "UPTIME_PATH", str(up))
    assert control._boot_seconds() == 12345
    monkeypatch.setattr(control, "UPTIME_PATH", str(tmp_path / "missing"))
    assert control._boot_seconds() is None


def test_storage_is_in_gb_with_free_under_total(tmp_path):
    disk = control._read_storage(str(tmp_path))
    assert disk["total_gb"] > 0 and disk["free_gb"] >= 0
    assert disk["free_gb"] <= disk["total_gb"]


def test_storage_falls_back_to_home_when_the_state_folder_is_missing(tmp_path):
    assert control._read_storage(str(tmp_path / "not-made-yet"))["total_gb"] > 0


# ---- the temperature log -------------------------------------------------------

def test_a_temperature_a_minute_for_the_last_hour(monkeypatch):
    ctrl = ControlState()
    readings = iter(50.0 + i / 10 for i in range(1000))
    monkeypatch.setattr(control, "_read_temp", lambda: next(readings))
    start = time.monotonic() - 7200
    for second in range(0, 7200, 20):             # the loop passes every 20 s
        ctrl.sample_vitals(now=start + second)
    assert len(ctrl.temp_log) == 60                # an hour, one a minute
    stamps = [t for t, _ in ctrl.temp_log]
    assert all(b - a == pytest.approx(60) for a, b in zip(stamps, stamps[1:]))
    log = ctrl.health()["temp_log"]
    assert len(log) == 60
    ages = [age for age, _ in log]
    assert ages == sorted(ages, reverse=True)      # oldest first
    assert ages[0] == pytest.approx(time.monotonic() - stamps[0], abs=1.5)
    assert log[-1][1] == round(ctrl.temp_log[-1][1], 1)


def test_no_sensor_is_an_empty_log(monkeypatch):
    ctrl = ControlState()
    monkeypatch.setattr(control, "_read_temp", lambda: None)
    ctrl.sample_vitals(now=10.0)
    ctrl.sample_vitals(now=100.0)
    assert ctrl.health()["temp_log"] == []


def test_a_reader_that_fails_cannot_stop_the_loop(monkeypatch):
    ctrl = ControlState()

    def boom():
        raise RuntimeError("sensor")

    monkeypatch.setattr(control, "_read_temp", boom)
    ctrl.sample_vitals(now=1.0)                    # does not raise
    assert list(ctrl.temp_log) == []


# ---- the frame rates -------------------------------------------------------------

def test_the_paced_reading_says_how_old_it_is():
    ctrl = ControlState()
    assert ctrl.health()["fps_age_s"] is None
    ctrl.fps_last, ctrl.fps_at, ctrl.fps_target = 59.6, time.monotonic() - 3, 60.0
    body = ctrl.health()
    assert body["fps"] == 59.6 and body["fps_target"] == 60.0
    assert body["fps_age_s"] == pytest.approx(3, abs=0.3)


def test_a_still_face_is_zero_frames_not_an_old_brain():
    """0.0 is falsy, and `round(x) or None` would turn a still sleeve into
    a brain that does not report the field at all."""
    ctrl = ControlState()
    assert ctrl.health()["sent_fps"] is None       # nothing wired: not reported
    ctrl.frames_sent_rate = lambda: 0.0
    assert ctrl.health()["sent_fps"] == 0.0


class RecordingSink:
    def __init__(self):
        self.shown, self.brightness, self.dither = 0, None, None

    def show(self, rgb888, pre_wb_img=None):
        self.shown += 1


class Clock:
    def __init__(self, t=0.0):
        self.t = t

    def __call__(self):
        return self.t


def tee_on(clock, sink=None):
    ctrl = ControlState(frame_len=64 * 64 * 3)
    tee = _FrameTee(sink or RecordingSink(), ctrl, 64)
    tee._clock = clock
    tee._win = (clock(), 0, 0.0, None)
    return tee


def test_frames_handed_to_the_panels_are_counted_a_second():
    clock = Clock()
    tee = tee_on(clock)
    frame = bytes(64 * 64 * 3)
    for i in range(60):                            # 60 frames over 2.5 s
        clock.t = i * 2.5 / 59
        tee.show(frame)
    assert tee.sent_rate() == pytest.approx(59 / 2.5, rel=0.05)
    clock.t = 12.5                                 # then ten still seconds
    assert tee.sent_rate() < 0.5


def test_nothing_shown_yet_is_zero():
    assert tee_on(Clock()).sent_rate() == 0.0


def test_a_slow_face_reads_as_slow_not_as_still():
    """The imagine hold sends two frames a second and a sleep fade one. A
    window that has not closed is read as it stands."""
    clock = Clock()
    tee = tee_on(clock)
    for i in range(10):
        clock.t = i * 1.0
        tee.show(bytes(64 * 64 * 3))
    clock.t = 9.5
    assert 0.5 < tee.sent_rate() <= 1.5


def test_renderer_status_passes_through_or_is_none():
    assert tee_on(Clock()).renderer_status() is None

    class WithStatus(RecordingSink):
        def status(self):
            return {"attached": True, "connects": 2, "detached_s": None, "pending_s": None}

    assert tee_on(Clock(), WithStatus()).renderer_status()["connects"] == 2


def test_a_renderer_status_that_fails_leaves_health_answering():
    ctrl = ControlState()

    def boom():
        raise OSError("pipe")

    ctrl.renderer_status = boom
    body = ctrl.health()
    assert body["renderer"] is None and "fps" in body


# ---- yt-dlp is asked rarely ---------------------------------------------------------

def test_yt_dlp_is_asked_once_not_on_every_poll(monkeypatch):
    from brain.video import ytdlp
    spawned = []
    monkeypatch.setattr(ytdlp, "binary", lambda: "/opt/fake/yt-dlp")
    real = subprocess.run

    def run(args, *rest, **kwargs):
        if "yt-dlp" in args[0]:
            spawned.append(args)
            return subprocess.CompletedProcess(args, 0, stdout="2026.09.01\n", stderr="")
        return real(args, *rest, **kwargs)

    monkeypatch.setattr(subprocess, "run", run)
    ctrl = ControlState()
    answers = [ctrl.health()["ytdlp"] for _ in range(3)]
    assert answers == ["2026.09.01"] * 3
    assert len(spawned) == 1


def test_yt_dlp_is_asked_again_after_ten_minutes(monkeypatch):
    asked = []
    from brain.video import ytdlp
    monkeypatch.setattr(ytdlp, "version", lambda: asked.append(1) or "1")
    control._ytdlp_version(now=0.0)
    control._ytdlp_version(now=599.0)
    assert len(asked) == 1
    control._ytdlp_version(now=601.0)
    assert len(asked) == 2


# ---- the whole reading --------------------------------------------------------------

def test_health_keeps_every_old_key_and_adds_the_new_ones():
    body = ControlState().health()
    old = {"fps", "temp_c", "throttled", "uptime_s", "loop_age_s", "quiet_s", "idle",
           "mode", "ytdlp"}
    new = {"fps_age_s", "fps_target", "sent_fps", "temp_log", "boot_s", "renderer",
           "memory", "storage"}
    assert old | new <= set(body)


# ---- the QA wall's authored readings ------------------------------------------------

def test_the_qa_health_presets_are_in_the_brains_own_schema(tmp_path):
    """scripts/qa/serve_setup.py serves these to the app, and the phone's
    model test decodes them. They must be bodies this brain could send."""
    import json
    from pathlib import Path
    from brain.sinks.pi_renderer import PiRendererSink

    presets = json.loads((Path(__file__).resolve().parents[2]
                          / "scripts" / "qa" / "health_fixtures.json").read_text())
    keys = set(ControlState().health())
    status_keys = set(PiRendererSink(str(tmp_path / "no.fifo")).status())
    assert "steady" in presets and "legacy" in presets
    # a Pi at 82°C has hit its soft temperature limit, and says so
    hot = presets["hot"]["throttled"]
    assert hot["soft_temp_now"] and hot["soft_temp_ever"] and not hot["undervolt_now"]
    for name, body in presets.items():
        if name == "legacy":
            # a brain from before: only the keys it had, and the old flags
            assert set(body) < keys and set(body["throttled"]) == {"now", "ever"}
            continue
        assert set(body) == keys, name
        throttled = body["throttled"]
        if throttled is not None:
            assert throttled == _throttle_detail(int(throttled["raw"], 16)), name
        renderer = body["renderer"]
        if renderer is not None:
            assert set(renderer) == status_keys, name
            assert (renderer["detached_s"] is None) == renderer["attached"], name
        ages = [age for age, _ in body["temp_log"]]
        assert ages == sorted(ages, reverse=True) and len(ages) <= 60, name
        if ages:
            assert ages[-1] < 60 and body["temp_c"] == body["temp_log"][-1][1], name
        if body["memory"] is not None:
            assert set(body["memory"]) == {"total_mb", "available_mb"}, name
        if body["storage"] is not None:
            assert set(body["storage"]) == {"total_gb", "free_gb"}, name
