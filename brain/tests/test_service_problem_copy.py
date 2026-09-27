"""Service problems the phone shows as written: full sentences, no semicolons,
and a code for the one Claude problem the phone acts on."""
from brain.ask import PROBLEM_CODES
from brain.tests.test_ask_notes_batch import asker  # noqa: F401
from brain.tests.test_scrobble import Room, song
from brain.tests.test_shelf_batch import create


def _fail(value, error):
    def request(**kw):
        raise error
    value._client.messages.create = request
    reply = value.ask_reply("A question")
    return reply, value.status()


def test_workspace_code_only_for_the_workspace_request(asker):
    value, module = asker
    needs = module.APIStatusError("workspace required")
    needs.status_code = 400
    assert _fail(value, needs)[1]["problem_code"] == "needs_workspace"
    # A 403 mentions a workspace too, but the workspace field would not fix it.
    forbidden = module.APIStatusError("forbidden")
    forbidden.status_code = 403
    status = _fail(value, forbidden)[1]
    assert "workspace" in status["problem"] and status["problem_code"] == "forbidden"


def test_coded_problems_are_sentences():
    assert "needs_workspace" in PROBLEM_CODES.values()
    for words in PROBLEM_CODES:
        assert words[0].isupper() and words.endswith(".") and ";" not in words


def test_claude_failures_never_publish_fragments(asker):
    value, module = asker
    for error, code in ((module.RateLimitError(), "rate_limited"),
                        (module.APIConnectionError(), "offline"),
                        (module.AuthenticationError(), "refused"),
                        (TimeoutError(), "timeout")):
        value.problem = None
        reply, status = _fail(value, error)
        assert reply["error"] and ";" not in reply["error"]
        # Whether a passing failure marks the connection is ask.py's choice;
        # when it does, it is a coded sentence, never "rate limited".
        if status["problem"] is not None:
            assert status["problem"] in PROBLEM_CODES and status["problem_code"] == code


def test_other_problems_carry_no_code(asker):
    value, _ = asker
    assert value.status()["problem_code"] is None
    value.problem = "Claude could not complete the request. Check the connection and try again."
    assert value.status()["problem_code"] is None


def test_listenbrainz_rate_limit_is_two_sentences(tmp_path):
    room = Room(tmp_path)
    room.answers.append((200, {"valid": True, "user_name": "jalen"}, {}))
    room.current = song(dur=100_000)
    room.answers.append((429, {}, {"X-RateLimit-Reset-In": "40"}))
    room.tick()
    assert room.scr.status()["problem"] == "ListenBrainz is rate limited. Retry in 40 seconds."


def test_discogs_failed_read_has_no_semicolon(tmp_path):
    def fetch(*args):
        raise RuntimeError("provider down")
    shelf = create(tmp_path, fetch)
    shelf.sync()
    assert shelf.problem.endswith("Your previous collection is safe. Try again.")
    assert ";" not in shelf.problem
