"""Production timing, steering and pixel-geometry contracts for G11–G12."""
import copy

import numpy as np
import pytest

from brain.games.reaction import ReactionKnock, COLOURS as REACTION_COLOURS
from brain.games.whistlebird import (
    WhistleBird, BIRD_X, BIRD_LEFT, BIRD_RIGHT, BIRD_RADIUS, GROUND,
    PIPE_WIDTH, PIPE_CAP, GAP, COLOURS as FLIGHT_COLOURS,
)


def reaction(rounds=2, players=None):
    game = ReactionKnock(None, {"rounds": rounds, "seed": 1}, players or ["You"])
    game.setup()
    clock = [100.0]
    game._clock = lambda: clock[0]
    return game, clock


def bird(speed=14):
    game = WhistleBird(None, {"seed": 1, "speed": speed})
    clock = [100.0]
    game._clock = lambda: clock[0]
    game.setup()
    return game, clock


BAD_NUMBERS = [None, True, False, "0.5", [], {}, float("nan"), float("inf"), -float("inf"), 10**1000]


@pytest.mark.parametrize("rounds", [0, 21, -1, 2.5, True, "5", None])
def test_reaction_round_bounds_reject_before_play(rounds):
    with pytest.raises(ValueError):
        reaction(rounds)


def test_knock_timestamp_wins_over_undrawn_red_phase():
    game, clock = reaction(1)
    game.begin()
    clock[0] = game.t_go + 0.187
    assert game.phase == "red"  # No render or status tick ran first.
    assert game.knock_at(clock[0]) == {"ms": 187, "how": "knock"}
    receipt = game.public()
    assert receipt["over"] and receipt["phase"] == "shown"
    assert receipt["last_kind"] == "hit" and receipt["round"] == 1
    assert receipt["trials"]["You"] == [{"ms": 187, "kind": "hit", "how": "knock"}]


@pytest.mark.parametrize("timestamp", BAD_NUMBERS + [-1, 99.9, 1000])
def test_invalid_knock_samples_do_not_consume_turn(timestamp):
    game, _ = reaction()
    game.begin()
    before = (game.seq, copy.deepcopy(game.times), game.phase)
    assert "error" in game.knock_at(timestamp)
    assert (game.seq, game.times, game.phase) == before


@pytest.mark.parametrize("move", [{"tap": 1}, {"go": False}, {"start": "yes"}, {"tap": True, "go": True}, {}, [], None])
def test_reaction_only_accepts_one_explicit_command(move):
    game, _ = reaction()
    assert "error" in game.apply(move, "You")
    assert game.phase == "ready" and not game.times["You"]


def test_repeated_tap_and_completed_game_do_not_append_trials():
    game, clock = reaction(1)
    game.begin()
    clock[0] = game.t_go + 0.2
    assert game.apply({"tap": True}, "You")["ms"] == 200
    snapshot = copy.deepcopy(game.state())
    for command in [{"tap": True}, {"go": True}, {"start": True}]:
        assert "error" in game.apply(command, "You")
    assert game.knock_at(clock[0]).get("error")
    clock[0] += 100
    game.tick()
    assert game.state() == snapshot


def test_mixed_trials_average_and_final_round_do_not_overflow():
    game, clock = reaction(3)
    game.begin()
    assert game.knock_at(clock[0] + 0.01)["false_start"]
    for ms in [200, 400]:
        clock[0] += 3
        game.tick()
        clock[0] = game.t_go + ms / 1000
        assert game.apply({"tap": True}, "You")["ms"] == ms
    state = game.state()
    assert game.over and state["round"] == state["rounds"] == 3
    assert state["times"]["You"] == [None, 200, 400]
    assert state["best"]["You"] == 200 and state["average"]["You"] == 300
    state["times"]["You"].append(1)
    state["trials"]["You"][0]["ms"] = 1
    assert game.times["You"] == [None, 200, 400] and game.trials["You"][0]["ms"] is None


def test_timeout_publishes_finished_metadata_same_receipt():
    game, clock = reaction(1)
    game.begin()
    clock[0] = game.t_go + 30.1
    receipt = game.public()
    assert receipt["over"] and receipt["finished"] and receipt["last_kind"] == "missed"
    assert receipt["times"]["You"] == [None]


@pytest.mark.parametrize("size", [64, 192, 512])
def test_reaction_visual_states_have_words_and_noncolour_signals(size):
    game, clock = reaction(20)
    ready = game.frame_at(size, 0)
    game.begin()
    waiting = game.frame_at(size, 0)
    clock[0] = game.t_go
    go = game.frame_at(size, 0)
    for image, colour in [(ready, "ground"), (waiting, "red"), (go, "green")]:
        assert image.shape == (size, size, 3) and image.dtype == np.uint8
        assert (image == REACTION_COLOURS[colour]).all(axis=2).mean() > 0.65
        assert (image == REACTION_COLOURS["white"]).all(axis=2).sum() > 10
    # The open target, stop bars and solid target differ in luminance geometry.
    region = np.s_[int(size * .19):int(size * .4), int(size * .38):int(size * .63)]
    assert not np.array_equal(waiting[region].mean(axis=2) > 100, go[region].mean(axis=2) > 100)


@pytest.mark.parametrize("speed", BAD_NUMBERS + [0, 3.9, 40.1])
def test_invalid_flight_speed_is_rejected(speed):
    with pytest.raises(ValueError):
        bird(speed)


def test_ready_waits_indefinitely_and_touch_starts_from_current_height():
    game, clock = bird()
    clock[0] += 3600
    game.step()
    assert game.phase == "ready" and game.y == .5 and not game.pipes and game.elapsed == 0
    assert game.apply({"y": .4}, "You") == {"y": .4}
    assert game.phase == "flying" and game.y == .5
    for _ in range(100):
        clock[0] += .05
        game.step()
    assert game.source == "phone" and abs(game.y - .4) < .001 and not game.dead


def test_whistle_calibration_holds_bird_and_silence_glides_afterward():
    game, clock = bird()
    assert game.pitch(1000)
    assert game.phase == "calibrating"
    clock[0] += .8
    assert game.pitch(1400)
    game.step()
    assert game.y == .5 and not game.pipes and game.elapsed == 0
    clock[0] = game.calib_until
    game.step()
    assert game.phase == "flying" and game.y == .5
    clock[0] += .4
    game.step()
    assert game.y > .5 and not game.dead
    assert game.state()["range"] == [1000, 1400]


@pytest.mark.parametrize("value", BAD_NUMBERS + [-.01, 1.01])
def test_invalid_height_leaves_flight_unchanged(value):
    game, _ = bird()
    before = game.state()
    assert "error" in game.apply({"y": value}, "You")
    assert game.state() == before


@pytest.mark.parametrize("hz", BAD_NUMBERS + [299, 5001, -1000])
def test_invalid_pitch_does_not_start_or_mutate_calibration(hz):
    game, _ = bird()
    before = game.state()
    assert game.pitch(hz) is False
    assert game.state() == before


@pytest.mark.parametrize("timestamp", [value for value in BAD_NUMBERS if value is not None] + [-1, 99.49, 100.1])
def test_stale_future_and_invalid_pitch_timestamps_are_ignored(timestamp):
    game, _ = bird()
    assert game.pitch(1000, timestamp) is False
    assert game.phase == "ready" and game.lo is None


def test_out_of_order_pitch_cannot_rewrite_newer_target():
    game, clock = bird()
    assert game.pitch(1000)
    clock[0] += .2
    assert game.pitch(1400)
    target = game.target
    assert game.pitch(1100, clock[0] - .1) is False
    assert game.target == target


def test_long_stall_preserves_world_until_explicit_resume():
    game, clock = bird()
    game.apply({"start": True}, "You")
    game.pipes = [[.6, .4, False, 1]]
    before = copy.deepcopy((game.y, game.pipes, game.elapsed, game.distance))
    clock[0] += 10
    game.step()
    assert game.phase == "paused" and not game.dead
    assert (game.y, game.pipes, game.elapsed, game.distance) == before
    clock[0] += 20
    game.step()
    assert game.apply({"start": True}, "You") == {"started": True}
    assert (game.y, game.pipes, game.elapsed, game.distance) == before
    clock[0] += .1
    game.step()
    assert game.phase == "flying" and game.pipes[0][0] < .6


def test_cap_and_bird_radius_collision_at_zero_elapsed_time():
    game, _ = bird()
    game.apply({"start": True}, "You")
    game.y = .4
    # The beak touches the cap before either object's center reaches the other.
    game.pipes = [[BIRD_X + BIRD_RIGHT + PIPE_CAP - .001, .4 + GAP / 2 - BIRD_RADIUS + .002, False, 0]]
    game.step()
    assert game.dead and game.reason == "pipe" and game.score == 0


def test_swept_collision_catches_pipe_during_long_but_valid_frame():
    game, clock = bird(40)
    game.apply({"start": True}, "You")
    game.y = game.target = .2
    game.pipes = [[.5, .7, False, 0]]
    clock[0] += 1
    game.step()
    assert game.dead and game.score == 0
    assert game.pipes[0][0] > BIRD_X - BIRD_LEFT


def test_score_only_after_full_pipe_clears_bird_and_only_once():
    game, clock = bird()
    game.apply({"start": True}, "You")
    right_edge = BIRD_X - BIRD_LEFT
    game.pipes = [[right_edge - PIPE_WIDTH - PIPE_CAP + .001, .5, False, 0]]
    game.step()
    assert game.score == 0
    clock[0] += .02
    game.step()
    assert game.score == 1 and not game.dead
    game.step()
    assert game.score == 1


def test_late_pitch_cannot_retroactively_steer_through_pipe():
    game, clock = bird()
    game.apply({"start": True}, "You")
    game.y = game.target = .2
    game.pipes = [[.33, .7, False, 0]]
    clock[0] += .4
    assert game.pitch(1000) is False
    assert game.dead and game.score == 0


def test_ground_finishes_same_public_receipt_and_again_clears_all_completion():
    game, _ = bird()
    game.apply({"start": True}, "You")
    game.score = game.best = 4
    game.y = GROUND - BIRD_RADIUS
    receipt = game.public()
    assert receipt["over"] and receipt["won"] and receipt["phase"] == "finished"
    assert receipt["reason"] == "ground"
    assert "error" in game.apply({"y": .5}, "You")
    assert game.apply({"again": True}, "You") == {"again": True}
    receipt = game.public()
    assert not receipt["over"] and not receipt["won"] and not receipt["dead"]
    assert receipt["finished"] is None and receipt["phase"] == "ready"
    assert receipt["score"] == 0 and receipt["best"] == 4


@pytest.mark.parametrize("bad_clock", [float("nan"), float("inf"), -1, 99])
def test_invalid_or_backward_clock_cannot_advance_world(bad_clock):
    game, clock = bird()
    game.apply({"start": True}, "You")
    before = (game.y, game.elapsed, game.distance)
    clock[0] = bad_clock
    game.step()
    assert (game.y, game.elapsed, game.distance) == before


@pytest.mark.parametrize("size", [64, 192, 512])
def test_flight_renderer_preserves_normalized_colour_geometry(size):
    game, _ = bird()
    game.apply({"start": True}, "You")
    game.y = game.target = .4
    game.pipes = [[.55, .35, False, 0], [1, .65, False, 1]]
    game.score = 3
    image = game.frame_at(size, 0)
    assert image.shape == (size, size, 3) and image.dtype == np.uint8
    assert np.array_equal(image[int(.1 * size), int(.59 * size)], FLIGHT_COLOURS["pipe"])
    assert np.array_equal(image[int(.6 * size), int(.59 * size)], FLIGHT_COLOURS["pipe"])
    assert np.array_equal(image[int(.35 * size), int(.59 * size)], FLIGHT_COLOURS["sky"])
    assert np.array_equal(image[int(.99 * size), int(.5 * size)], FLIGHT_COLOURS["ground"])
    region = image[round(.4 * size) - round(size / 32):round(.4 * size) + round(size / 32), round(14 * size / 64):round(20 * size / 64)]
    assert (region == FLIGHT_COLOURS["bird"]).all(axis=2).any()
    # Returned status containers cannot be used to mutate the live obstacle list.
    snapshot = game.state()
    snapshot["obstacles"][0]["gap"] = 0
    snapshot["pipes"][0][0] = 0
    assert game.pipes[0][:2] == [.55, .35]
