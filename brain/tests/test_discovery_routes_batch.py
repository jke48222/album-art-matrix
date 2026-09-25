"""Native discovery request validation against the real HTTP router."""
from types import SimpleNamespace
from unittest.mock import Mock, patch
import pytest
from brain.tests.test_control import api
from brain.nowplaying.ears import EarsSource
from brain.nowplaying import NowPlaying

@pytest.fixture
def features(api):
    sh=SimpleNamespace(show=Mock(return_value={'shown':True}),earworm=Mock(return_value={'shown':True}),play=Mock(return_value={'playing':True}),imagine=Mock(return_value={'id':'art'}),show_earworm=Mock(return_value={'shown':True}),discovery_status=lambda:{'last':{'id':'picture'}},earworm_status=lambda:{'last':{'id':'song'},'ready':True})
    api.ctrl.shower=sh
    api.ctrl.imaginer=SimpleNamespace(begin=Mock(return_value={'accepted':True,'job_id':'new-job'}),show_again=Mock(return_value={'error':'Already drawing','code':'busy'}),forget=Mock(return_value={'error':'No picture','code':'not_found'}))
    return sh

@pytest.mark.parametrize('route,body',[('/show',{'query':123}),('/show',{'query':'a'*501}),('/show',{'query':'A painting','kind':'bogus'}),('/earworm',{'words':[]}),('/earworm',{'words':'a'*2001}),('/play',{'query':False}),('/imagine',{'prompt':True}),('/imagine',{'prompt':'a'*2001})])
def test_invalid_discovery_never_invokes_provider(api,features,route,body):
    assert api.post(route,body)[0]==400
    for name in ('show','earworm','play','imagine'):getattr(features,name).assert_not_called()

@pytest.mark.parametrize('route',['/showtime','/show/extra','/playback','/imagine/show/extra'])
def test_routes_do_not_accept_lookalikes(api,features,route):
    assert api.post(route,{'query':'test'})[0]==404

def test_separate_results_and_earworm_replay(api,features):
    assert api.get('/show')[1]['last']['id']=='picture'
    assert api.get('/earworm')[1]['last']['id']=='song'
    assert api.post('/earworm',{'action':'show','id':'song'})[0]==200
    features.show_earworm.assert_called_once_with('song')
    features.earworm.assert_not_called()
    assert api.post('/earworm',{'action':'show'})[0]==400

def test_async_imagine_and_semantic_errors(api,features):
    assert api.post('/imagine',{'prompt':'An amber sun','async':True})[0]==202
    assert api.post('/imagine/show',{'id':'a'})[0]==409
    assert api.post('/imagine/forget',{'id':'a'})[0]==404
    api.ctrl.imaginer.begin.return_value={'error':'Try later','code':'unavailable'}
    assert api.post('/imagine',{'prompt':'A sun','async':True})[0]==503

@pytest.fixture
def voice(api):
    v=SimpleNamespace(status=lambda:{'state':'idle'},wake_now=Mock(return_value=False),say=Mock(return_value=True),wake=SimpleNamespace(name='hey_jarvis',configure=Mock()))
    api.ctrl.voice=v
    return v

@pytest.mark.parametrize('threshold',[float('nan'),float('inf'),True,.1,1,'not numeric'])
def test_invalid_wake_threshold_is_rejected(api,voice,threshold):
    assert api.post('/voice/wakeword',{'threshold':threshold})[0]==400
    voice.wake.configure.assert_not_called()

def test_stale_wake_word_slider_is_rejected(api,voice):
    assert api.post('/voice/wakeword',{'threshold':.5,'expected_model':'alexa'})[0]==409
    voice.wake.configure.assert_not_called()

def test_busy_voice_and_bad_commands_are_honest(api,voice):
    assert api.post('/voice/wake',{})[0]==409
    for words in ('', 'a'*1001, 123, []):assert api.post('/voice/say',{'text':words})[0]==400
    voice.say.assert_not_called()
    assert api.post('/voice/say',{'text':'  show the clock  '})[0]==200
    voice.say.assert_called_once_with('show the clock')

def test_hearing_keeps_pending_match_off_wall_and_reports_source():
    with patch('brain.nowplaying.ears.threading.Thread.start'),patch('brain.nowplaying.ears.tools_present',return_value=(True,None)):
        ears=EarsSource()
    track=NowPlaying(title='Song',artist='Artist',album='Album',art_url='',duration_ms=180000,track_id='test',progress_ms=0,is_playing=True)
    ears._pending={'track':track,'key':'unverified','at':0}
    assert ears.status()['heard'] is None
    assert 'catalogue' in ears.status()['last_rejected']['reason']
    ears._pending=None;ears._hit=track;ears._hit_key='taught:123';ears._heard_at=0;ears._offset=179;ears._clip_start=0
    status=ears.status()
    assert status['match_source']=='local'
    assert status['heard']['at_s']==180
    ears._hit_key='shazam123'
    assert ears.status()['match_source']=='shazam'
