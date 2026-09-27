"""Review fixes for the games: parked games hold still, the wall's ears leave
a parked game alone, turns and marks match what the boards say, one clue
request per crossword, the wall's hint and wrong marks can be seen at 64,
and plain copy.

    .venv/bin/python -m pytest brain/tests/test_games_review_batch.py -q
"""
import random
import re
import time
from types import SimpleNamespace

import numpy as np
import pytest
from PIL import Image

from brain.games import board, crossword, twentyq
from brain.games import pictionary, quiz, reaction   # noqa: F401  (registers the games)
from brain.games.arcade import Pong, Snake, Tetris, _ARCADE_GLYPHS
from brain.games.connections import Connections
from brain.games.contexto import Contexto
from brain.games.crossword import BUNDLED, PATTERNS, Crossword, fill_grid
from brain.games.heardle import Heardle
from brain.games.host import GameHost
from brain.games.letterboxed import LetterBoxed
from brain.games.parking import ParkedClock
from brain.games.pictures import Reveal, pick_sleeve
from brain.games.spellingbee import SpellingBee
from brain.games.strands import HINT_TILE, Strands
from brain.games.sudoku import Sudoku
from brain.games.whistlebird import WhistleBird
from brain.tests.test_games import FakeCtrl, shown_for

BANNED = re.compile("[—–·×;]")


def host_with(tmp_path, name, options=None, players=None):
    ctrl = FakeCtrl()
    host = GameHost(ctrl, path=str(tmp_path / "games.json"))
    result = host.start(name, options or {}, players)
    assert "error" not in result, result
    return host, ctrl, host.game


def park(ctrl):
    ctrl.s["mode"] = "art"


def unpark(ctrl):
    ctrl.s["mode"] = "game"


# ---- the parked clock ----------------------------------------------------------------------

def test_parked_clock_stands_still_from_the_last_reading_on_the_wall():
    clock = ParkedClock()
    assert clock.now(10.0, False) == 10.0
    assert clock.now(12.0, False) == 12.0
    # Nobody read it between 12 and 40: the park is dated from 12.
    assert clock.now(40.0, True) == 12.0
    assert clock.now(90.0, True) == 12.0
    assert clock.now(100.0, False) == 12.0
    assert clock.now(101.5, False) == 13.5


def test_parked_clock_takes_a_hosted_silence_as_parked_time():
    clock = ParkedClock()
    assert clock.now(10.0, False, hosted=True) == 10.0
    assert clock.now(11.0, False, hosted=True) == 11.0                       # the wall's cadence counts
    # Nothing read it from 11 to 70 and then it was on the wall again: a park
    # that ended with no reading, dated from the last reading on the wall.
    assert clock.now(70.0, False, hosted=True) == 11.0
    assert clock.now(71.0, False, hosted=True) == 12.0
    # A park a reading noticed is taken out once, not again as a silence.
    assert clock.now(90.0, True, hosted=True) == 12.0
    assert clock.now(95.0, False, hosted=True) == 12.0
    assert clock.now(96.0, False, hosted=True) == 13.0
    # A game with no host keeps every second, so a test can jump a fake clock.
    free = ParkedClock()
    assert free.now(10.0, False) == 10.0 and free.now(70.0, False) == 70.0


# ---- the host and the wall's ears -------------------------------------------------------------

def test_wall_voice_leaves_a_parked_game_alone_but_the_phone_session_still_reaches_it(tmp_path):
    host, ctrl, game = host_with(tmp_path, "wordle", {"word": "crane"})
    park(ctrl)
    assert host.hear("clock") is None and host.hear("sleep") is None
    assert game.rows == []                                                   # no guesses burned
    assert host.hear("guess slate", session_id=host.session_id)["marks"]      # the phone's own call
    unpark(ctrl)
    assert host.hear("clock")["marks"] and len(game.rows) == 2                # on the wall it is a guess


def test_parked_contexto_and_reveal_do_not_swallow_commands(tmp_path):
    host, ctrl, _ = host_with(tmp_path, "contexto", {"seed": 1})
    park(ctrl)
    assert host.hear("off") is None


def test_status_sends_at_most_the_hundred_words_the_phone_uses(tmp_path):
    host, _, game = host_with(tmp_path, "sudoku", {"seed": 1})
    game.voice_words = lambda: [f"w{i}" for i in range(2000)]
    assert len(host.status()["voice_words"]) == 100


def test_wordle_and_quiz_never_send_their_answers_as_voice_words(tmp_path):
    host, _, _ = host_with(tmp_path, "wordle", {"word": "crane"})
    assert host.status()["voice_words"] == ["guess"]
    host, _, _ = host_with(tmp_path, "quiz", {"set": 1})
    assert host.status()["voice_words"] == []


# ---- turns, marks and results ----------------------------------------------------------------------

def test_multiplayer_wordle_credits_the_player_whose_turn_it_is(tmp_path):
    host, _, game = host_with(tmp_path, "wordle", {"word": "crane"}, ["Ana", "Ben"])
    host.move("Ana", {"guess": "slate"})
    assert host.status()["game"]["turn"] == "Ben"
    # A shared phone still picked Ana, and the wall's ears have no name at all.
    host.hear("crane")
    assert game.over and game.winner == "Ben"
    assert game.message == "Solved in 2 guesses."
    assert host.scores("wordle")["Ben"]["won"] == 1 and host.scores("wordle")["Ana"]["won"] == 0


def test_single_guess_wordle_message():
    from brain.games.wordle import Wordle
    game = Wordle(None, {"word": "crane"})
    game.setup()
    game.guess("crane", "You")
    assert game.message == "Solved in 1 guess."


@pytest.mark.parametrize("size", [64, 192])
def test_sudoku_wrong_mark_sits_below_the_digit_on_the_chosen_cell_and_the_bottom_row(size):
    game = Sudoku(None, {"seed": 1})
    game.setup()
    blanks = [i for i in range(81) if not game.puzzle[i]]
    targets = [next(i for i in blanks if i >= 72), next(i for i in blanks if 36 <= i < 45)]
    for i in targets:
        game.apply({"cell": i, "digit": next(d for d in range(1, 10) if d != game.solution[i])}, "You")
    assert game.chosen == targets[-1]                                        # the latest mistake is selected
    frame = game.frame_at(size, 0)
    x0, y0, cell = game.board_geometry(size)
    for i in targets:
        r, c = divmod(i, 9)
        box = frame[y0 + r * cell:y0 + (r + 1) * cell, x0 + c * cell:x0 + (c + 1) * cell]
        mark = (box == (255, 167, 143)).all(axis=2)
        glyph = (box == (224, 76, 63)).all(axis=2)
        assert mark.sum() >= 3 and glyph.sum() >= 5 and not (mark & glyph).any()
        assert np.nonzero(mark)[0].min() > np.nonzero(glyph)[0].max()          # under the digit, not on it


def test_sudoku_errors_are_plain_sentences():
    game = Sudoku(None, {"seed": 1})
    game.setup()
    i = next(i for i in range(81) if not game.puzzle[i])
    assert game.apply({"cell": i, "digit": "x"}, "You")["error"] == "Choose a digit from 1 to 9, or 0 to erase."
    with pytest.raises(ValueError, match=r"^A puzzle is 81 digits\. Use 0 or a dot for blanks\.$"):
        Sudoku(None, {"puzzle": "12x"}).setup()


# ---- crossword ------------------------------------------------------------------------------------

def test_a_failed_clue_request_is_made_once_then_the_bundled_puzzle_is_used(monkeypatch):
    calls, fills = [], []
    fallback = Crossword(None, {"set": 0})
    fallback.setup()

    def fake_fill(blacks, rng, by_len, tries=4000, deadline=None):
        fills.append(deadline)
        return dict(fallback.solution) if set(blacks) == set(BUNDLED[0][0]) else None

    monkeypatch.setattr(crossword, "fill_grid", fake_fill)
    host = SimpleNamespace(ctrl=SimpleNamespace(asker=SimpleNamespace(
        ready=True, crossword_clues=lambda words: calls.append(words))))   # None, as the provider reports failure
    game = Crossword(host, {"seed": 1})
    game.setup()
    assert len(calls) == 1 and len(PATTERNS) > 1
    assert all(deadline is not None for deadline in fills)
    assert game.bundled is not None and game.clues == BUNDLED[game.bundled][2]


def test_grid_filling_stops_at_its_deadline():
    started = time.monotonic()
    by_len = {5: ["crane"] * 10}
    assert fill_grid(set(), random.Random(1), by_len, deadline=time.monotonic() - 1) is None
    assert time.monotonic() - started < 0.5


def test_a_slow_fill_falls_back_without_asking_for_clues(monkeypatch):
    calls = []
    monkeypatch.setattr(crossword, "FILL_SECONDS", -1.0)
    host = SimpleNamespace(ctrl=SimpleNamespace(asker=SimpleNamespace(
        ready=True, crossword_clues=lambda words: calls.append(words))))
    game = Crossword(host, {"seed": 1})
    game.setup()
    assert calls == [] and game.bundled is not None


def test_a_new_keyless_round_does_not_repeat_the_last_bundled_grid():
    assert len(BUNDLED) >= 12
    for seed in range(12):
        previous = Crossword(None, {"seed": seed})
        previous.setup()
        host = SimpleNamespace(game=previous)
        again = Crossword(host, {"seed": seed})
        again.setup()
        assert again.bundled != previous.bundled


def test_crossword_messages_are_plain():
    game = Crossword(None, {"set": 0})
    game.setup()
    assert game.message == f"{len(game.slots)} clues." and game.feedback["message"] == "Choose a clue to start."
    for slot in game.slots:
        game.apply({"slot": slot["id"], "word": "".join(game.solution[c] for c in slot["cells"])}, "You")
    assert game.over and game.message == "No checks used." and game.feedback["message"] == "Solved."


def test_crossword_closing_line_counts_checks_instead_of_repeating_solved():
    for checks, line in [(1, "1 check used."), (3, "3 checks used.")]:
        game = Crossword(None, {"set": 0})
        game.setup()
        for _ in range(checks):
            game.apply({"check": True}, "You")
        for slot in game.slots:
            game.apply({"slot": slot["id"], "word": "".join(game.solution[c] for c in slot["cells"])}, "You")
        assert game.over and game.won and game.message == line


# ---- the wall's marks at 64 -----------------------------------------------------------------------

def test_strands_hint_at_64_is_a_lit_tile_and_the_ordered_hint_steps_down():
    game = Strands(None, {"set": 0, "seed": 1})
    game.setup()
    plain = game.frame_at(64, 0).copy()
    game.hinted, game.hint_ordered = game.words[0], False
    hinted = game.frame_at(64, 0).copy()
    game.hint_ordered = True
    ordered = game.frame_at(64, 0).copy()
    x0, y0, step = game.geometry(64)
    boxes = np.zeros((64, 64), bool)
    for r in range(8):
        for c in range(6):
            tx, ty = int(x0 + c * step) - 2, int(y0 + r * step) - 3
            boxes[ty:ty + 7, tx - 1:tx + 6] = True
    changed = (hinted != plain).any(axis=2)
    assert changed.sum() > 0 and not (changed & ~boxes).any()                # no slivers in the gaps
    assert not ((ordered != hinted).any(axis=2) & ~boxes).any()
    path = game.path_of(game.hinted)
    tiles = [tuple(int(v) for v in ordered[int(y0 + r * step) - 3, int(x0 + c * step) - 3]) for r, c in path]
    assert tiles[0] == HINT_TILE and all(sum(a) > sum(b) for a, b in zip(tiles, tiles[1:]))
    assert tuple(int(v) for v in hinted[int(y0 + path[-1][0] * step) - 3, int(x0 + path[-1][1] * step) - 3]) == HINT_TILE


def test_strands_extra_word_messages(monkeypatch):
    from brain.games import strands as strands_module
    game = Strands(None, {"set": 0, "seed": 1})
    game.setup()
    monkeypatch.setattr(strands_module, "common_set", lambda: {"zzzz", "yyyy", "xxxx"})
    game._in_grid = lambda word: True
    assert game.say("zzzz", "You")["extras"] == 1 and game.message == "Not a theme word. 2 more for a hint."
    game.say("yyyy", "You")
    assert game.message == "Not a theme word. 1 more for a hint."
    game.say("xxxx", "You")
    assert game.message == "Hint ready."


def test_spelling_bee_wall_shows_the_whole_rank_at_64(monkeypatch):
    game = SpellingBee(None, {"seed": 1})
    game.setup()
    game.points = max(1, int(game.total * 0.06))                            # Moving Up
    labels = []
    original = board.text_scrolled
    monkeypatch.setattr(board, "text_scrolled", lambda canvas, s, *a, **k: (labels.append(s), original(canvas, s, *a, **k)))
    game.frame_at(64, 0)
    assert labels[0] == "MOVING UP"


def test_finished_spelling_bee_rank_holds_still_and_a_moving_rank_stays_clear_of_the_score(monkeypatch):
    from brain.art.pixelfont import text_width
    game = SpellingBee(None, {"seed": 1})
    game.setup()
    game.points = max(1, int(game.total * 0.03))                            # Good Start, wider than its box
    size, top, margin = 64, 2, 3
    left_of_score = size - margin - text_width(str(game.points), 1)
    for t in (0, 1.5, 2.5, 3.5, 5.0, 6.5):
        frame = game.frame_at(size, t)
        assert not frame[top:top + 7, left_of_score - 6:left_of_score].any()   # a letter's width of dark
    for word in game.answers:
        game.apply({"word": word}, "You")
    labels = []
    original = board.text_scrolled
    monkeypatch.setattr(board, "text_scrolled", lambda canvas, s, *a, **k: (labels.append(s), original(canvas, s, *a, **k)))
    frames = [game.frame_at(size, t) for t in (0, 2, 4)]
    assert labels[0] == "QUEEN"
    assert all(np.array_equal(frames[0][:10], f[:10]) for f in frames[1:])


# ---- parked timed games ---------------------------------------------------------------------------

def test_parked_whistle_bird_pauses_instead_of_crashing(tmp_path):
    host, ctrl, game = host_with(tmp_path, "whistlebird", {"seed": 1})
    clock = [500.0]
    game._clock = lambda: clock[0]
    game.last_t = clock[0]
    assert host.move(None, {"start": True})["started"]
    park(ctrl)
    for _ in range(20):                                                       # the phone's 1 s polls
        clock[0] += 1.0
        host.status()
    assert not game.over and game.phase == "paused"
    assert host.scores("whistlebird") == {}
    assert host.move(None, {"start": True})["error"] == "Return this game to the wall before flying."
    assert host.hear("again") is None and not game.over                      # no voice restart
    unpark(ctrl)
    assert host.move(None, {"start": True})["started"]


def test_parked_reaction_game_hands_the_turn_back_unscored(tmp_path):
    host, ctrl, game = host_with(tmp_path, "reaction", {"rounds": 2, "seed": 1}, ["Ana", "Ben"])
    clock = [1000.0]
    game._clock = lambda: clock[0]
    assert host.move("Ana", {"go": True})["phase"] == "red"
    park(ctrl)
    for _ in range(200):
        clock[0] += 1.0
        host.status()
    assert not game.over and game.phase == "ready" and game.times == {"Ana": [], "Ben": []}
    assert game.message == "Ana: start when you're ready."


def test_reaction_with_no_scored_turns_says_so():
    from brain.games.reaction import ReactionKnock
    game = ReactionKnock(None, {"rounds": 1, "seed": 1})
    game.setup()
    game._clock = lambda: 10.0
    game.begin()
    game._score(None, "missed", "none", "No response this round.")
    assert game.over and game.message == "No turns scored."


def test_parked_quiz_freezes_and_refuses_answers_then_carries_on(tmp_path):
    host, ctrl, game = host_with(tmp_path, "quiz", {"set": 1, "seconds": 20}, ["Ana", "Ben"])
    clock = [0.0]
    game._clock = lambda: clock[0]
    game.t_q = 0.0
    clock[0] = 5.0
    assert host.status()["game"]["seconds_left"] == 15
    park(ctrl)
    for _ in range(60):
        clock[0] += 1.0
        state = host.status()["game"]
    assert state["phase"] == "question" and state["seconds_left"] == 15 and state["paused"]
    assert host.hear("canberra", "Ana", session_id=host.session_id)["error"] == "Return the quiz to the wall to answer."
    clock[0] += 1.0
    unpark(ctrl)
    host.frame_at(64)                                                         # the wall's next frame ends the park
    clock[0] += 1.0
    state = host.status()["game"]
    assert state["phase"] == "question" and state["seconds_left"] == 14 and not state["paused"]


def test_a_quiz_parked_with_nobody_polling_is_frozen_by_resume(tmp_path):
    host, ctrl, game = host_with(tmp_path, "quiz", {"set": 1, "seconds": 20})
    clock = [0.0]
    game._clock = lambda: clock[0]
    game.t_q = 0.0
    clock[0] = 3.0
    host.frame_at(64)                                                         # the wall renders it
    park(ctrl)
    clock[0] = 300.0                                                          # no polls at all
    host.resume(host.session_id)
    clock[0] = 301.0
    state = host.status()["game"]
    assert state["phase"] == "question" and state["number"] == 1 and state["seconds_left"] == 16


def test_quiz_draw_message_has_no_dash(tmp_path):
    host, _, game = host_with(tmp_path, "quiz", {"set": 1}, ["Ana", "Ben"])
    for _ in range(10):
        host.move(None, {"next": True})
        host.move(None, {"next": True})
    assert game.over and game.message.startswith("Draw. ") and not BANNED.search(game.message)


class Drawer:
    ready = True

    def draw(self, *args, on_partial=None, **kwargs):
        return Image.new("RGB", (640, 640), (46, 92, 117))


def test_parked_pictionary_keeps_its_minute(tmp_path):
    host, ctrl, game = host_with(tmp_path, "pictionary", {"imaginer": Drawer(), "word": "elephant", "seconds": 60})
    for _ in range(400):
        if game.t0 is not None and not game.drawing:
            break
        time.sleep(0.005)
    clock = [game.t0]
    game._clock = lambda: clock[0]
    shown_for(host, clock, 10.0)
    assert host.status()["game"]["remaining"] == 50
    park(ctrl)
    for _ in range(120):
        clock[0] += 1.0
        state = host.status()["game"]
    assert not game.over and state["remaining"] == 50 and state["paused"]
    assert host.hear("elephant", session_id=host.session_id)["error"] == "Return the picture to the wall to guess."
    unpark(ctrl)
    assert host.hear("elephant")["hit"] and game.won


def test_pictionary_copy():
    from brain.games.pictionary import Pictionary
    with pytest.raises(ValueError, match=r"^Choose a short word or phrase using letters A to Z\.$"):
        Pictionary(None, {"imaginer": Drawer(), "word": "x1"}).setup()


def test_parked_cover_reveal_countdown_holds(tmp_path):
    y, x = np.mgrid[:64, :64]
    path = tmp_path / "sleeve.png"
    Image.fromarray(np.stack((x * 4, y * 4, (x + y) * 2), axis=-1).astype(np.uint8)).save(path)
    host, ctrl, game = host_with(tmp_path, "reveal", {"image": str(path), "album": "Blonde", "artist": "Frank Ocean",
                                                    "title": "Nights", "seconds": 30})
    clock = [100.0]
    game.t0 = 100.0
    game._clock = lambda: clock[0]
    host.status()
    park(ctrl)
    clock[0] = 131.0
    state = host.status()
    assert not state["game"]["over"] and host.scores("reveal") == {}
    unpark(ctrl)
    host.frame_at(64)                                                         # the wall's next frame ends the park
    shown_for(host, clock, 10.0)
    assert host.status()["game"]["remaining"] == 20


# ---- parks that end without the host ----------------------------------------------------------
# A knock, a word, a timer and the phone all move the wall in and out of game
# mode through the controller alone. Nothing reads the game while it is away,
# so only the silence says it was parked.

def real_wall(tmp_path):
    from brain.control import ControlState
    ctrl = ControlState(frame_len=64 * 64 * 3)
    host = GameHost(ctrl, path=str(tmp_path / "games.json"))
    ctrl.games = host
    return ctrl, host


def on_fake_clock(game, start):
    clock = [start]
    game._clock = lambda: clock[0]
    game._park = ParkedClock()                                                # no readings from the real clock
    return clock


def test_a_quiz_knocked_off_and_woken_by_a_word_keeps_its_question(tmp_path):
    from brain.voice.voice import Voice
    ctrl, host = real_wall(tmp_path)
    host.start("quiz", {"set": 1, "seconds": 20})
    game = host.game
    clock = on_fake_clock(game, 0.0)
    game.t_q = game._now()
    shown_for(host, clock, 3.0)
    assert not host.event("double", {})                                      # the quiz does not take knocks
    assert ctrl.knock_toggle("two knocks") == "off"                           # so the wall goes off
    clock[0] = 120.0                                                          # and nobody polls
    voice = Voice(ctrl, None, None, log=lambda s: None)
    assert voice.say("turn the wall on")
    for _ in range(400):
        if ctrl.get()["mode"] == "game":
            break
        time.sleep(0.005)
    assert ctrl.get()["mode"] == "game" and voice.last_command == "Command(on)"
    host.frame_at(64)                                                         # the wall's next frame
    state = host.status()["game"]
    assert state["phase"] == "question" and state["number"] == 1 and state["seconds_left"] == 17
    shown_for(host, clock, 1.0)
    assert host.status()["game"]["seconds_left"] == 16


def test_a_cover_reveal_sent_away_and_back_by_the_phone_is_not_run_out(tmp_path):
    y, x = np.mgrid[:64, :64]
    path = tmp_path / "sleeve.png"
    Image.fromarray(np.stack((x * 4, y * 4, (x + y) * 2), axis=-1).astype(np.uint8)).save(path)
    ctrl, host = real_wall(tmp_path)
    host.start("reveal", {"image": str(path), "album": "Blonde", "artist": "Frank Ocean", "title": "Nights",
                          "seconds": 30})
    game = host.game
    clock = on_fake_clock(game, 100.0)
    game.t0 = 100.0
    shown_for(host, clock, 5.0)
    ctrl.apply({"mode": "clock"})                                             # POST /state from the phone
    clock[0] = 200.0
    ctrl.apply({"mode": "game"})
    host.frame_at(64)
    state = host.status()["game"]
    assert not state["over"] and state["remaining"] == 25 and host.scores("reveal") == {}
    shown_for(host, clock, 25.0)                                              # on the wall it still runs out
    assert game.over and not game.won and host.scores("reveal")["You"]["played"] == 1


def test_pictionary_under_a_timer_keeps_its_minute(tmp_path):
    ctrl, host = real_wall(tmp_path)
    host.start("pictionary", {"imaginer": Drawer(), "word": "elephant", "seconds": 60})
    game = host.game
    for _ in range(400):
        if game.t0 is not None and not game.drawing:
            break
        time.sleep(0.005)
    clock = on_fake_clock(game, game.t0)
    shown_for(host, clock, 10.0)
    ctrl.apply({"timer_min": 1})                                              # a countdown takes the wall
    assert ctrl.get()["mode"] == "timer"
    clock[0] += 300.0
    ctrl.apply({"timer_action": "stop", "timer_id": ctrl.timer["id"]})        # and hands it back
    assert ctrl.get()["mode"] == "game"
    host.frame_at(64)
    state = host.status()["game"]
    assert not game.over and state["remaining"] == 50 and not state["paused"]
    assert host.hear("elephant")["hit"] and game.won


def test_picture_game_start_errors_are_sentences():
    ctrl = SimpleNamespace(journal_read=lambda n: [], now_showing={})
    with pytest.raises(RuntimeError, match=r"^No sleeve in the journal yet\. Play something first\.$"):
        pick_sleeve(SimpleNamespace(ctrl=ctrl), random.Random(1), 64, {})


# ---- whistles, knocks and answers ------------------------------------------------------------------

def test_a_whistle_while_twenty_questions_is_thinking_is_still_used(monkeypatch):
    release = __import__("threading").Event()

    def provider(asker, history):
        if history:
            assert release.wait(2)
        return {"question": f"Question {len(history) + 1}?"}

    monkeypatch.setattr(twentyq, "ask_claude", provider)
    game = twentyq.TwentyQuestions(None, {"asker": SimpleNamespace(ready=True)})
    game.setup()
    for _ in range(400):
        if not game.thinking:
            break
        time.sleep(0.005)
    assert game.event("whistle", {"kind": "down"}) is True
    assert game.thinking and game.event("whistle", {"kind": "down"}) is True   # used, so the wall stays on
    release.set()


@pytest.mark.parametrize("title, guess", [("Nights (feat. Frank Ocean)", "nights"),
                                          ("Hey Jude - Remastered 2015", "hey jude"),
                                          ("The Less I Know The Better", "less i know the better"),
                                          ("The Less I Know The Better", "the less i know the better")])
def test_heardle_accepts_the_plain_title(title, guess):
    game = Heardle(None, {"title": title, "artist": "Someone", "preview": "https://example/a.m4a"})
    game.setup()
    assert game.guess(guess, "You")["hit"]


@pytest.mark.parametrize("guess", ["nights wrong", "night", "nights feat"])
def test_heardle_still_needs_the_whole_title(guess):
    game = Heardle(None, {"title": "Nights", "artist": "Frank Ocean", "preview": "https://example/a.m4a"})
    game.setup()
    assert not game.guess(guess, "You")["hit"]


def test_heardle_result_names_the_song_without_a_dash():
    game = Heardle(None, {"title": "Nights", "artist": "Frank Ocean", "preview": "https://example/a.m4a"})
    game.setup()
    game.guess("nights", "You")
    assert game.message == "Nights by Frank Ocean, in 1."


# ---- arcade ---------------------------------------------------------------------------------------

def test_snake_cells_are_even_at_64_and_192():
    game = Snake(None, {"seed": 1})
    game.setup()
    for size, width in ((64, 2), (192, 6)):
        x0, y0, span = [value * size for value in game.GRID]
        cell = span / game.N
        assert cell == width
        edges = [round(x0 + i * cell) for i in range(game.N + 1)]
        assert {b - a for a, b in zip(edges, edges[1:])} == {width}


def arcade(kind):
    clock = [10.0]
    game = kind(None, {"seed": 1}, ["You"])
    game._clock = lambda: clock[0]
    game.setup()
    assert game.apply({"start": True}, "You") == {"started": True}
    return game, clock


@pytest.mark.parametrize("kind", [Snake, Tetris])
def test_arcade_pauses_when_the_phone_goes_quiet(kind):
    game, clock = arcade(kind)
    if kind is Snake:
        game.step_s = 0.5                                                     # room to run before the edge
    for _ in range(40):                                                       # frames, but no phone
        clock[0] += 0.1
        game.step()
    assert game.phase == "paused" and not game.over
    assert game.message == "Paused while your phone reconnects."
    assert game.apply({"resume": True}, "You")["resumed"]


@pytest.mark.parametrize("kind", [Snake, Tetris])
def test_arcade_keeps_playing_while_the_phone_polls(kind):
    game, clock = arcade(kind)
    if kind is Snake:
        game.step_s = 0.5
    for _ in range(40):
        clock[0] += 0.1
        game.state()
        if kind is Snake and game.body[0][0] > game.N - 3:
            game.apply({"dir": "down" if game.dir == (1, 0) else "left"}, "You")
    assert game.phase == "playing" or game.over


@pytest.mark.parametrize("kind, move", [(Snake, {"dir": "up"}), (Tetris, {"move": "left"})])
def test_a_move_that_lands_as_the_round_ends_is_not_an_error(kind, move):
    game, clock = arcade(kind)
    if kind is Snake:
        game.body = [(game.N - 1, 5), (game.N - 2, 5), (game.N - 3, 5)]
        game.dir = game.next_dir = (1, 0)
    else:
        # A grounded piece on a nearly full well: it locks, and the next
        # piece has nowhere to go.
        game.well = [[None] * game.W for _ in range(2)] + [["Z"] * (game.W - 1) + [None] for _ in range(game.H - 2)]
        game.piece = {"kind": "O", "x": 3, "y": 0, "r": 0}
        game.grounded_since = clock[0] - 1
    clock[0] += 0.5
    assert game.apply(move, "You") == {"over": True} and game.over


def test_n_and_m_are_different_in_the_wall_font():
    def differ(a, b):
        return sum(x != y for row_a, row_b in zip(_ARCADE_GLYPHS[a], _ARCADE_GLYPHS[b]) for x, y in zip(row_a, row_b))
    # One LED apart read as the same letter: NEXT became MEXT on the panel.
    assert differ("N", "M") >= 3 and differ("N", "D") >= 2 and differ("N", "U") >= 2


def test_pong_scores_use_words_not_dashes():
    game = Pong(None, {"seed": 1, "to": 2}, ["You"])
    game._clock = lambda: 10.0
    game.setup()
    game._point(1)
    assert game.message == "Point to the wall, 0 to 1."
    game._point(1)
    assert game.message == "Match to the wall, 2 to 0."


# ---- copy ---------------------------------------------------------------------------------------------

def test_connections_results_are_plain():
    game = Connections(None, {"set": 1})
    game.setup()
    for theme, words in game.groups:
        game.apply({"words": list(words)}, "You")
    assert game.over and game.message == "Solved with no mistakes."


def test_letterboxed_undo_and_hint_copy():
    game = LetterBoxed(None, {"seed": 1})
    game.setup()
    game.letters = set("abcdefghijkl")
    game.words, game.used = [], set()
    game.words = ["abcdefghijk"]
    game.undo()
    assert game.message == "12 letters to go."
    game.words = ["abcdefghijk", "k"]
    game.used = set("abcdefghijk")
    game.undo()
    assert game.message == "1 letter to go."
    game.check = lambda word: "no"
    assert game.hint()["error"] == "No word continues from here. Undo the last word to try another route."


def test_contexto_move_message_has_no_middot():
    game = Contexto(None, {"seed": 1})
    game.setup()
    word = next(w for w in ("house", "water", "music", "table") if w != game.secret)
    game.guess(word, "You")
    assert game.message.startswith(f"{word.upper()}, rank ") and not BANNED.search(game.message)


@pytest.mark.parametrize("cls", [Snake, Tetris, Strands, WhistleBird, Reveal])
def test_blurbs_have_no_banned_characters(cls):
    assert not BANNED.search(cls.blurb)
