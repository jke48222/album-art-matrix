"""Credential changes cannot publish stale AI actions or mutate another shelf."""
import json
import threading
from types import SimpleNamespace

import pytest

from brain.ask import Asker
from brain.tests.test_ask_notes_batch import asker  # noqa: F401
from brain.tests.test_shelf_batch import create, item


def test_removed_key_discards_delayed_answer_and_history(asker):
    value, _ = asker
    started, finish = threading.Event(), threading.Event()
    original = value._client.messages.create
    def request(**kw):
        started.set(); assert finish.wait(3)
        return original(**kw)
    value._client.messages.create = request
    replies = []
    thread = threading.Thread(target=lambda: replies.append(value.ask_reply("A question")))
    thread.start(); assert started.wait(3)
    value.configure(api_key="")
    finish.set(); thread.join(3)
    assert not thread.is_alive()
    assert replies[0]["answer"] is None and "changed" in replies[0]["error"]
    assert not value.history and value.answers == 0 and value.problem is None
    assert value.status()["ready"] is False and not value.pending


def test_removed_key_cannot_apply_delayed_tool_action(asker):
    value, _ = asker
    started, finish = threading.Event(), threading.Event()
    calls = []
    def request(**kw):
        started.set(); assert finish.wait(3)
        return SimpleNamespace(stop_reason="tool_use", usage=SimpleNamespace(input_tokens=1, output_tokens=1),
                               content=[SimpleNamespace(type="tool_use", name="set_face", id="1", input={"face": "off"})])
    value._client.messages.create = request
    value._run_tool = lambda *args: calls.append(args)
    thread = threading.Thread(target=lambda: value.ask_reply("Turn it off"))
    thread.start(); assert started.wait(3)
    value.configure(api_key="replacement-key")
    finish.set(); thread.join(3)
    assert not thread.is_alive() and calls == [] and value.last is None


def test_replaced_key_does_not_inherit_old_authentication_failure(asker):
    value, module = asker
    started, finish = threading.Event(), threading.Event()
    def request(**kw):
        started.set(); assert finish.wait(3)
        raise module.AuthenticationError("old rejected key")
    value._client.messages.create = request
    thread = threading.Thread(target=lambda: value.ask_reply("A question"))
    thread.start(); assert started.wait(3)
    value.configure(api_key="replacement-key")
    finish.set(); thread.join(3)
    assert not thread.is_alive() and value.problem is None and value.ready


def test_provider_exception_body_never_reaches_public_status(asker):
    value, _ = asker
    secret = "sk-ant-this-is-a-secret-key"
    def request(**kw): raise RuntimeError(f"Bad request with Authorization {secret}")
    value._client.messages.create = request
    assert value.ask_reply("Hi")["answer"] is None
    assert secret not in json.dumps(value.status())


def test_workspace_required_error_has_actionable_secret_free_status(asker):
    value, module = asker
    error = module.APIStatusError("workspace required; private-token")
    error.status_code = 400
    def request(**kw): raise error
    value._client.messages.create = request
    value.ask_reply("Hi")
    assert "workspace ID" in value.problem and "private-token" not in value.problem


def test_identical_credential_save_does_not_cancel_active_generation(asker):
    value, _ = asker
    generation, client = value._generation, value._client
    value.configure(api_key=" test-key ", workspace="")
    assert value._generation == generation and value._client is client


def test_discogs_disconnect_keeps_cached_collection_across_restart(tmp_path):
    shelf = create(tmp_path); shelf.sync()
    original = shelf.releases.copy(), shelf.synced_at
    shelf.configure(token="")
    assert (shelf.releases, shelf.synced_at) == original
    assert shelf.status()["token_set"] is False and not shelf.status()["syncing"]
    assert shelf.request_sync() is None
    from brain.shelf import Shelf
    restored = Shelf(None, token="", user="collector", path=shelf.path)
    assert (restored.releases, restored.synced_at) == original
    assert restored.match("Blue", "Joni Mitchell") is not None


def test_discogs_sync_progress_describes_received_pages(tmp_path, monkeypatch):
    monkeypatch.setattr("brain.shelf.PACE_S", 0)
    reads = []
    shelf = None
    def fetch(path, params):
        reads.append(shelf.status())
        return {"pagination": {"pages": 3}, "releases": [item(params["page"])]}
    shelf = create(tmp_path, fetch)
    assert shelf.sync() == 3
    assert [(s["pages_read"], s["releases_read"]) for s in reads] == [(0, 0), (1, 1), (2, 2)]
    status = shelf.status()
    assert status["pages_read"] == status["pages_total"] == 3 and status["releases_read"] == 3
    assert not status["syncing"]


def test_discogs_disconnect_during_read_does_not_replace_local_records(tmp_path):
    shelf = create(tmp_path); shelf.sync()
    started, finish = threading.Event(), threading.Event()
    def fetch(*args):
        started.set(); assert finish.wait(3)
        return {"releases": [item(2, "A different record")]}
    shelf._fetch = fetch
    thread = threading.Thread(target=shelf.sync); thread.start(); assert started.wait(3)
    shelf.configure(token="")
    finish.set(); thread.join(3)
    assert not thread.is_alive() and [r["id"] for r in shelf.releases] == [1]
    assert not shelf.status()["syncing"] and shelf.status()["pages_read"] == 0


def test_discogs_account_switch_drops_inflight_pressing_details(tmp_path, monkeypatch):
    monkeypatch.setattr("brain.shelf.PACE_S", 0)
    shelf = create(tmp_path); shelf.sync()
    started, finish = threading.Event(), threading.Event()
    calls = []
    def fetch(path, params):
        calls.append(path); started.set(); assert finish.wait(3)
        return {"country": "Old account", "notes": "private"}
    shelf._fetch = fetch
    thread = threading.Thread(target=lambda: shelf.enrich(1)); thread.start(); assert started.wait(3)
    shelf.configure(user="new-account")
    finish.set(); thread.join(3)
    assert not thread.is_alive() and shelf._details == {} and shelf._prices == {}
    assert len(calls) == 1 and shelf.releases == []
    disk = json.loads(open(shelf.path).read())
    assert disk["user"] == "new-account" and disk["details"] == {}


def test_discogs_disconnected_enrichment_never_contacts_provider(tmp_path):
    shelf = create(tmp_path); shelf.sync(); shelf.configure(token="")
    shelf._fetch = lambda *args: pytest.fail("Disconnected account must not send provider requests")
    assert shelf.enrich(1)["title"] == "Blue"


@pytest.mark.parametrize("bad", [{}, {"basic_information": {"id": None}}, {"basic_information": {"id": True}},
                                  {"basic_information": {"id": 2, "artists": [{"name": 12}]}}])
def test_discogs_malformed_release_keeps_last_good_cache(tmp_path, bad):
    shelf = create(tmp_path); shelf.sync()
    shelf._fetch = lambda *args: {"releases": [bad]}
    shelf.sync()
    assert [r["id"] for r in shelf.releases] == [1] and shelf.problem


def test_discogs_queued_enrichment_ignores_replaced_account(tmp_path):
    shelf = create(tmp_path); shelf.sync()
    generation = shelf._generation
    shelf.configure(user="new-owner")
    shelf._fetch = lambda *args: pytest.fail("Old worker must not read with new account credentials")
    assert shelf.enrich(1, expected_generation=generation) == {"release_id": 1}


def test_discogs_rate_limit_retry_stops_after_token_removal(tmp_path, monkeypatch):
    shelf = create(tmp_path)
    calls = []
    response = SimpleNamespace(status_code=429, headers={"Retry-After": "1"})
    monkeypatch.setattr("brain.shelf.requests.get", lambda *args, **kwargs: calls.append(args) or response)
    monkeypatch.setattr("brain.shelf.time.sleep", lambda delay: shelf.configure(token=""))
    with pytest.raises(InterruptedError):
        shelf._http_get("/releases/1")
    assert len(calls) == 1
