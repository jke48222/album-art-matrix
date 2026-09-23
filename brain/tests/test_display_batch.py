import threading
import time
from types import SimpleNamespace

import numpy as np
import pytest
from PIL import Image

from brain.art.nine import compose, NineBuilder
from brain.art.lyrics import LyricSheet, LyricCanvas, LyricBook, parse_lrc
from brain.art.effects import Ambient
from brain.nowplaying.pushed import PushedSource
from brain.playback import ReplayHold


def song(key='song', playing=True):
    return SimpleNamespace(track_id=key, is_playing=playing)


@pytest.mark.parametrize('release', ['resume', 'track', 'manual', 'expiry'])
def test_archive_always_returns_to_music(release):
    hold = ReplayHold()
    hold.arm(song(), 100)
    assert not hold.release(song(), 101)
    assert not hold.release(song(playing=False), 102)
    assert hold.release(song('next' if release == 'track' else 'song', release == 'resume'),
                        701 if release == 'expiry' else 103, release == 'manual')
    assert not hold.active


def test_archive_started_while_paused_releases_on_play():
    hold = ReplayHold(); hold.arm(song(playing=False), 0)
    assert hold.release(song(), 1)


def test_delayed_play_push_cannot_undo_a_pause():
    source = PushedSource()
    source.push({'session': 'a', 'sequence': 2, 'track': 'Song', 'art': 'https://art', 'progress_ms': 2000, 'playing': False})
    source.push({'session': 'a', 'sequence': 1, 'track': 'Song', 'art': 'https://art', 'progress_ms': 1000, 'playing': True})
    assert source.get_current().progress_ms == 2000
    assert not source.get_current().is_playing


@pytest.mark.parametrize('side', [32, 64, 192, 512])
def test_nine_fills_all_three_rows_and_preserves_square_crop(side):
    art = Image.new('RGB', (90, 30), 'red')
    art.paste(Image.new('RGB', (30, 30), 'blue'), (30, 0))
    grid = compose([art] * 9, side)
    assert grid.size == (side, side)
    assert grid.getpixel((side//2, side//2))[2] > 240
    assert grid.getpixel((side*5//6, side*5//6))[2] > 240
    assert grid.getpixel((0,0)) == (8,10,10)


def test_nine_coalesces_new_request_while_fetch_is_blocked(monkeypatch):
    entered, release = threading.Event(), threading.Event()
    def fetch(url):
        if url == 'old': entered.set(); release.wait(2)
        return Image.new('RGB', (64,64), 'red' if url == 'old' else 'blue')
    monkeypatch.setattr('brain.art.nine.fetch_art', fetch)
    nine = NineBuilder()
    nine.ask([{'ts': 1, 'art_url': 'old'}]); assert entered.wait(1)
    nine.ask([{'ts': 1, 'art_url': 'new'}]); release.set()
    until = time.monotonic() + 2
    while nine._building and time.monotonic() < until: time.sleep(.01)
    assert nine.built_for == ('new',)
    assert nine.frame.getpixel((10,10)) == (0,0,255)


def test_empty_nine_builds_a_deliberate_empty_grid():
    nine = NineBuilder(); nine.ask([])
    until = time.monotonic() + 2
    while nine._building and time.monotonic() < until: time.sleep(.01)
    assert nine.frame is not None and nine.built_for == ()


def test_instrumental_gap_does_not_hold_last_lyric():
    sheet = LyricSheet(parse_lrc('[00:01]first line\n[00:04]\n[00:06]next line'))
    assert sheet.at(5)[0] == ''
    assert sheet.at(7)[0] == 'next line'


@pytest.mark.parametrize('side', [64,192])
def test_lyrics_use_the_whole_canvas_at_every_resolution(side):
    sheet = LyricSheet([(0, 'stay', [(0,'stay')])])
    img = np.asarray(LyricCanvas(side, None, sheet).frame_at(1))
    y, x = np.where(img.max(axis=2) > 150)
    assert side*.2 < y.mean() < side*.7
    assert y.max() - y.min() >= side*.18
    assert x.max() - x.min() >= side*.5


@pytest.mark.parametrize('effect', ['solid','breathe','pulse','rainbow','gradient','plaid','weave','deco','snake'])
@pytest.mark.parametrize('side', [64,192])
def test_all_lamp_studies_render_real_finite_pixels(effect, side):
    frame = Ambient(side, effect, '#e5a343', '#215059', 1).frame_at(8)
    assert frame.size == (side,side) and frame.mode == 'RGB'
    assert np.asarray(frame).max() > 0


def test_shared_lyrics_payload_retains_word_timestamps():
    book=LyricBook(); book.track='a'; book.state='done'
    book.sheet=LyricSheet([(0, 'hello there', [(0,'hello'),(1,'there')])])
    assert book.snapshot()['lines'][0]['words'][1] == {'at':1,'text':'there'}


def test_real_render_loop_restores_same_track_after_archive(monkeypatch):
    """Run main's production loop; only the hardware, network and music are fixtures."""
    from brain import main as runtime
    from brain.features import KNOWN
    from brain.nowplaying import NowPlaying
    stop = threading.Event()
    control = []
    source = SimpleNamespace(name='fixture', answer=None)
    source.get_current = lambda: source.answer
    class EndLoop(BaseException): pass
    class Sink:
        def show(self, *args, **kwargs):
            if stop.is_set(): raise EndLoop()
    def sources(cfg, ctrl):
        control.append(ctrl)
        return [source]
    config = {'panel':{'width':64,'height':64}, 'sink':{'type':'preview'},
              'nowplaying':{'poll_seconds':.02}, 'features':{name:False for name, _ in KNOWN}}
    monkeypatch.setattr(runtime, 'load_config', lambda path:config)
    monkeypatch.setattr(runtime, 'build_sources', sources)
    monkeypatch.setattr(runtime, 'make_sink', lambda *args:Sink())
    monkeypatch.setattr(runtime, 'serve_control', lambda *args:None)
    monkeypatch.setattr(runtime, 'fetch_art', lambda url:Image.new('RGB',(64,64),url))
    monkeypatch.setattr('brain.art.lyrics.fetch_sheet', lambda *args:None)
    monkeypatch.setattr('sys.argv',['brain','--config','fixture'])
    errors=[]
    def run():
        try: runtime.main()
        except EndLoop: pass
        except BaseException as exc: errors.append(exc)
    thread=threading.Thread(target=run,daemon=True);thread.start()
    def wait(predicate):
        end=time.monotonic()+4
        while not predicate() and not errors and time.monotonic()<end: time.sleep(.02)
        assert not errors, errors
        assert predicate()
    def music(playing=True, key='one', art='blue'):
        source.answer=NowPlaying(key,key,'Fixture','Album',art,40000,180000,playing)
        if control: control[0].repoll.set()
    try:
        wait(lambda:bool(control)); ctrl=control[0]
        ctrl.apply({'mode':'lyrics'})
        wait(lambda:ctrl.last_frame is not None)
        assert not any(ctrl.last_frame)
        ctrl.apply({'mode':'art'})
        music(); wait(lambda:ctrl.now_showing.get('title')=='one' and ctrl.last_frame is not None)
        def replay():
            ctrl.apply({'mode':'art'});ctrl.resume_music=False
            ctrl.replay={'title':'Archive','artist':'Fixture','album':'Archive','art_url':'red'}
            ctrl.news.set()
            wait(lambda:ctrl.now_showing.get('title')=='Archive')
            assert ctrl.finish_base.getpixel((32,32)) == (255,0,0)
        replay()
        music(False);wait(lambda:ctrl.progress.get('playing') is False)
        assert ctrl.now_showing['title']=='Archive'
        music();wait(lambda:ctrl.now_showing.get('title')=='one' and not ctrl.replay_active)
        assert ctrl.finish_base.getpixel((32,32)) == (0,0,255)
        replay();ctrl.apply({'resume_music':True,'mode':'art'})
        wait(lambda:ctrl.now_showing.get('title')=='one' and not ctrl.replay_active)
        assert ctrl.finish_base.getpixel((32,32)) == (0,0,255)
        replay();music(key='two',art='green')
        wait(lambda:ctrl.now_showing.get('title')=='two' and not ctrl.replay_active)
        assert ctrl.finish_base.getpixel((32,32)) == (0,128,0)
    finally:
        stop.set()
        if control: control[0].dirty.set();control[0].news.set()
        thread.join(5)


def test_lyric_service_failure_is_distinct_from_no_lyrics(monkeypatch):
    def failure(*args): raise OSError('offline')
    monkeypatch.setattr('brain.art.lyrics.fetch_sheet',failure)
    book=LyricBook();book.ask('one','artist','song','album',100)
    end=time.monotonic()+2
    while book.state=='loading' and time.monotonic()<end:time.sleep(.01)
    assert book.snapshot()['state']=='error'
    assert not book.snapshot()['lines']


def test_enhanced_word_groups_keep_their_timestamps():
    canvas=LyricCanvas(64,None,LyricSheet([]))
    assert canvas._borns(['a','little','colour'],0,9,[(0,'a little'),(5,'colour')]) == [0,0,5]
