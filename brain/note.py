"""Leave a message on the wall, then let its previous face come back.

A timed note scrolls until its time is up. A second note replaces the first
without losing the original face. Any control change ends the note. Notes
stay in memory, and restarting brings back the earlier settings rather than
an expired message. The Tell the wall Shortcut uses the existing one-pass
ticker for a quick message instead.
"""
import math
import threading
import time

FIELDS = ('mode', 'ticker_text', 'ticker_loop', 'ticker_style', 'ticker_colors')


def show(ctrl, text, minutes=30):
    if not isinstance(text, str) or not text.strip() or len(text) > 120:
        raise ValueError('text must contain 1 to 120 characters')
    if isinstance(minutes, bool) or not isinstance(minutes, (int, float)) or not math.isfinite(minutes) or not 0 < minutes <= 1440:
        raise ValueError('minutes must be greater than zero and at most 1440')
    if not ctrl.features.enabled('note'):
        return {'shown': False, 'problem': 'Notes are off for this build.'}
    previous = ctrl.note['previous'] if ctrl.note else {k: ctrl.get()[k] for k in FIELDS}
    if previous['mode'] == 'answer' and ctrl.answer:
        previous['mode'] = ctrl.answer['ret']
    ctrl.answer = None
    ctrl.horizon = None
    ctrl.control_seq += 1
    note = {'previous': previous, 'end': time.monotonic() + minutes*60}
    ctrl.note = note
    ctrl.apply({'mode': 'ticker', 'ticker_text': text.strip(), 'ticker_style': 'across',
                'ticker_loop': True, 'ticker_colors': []}, internal=True)
    def restore():
        if ctrl.note is note:
            ctrl.note = None
            ctrl.apply(previous, internal=True)
    timer = threading.Timer(minutes*60, restore)
    timer.daemon = True
    timer.start()
    return {'shown': True, 'minutes': minutes}
