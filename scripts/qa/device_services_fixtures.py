"""Authored, credential-free fixtures for S09–S13 native captures."""
import time
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]))
from connections_fixtures import configure as base


def configure(wall, phase='connected', host=''):
    payload=base(wall,'connected');now=int(time.time())
    payload.update({
        'tmdb':{'key_set':True,'verified':True,'posters':18,'known':12,'state':'matched','checking':False,'checked_at':now,'last':{'title':'The Quiet Hours','kind':'tv','year':2026,'at':now-600}},
        'images':{'ready':True,'verified':True,'provider':'openai','model':'gpt-image-1.5','quality':'medium','images':7,'cost_usd':0.28,'busy':False,'last':{'id':'qa-art','prompt':'An amber sun over a quiet sea, layers of paper and light','ts':now-900}},
        'airplay':{'running':True,'pipe_exists':True,'reading':True,'state':'playing','last':'Into the Quiet — The Tessera Sessions','connected_from':'Living room iPhone','receiver':{'installed':True,'on':True,'name':'Tessera','running':True,'up_s':3600,'restarts':0,'external':False,'controllable':True,'state':'ready','output':'silent','protocol':'classic','port':5000},'current':{'title':'Into the Quiet','artist':'The Tessera Sessions','album':'After the Rain','is_playing':True,'progress_ms':83000,'duration_ms':252000}},
        'mac':{'endpoint':'http://studio-mac.local:8787','answering':True,'state':'playing','checked_at':now,'current':{'title':'Into the Quiet','artist':'The Tessera Sessions','album':'After the Rain','is_playing':True},'problem':None}
    })
    hk={'enabled':True,'ready':True,'name':'Tessera','paired':False,'code':'031-45-154','uri':'X-HM://0023ISYWY7OSY','showing_code':False,'faces':[{'id':1,'name':'Album art','mode':'art'},{'id':2,'name':'Lamp','mode':'ambient'}],'television':True,'sensors':True}
    if phase=='unlinked':
        payload['tmdb'].update(key_set=False,state='unlinked',last=None,posters=0)
        payload['images'].update(ready=False,verified=False,last=None,images=0)
        payload['mac'].update(endpoint='',answering=None,state='unconfigured',current=None)
        payload['airplay']['receiver'].update(on=False,running=False,state='off');payload['airplay'].update(state='off',current=None)
    elif phase=='refused':
        payload['tmdb'].update(state='refused',problem='TMDB refused this key. Replace it and check again.')
        payload['images'].update(verified=False,problem='The image provider refused this key. Replace it in connection settings.')
        payload['mac'].update(answering=False,state='unavailable',current=None,problem='The wall could not reach the reporter. Check the address and keep the Mac awake.')
        payload['airplay']['receiver'].update(running=False,state='error',problem='The receiver could not start. Try restarting it.')
        hk.update(ready=False,error='HomeKit could not start. Check the wall connection and try again.')
    elif phase=='empty':
        payload['tmdb'].update(state='ready',last=None,posters=0)
        payload['images'].update(last=None,images=0)
        payload['mac'].update(state='idle',current=None)
        payload['airplay'].update(state='idle',current=None,last=None)
    elif phase=='paused':
        payload['airplay']['current']['is_playing']=False;payload['airplay']['state']='paused'
    elif phase=='external':
        payload['airplay']['receiver'].update(external=True,controllable=False,name=None,output=None,protocol=None,state='external')
    elif phase=='paired':hk.update(paired=True,code=None,uri=None)
    elif phase=='showing':hk.update(showing_code=True,code_seconds_remaining=173)
    elif phase=='disabled':hk.update(enabled=False,ready=False,code=None,uri=None)
    elif phase=='notinstalled':
        payload['airplay']['receiver'].update(installed=False,running=False,state='not_installed')
        payload['airplay'].update(state='idle',current=None)
    elif phase=='artwork' and host:
        import io
        from PIL import Image
        from capture_home import artwork
        source=Image.frombytes('RGB',(64,64),artwork())
        stream=io.BytesIO();source.save(stream,format='PNG')
        wall.covers['/qa/art.png']=stream.getvalue()
        payload['airplay']['current']['art_url']='http://'+host+'/qa/art.png'
        payload['tmdb']['last'].update(poster='http://'+host+'/qa/art.png',overview='An authored film fixture for the poster layout, using the same abstract artwork as the QA wall.')
    elif phase=='google':payload['images'].update(provider='google',model='imagen-4.0-ultra-generate-001')
    elif phase=='checking':
        payload['tmdb'].update(state='checking',checking=True)
        payload['mac'].update(state='checking',answering=None,current=None)
    from brain.homekit import code_modules
    if hk.get('uri'): hk['qr_modules']=code_modules(hk['uri'])
    wall.studies['/services']=payload;wall.studies['/homekit']=hk
    return {'services':payload,'homekit':hk}
