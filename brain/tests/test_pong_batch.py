"""Pong's authoritative clock, fair collision geometry and deliberate controls."""
import copy
import math

import numpy as np
import pytest

from brain.games.arcade import Pong
from brain.games.host import GameHost
from brain.tests.test_games import FakeCtrl


def court(target=7, players=None):
    clock = [100.0]
    game = Pong(None, {"seed": 5, "to": target}, players or ["You", "Sam"])
    game._clock = lambda: clock[0]
    game.setup()
    return game, clock


def rally(game):
    game.phase = "rally"
    game.ball = [.5, .5]
    game.vel = [.45, .1]
    game.wait_until = game.last_t


BAD = [None, True, False, "0.5", [], {}, float("nan"), float("inf"), -float("inf"), 10**1000]


@pytest.mark.parametrize("target", [0, -1, 22, True, 7.5, "7", None])
def test_winning_score_is_bounded_integer(target):
    with pytest.raises(ValueError):
        court(target)


def test_new_match_is_still_until_explicit_serve():
    game, clock = court()
    clock[0] += 600
    assert game.public()["phase"] == "ready"
    assert game.ball == [.5, .5] and game.score == [0, 0]
    assert game.apply({"paddle": .4}, "You")["paddle"] == .4
    assert game.phase == "ready"
    assert game.apply({"serve": True}, "You") == {"served": True}
    clock[0] += .9
    game.step()
    assert game.ball == [.5, .5] and game.phase == "serve"
    clock[0] += .2
    game.step()
    assert game.phase == "rally" and game.ball != [.5, .5]


@pytest.mark.parametrize("value", BAD + [-.01, 1.01])
def test_invalid_paddle_payload_is_not_coerced(value):
    game, _ = court()
    before = game.state()
    assert "error" in game.apply({"paddle": value}, "You")
    assert game.state() == before


@pytest.mark.parametrize("move", [{}, [], None, {"serve": 1}, {"pause": "true"}, {"resume": False}, {"paddle": .5, "serve": True}, {"again": "yes"}])
def test_one_explicit_command_only(move):
    game, _ = court()
    before = game.state()
    assert "error" in game.apply(move, "You")
    assert game.state() == before


def test_multiplayer_moves_only_selected_player_paddle():
    game, _ = court()
    assert game.apply({"paddle": .7}, "Sam") == {"paddle": .7, "side": 1}
    assert game.paddles == [.5, .7]
    for side in [0, True, "1"]:
        assert "error" in game.apply({"paddle": .2, "side": side}, "Sam")
    assert "error" in game.apply({"paddle": .1}, "Stranger")
    assert game.paddles == [.5, .7]
    assert game.apply({"paddle": 0, "side": 0}, "You")["paddle"] == .11
    assert game.apply({"paddle": 1}, "Sam")["paddle"] == .89


def test_solo_cannot_take_over_wall_paddle():
    game, _ = court(players=["You"])
    assert "error" in game.apply({"paddle": .2, "side": 1}, "You")
    assert game.paddles[1] == .5


def test_fixed_step_matches_different_poll_cadences():
    slow, slow_clock = court()
    fast, fast_clock = court()
    for game in [slow, fast]:
        rally(game)
        game.ball = [.4, .35]
        game.vel = [.45, .25]
    for _ in range(7):
        slow_clock[0] += .1
        slow.step()
    for _ in range(70):
        fast_clock[0] += .01
        fast.step()
    assert slow.ball == pytest.approx(fast.ball, abs=1e-9)
    assert slow.vel == fast.vel and slow.trail == pytest.approx(np.array(fast.trail))


def test_serve_counts_only_time_after_countdown():
    game, clock = court()
    game.apply({"serve": True}, "You")
    vx, vy = game.vel
    clock[0] += .8
    game.step()
    clock[0] += .4
    game.step()
    assert game.ball == pytest.approx([.5 + vx * .2, .5 + vy * .2], abs=1e-9)


def test_swept_paddle_collision_prevents_fast_ball_tunneling():
    game, clock = court()
    rally(game)
    game.ball = [.4, .5]
    game.vel = [-20, 0]
    clock[0] += .05
    game.step()
    assert game.vel[0] > 0 and game.rally == 1
    assert game.score == [0, 0]
    assert math.hypot(*game.vel) <= 1.2 + 1e-9
    assert game.ball[0] >= game.PAD_X + game.PAD_W / 2 + game.BALL_R


def test_edge_of_ball_counts_against_paddle():
    game, clock = court()
    rally(game)
    radius_y = game.BALL_R / (game.COURT_BOTTOM - game.COURT_TOP)
    game.ball = [.1, .5 + game.pad_h / 2 + radius_y - .001]
    game.vel = [-1, 0]
    clock[0] += .05
    game.step()
    assert game.rally == 1 and game.vel[0] > 0 and game.score == [0, 0]


def test_missed_paddle_scores_once_and_next_serve_is_deliberate():
    game, clock = court()
    rally(game)
    game.ball = [.1, .12]
    game.vel = [-1, 0]
    clock[0] += .05
    game.step()
    assert game.phase == "point" and game.score == [0, 1]
    position = list(game.ball)
    clock[0] += .6
    game.step()
    assert game.ball == position and game.score == [0, 1]
    clock[0] += .7
    game.step()
    assert game.phase == "serve" and game.ball == [.5, .5]
    assert game.state()["serve_remaining"] == 1.0


def test_vertical_collision_keeps_entire_ball_inside_court():
    game, clock = court()
    rally(game)
    game.ball, game.vel = [.5, .04], [.1, -2]
    clock[0] += .05
    game.step()
    radius_y = game.BALL_R / (game.COURT_BOTTOM - game.COURT_TOP)
    assert game.vel[1] > 0 and game.ball[1] >= radius_y
    assert game.score == [0, 0]


def test_corner_contacts_resolve_both_axes_without_double_scoring():
    game, clock = court()
    rally(game)
    radius_y = game.BALL_R / (game.COURT_BOTTOM - game.COURT_TOP)
    left = game.PAD_X + game.PAD_W / 2 + game.BALL_R
    game.paddles[0] = game.pad_h / 2
    game.ball, game.vel = [left + .01, radius_y + .01], [-1, -1]
    clock[0] += .05
    game.step()
    assert game.ball[0] >= left and game.ball[1] >= radius_y
    assert game.vel[0] > 0 and game.vel[1] > 0
    assert game.rally == 1 and game.score == [0, 0]


def test_new_paddle_cannot_retroactively_return_a_missed_ball():
    game, clock = court()
    rally(game)
    game.ball, game.vel = [.1, .2], [-1, 0]
    clock[0] += .05
    game.apply({"paddle": .2}, "You")
    assert game.score == [0, 1] and game.phase == "point"


def test_pause_and_resume_keep_pose_and_countdown():
    game, clock = court()
    game.apply({"serve": True}, "You")
    clock[0] += .4
    assert game.apply({"pause": True}, "You") == {"paused": True}
    assert game.paused_remaining == pytest.approx(.6)
    clock[0] += 60
    game.step()
    assert game.phase == "paused" and game.ball == [.5, .5]
    assert game.apply({"resume": True}, "You") == {"resumed": True}
    assert game.state()["serve_remaining"] == .6
    clock[0] += .5
    game.step()
    assert game.phase == "serve"
    clock[0] += .2
    game.step()
    assert game.phase == "rally"


def test_long_frame_delay_pauses_without_unseen_rally():
    game, clock = court()
    rally(game)
    before = copy.deepcopy((game.ball, game.score, game.paddles))
    clock[0] += 5
    game.step()
    assert game.phase == "paused" and (game.ball, game.score, game.paddles) == before
    game.apply({"resume": True}, "You")
    clock[0] += .1
    game.step()
    assert game.phase == "rally" and game.ball != before[0]


def test_switching_wall_mode_freezes_game_until_explicit_resume(tmp_path):
    ctrl = FakeCtrl()
    host = GameHost(ctrl, path=str(tmp_path / "pong.json"))
    host.start("pong", {"seed": 5})
    game = host.game
    clock = [100.0]
    game._clock = lambda: clock[0]
    game.last_t = clock[0]
    rally(game)
    before = list(game.ball)
    ctrl.apply({"mode": "art"})
    clock[0] += .5
    assert host.status()["game"]["phase"] == "paused"
    assert game.ball == before
    ctrl.apply({"mode": "game"})
    clock[0] += 10
    assert host.status()["game"]["phase"] == "paused"
    assert host.move(None, {"resume": True})["resumed"]
    clock[0] += .1
    game.step()
    assert game.ball != before


@pytest.mark.parametrize("now", [float("nan"), float("inf"), -1, 99, True])
def test_bad_or_backward_clock_cannot_advance_court(now):
    game, clock = court()
    rally(game)
    before = copy.deepcopy((game.ball, game.score, game.phase, game.last_t))
    clock[0] = now
    game.step()
    assert (game.ball, game.score, game.phase, game.last_t) == before


def test_finished_receipt_and_restart_do_not_leak_completion_flags():
    game, clock = court(1)
    rally(game)
    game.ball, game.vel = [.1, .12], [-1, 0]
    clock[0] += .1
    public = game.public()
    assert public["over"] and public["phase"] == "finished" and public["winner"] == "Sam"
    frozen = game.state()
    for move in [{"serve": True}, {"paddle": .3}, {"pause": True}, {"resume": True}]:
        assert "error" in game.apply(move, "You")
    assert game.state() == frozen
    assert game.apply({"again": True}, "You") == {"again": True}
    public = game.public()
    assert not public["over"] and not public["won"] and public["finished"] is None
    assert public["winner"] is None and public["phase"] == "ready" and public["score"] == [0, 0]


@pytest.mark.parametrize("size", [64, 192, 512])
def test_rgb_court_uses_same_normalized_geometry(size):
    game, _ = court()
    game.paddles = [.42, .61]
    game.ball = [.63, .38]
    game.score = [3, 2]
    image = game.frame_at(size, 0)
    assert image.shape == (size, size, 3) and image.dtype == np.uint8
    bx = round(game.ball[0] * size)
    by = round((game.COURT_TOP + game.ball[1] * (game.COURT_BOTTOM - game.COURT_TOP)) * size)
    assert np.array_equal(image[by, bx], game.COLOURS["ball"])
    for side, colour in [(0, "left"), (1, "right")]:
        px = round((game.PAD_X if side == 0 else 1 - game.PAD_X) * size)
        py = round((game.COURT_TOP + game.paddles[side] * (game.COURT_BOTTOM - game.COURT_TOP)) * size)
        assert (image[py - 1:py + 2, px - 1:px + 2] == game.COLOURS[colour]).all(axis=2).any()
    assert np.array_equal(image[round(.97 * size), round(.3 * size)], game.COLOURS["ground"])
    snapshot = game.state()
    snapshot["score"][0] = 100
    snapshot["ball"][0] = 0
    assert game.score[0] == 3 and game.ball[0] == .63
