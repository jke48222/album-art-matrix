"""Readability, temporary control and Claude tools without a network account."""
import json
from types import SimpleNamespace

import pytest

from brain.art.answer import Answer, PAGE_SECONDS
from brain.art.pixelfont import text_width
from brain.ask import Ask, dispatch
from brain.features import Features


@pytest.fixture
def ctrl(tmp_path, monkeypatch):
    from brain import control, services
    monkeypatch.setattr(control, 'STATE_PATH', str(tmp_path / 'control.json'))
    monkeypatch.setattr(control, 'JOURNAL_PATH', str(tmp_path / 'journal.jsonl'))
    monkeypatch.setattr(services, 'PATH', str(tmp_path / 'services.json'))
    state = control.ControlState(seed={'mode': 'clock'})
    state.features = Features({'features': {'ask': True}})
    state.services_store = services.Services({})
    return state


@pytest.mark.parametrize('size', [64, 192])
@pytest.mark.parametrize('text', ['', 'no key yet', 'The rain will stop in an hour.', 'Supercalifragilisticexpialidocious is a very long word.', '안녕하세요 hello to the room'])
def test_lines_fit_and_pages_are_complete(size, text):
    face = Answer(size, text)
    assert all(text_width(line, face.scale) <= face.width for line in face.lines)
    assert all(len(page) <= face.rows for page in face.pages)
    assert sum(len(p) for p in face.pages) == len(face.lines)
    for i, page in enumerate(face.pages):
        frame = face.frame_at(i * PAGE_SECONDS)
        assert frame.shape == (size, size, 3) and frame.dtype.name == 'uint8'
        assert frame.any()
    assert (face.frame_at(face.duration) == face.frame_at((len(face.pages)-1)*PAGE_SECONDS)).all()


def test_state_tools_and_bounded_mutations(ctrl):
    assert dispatch(ctrl, 'wall_state', {})['mode'] == 'clock'
    assert dispatch(ctrl, 'journal', {}) == []
    dispatch(ctrl, 'set_brightness', {'brightness': .3})
    dispatch(ctrl, 'set_face', {'mode': 'ambient'})
    dispatch(ctrl, 'timer', {'minutes': 3})
    assert ctrl.get()['brightness'] == .3 and ctrl.get()['mode'] == 'timer'
    for name, args in [('timer', {'minutes': float('nan')}), ('set_face', {'mode': 'missing'}), ('set_brightness', {'brightness': True})]:
        with pytest.raises(ValueError):
            dispatch(ctrl, name, args)


def test_no_key_once_and_control_change_restores(ctrl):
    asker = Ask(ctrl)
    assert asker.ask('hello')['shown'] is True
    assert ctrl.get()['mode'] == 'answer'
    assert asker.ask('hello')['shown'] is False
    ctrl.apply({'brightness': .4})
    assert ctrl.answer is None and ctrl.get()['mode'] == 'clock'


def test_temporary_answer_does_not_persist_as_a_face(ctrl):
    from brain import control
    ctrl.show_answer('hello')
    assert json.loads(open(control.STATE_PATH).read())['mode'] == 'clock'
    assert control.ControlState().get()['mode'] == 'clock'


class Block:
    def __init__(self, **values):
        self.__dict__.update(values)
    def model_dump(self):
        return vars(self)


class FixtureClient:
    def __init__(self):
        self.messages = self
        self.calls = []
    def create(self, **kwargs):
        self.calls.append(kwargs)
        content = ([Block(type='tool_use', id='one', name='set_brightness', input={'brightness': .5})]
                   if len(self.calls) == 1 else [Block(type='text', text='A little dimmer.')])
        return SimpleNamespace(content=content, usage=SimpleNamespace(input_tokens=100, output_tokens=20))


def test_fake_client_tool_round_trip_and_text_reply(ctrl):
    ctrl.services_store.update({'claude': {'api_key': 'sk-ant-' + 'x'*30}})
    client = FixtureClient()
    asker = Ask(ctrl, client_factory=lambda key: client)
    result = asker.ask('Dim the wall', 'text')
    assert result == {'answer': 'A little dimmer.', 'shown': False}
    assert ctrl.get()['brightness'] == .5 and ctrl.get()['mode'] == 'clock'
    assert client.calls[0]['model'] == 'claude-opus-5'
    assert client.calls[0]['thinking'] == {'type': 'adaptive'}
    assert client.calls[1]['messages'][-1]['content'][0]['type'] == 'tool_result'
    assert asker.last_cost == .002


def test_disabled_feature_does_not_show(ctrl):
    ctrl.features = Features()
    assert Ask(ctrl).ask('hello')['shown'] is False
    assert ctrl.answer is None


def test_timeout_does_not_execute_late_tools(ctrl, monkeypatch):
    import threading
    import time
    from brain import ask as module
    monkeypatch.setattr(module, 'BUDGET', .04)
    release, finished = threading.Event(), threading.Event()
    class Slow(FixtureClient):
        def create(self, **kwargs):
            release.wait(1)
            return super().create(**kwargs)
        def close(self):
            finished.set()
    ctrl.services_store.update({'claude': {'api_key': 'sk-ant-' + 'x'*30}})
    asker = Ask(ctrl, client_factory=lambda key: Slow())
    start = time.monotonic()
    result = asker.ask('dim it', 'text')
    assert time.monotonic() - start < .2
    assert result['answer'] == 'no answer right now'
    release.set()
    assert finished.wait(1)
    assert ctrl.get()['brightness'] == 1


def test_shortcut_posts_dictation_and_speaks_only_answer():
    from shortcuts.build import build
    actions = build()['WFWorkflowActions']
    request = actions[2]['WFWorkflowActionParameters']
    assert request['WFHTTPMethod'] == 'POST' and request['WFHTTPBodyType'] == 'JSON'
    fields = request['WFJSONValues']['Value']['WFDictionaryFieldValueItems']
    assert fields[0]['WFKey'] == 'text'
    assert fields[1]['WFKey'] == 'reply' and fields[1]['WFValue'] == 'text'
    assert actions[3]['WFWorkflowActionParameters']['WFDictionaryKey'] == 'answer'
    assert actions[4]['WFWorkflowActionIdentifier'] == 'is.workflow.actions.speaktext'
