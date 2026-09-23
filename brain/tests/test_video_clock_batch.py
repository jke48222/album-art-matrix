"""Late clock requests cannot pause a replacement video."""
import pytest
from brain.tests.test_ticker_api import ticker_api

class Video:
    url = 'new-video'
    calls = []
    def clock(self, t, playing):
        self.calls.append((t, playing))
    def public(self):
        return {'url': self.url, 'status': 'playing'}

def test_stale_video_clock_is_rejected(ticker_api):
    video = Video(); video.calls = []; ticker_api.ctrl.video = video
    assert ticker_api.post('/video/clock', {'url':'old-video','t':12,'playing':False})[0] == 409
    assert not video.calls
    assert ticker_api.post('/video/clock', {'url':'new-video','t':12,'playing':False})[0] == 200
    assert video.calls == [(12,False)]
    assert ticker_api.post('/video/clock', {'t':13,'playing':True})[0] == 200
    assert video.calls[-1] == (13,True)

@pytest.mark.parametrize('value',[float('nan'),float('inf'),float('-inf'),None,{}])
def test_nonfinite_video_clock_never_reaches_player(ticker_api,value):
    video=Video();video.calls=[];ticker_api.ctrl.video=video
    assert ticker_api.post('/video/clock',{'url':'new-video','t':value})[0] == 400
    assert not video.calls
