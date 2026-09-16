"""Timed notes restore the original face and cannot outlive a control change."""
import json
import time
import pytest
from brain.tests.test_ask import ctrl
from brain.features import Features
from brain.note import show
from shortcuts.build import build_note


def test_note_replacement_and_disk_state(ctrl):
    ctrl.features = Features({'features': {'note': True}})
    old = ctrl.get()
    assert show(ctrl, 'Back at six', .0005)['shown']
    assert ctrl.get()['mode'] == 'ticker'
    saved = json.loads(open(ctrl._state_path).read())
    assert saved['mode'] == old['mode'] and saved['ticker_text'] == old['ticker_text']
    show(ctrl, 'Back at seven', .001)
    time.sleep(.04)
    assert ctrl.get()['ticker_text'] == 'Back at seven'
    time.sleep(.04)
    assert ctrl.get()['mode'] == old['mode'] and ctrl.note is None


def test_change_cancels_note_and_preserves_change(ctrl):
    ctrl.features = Features({'features': {'note': True}})
    show(ctrl, 'Hi', .0005)
    ctrl.apply({'brightness': .2})
    time.sleep(.04)
    assert ctrl.get()['brightness'] == .2 and ctrl.get()['mode'] == 'clock'
    assert ctrl.note is None


def test_disabled_and_validation(ctrl):
    assert show(ctrl, 'Hi')['shown'] is False
    for text, minutes in [('', 1), ('x'*121, 1), ('Hi', 0), ('Hi', float('nan')), ('Hi', True)]:
        with pytest.raises(ValueError): show(ctrl, text, minutes)
    assert ctrl.apply({'_feature': 'note', 'mode': 'ticker'})
    assert ctrl.get()['mode'] == 'clock'


def test_shortcut_request():
    actions = build_note()['WFWorkflowActions']
    request = actions[-1]['WFWorkflowActionParameters']
    assert actions[0]['WFWorkflowActionParameters']['WFTextActionText'].endswith('/state')
    fields = {x['WFKey']: x['WFValue'] for x in request['WFJSONValues']['Value']['WFDictionaryFieldValueItems']}
    assert fields['mode'] == 'ticker' and fields['ticker_loop'] is False
    assert fields['ticker_style'] == 'across' and fields['_feature'] == 'note'
