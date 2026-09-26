"""Library ownership, migration and acknowledged operations; no network or audio hardware."""
import json
import threading
from unittest.mock import patch

import numpy as np
import pytest

from brain.nowplaying.teach import Library, Teacher, TeachBusy, RATE, pick_preview


@pytest.fixture
def marks():
    with patch("brain.nowplaying.teach.fingerprint", return_value=(np.arange(30, dtype=np.uint32), np.arange(30, dtype=np.int32))):
        yield


def learn(lib, name="One", **kwargs):
    return lib.learn(np.zeros(RATE * 4, dtype=np.int16), name, "Artist", **kwargs)


def test_repeat_preview_does_not_inflate_votes(tmp_path, marks):
    lib = Library(str(tmp_path))
    learn(lib)
    learn(lib, how="told")
    assert lib.status()["landmarks"] == 30
    assert lib.listing()[0]["how"] == ["preview", "told"]
    assert lib.query(np.zeros(RATE * 4, dtype=np.int16)).score == 30


def test_read_results_cannot_mutate_library(tmp_path, marks):
    lib = Library(str(tmp_path))
    result = learn(lib, art_url="https://example.com/cover.jpg")
    result["how"].append("changed")
    listing = lib.listing()
    listing[0]["title"] = "changed"
    listing[0]["how"].clear()
    match = lib.query(np.zeros(RATE * 4, dtype=np.int16))
    match.song["title"] = "changed"
    status = lib.status()
    status["last_match"]["title"] = "changed"
    assert lib.listing()[0]["title"] == "One"
    assert lib.listing()[0]["how"] == ["preview"]
    assert lib.listing()[0]["art_url"] == "https://example.com/cover.jpg"
    assert lib.status()["last_match"]["title"] == "One"


def test_legacy_library_migrates_as_atomic_snapshot(tmp_path, marks):
    lib = Library(str(tmp_path))
    learn(lib)
    (tmp_path / "songs.json").write_text(json.dumps({"songs": lib.songs, "ids": lib._ids}))
    np.savez(tmp_path / "index.npz", hash=lib._hash, song=lib._song, time=lib._time)
    (tmp_path / "library.npz").unlink()
    legacy = Library(str(tmp_path))
    assert legacy.has("One", "Artist")
    learn(legacy, "Two")
    assert (tmp_path / "library.npz").exists()
    assert len(Library(str(tmp_path)).listing()) == 2


def test_failed_save_rolls_back_membership_and_survives_restart(tmp_path, marks):
    lib = Library(str(tmp_path))
    learn(lib)
    with patch("brain.nowplaying.teach.os.replace", side_effect=OSError("disk full")):
        with pytest.raises(RuntimeError):
            learn(lib, "Two")
        with pytest.raises(RuntimeError):
            lib.forget(Library.song_id("One", "Artist"))
        with pytest.raises(RuntimeError):
            lib.clear()
    assert [x["title"] for x in lib.listing()] == ["One"]
    assert [x["title"] for x in Library(str(tmp_path)).listing()] == ["One"]
    assert lib.problem
    learn(lib, "Two")
    assert lib.problem is None


def test_corrupt_new_snapshot_never_resurrects_legacy_or_overwrites_it(tmp_path, marks):
    (tmp_path / "library.npz").write_bytes(b"broken snapshot")
    lib = Library(str(tmp_path))
    assert lib.problem
    with pytest.raises(RuntimeError, match="could not be read"):
        learn(lib)
    assert (tmp_path / "library.npz").read_bytes() == b"broken snapshot"
    assert not lib.listing()


def test_forgetting_invalidates_pending_learning_and_last_match(tmp_path, marks):
    lib = Library(str(tmp_path))
    learn(lib)
    generation = lib.generation
    assert lib.query(np.zeros(RATE * 4, dtype=np.int16))
    assert lib.forget(Library.song_id("One", "Artist"))
    assert lib.status()["last_match"] is None
    with pytest.raises(RuntimeError, match="changed while learning"):
        learn(lib, expected_generation=generation)
    assert lib.listing() == []


def test_single_teacher_admission_includes_manual_jobs(tmp_path, marks):
    entered, release = threading.Event(), threading.Event()
    def fetch(*_):
        entered.set()
        assert release.wait(3)
        return np.zeros(RATE * 4, dtype=np.int16), {}
    teacher = Teacher(Library(str(tmp_path)), object(), fetch=fetch)
    job = threading.Thread(target=lambda: teacher.learn_named("One", "Artist"))
    job.start()
    assert entered.wait(3)
    assert teacher.status()["learning"] == "Artist — One"
    with pytest.raises(TeachBusy):
        teacher.learn_named("Two", "Artist")
    release.set(); job.join(3)
    assert not job.is_alive()
    assert teacher.status()["learning"] is None
    assert teacher.status()["last_learned"]["title"] == "One"
    assert [x["title"] for x in teacher.library.listing()] == ["One"]


def test_learning_errors_release_admission_and_report_problem(tmp_path, marks):
    def fail(*_):
        raise RuntimeError("catalogue unavailable")
    teacher = Teacher(Library(str(tmp_path)), object(), fetch=fail)
    with pytest.raises(RuntimeError, match="catalogue unavailable"):
        teacher.learn_named("One", "Artist")
    assert teacher.status()["learning"] is None
    assert teacher.status()["problem"] == "catalogue unavailable"
    teacher._fetch = lambda *_: (np.zeros(RATE * 4, dtype=np.int16), {})
    assert teacher.learn_named("One", "Artist")
    assert teacher.status()["problem"] is None


@pytest.mark.parametrize("title,artist", [(None, "A"), ("", "A"), ("A", "  "), ("x" * 201, "A")])
def test_invalid_names_do_not_fetch(tmp_path, title, artist):
    def fetch(*_):
        pytest.fail("invalid input reached the network")
    teacher = Teacher(Library(str(tmp_path)), object(), fetch=fetch)
    with pytest.raises(ValueError):
        teacher.learn_named(title, artist)


def test_catalogue_result_needs_nonempty_title_and_artist():
    assert pick_preview([{"wrapperType": "track", "trackName": "", "artistName": "Artist", "previewUrl": "url"}], "One", "Artist") is None
    assert pick_preview([{"wrapperType": "track", "trackName": "One", "artistName": "", "previewUrl": "url"}], "One", "Artist") is None


def test_incomplete_legacy_library_is_not_overwritten(tmp_path, marks):
    (tmp_path / "songs.json").write_text(json.dumps({"songs": {}, "ids": []}))
    lib = Library(str(tmp_path))
    assert "incomplete" in lib.problem
    with pytest.raises(RuntimeError):
        learn(lib)
    assert not (tmp_path / "library.npz").exists()


def test_gets_can_run_while_learning_and_forgetting(tmp_path, marks):
    lib = Library(str(tmp_path))
    failures = []
    def reads():
        try:
            for _ in range(250):
                lib.listing(); lib.status(); lib.has("One", "Artist")
        except Exception as exc:
            failures.append(exc)
    reader = threading.Thread(target=reads)
    reader.start()
    for _ in range(5):
        learn(lib)
        assert lib.forget(Library.song_id("One", "Artist"))
    reader.join(3)
    assert not reader.is_alive() and not failures


def test_truncated_snapshot_reports_problem_instead_of_crashing(tmp_path, marks):
    lib = Library(str(tmp_path))
    learn(lib)
    path = tmp_path / "library.npz"
    path.write_bytes(path.read_bytes()[:90])
    reloaded = Library(str(tmp_path))
    assert reloaded.problem
    assert reloaded.listing() == []
