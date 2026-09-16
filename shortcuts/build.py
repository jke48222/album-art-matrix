"""Build the Ask the wall Shortcut's reviewable unsigned property list.

Apple's shortcuts sign command signs this for sharing. The first action is
a wall URL text value, editable on the phone. Dictation is posted as JSON;
the returned answer alone is spoken. No API credentials live in a Shortcut.
"""
from pathlib import Path
import plistlib
import uuid


def action(name, parameters):
    return {'WFWorkflowActionIdentifier': name, 'WFWorkflowActionParameters': parameters}


def output(ident, name):
    return {'Value': {'OutputUUID': ident, 'OutputName': name, 'Type': 'ActionOutput'},
            'WFSerializationType': 'WFTextTokenAttachment'}


def token_text(ident, name):
    return {'Value': {'string': '\ufffc', 'attachmentsByRange': {'{0, 1}': output(ident, name)['Value']}},
            'WFSerializationType': 'WFTextTokenString'}


def build():
    host, speech, request, answer = [str(uuid.uuid5(uuid.NAMESPACE_URL, "album-matrix-ask-" + name)).upper() for name in ("host", "speech", "request", "answer")]
    fields = {'Value': {'WFDictionaryFieldValueItems': [
        {'WFItemType': 0, 'WFKey': 'text', 'WFValue': token_text(speech, 'Dictated Text')},
        {'WFItemType': 0, 'WFKey': 'reply', 'WFValue': 'text'}]}, 'WFSerializationType': 'WFDictionaryFieldValue'}
    actions = [action('is.workflow.actions.gettext', {'WFTextActionText': 'http://album-matrix.local:8788/ask', 'UUID': host}),
               action('is.workflow.actions.dictatetext', {'WFDictateTextLanguage': 'en-US', 'WFDictateTextStopListening': 'After Pause', 'UUID': speech}),
               action('is.workflow.actions.downloadurl', {'WFInput': output(host, 'Text'), 'WFHTTPMethod': 'POST',
                      'WFHTTPBodyType': 'JSON', 'WFJSONValues': fields, 'UUID': request}),
               action('is.workflow.actions.getvalueforkey', {'WFInput': output(request, 'Contents of URL'),
                      'WFDictionaryKey': 'answer', 'WFGetDictionaryValueType': 'Value', 'UUID': answer}),
               action('is.workflow.actions.speaktext', {'WFInput': output(answer, 'Dictionary Value'), 'WFSpeakTextWait': True})]
    return {'WFWorkflowActions': actions, 'WFWorkflowName': 'Ask the wall',
            'WFWorkflowClientVersion': '3036.0.4', 'WFWorkflowClientRelease': '18.0',
            'WFWorkflowMinimumClientVersion': 900, 'WFWorkflowTypes': ['NCWidget', 'WatchKit'],
            'WFWorkflowInputContentItemClasses': [],
            'WFWorkflowIcon': {'WFWorkflowIconStartColor': 4282601983, 'WFWorkflowIconGlyphNumber': 59456},
            'WFWorkflowImportQuestions': []}


def build_note():
    workflow = build()
    workflow['WFWorkflowName'] = 'Tell the wall'
    actions = workflow['WFWorkflowActions'][:3]
    actions[0]['WFWorkflowActionParameters']['WFTextActionText'] = 'http://album-matrix.local:8788/state'
    speech = actions[1]['WFWorkflowActionParameters']['UUID']
    fields = [
        {'WFItemType': 0, 'WFKey': 'mode', 'WFValue': 'ticker'},
        {'WFItemType': 0, 'WFKey': 'ticker_text', 'WFValue': token_text(speech, 'Dictated Text')},
        {'WFItemType': 4, 'WFKey': 'ticker_loop', 'WFValue': False},
        {'WFItemType': 0, 'WFKey': 'ticker_style', 'WFValue': 'across'},
        {'WFItemType': 0, 'WFKey': '_feature', 'WFValue': 'note'},
    ]
    actions[2]['WFWorkflowActionParameters']['WFJSONValues']['Value']['WFDictionaryFieldValueItems'] = fields
    workflow['WFWorkflowActions'] = actions
    return workflow


if __name__ == '__main__':
    note = Path(__file__).with_name('Tell the wall.unsigned.shortcut')
    note.write_bytes(plistlib.dumps(build_note(), fmt=plistlib.FMT_BINARY))
    print(note)
    target = Path(__file__).with_name('Ask the wall.unsigned.shortcut')
    target.write_bytes(plistlib.dumps(build(), fmt=plistlib.FMT_BINARY))
    print(target)
