#!/usr/bin/env python3
"""Local-only, interactive production-game fixtures for XCUITest (never deployed)."""
import argparse
import io
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
import tempfile
import threading
from urllib.parse import urlsplit
from PIL import Image

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT))
from brain.games.host import GameHost
from capture_home import fixture
from motion_games_fixtures import build, NAMES

class Control:
    def __init__(self):
        self.state=fixture('live');self.state['mode']='game';self.state['display_mode']='game'
        self.shown_seq=1;self.dirty=threading.Event()
    def get(self):return dict(self.state)
    def apply(self,patch):self.state.update(patch);self.state['display_mode']=self.state['mode']

class Session:
    def __init__(self,path):
        self.ctrl=Control();self.host=GameHost(self.ctrl,path=path);self.moves=[];self.fail_next=False;self.lock=threading.RLock()
        self.reset('contexto','playing')
    def reset(self,name,phase):
        assert name in NAMES
        game=build(name,phase);game.host=self.host
        self.host.game=game;self.host.session_id=f'qa-interaction-{name}';self.host.seq=1
        self.host._recorded=None;self.host._ret='off';self.ctrl.apply({'mode':'game'})
        self.moves=[];self.fail_next=False;self.artwork_failures=0


def handler(session):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self,*args):pass
        def reply(self,code,value,mime='application/json'):
            body=json.dumps(value).encode() if mime=='application/json' else value
            self.send_response(code);self.send_header('Content-Type',mime);self.send_header('Content-Length',str(len(body)));self.send_header('Cache-Control','no-store');self.end_headers()
            try:self.wfile.write(body)
            except (BrokenPipeError,ConnectionResetError):pass
        def do_GET(self):
            path=urlsplit(self.path).path
            with session.lock:
                if path=='/state':self.reply(200,session.ctrl.get())
                elif path in ('/game','/qa/status'):self.reply(200,{**session.host.status(),'qa_moves':session.moves})
                elif path=='/game/list':self.reply(200,{'games':session.host.listing()})
                elif path=='/frame.raw':self.reply(200,session.host.frame_at(64).tobytes(),'application/octet-stream')
                elif path=='/game/frame.png':
                    if session.artwork_failures:
                        session.artwork_failures-=1;self.reply(503,{'error':'Temporary artwork failure'});return
                    out=io.BytesIO();Image.fromarray(session.host.frame_at(512)).save(out,format='PNG');self.reply(200,out.getvalue(),'image/png')
                else:self.reply(200,{})
        def do_POST(self):
            body=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))) or '{}')
            with session.lock:
                path=urlsplit(self.path).path
                if path=='/qa/reset':session.reset(body['name'],body.get('phase','playing'));self.reply(200,session.host.status())
                elif path=='/qa/fail-artwork':session.artwork_failures=4;self.reply(200,{'ready':True})
                elif path=='/qa/fail-next':session.fail_next=True;self.reply(200,{'ready':True})
                elif path=='/game/move':
                    if session.fail_next:
                        session.fail_next=False;self.reply(400,{'error':'The wall refused this test move. Try again.'});return
                    session.moves.append(body['move'])
                    result=session.host.move(body.get('player'),body['move'],body.get('session_id'))
                    self.reply(result.get('code',200),result)
                elif path=='/game/end':self.reply(200,session.host.end(body.get('session_id')))
                elif path=='/game/resume':self.reply(200,session.host.resume(body.get('session_id')))
                else:self.reply(200,{})
    return Handler

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--port',type=int,default=65357);args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='tessera-interaction-') as directory:
        session=Session(str(Path(directory)/'scores.json'))
        server=ThreadingHTTPServer(('127.0.0.1',args.port),handler(session))
        print(f'Production games fixture on 127.0.0.1:{args.port}',flush=True)
        try:server.serve_forever()
        except KeyboardInterrupt:pass
        finally:server.server_close()
