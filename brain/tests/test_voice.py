"""Commands cannot leak through questions; capture and failures stay bounded."""
import time
from types import SimpleNamespace
import numpy as np
import pytest
from brain.voice import Capture, Command, Voice, match_command, perform
from brain.features import Features
from brain.tests.test_ask import ctrl

@pytest.mark.parametrize('words, expected', [
    ('OFF.', Command('power', 'off')), ('please turn on', Command('power', 'on')),
    ('disk', Command('face', 'cd')), ('ambent', Command('face', 'ambient')),
    ('lyricks', Command('face', 'lyrics')), ('brigher', Command('brightness', .1)),
    ('quieter', Command('brightness', -.1)), ('video off', Command('video_off')),
    ('what is this?', Command('song')), ('timer twenty five minutes', Command('timer', 25)),
    ('Set a timer for five minutes.', Command('timer', 5)),
    ('teach this, it is Tower of Roses by MALI', Command('teach', ('tower of roses', 'mali'))),
    ('How do I turn off the sun?', None), ('What is ambient music?', None),
    ('timer -2 minutes', None), ('timer 200 minutes', None),
    ('I need an artist', None), ('offer', None), ('one', None)])
def test_matcher(words, expected):
    assert match_command(words) == expected


def test_capture_silence_and_eight_second_limit():
    voice = np.full(1600, 12000, dtype='<i2').tobytes()
    quiet = bytes(3200)
    capture = Capture()
    assert not capture.feed(voice)
    for _ in range(7):
        assert not capture.feed(quiet)
    assert capture.feed(quiet)
    assert len(capture.take()) == 9*3200 and not capture.parts
    capture = Capture()
    for _ in range(79):
        assert not capture.feed(voice)
    assert capture.feed(voice)
    assert len(capture.take()) == 256000
    capture = Capture()
    for _ in range(8): capture.feed(quiet)
    assert capture.take() == b''


def test_commands_change_real_control(ctrl):
    perform(ctrl, match_command('off'))
    assert ctrl.get()['mode'] == 'off'
    perform(ctrl, match_command('on'))
    assert ctrl.get()['mode'] == 'clock'
    perform(ctrl, match_command('timer five minutes'))
    assert ctrl.timer['total'] == 300 and ctrl.get()['mode'] == 'timer'
    perform(ctrl, match_command('brighter'))
    assert ctrl.get()['brightness'] <= 1


def voice_ctrl(ctrl, transcriber):
    ctrl.features = Features({'features': {'wake': True, 'horizon': True}})
    ctrl.tuning = SimpleNamespace(get=lambda key: {'wake': True, 'speech_model': 0}[key])
    from brain.art.horizon import Horizon
    ctrl.horizon = Horizon(64)
    voice = Voice(ctrl, start=False, transcriber=transcriber)
    voice.revision = ctrl.control_seq
    return voice


def test_transcription_failure_keeps_old_face(ctrl):
    def fail(*args): raise TimeoutError()
    voice = voice_ctrl(ctrl, SimpleNamespace(transcribe=fail))
    voice._finish(bytes(3200))
    assert ctrl.get()['mode'] == 'clock'
    assert ctrl.horizon.phase == 'failed' and voice.problem


def test_phone_change_cancels_late_transcription(ctrl):
    def late(*args):
        ctrl.apply({'mode': 'ambient'})
        return 'off'
    voice = voice_ctrl(ctrl, SimpleNamespace(transcribe=late))
    voice._finish(bytes(3200))
    assert ctrl.get()['mode'] == 'ambient' and ctrl.horizon is None


def test_local_command_opens_into_new_face(ctrl):
    voice = voice_ctrl(ctrl, SimpleNamespace(transcribe=lambda *args: 'ambient'))
    voice._finish(bytes(3200))
    assert ctrl.get()['mode'] == 'ambient' and ctrl.horizon.waiting
