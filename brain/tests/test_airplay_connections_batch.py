"""Receiver truth and pause-clock regressions; only synthetic pipe/process data."""
import threading

import pytest

from brain.nowplaying import airplay as A
from brain.nowplaying import receiver as R


def source(monkeypatch):
    monkeypatch.setattr(A, "_running", lambda: True)
    clock = [100.0]
    src = A.AirPlaySource(pipe="/nonexistent", host="wall.local", clock=lambda: clock[0])
    src.handle("ssnc", "pbeg", b"")
    src.handle("ssnc", "mdst", b"")
    src.handle("core", "minm", b"The Song")
    src.handle("core", "asar", b"The Artist")
    src.handle("core", "asal", b"The Album")
    src.handle("ssnc", "mden", b"")
    src.handle("ssnc", "prgr", b"0/220500/13230000")
    return src, clock


def test_pause_preserves_time_since_last_rtp_record(monkeypatch):
    src, clock = source(monkeypatch)
    clock[0] += 8
    assert src.progress()[0] == 13000
    src.handle("ssnc", "pfls", b"")
    assert src.progress()[0] == 13000
    clock[0] += 90
    assert src.progress()[0] == 13000
    assert src.status()["current"]["progress_ms"] == 13000
    assert src.status()["current"]["is_playing"] is False


@pytest.mark.parametrize("resume", ["prsm", "pffr", "pbeg"])
def test_resume_excludes_paused_interval_without_new_rtp(monkeypatch, resume):
    src, clock = source(monkeypatch)
    clock[0] += 2
    src.handle("ssnc", "pfls", b"")
    clock[0] += 60
    src.handle("ssnc", resume, b"")
    assert src.progress()[0] == 7000
    clock[0] += 4
    assert src.progress()[0] == 11000


def test_duplicate_flush_does_not_advance_clock(monkeypatch):
    src, clock = source(monkeypatch)
    clock[0] += 2
    src.handle("ssnc", "pfls", b"")
    clock[0] += 40
    src.handle("ssnc", "pfls", b"")
    assert src.progress()[0] == 7000
    src.handle("ssnc", "prsm", b"")
    assert src.progress()[0] == 7000


def test_pause_at_end_caps_progress(monkeypatch):
    src, clock = source(monkeypatch)
    clock[0] += 400
    src.handle("ssnc", "pfls", b"")
    assert src.progress() == (300000, 300000)


def test_disconnect_clears_current_and_pending_track(monkeypatch):
    src, _ = source(monkeypatch)
    src.handle("core", "minm", b"Uncommitted old track")
    src.handle("ssnc", "disc", b"")
    assert src.status()["current"] is None
    assert src.status()["last"] is None
    src.handle("ssnc", "pbeg", b"")
    src.handle("ssnc", "mden", b"")
    assert src.get_current() is None


def test_pipe_close_clears_song_while_stream_end_retains_same_stream_metadata(monkeypatch):
    src, _ = source(monkeypatch)
    src.handle("ssnc", "pend", b"")
    assert src.status()["current"] is None
    src.handle("ssnc", "pbeg", b"")
    assert src.status()["current"]["title"] == "The Song"
    src._end()
    src.handle("ssnc", "pbeg", b"")
    assert src.status()["current"] is None


def test_status_discovery_does_not_hold_metadata_lock(monkeypatch):
    src, _ = source(monkeypatch)
    entered, finished = threading.Event(), threading.Event()

    def slow_process_read():
        entered.set()
        assert finished.wait(2)
        return True

    monkeypatch.setattr(A, "_running", slow_process_read)
    thread = threading.Thread(target=src.status)
    thread.start()
    assert entered.wait(2)
    assert src._lock.acquire(timeout=1)
    src._lock.release()
    finished.set()
    thread.join(2)
    assert not thread.is_alive()


def receiver(tmp_path, monkeypatch, *, external=False, on=True, installed=True):
    monkeypatch.setattr(R, "find_binary", lambda _: "/fake/shairport-sync" if installed else None)
    r = R.Receiver("/test/pipe", conf_path=str(tmp_path / "config"),
                   settings=lambda: {"airplay_receiver": on, "airplay_name": "Wall"},
                   sleep=lambda _: None, elsewhere=lambda _: external, log=lambda _: None)
    return r


@pytest.mark.parametrize("installed", [True, False])
@pytest.mark.parametrize("on", [True, False])
def test_external_receiver_is_never_reported_off_or_missing(tmp_path, monkeypatch, installed, on):
    r = receiver(tmp_path, monkeypatch, external=True, installed=installed, on=on)
    r._tick(0)
    status = r.status()
    assert status["state"] == "external"
    assert status["external"] is True
    assert status["controllable"] is False
    assert status["name"] is None
    assert status["port"] is None
    assert status["output"] is None
    assert status["protocol"] is None
    assert r.restart() is False
    assert not r._restart.is_set()


def test_restart_refuses_disabled_receiver(tmp_path, monkeypatch):
    r = receiver(tmp_path, monkeypatch, on=False)
    r._tick(0)
    assert r.status()["state"] == "off"
    assert r.restart() is False


def test_restart_refuses_absent_receiver(tmp_path, monkeypatch):
    r = receiver(tmp_path, monkeypatch, installed=False)
    r._tick(0)
    assert r.status()["state"] == "not_installed"
    assert r.restart() is False


def test_restart_requests_only_managed_enabled_receiver(tmp_path, monkeypatch):
    r = receiver(tmp_path, monkeypatch)
    assert r.restart() is True
    assert r._restart.is_set()
    r._stopping = True
    assert r.restart() is False


@pytest.mark.parametrize("version,protocol", [(None, None), ("4.3.7-dummy-metadata", "classic"), ("4.3.7-AirPlay2-dummy", "airplay2")])
def test_receiver_reports_actual_protocol_and_silent_output(tmp_path, monkeypatch, version, protocol):
    r = receiver(tmp_path, monkeypatch)
    r.version = version
    state = r.status()
    assert state["protocol"] == protocol
    assert state["output"] == "silent"
    assert state["controllable"] is True


def test_uptime_at_monotonic_zero_is_not_missing(tmp_path, monkeypatch):
    r = receiver(tmp_path, monkeypatch)
    r.proc = type("Process", (), {"pid": 123, "poll": lambda _: None})()
    r.started_at = 0
    r._clock = lambda: 12
    assert r.status()["up_s"] == 12
