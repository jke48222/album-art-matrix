"""Collection reads are acknowledged, account-scoped and atomic across failures."""
import json
import threading

import pytest

from brain.shelf import Shelf, release_from_api


def item(rid=1, title="Blue", artist="Joni Mitchell"):
    return {"basic_information": {"id": rid, "title": title, "artists": [{"name": artist}],
            "formats": [{"name": "Vinyl"}], "labels": [{"name": "Reprise", "catno": "MS 2038"}]}}


def create(tmp_path, fetch=None, user="collector", clock=None):
    return Shelf(None, token="test-token", user=user, path=str(tmp_path / "shelf.json"),
                 fetch=fetch or (lambda *a: {"releases": [item()]}), clock=clock or (lambda: 1000))


def test_read_again_fetches_even_when_collection_is_fresh(tmp_path):
    calls = []
    s = create(tmp_path, lambda *a: (calls.append(a), {"releases": [item()]})[1])
    s.sync()
    at = s.synced_at
    first = s.request_sync()
    assert s.status()["syncing"] is True and s.synced_at == at
    assert s.request_sync() == first
    s.tick()
    assert len(calls) == 2
    assert s.status()["completed_sync_id"] == first
    assert s.status()["syncing"] is False
    assert s.revision == 2


def test_unconfigured_read_is_not_acknowledged(tmp_path):
    s = Shelf(None, path=str(tmp_path / "shelf.json"))
    assert s.request_sync() is None
    assert s.status()["syncing"] is False
    assert s.status()["sync_id"] is None


def test_active_read_taps_coalesce_and_do_not_start_second_provider_call(tmp_path):
    started, finish = threading.Event(), threading.Event()
    calls = []
    def fetch(*args):
        calls.append(args); started.set(); assert finish.wait(2)
        return {"releases": [item()]}
    s = create(tmp_path, fetch)
    request_id = s.request_sync()
    thread = threading.Thread(target=s.tick); thread.start()
    assert started.wait(2)
    assert s.request_sync() == request_id
    assert s.sync() == 0
    assert s.status()["syncing"] is True
    finish.set(); thread.join(2)
    assert not thread.is_alive() and len(calls) == 1
    assert s.completed_sync_id == request_id
    s.tick()
    assert len(calls) == 1


@pytest.mark.parametrize("failure", [PermissionError("bad token"), TimeoutError(), ValueError(), RuntimeError("https://private/?token=secret")])
def test_failed_read_retains_last_good_records_and_date(tmp_path, failure):
    s = create(tmp_path); s.sync()
    before = list(s.releases), s.synced_at
    def fail(*a): raise failure
    s._fetch = fail
    requested = s.request_sync(); s.tick()
    assert (s.releases, s.synced_at) == before
    assert s.completed_sync_id == requested and not s.status()["syncing"]
    assert s.problem and "secret" not in s.problem
    reloaded = create(tmp_path)
    assert reloaded.releases == before[0]


def test_partial_second_page_failure_never_replaces_cache(tmp_path, monkeypatch):
    monkeypatch.setattr("brain.shelf.PACE_S", 0)
    s = create(tmp_path); s.sync()
    def fetch(path, params):
        if params["page"] == 2: raise TimeoutError()
        return {"pagination": {"pages": 2}, "releases": [item(2)]}
    s._fetch = fetch
    s.request_sync(); s.tick()
    assert [r["id"] for r in s.releases] == [1]


@pytest.mark.parametrize("response", [{}, {"releases": {}}, {"releases": [], "pagination": {"pages": -1}}, {"releases": [], "pagination": {"pages": 10001}}])
def test_invalid_response_does_not_erase_collection(tmp_path, response):
    s = create(tmp_path); s.sync()
    s._fetch = lambda *a: response
    s.request_sync(); s.tick()
    assert len(s.releases) == 1 and s.problem


def test_account_change_drops_prior_membership_immediately(tmp_path):
    s = create(tmp_path); s.sync(); s.playing = s.pressing(s.releases[0])
    s.configure(user="new-collector")
    assert s.releases == [] and s.playing is None and s.synced_at is None
    assert s.match("Blue", "Joni Mitchell") is None
    assert s.status()["syncing"] is True
    assert json.loads((tmp_path / "shelf.json").read_text())["user"] == "new-collector"


def test_cache_cannot_load_another_accounts_records(tmp_path):
    s = create(tmp_path); s.sync()
    other = create(tmp_path, user="someone-else")
    assert other.releases == [] and other.synced_at is None


def test_old_accounts_inflight_read_cannot_publish_after_switch(tmp_path):
    started, finish = threading.Event(), threading.Event()
    def fetch(path, params):
        if "/collector/" in path:
            started.set(); assert finish.wait(2)
            return {"releases": [item(1, "Old record")]}
        return {"releases": [item(2, "New record")]}
    s = create(tmp_path, fetch)
    thread = threading.Thread(target=s.sync); thread.start(); assert started.wait(2)
    s.configure(user="new-owner")
    newest = s.status()["sync_id"]
    finish.set(); thread.join(2)
    assert s.releases == [] and s.status()["syncing"]
    s.tick()
    assert [r["id"] for r in s.releases] == [2]
    assert s.completed_sync_id == newest


def test_new_token_preserves_same_accounts_cache_and_forces_read(tmp_path):
    s = create(tmp_path); s.sync()
    before = list(s.releases), s.synced_at
    s.configure(token="replacement-token")
    assert (s.releases, s.synced_at) == before
    assert s.status()["syncing"] is True
    s.tick()
    assert not s.status()["syncing"]


def test_duplicate_pressings_are_one_stable_row_with_copy_count(tmp_path):
    s = create(tmp_path, lambda *a: {"releases": [item(), item(), item(2, "Hejira")]})
    s.sync()
    listing = s.listing([{"album": "Blue", "artist": "Joni Mitchell"}] * 2)
    assert [r["release_id"] for r in listing] == [1, 2]
    assert listing[0]["copies"] == 2 and listing[0]["plays"] == 2
    assert s.status()["releases"] == 3


def test_listing_skips_invalid_release_identifiers(tmp_path):
    s = create(tmp_path)
    s.releases = [release_from_api(item(None)), release_from_api(item(True)), release_from_api(item(-1)), release_from_api(item())]
    assert [r["release_id"] for r in s.listing()] == [1]


def test_user_is_encoded_as_one_url_path_component(tmp_path):
    calls = []
    s = create(tmp_path, lambda path, params: (calls.append(path), {"releases": []})[1], user="collector/other")
    s.sync()
    assert calls == ["/users/collector%2Fother/collection/folders/0/releases"]


def test_empty_successful_collection_clears_old_membership(tmp_path):
    s = create(tmp_path); s.sync()
    s._fetch = lambda *a: {"releases": []}
    s.request_sync(); s.tick()
    assert s.releases == [] and s.problem is None and s.revision == 2

@pytest.mark.parametrize("cache", [[], {"user": "collector", "releases": {}}, {"user": "collector", "releases": [None, 3, {"id": -1}]}])
def test_malformed_cache_is_ignored_without_crashing_startup(tmp_path, cache):
    (tmp_path / "shelf.json").write_text(json.dumps(cache))
    s = create(tmp_path)
    assert s.releases == [] and s.synced_at is None


def test_invalid_cached_date_forces_a_fresh_read(tmp_path):
    (tmp_path / "shelf.json").write_text(json.dumps({"user": "collector", "releases": [], "synced_at": "yesterday"}))
    s = create(tmp_path)
    s.tick()
    assert s.synced_at == 1000 and len(s.releases) == 1

@pytest.mark.parametrize("size", [64, 192, 512])
def test_refresh_current_or_archived_sleeve_adds_and_removes_mark_without_changing_identity(size):
    import numpy as np
    from brain.main import _refresh_shelf_sleeve
    calls = []
    class Collection:
        owned = True
        def note_playing(self, album, artist):
            calls.append((album, artist))
            return {"release_id": 1} if self.owned else None
    shelf = Collection()
    original = np.full((size, size, 3), 140, dtype=np.uint8)
    shown = {"title": "Old song held in Archive", "album": "Archive record", "artist": "Archive artist"}
    marked = _refresh_shelf_sleeve(original, shelf, shown, True)
    assert np.any(marked != original)
    assert np.all(original == 140)
    assert calls == [("Archive record", "Archive artist")]
    assert shown["title"] == "Old song held in Archive"
    shelf.owned = False
    removed = _refresh_shelf_sleeve(original, shelf, shown, True)
    assert np.array_equal(removed, original)
    shelf.owned = True
    disabled = _refresh_shelf_sleeve(original, shelf, shown, False)
    assert np.array_equal(disabled, original)
    assert removed is not original and disabled is not original


def test_refresh_without_sleeve_clears_old_membership_without_making_art():
    from brain.main import _refresh_shelf_sleeve
    class Collection:
        def note_playing(self, album, artist):
            assert album == artist == ""
    assert _refresh_shelf_sleeve(None, Collection(), {}, True) is None
