"""Reporter state, provider ownership and connection API regressions."""
import threading
from types import SimpleNamespace

import pytest
import requests

from brain import services
from brain.nowplaying.applemusic import AppleMusicSource
from brain.nowplaying.reporter_endpoint import normalize_endpoint
from brain.tests.test_control import api  # noqa: F401


@pytest.mark.parametrize('raw,want', [('studio-mac.local','http://studio-mac.local:8787'),('studio-mac.local:8787/','http://studio-mac.local:8787'),('https://Studio-Mac.local:443','https://studio-mac.local:443'),('[::1]:8787','http://[::1]:8787'),('','')])
def test_reporter_address_normalization(raw,want):
    assert normalize_endpoint(raw)==want


@pytest.mark.parametrize('raw',['http://mac:0','http://mac:70000','file:///tmp/a','http://user:password@mac','http://mac/path','http://mac?a=b','http://mac#x','a b','http://'])
def test_reporter_address_rejects_invalid_origins(raw):
    with pytest.raises(ValueError):normalize_endpoint(raw)


def store(monkeypatch,tmp_path):
    monkeypatch.setattr(services,'PATH',str(tmp_path/'services.json'))
    return services.Services({'applemusic':{'endpoint':'http://old-mac.local:8787'},'images':{'provider':'openai','api_key':'sk-'+('a'*30),'model':'gpt-image-1.5'}})


def test_provider_switch_clears_old_credentials_and_model(monkeypatch,tmp_path):
    s=store(monkeypatch,tmp_path)
    s.update({'images':{'provider':'google'}})
    assert s.get('images','api_key')==s.get('images','model')==''
    assert services.Services({}).get('images','api_key')==''


def test_rejected_replacement_never_reuses_old_key(monkeypatch,tmp_path):
    s=store(monkeypatch,tmp_path)
    changed,rejected=s.update({'images':{'provider':'google','api_key':'bad'}})
    assert 'images.api_key' in rejected and s.get('images','api_key')==''


def test_provider_change_accepts_valid_explicit_key(monkeypatch,tmp_path):
    s=store(monkeypatch,tmp_path);key='g'*30
    s.update({'images':{'provider':'google','api_key':key}})
    assert s.get('images','api_key')==key


def test_mac_endpoint_migrates_and_disconnect_persists(monkeypatch,tmp_path):
    s=store(monkeypatch,tmp_path)
    assert s.get('mac','endpoint')=='http://old-mac.local:8787'
    s.update({'mac':{'endpoint':''}})
    assert services.Services({'applemusic':{'endpoint':'http://old-mac.local:8787'}}).get('mac','endpoint')==''


def response(code=200,body=None,headers=None):
    if body is None:body={'track_id':'mac:1','title':'Quiet','artist':'Tessera','album':'Room','art_url':None,'progress_ms':3000,'duration_ms':40000,'is_playing':True}
    return SimpleNamespace(status_code=code,headers=headers or {},json=lambda:body)


def test_idle_reporter_is_connected_without_track(monkeypatch):
    source=AppleMusicSource('http://mac:8787');monkeypatch.setattr(requests,'get',lambda *a,**k:response(204))
    assert source.get_current() is None
    assert source.status()['state']=='idle' and source.answering is True


@pytest.mark.parametrize('body',[[],{'title':'only'}, {'track_id':'a','title':'Quiet','artist':'Tessera','album':'Room','is_playing':'yes'}])
def test_malformed_reporter_cannot_claim_connection(monkeypatch,body):
    source=AppleMusicSource('http://mac:8787');monkeypatch.setattr(requests,'get',lambda *a,**k:response(body=body))
    assert source.get_current() is None
    assert not source.answering


@pytest.mark.parametrize('age',['not-a-number','NaN','-1','inf'])
def test_invalid_presence_header_does_not_break_track(monkeypatch,age):
    source=AppleMusicSource('http://mac:8787');monkeypatch.setattr(requests,'get',lambda *a,**k:response(headers={'X-Phone-Age':age}))
    assert source.get_current().title=='Quiet' and source.phone_age is None


def test_http_error_clears_previous_show_and_song(monkeypatch):
    source=AppleMusicSource('http://mac:8787');monkeypatch.setattr(requests,'get',lambda *a,**k:response())
    source.get_current();source.show={'title':'Old film'}
    monkeypatch.setattr(requests,'get',lambda *a,**k:response(503))
    assert source.get_current() is None and not source.answering
    assert source.show is None and source.status()['current'] is None


def test_endpoint_switch_drops_inflight_response(monkeypatch):
    entered=threading.Event();release=threading.Event();source=AppleMusicSource('http://old:8787')
    def get(*a,**k):entered.set();release.wait(2);return response()
    monkeypatch.setattr(requests,'get',get)
    t=threading.Thread(target=source.get_current);t.start();assert entered.wait(1)
    source.configure('new-mac.local:8787');release.set();t.join(2)
    assert source.status()['state']=='saved' and source.status()['current'] is None
    assert source.answering is None


def test_retry_coalesces_without_waiting_for_network(monkeypatch):
    entered=threading.Event();release=threading.Event();calls=[];source=AppleMusicSource('http://mac:8787')
    def get(*a,**k):calls.append(1);entered.set();release.wait(2);return response()
    monkeypatch.setattr(requests,'get',get)
    assert source.retry();assert entered.wait(1);assert source.retry();assert calls==[1];release.set()


def test_reporter_status_expires_cached_song(monkeypatch):
    release=threading.Event();calls=[]
    def get(*a,**k):calls.append(1);release.wait(2);return response()
    source=AppleMusicSource('http://mac:8787');monkeypatch.setattr(requests,'get',lambda *a,**k:response());source.get_current()
    monkeypatch.setattr(requests,'get',get)
    source._remote_checked-=31
    first=source.status()
    # The old song is not claimed, the last answer stands, and exactly one
    # background check asks the Mac again.
    assert first['state']=='checking' and first['current'] is None and first['answering'] is True
    second=source.status()
    assert second['state']=='checking'
    release.set()
    for _ in range(200):
        if source._remote_busy is None:break
        threading.Event().wait(0.01)
    assert calls==[1] and source.status()['state']=='playing' and source.status()['current']['title']=='Quiet'


@pytest.mark.parametrize('path',['/mac/retry','/posters/check'])
def test_missing_device_service_returns_404(api,path):
    assert api.post(path,{})[0]==404


@pytest.mark.parametrize('path',['/mac/retry','/posters/check'])
def test_invalid_device_body_is_rejected(api,path):
    assert api.post(path,raw=b'[]')[0]==400


def test_invalid_poster_title_never_calls_provider(api):
    api.ctrl.posters=SimpleNamespace(check=lambda _:pytest.fail('must not check'))
    assert api.post('/posters/check',{'title':7})[0]==400
    assert api.post('/posters/check',{'title':'x'*241})[0]==400


@pytest.mark.parametrize('value',['nan','inf','bad'])
def test_homekit_duration_must_be_finite(api,value):
    api.ctrl.homekit=SimpleNamespace(show_code=lambda _:pytest.fail('must not show'))
    assert api.post('/homekit/show?s='+value,{})[0]==400


def test_homekit_route_prefix_cannot_show_pairing(api):
    api.ctrl.homekit=SimpleNamespace(show_code=lambda _:pytest.fail('must not show'))
    assert api.post('/homekit/show-something',{})[0]==404


def test_external_receiver_settings_stay_unchanged(api):
    api.ctrl.airplay_receiver=SimpleNamespace(status=lambda:{'external':True})
    old=api.ctrl.get();bad=api.ctrl.apply({'airplay_receiver':False,'airplay_name':'Changed'})
    assert set(bad)=={'airplay_receiver','airplay_name'}
    assert api.ctrl.get()['airplay_name']==old['airplay_name']


def test_disallowed_receiver_restart_reports_conflict(api):
    api.ctrl.airplay_receiver=SimpleNamespace(restart=lambda:False,status=lambda:{'external':True})
    assert api.post('/airplay/restart',{})[0]==409


def test_switch_checks_new_endpoint_while_old_request_is_pending(monkeypatch):
    old_entered=threading.Event();new_entered=threading.Event();release=threading.Event();source=AppleMusicSource('http://old:8787')
    def get(url,**kwargs):
        if 'old:' in url:old_entered.set();release.wait(2)
        else:new_entered.set()
        return response()
    monkeypatch.setattr(requests,'get',get)
    t=threading.Thread(target=source.get_current);t.start();assert old_entered.wait(1)
    source.configure('new:8787');assert source.retry();assert new_entered.wait(1)
    release.set();t.join(2)
    assert source.endpoint=='http://new:8787'


@pytest.mark.parametrize('field,value',[('art_url',{}),('heard_at','yesterday'),('clock',False)])
def test_reporter_invalid_optional_metadata_is_rejected(monkeypatch,field,value):
    payload=response().json();payload[field]=value
    source=AppleMusicSource('http://mac:8787');monkeypatch.setattr(requests,'get',lambda *a,**k:response(body=payload))
    assert source.get_current() is None and source.answering is False
