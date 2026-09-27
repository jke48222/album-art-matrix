"""Private credential checking must not consume state, reveal keys or accept stale replies."""
import http.client
import io
import json
import socket
import threading
from types import SimpleNamespace
from unittest.mock import Mock
import pytest
import requests
from PIL import Image
from brain.control import ControlState, serve
from brain.picture_connection import PictureConnection
from brain.show import Shower

@pytest.mark.parametrize('code,body,state',[(200,{'items':[]},'ready'),(200,{'items':None},'unavailable'),(200,[],'unavailable'),(200,{'error':{}},'unavailable'),(400,{},'refused'),(401,{},'refused'),(403,{},'refused'),(429,{},'limited'),(500,{},'unavailable')])
def test_check_sanitized_and_closes(monkeypatch,code,body,state):
    response=SimpleNamespace(status_code=code,json=lambda:body,close=Mock())
    monkeypatch.setattr('brain.picture_connection.requests.get',lambda *a,**k:response)
    check=PictureConnection('private-key','engine');check._run(0,'private-key','engine')
    result=check.status();assert result['state']==state;assert result['verified']==(state=='ready')
    assert 'private-key' not in str(result);response.close.assert_called_once()

def test_exception_never_exposes_request_url(monkeypatch):
    def fail(*a,**k):raise requests.ConnectionError('https://example.com/?key=SECRET')
    monkeypatch.setattr('brain.picture_connection.requests.get',fail)
    check=PictureConnection('SECRET','engine');check._run(0,'SECRET','engine')
    assert 'SECRET' not in str(check.status());assert check.status()['state']=='unavailable'

def test_old_check_cannot_validate_replacement(monkeypatch):
    started=threading.Event();release=threading.Event()
    def read(*a,**k):
        started.set();release.wait(2)
        return SimpleNamespace(status_code=200,json=lambda:{},close=lambda:None)
    monkeypatch.setattr('brain.picture_connection.requests.get',read)
    check=PictureConnection('old','oldengine');worker=threading.Thread(target=check._run,args=(0,'old','oldengine'));worker.start()
    assert started.wait(1);check.configure('new','newengine');release.set();worker.join(2)
    assert check.status()['state']=='saved';assert check.status()['checked_at'] is None

def test_unlink_and_repeat_check_coalescing(monkeypatch):
    calls=[]
    monkeypatch.setattr('brain.picture_connection.threading.Thread',lambda **kw:SimpleNamespace(start=lambda:calls.append(kw)))
    check=PictureConnection();assert not check.check()
    check.configure('key','engine');assert check.check();assert check.check();assert len(calls)==1
    check.configure('','');assert check.status()['state']=='default';assert not check.check()

def test_refused_thread_settles_the_check(monkeypatch):
    def refuse(**kw):
        def start():raise RuntimeError("can't start new thread")
        return SimpleNamespace(start=start)
    monkeypatch.setattr('brain.picture_connection.threading.Thread',refuse)
    check=PictureConnection('key','engine');assert check.check()
    assert check.status()['state']=='unavailable';assert not check.status()['checking']
    calls=[];monkeypatch.setattr('brain.picture_connection.threading.Thread',lambda **kw:SimpleNamespace(start=lambda:calls.append(kw)))
    assert check.check();assert len(calls)==1

def test_unexpected_error_still_ends_the_check(monkeypatch):
    def fail(*a,**k):raise KeyError('SECRET')
    monkeypatch.setattr('brain.picture_connection.requests.get',fail)
    check=PictureConnection('SECRET','engine');check.state='checking';check._run(0,'SECRET','engine')
    assert check.status()['state']=='unavailable';assert 'SECRET' not in str(check.status())

def test_real_search_answers_update_the_connection():
    check=PictureConnection('key','engine')
    check.note('key','engine',403);assert check.status()['state']=='refused';assert check.status()['checked_at']
    check.note('key','engine',429);assert check.status()['state']=='limited'
    check.note('key','engine',500);assert check.status()['state']=='limited'
    check.note('key','engine',200);assert check.status()['verified'];assert check.status()['problem'] is None
    check.note('old','engine',403);assert check.status()['state']=='ready'
    check.state='checking';check.note('key','engine',403);assert check.status()['state']=='checking'


# ---- over HTTP, on one kept-alive connection the way the phone calls ------------

@pytest.fixture
def wall():
    with socket.socket() as s:
        s.bind(('127.0.0.1',0));port=s.getsockname()[1]
    ctrl=ControlState(frame_len=64*64*3);httpd=serve(ctrl,port)
    try:yield ctrl,port
    finally:httpd.shutdown();httpd.server_close()

def _ask(conn,method,path,body=None):
    conn.request(method,path,body=body,headers={'Content-Type':'application/json'} if body is not None else {})
    response=conn.getresponse();return response.status,response.getheader('Content-Type'),response.read()

@pytest.mark.parametrize('setup,code',[('saved',200),('empty',409),('off',503)])
def test_check_then_services_share_one_kept_alive_socket(monkeypatch,wall,setup,code):
    ctrl,port=wall
    monkeypatch.setattr('brain.picture_connection.requests.get',lambda *a,**k:SimpleNamespace(status_code=200,json=lambda:{'items':[]},close=lambda:None))
    if setup!='off':
        ctrl.shower=Shower(ctrl,google_key='k'*39 if setup=='saved' else '',google_cx='engine123' if setup=='saved' else '')
    conn=http.client.HTTPConnection('127.0.0.1',port,timeout=5)
    try:
        status,_,_=_ask(conn,'POST','/pictures/check',b'{}');sock=conn.sock
        assert status==code;assert sock is not None
        status,_,raw=_ask(conn,'GET','/services')
        assert status==200;assert conn.sock is sock
        state=json.loads(raw)['google']['state']
        assert state in {'saved':('checking','ready'),'empty':('default',),'off':('off',)}[setup]
    finally:
        conn.close()
    if setup=='saved':
        for _ in range(200):
            if not ctrl.shower.picture_connection.status()['checking']:break
            threading.Event().wait(0.01)
        assert ctrl.shower.picture_connection.status()['state']=='ready'

def test_last_picture_frame_is_served_apart_from_services(wall):
    ctrl,port=wall
    conn=http.client.HTTPConnection('127.0.0.1',port,timeout=5)
    try:
        assert _ask(conn,'GET','/pictures/last.png')[0]==404
        ctrl.shower=Shower(ctrl);assert _ask(conn,'GET','/pictures/last.png')[0]==404
        buffer=io.BytesIO();Image.new('RGB',(64,64),(9,8,7)).save(buffer,format='PNG')
        ctrl.shower._last_picture_png=buffer.getvalue()
        status,kind,raw=_ask(conn,'GET','/pictures/last.png')
        assert (status,kind,raw)==(200,'image/png',buffer.getvalue())
        status,_,raw=_ask(conn,'GET','/services');assert status==200;assert b'iVBOR' not in raw
    finally:
        conn.close()
