#!/usr/bin/env python3
"""Isolated native-test server using production field validation; no real accounts."""
import json
import sys
import tempfile
import threading
from pathlib import Path
from types import SimpleNamespace
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from urllib.parse import urlsplit
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT))
from brain import services as store_module
from capture_home import artwork,fixture
from device_services_fixtures import configure

class Session:
    def __init__(self):self.lock=threading.RLock();self.reset('connected')
    def reset(self,phase):
        data=configure(SimpleNamespace(studies={}),phase)
        self.services=data['services'];self.homekit=data['homekit'];self.state=fixture('live');self.requests=[];self.reject=False
        Path(store_module.PATH).unlink(missing_ok=True)
        self.store=store_module.Services({'mac':{'endpoint':self.services['mac']['endpoint']},'images':{'provider':'openai','api_key':'sk-'+('q'*30) if phase!='unlinked' else '', 'model':'gpt-image-1.5'},'tmdb':{'api_key':'a'*32 if phase!='unlinked' else ''}})
    def update(self,body):
        _,rejected=self.store.update(body)
        for name,values in body.items():
            if name not in self.services or not isinstance(values,dict):continue
            s=self.services[name]
            if name=='images':
                s.update(provider=self.store.get(name,'provider'),ready=bool(self.store.get(name,'api_key')),verified=False,model='imagen-4.0-ultra-generate-001' if self.store.get(name,'provider')=='google' else 'gpt-image-1.5',problem=None)
                if 'quality' in values and 'images.quality' not in rejected:s['quality']=self.store.get(name,'quality')
            if name=='tmdb':s.update(key_set=bool(self.store.get(name,'api_key')),verified=False,state='saved' if self.store.get(name,'api_key') else 'unlinked',problem=None)
            if name=='mac':s.update(endpoint=self.store.get(name,'endpoint'),state='idle' if self.store.get(name,'endpoint') else 'unconfigured',answering=bool(self.store.get(name,'endpoint')),current=None,problem=None)
        return {**self.services,'rejected':list(rejected)}

def handler(session):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self,*args):pass
        def reply(self,status,value,mime='application/json'):
            body=json.dumps(value).encode() if mime=='application/json' else value
            self.send_response(status);self.send_header('Content-Type',mime);self.send_header('Content-Length',str(len(body)));self.end_headers()
            try:self.wfile.write(body)
            except (BrokenPipeError,ConnectionResetError):pass
        def do_GET(self):
            path=urlsplit(self.path).path
            with session.lock:
                if path=='/qa/status':self.reply(200,{'services':session.services,'homekit':session.homekit,'state':session.state,'requests':session.requests})
                elif path=='/services':self.reply(200,session.services)
                elif path=='/state':self.reply(200,session.state)
                elif path=='/homekit':self.reply(200,session.homekit)
                elif path=='/frame.raw':self.reply(200,artwork(),'application/octet-stream')
                else:self.reply(200,{})
        def do_POST(self):
            path=urlsplit(self.path).path;body=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))) or '{}')
            with session.lock:
                if path=='/qa/reset':session.reset(body.get('phase','connected'));self.reply(200,{'ready':True});return
                if path=='/qa/reject':session.reject=True;self.reply(200,{'ready':True});return
                session.requests.append({'path':path,'fields':list(body)})
                if session.reject and path in ('/services','/state','/homekit/show'):
                    self.reply(503,{'error':'Could not save'});return
                if path=='/services':self.reply(200,session.update(body))
                elif path=='/mac/retry':session.services['mac'].update(state='idle',answering=True,current=None);self.reply(200,session.services)
                elif path=='/posters/check':session.services['tmdb'].update(state='no_match' if body.get('title') else 'ready',verified=True,checking=False);self.reply(200,session.services)
                elif path=='/state':
                    rx=session.services['airplay']['receiver']
                    if 'airplay_name' in body:rx['name']=body['airplay_name']
                    if 'airplay_receiver' in body:rx.update(on=body['airplay_receiver'],running=body['airplay_receiver']);session.services['airplay']['state']='idle' if rx['on'] else 'off'
                    session.state.update(body);self.reply(200,session.state)
                elif path=='/homekit/show':session.homekit.update(showing_code=True,code_seconds_remaining=180);session.state['mode']='frame';self.reply(200,session.homekit)
                elif path=='/homekit/hide':session.homekit.update(showing_code=False,code_seconds_remaining=0);session.state['mode']='art';self.reply(200,session.homekit)
                elif path=='/homekit/refresh':self.reply(200,session.homekit)
                else:self.reply(404,{'error':'Unknown fixture route'})
    return Handler

if __name__=='__main__':
    with tempfile.TemporaryDirectory(prefix='tessera-device-fixture-') as temp:
        store_module.PATH=str(Path(temp)/'services.json')
        ThreadingHTTPServer(('127.0.0.1',65365),handler(Session())).serve_forever()
