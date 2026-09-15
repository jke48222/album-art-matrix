"""The AirPlay receiver run by the brain: its config, finding the unpacked
binary and its libraries, and the watch: start, rename, off, on, a crash,
stop. A shell script stands in for shairport-sync.

    .venv/bin/python -m pytest brain/tests/test_receiver.py -q
"""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.nowplaying import receiver as R      # noqa: E402

FAKE = """#!/bin/sh
if [ "$1" = "-V" ]; then echo "4.3.7-test-dummy-metadata"; exit 0; fi
echo "fake receiver with $@"
echo "warning: could not acquire an MPRIS interface named org.mpris.MediaPlayer2.ShairportSync"
exec sleep 30
"""


def fake_bin(tmp_path):
    base = tmp_path / "opt" / "shairport-sync" / "root"
    (base / "usr" / "bin").mkdir(parents=True)
    lib = base / "usr" / "lib" / "aarch64-linux-gnu"
    lib.mkdir(parents=True)
    (lib / "libconfig.so.11").write_text("")
    b = base / "usr" / "bin" / "shairport-sync"
    b.write_text(FAKE)
    b.chmod(0o755)
    return str(b)


def wait_for(pred, timeout=6.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if pred():
            return True
        time.sleep(0.02)
    return False


def test_config_and_names():
    t = R.config_text('My "Wall"', "/tmp/pipe", 5000)
    assert 'name = "My \\"Wall\\"";' in t and 'output_backend = "dummy";' in t
    assert 'pipe_name = "/tmp/pipe";' in t and 'include_cover_art = "yes";' in t and "port = 5000;" in t
    assert R.clean_name("") == "Wall" and R.clean_name("x" * 60) == "x" * 40 and R.clean_name("a\nb") == "ab"


def test_the_unpacked_binary_and_its_libraries(tmp_path):
    b = fake_bin(tmp_path)
    assert R.find_binary(b) == b
    assert R.lib_path(b).endswith("usr/lib/aarch64-linux-gnu")
    assert R.lib_path("/usr/bin/shairport-sync") == ""


def test_start_rename_off_on_crash_stop(tmp_path):
    b = fake_bin(tmp_path)
    settings = {"airplay_receiver": True, "airplay_name": "Wall"}
    logs = []
    r = R.Receiver("/tmp/test-pipe", settings=lambda: dict(settings), binary=b, conf_path=str(tmp_path / "ss.conf"),
                   sleep=lambda s: time.sleep(min(s, 0.05)), elsewhere=lambda pid: False, log=logs.append).start()
    try:
        assert wait_for(lambda: r.status()["running"])
        st = r.status()
        assert st["name"] == "Wall" and st["installed"] and st["version"] == "4.3.7-test-dummy-metadata"
        assert 'name = "Wall";' in (tmp_path / "ss.conf").read_text()
        first = st["pid"]
        settings["airplay_name"] = "Kitchen Wall"
        assert wait_for(lambda: r.status()["running"] and r.status()["pid"] != first
                        and r.status()["name"] == "Kitchen Wall")
        assert 'name = "Kitchen Wall";' in (tmp_path / "ss.conf").read_text()
        settings["airplay_receiver"] = False
        assert wait_for(lambda: not r.status()["running"] and r.status()["on"] is False)
        settings["airplay_receiver"] = True
        assert wait_for(lambda: r.status()["running"])
        os.kill(r.status()["pid"], 9)                                  # the receiver dies
        assert wait_for(lambda: r.restarts >= 1)
        assert wait_for(lambda: r.status()["running"])                 # and is started again
        assert any("receiver up" in line for line in logs)
        assert not any("MPRIS" in line for line in logs)               # the harmless warning stays quiet
    finally:
        r.stop()
    assert wait_for(lambda: r.proc is None)


def test_not_installed_and_run_by_the_system(tmp_path, monkeypatch):
    monkeypatch.setattr(R, "CANDIDATES", [str(tmp_path / "nothing")])
    r = R.Receiver("/tmp/p", conf_path=str(tmp_path / "c"), sleep=lambda s: None,
                   elsewhere=lambda pid: False, log=lambda s: None)
    r._tick(0)
    assert "install-airplay" in r.problem and not r.status()["installed"]
    b = fake_bin(tmp_path)
    r2 = R.Receiver("/tmp/p", binary=b, conf_path=str(tmp_path / "c2"), sleep=lambda s: None,
                    elsewhere=lambda pid: True, log=lambda s: None)
    r2._tick(0)
    assert r2.external and r2.proc is None and r2.status()["external"]
