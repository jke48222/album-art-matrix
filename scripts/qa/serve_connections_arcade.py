#!/usr/bin/env python3
"""Loopback-only UI fixture: real arcade rules, synthetic credential-free service states."""
import json,sys,tempfile,threading,time,io
from pathlib import Path
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from urllib.parse import urlsplit
from types import SimpleNamespace
from PIL import Image
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT))
from brain.games.host import GameHost
from capture_home import fixture
from arcade_games_fixtures import build
from connections_fixtures import configure
class Control:
 def __init__(self):self.state=fixture('live');self.shown_seq=1;self.dirty=threading.Event()
 def get(self):return dict(self.state)
 def apply(self,p):self.state.update(p);self.state['display_mode']=self.state['mode']
class Session:
 def __init__(self,path):self.ctrl=Control();self.host=GameHost(self.ctrl,path=path);self.lock=threading.RLock();self.reset('snake','ready')
 def reset(self,name,phase):
  self.moves=[];self.offline=False
  self.services=configure(SimpleNamespace(studies={}),phase)
  if name in ('snake','tetris'):
   g=build(name,phase);g.host=self.host;self.host.game=g;self.host.session_id='qa-arcade-'+name;self.host.seq=1;self.host._recorded=None;self.host._ret='off';self.ctrl.apply({'mode':'game'})
  else:self.ctrl.apply({'mode':'art'})
def handler(s):
 class Handler(BaseHTTPRequestHandler):
  def log_message(self,*args):pass
  def reply(self,status,value,mime='application/json'):
   body=json.dumps(value).encode() if mime=='application/json' else value
   self.send_response(status);self.send_header('Content-Type',mime);self.send_header('Content-Length',str(len(body)));self.end_headers()
   try:self.wfile.write(body)
   except (BrokenPipeError,ConnectionResetError):pass
  def do_GET(self):
   path=urlsplit(self.path).path
   with s.lock:
    if s.offline and not path.startswith('/qa'):self.reply(503,{'error':'Offline'});return
    if path=='/state':self.reply(200,s.ctrl.get())
    elif path=='/services':self.reply(200,s.services)
    elif path in ('/game','/qa/status'):self.reply(200,{**s.host.status(),'qa_moves':s.moves})
    elif path=='/game/list':self.reply(200,{'games':s.host.listing()})
    elif path=='/frame.raw':self.reply(200,s.host.frame_at(64).tobytes(),'application/octet-stream')
    elif path=='/game/frame.png':
     out=io.BytesIO();Image.fromarray(s.host.frame_at(512)).save(out,format='PNG');self.reply(200,out.getvalue(),'image/png')
    else:self.reply(200,{})
  def do_POST(self):
   body=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))) or '{}');path=urlsplit(self.path).path
   with s.lock:
    if path=='/qa/reset':s.reset(body['name'],body.get('phase','ready'));self.reply(200,{'ready':True})
    elif path=='/qa/offline':s.offline=True;self.reply(200,{'ready':True})
    elif path=='/game/move':
     s.moves.append(body['move']);result=s.host.move(body.get('player'),body['move'],body.get('session_id'));self.reply(result.get('code',200),result)
    elif path=='/spotify/retry':s.services['spotify'].update({'linked':True,'state':'idle','problem':None});self.reply(200,s.services)
    elif path.startswith('/services'):self.reply(200,s.services)
    else:self.reply(200,{})
 return Handler
if __name__=='__main__':
 with tempfile.TemporaryDirectory() as d:
  s=Session(str(Path(d)/'scores.json'));ThreadingHTTPServer(('127.0.0.1',65361),handler(s)).serve_forever()
