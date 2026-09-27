"""Session ownership, production pixels and time-derived completion receipts."""
from io import BytesIO
from urllib.request import urlopen
import numpy as np
from PIL import Image
import pytest

from brain.games import GAMES
from brain.games.host import GameHost
from brain.tests.test_control import api  # noqa: F401
from brain.tests.test_games_batch import TestPuzzle


@pytest.fixture
def games(api, tmp_path, monkeypatch):
    class Artwork(TestPuzzle):
        name = 'artwork-test'
        def frame_at(self, size, t):
            pixels=np.zeros((size,size,3),dtype=np.uint8)
            pixels[:,:,0]=np.arange(size,dtype=np.uint16)[:,None]%256
            pixels[:,:,1]=np.arange(size,dtype=np.uint16)[None,:]%256
            return pixels
    monkeypatch.setitem(GAMES,Artwork.name,Artwork)
    api.ctrl.games=GameHost(api.ctrl,path=str(tmp_path/'games.json'))
    api.post('/game/start',{'name':Artwork.name})
    return api


@pytest.mark.parametrize('side',[64,192,512])
def test_artwork_is_original_production_resolution_and_does_not_switch_wall(games,side):
    session=games.ctrl.games.session_id
    games.post('/state',{'mode':'off'})
    with urlopen(games.base+f'/game/frame.png?side={side}&session_id={session}&seq=0') as response:
        assert response.headers['Content-Type']=='image/png'
        assert response.headers['Cache-Control']=='no-store'
        image=Image.open(BytesIO(response.read()))
    assert image.size==(side,side)
    expected=games.ctrl.games.game.frame_at(side,0)
    assert np.array_equal(np.asarray(image),expected)
    assert games.ctrl.get()['mode']=='off'


@pytest.mark.parametrize('query',['','?side=4096&session_id=x','?side=64.0&session_id=x',
                                  '?side=64&side=512&session_id=x','?side=512','?side=512&session_id=x&session_id=y'])
def test_artwork_rejects_unbounded_or_ambiguous_requests(games,query):
    assert games.get('/game/frame.png'+query)[0]==400


def test_old_artwork_request_cannot_observe_new_session(games):
    old=games.ctrl.games.session_id
    games.post('/game/start',{'name':'artwork-test'})
    assert games.get('/game/frame.png?side=512&seq=0&session_id='+old)[0]==409
    games.post('/game/end',{})
    assert games.get('/game/frame.png?side=512&seq=0&session_id=old')[0]==409


def test_tick_completion_flags_and_score_are_in_the_same_receipt(games,monkeypatch):
    class Timed(TestPuzzle):
        name='tick-test'
        def setup(self):super().setup();self.expired=False
        def state(self):
            if self.expired and not self.over:self.finish(won=True,message='Finished on time')
            return {'expired':self.expired}
    monkeypatch.setitem(GAMES,Timed.name,Timed)
    games.post('/game/start',{'name':Timed.name})
    games.ctrl.games.game.expired=True
    code,state=games.get('/game')
    assert code==200
    assert state['game']['expired'] and state['game']['over'] and state['game']['won']
    assert state['game']['message']=='Finished on time'
    assert state['scores']['You']['played']==state['scores']['You']['won']==1
    assert games.get('/game')[1]['scores']['You']['played']==1


def test_newer_arrangement_never_returns_pixels_for_old_hit_targets(games):
    session=games.ctrl.games.session_id
    games.ctrl.games.game.changed()
    assert games.get('/game/frame.png?side=512&seq=0&session_id='+session)[0]==409
    assert games.ctrl.games.artwork(512,session,1) is not None


def test_render_that_advances_a_deadline_rejects_predeadline_receipt(games,monkeypatch):
    game=games.ctrl.games.game
    render=game.frame_at
    def advance(size,t):
        game.changed()
        return render(size,t)
    monkeypatch.setattr(game,'frame_at',advance)
    assert games.ctrl.games.artwork(512,games.ctrl.games.session_id,game.seq) is None


@pytest.mark.parametrize("move", [{"again":"false"}, {"again":1}, {"again":True,"y":0.5}])
def test_completed_game_requires_an_explicit_restart(games,move):
    session=games.ctrl.games.session_id
    games.post('/game/move',{'session_id':session,'move':{'finish':True}})
    code,reply=games.post('/game/move',{'session_id':session,'move':move})
    assert code==409 and reply['session_id']==session
    assert games.ctrl.games.game.over
