"""Deterministic provider doubles around production party games, for local QA only."""
from __future__ import annotations
import base64, importlib, io, json, os, subprocess, sys, time
from pathlib import Path
from PIL import Image, ImageDraw
from types import SimpleNamespace
NAMES=('heardle','twentyq','quiz','pictionary','pong')
ROOT=Path(__file__).resolve().parents[2]
ASSET=ROOT/'qa/batch-12/fixture-drawing.png'
OPTIONS={'heardle':{'title':'Prism Studies','artist':'Tessera Studio','preview':'http://127.0.0.1:65359/clip.wav'}, 'twentyq':{},'quiz':{'set':0,'seconds':20},'pictionary':{'word':'lighthouse','seconds':60},'pong':{'seed':12,'to':7}}
STAMP=1790491800

def make_asset():
    ASSET.parent.mkdir(parents=True,exist_ok=True)
    im=Image.new('RGB',(512,512),'#efe5d1');d=ImageDraw.Draw(im)
    d.ellipse((48,36,432,420),fill='#c6d9d1')
    d.polygon([(0,362),(130,345),(256,369),(396,343),(512,365),(512,512),(0,512)],fill='#416b7b')
    d.polygon([(184,385),(211,135),(291,135),(321,385)],fill='#f3eddb',outline='#173c48',width=7)
    d.polygon([(204,202),(297,202),(302,250),(199,250)],fill='#d76549')
    d.polygon([(193,304),(308,304),(313,348),(189,348)],fill='#d76549')
    d.rectangle((205,113,296,148),fill='#e5b957',outline='#173c48',width=7)
    d.polygon([(194,110),(250,65),(306,110)],fill='#173c48')
    d.rectangle((240,115,255,146),fill='#173c48');d.rectangle((241,337,270,385),fill='#173c48')
    for y in (407,440,473):
        for x in range(-30,540,90):d.arc((x,y,x+74,y+18),0,180,fill='#b1d1d1',width=4)
    im.save(ASSET)

class Imaginer:
    ready=True
    def draw(self,*args,on_partial=None,**kwargs):
        im=Image.open(ASSET).convert('RGB')
        if on_partial:on_partial(im.copy())
        return im

def wait_ready(game):
    for _ in range(300):
        if not getattr(game,'thinking',False) and not getattr(game,'drawing',False):return
        time.sleep(.01)
    raise RuntimeError('Fixture provider did not complete')

def build(name,phase='playing'):
    from brain.games import GAMES
    module='arcade' if name=='pong' else name
    mod=importlib.import_module('brain.games.'+module)
    options=dict(OPTIONS[name])
    if name=='heardle':options['art_url']='data:image/png;base64,'+base64.b64encode((ROOT/'qa/batch-12/fixture-sleeve.png').read_bytes()).decode()
    if name=='twentyq':
        def scripted(asker,history,salt=0):
            return {'guess':'a lighthouse'} if len(history)>=3 else {'question':['Is it something made by people?','Would you find it near water?','Does it help people find their way?'][len(history)]}
        mod.ask_claude=scripted;options['asker']=SimpleNamespace(ready=True)
    if name=='pictionary':options['imaginer']=Imaginer()
    game=GAMES[name](None,options,['You']);game.setup();wait_ready(game)
    now=[100.0];game._clock=lambda:now[0]
    game.t_q=game.last_t=100.0
    if name=='pictionary':game.t0=100.0
    def move(body):
        result=game.apply(body,'You')
        if result and result.get('error'):raise ValueError((name,phase,body,result))
        wait_ready(game)
    if name=='heardle':
        if phase!='ready':move({'guess':'Night Window'});move({'skip':True})
        if phase=='won':move({'guess':'Prism Studies'})
        elif phase=='lost':
            while not game.over:move({'skip':True})
    elif name=='twentyq':
        if phase not in ('ready','loading','error'):
            for answer in ['yes','yes']:move({'answer':answer,'question_id':game.state().get('question_id')})
        if phase=='won':move({'answer':'yes','question_id':game.state().get('question_id')});move({'answer':'yes','question_id':game.state().get('question_id')})
        elif phase=='loading':game.thinking=True;game.current=None
        elif phase=='error':game.thinking=False;game.current=None;game.problem='The question could not be loaded. Try again.'
    elif name=='quiz':
        if phase in ('answer','won'):move({'answer':'33','question_id':game.state().get('question_id')})
        if phase=='won':
            for _ in range(25):
                if game.over:break
                move({'next':True,'question_id':game.state().get('question_id')})
        elif phase=='playing':now[0]=107.0
    elif name=='pictionary':
        now[0]=117.0
        if phase not in ('ready','loading','error'):move({'guess':'windmill'})
        if phase=='won':move({'guess':'lighthouse'})
        elif phase=='lost':now[0]=161.0;game.tick()
        elif phase in ('loading','error'):
            game.picture=None;game.faces={};game.t0=None;game.drawing=phase=='loading';game.problem='The drawing could not be completed. Try again.' if phase=='error' else None
    elif name=='pong':
        if phase!='ready':
            if game.state().get('phase')=='ready':move({'serve':True})
            game.wait_until=99.;game.last_t=100.;game.ball=[.62,.37];game.paddles=[.42,.61];game.score=[3,2]
            if hasattr(game,'rally'):game.rally=6;game.longest_rally=9
            if hasattr(game,'phase'):game.phase='rally'
            if phase=='won':
                if hasattr(game,'_point'):game.score=[6,4];game._point(0)
                else:game.score=[7,4];game.finish(won=True,message='You win, 7 to 4.')
            elif phase=='paused':move({'pause':True})
    game.started=STAMP-120;game.finished=STAMP if game.over else None;game.changed_at=time.monotonic()-20
    return game

def render(root,name,phase):
    sys.path.insert(0,str(Path(root).resolve()))
    from brain.games import GAMES
    for module in ('wordle','sudoku','connections','spellingbee','letterboxed','strands','crossword','contexto','heardle','quiz','pictures','pictionary','twentyq','reaction','whistlebird','arcade'):importlib.import_module('brain.games.'+module)
    game=build(name,phase);public=game.public()
    status={'running':True,'seq':42,'session_id':'qa-party-001','on_wall':True,'game':public,'scores':{'You':{'played':12,'won':9,'streak':3,'best':5}},'voice_words':game.voice_words()[:100]}
    frames={str(side):base64.b64encode(game.frame_at(side,8).tobytes()).decode() for side in (64,192,512)}
    return {'name':name,'phase':phase,'status':status,'list':[c.describe() for c in GAMES.values()],'frames':frames}

def data(root,name,phase):
    result=subprocess.run([sys.executable,str(Path(__file__).resolve()),'--render',str(root),name,phase],text=True,capture_output=True,timeout=75,env={**os.environ,'PYTHONHASHSEED':'0'})
    if result.returncode:raise RuntimeError(f'{name}/{phase}: {result.stderr}')
    return json.loads(result.stdout)

def configure(wall,name,phase,renderer_root=None):
    root=Path(renderer_root) if renderer_root else ROOT;result=data(root,name,phase)
    wall.studies['/game']=result['status'];wall.studies['/game/list']={'games':result['list']};wall.capture_frame=base64.b64decode(result['frames']['64'])
    image=Image.frombytes('RGB',(512,512),base64.b64decode(result['frames']['512']));buffer=io.BytesIO();image.save(buffer,format='PNG');wall.covers['/game/frame.png']=buffer.getvalue()
    wall.party_game_fixture={k:v for k,v in result.items() if k!='frames'}|{'renderer_root':str(root),'options':OPTIONS[name]}
if __name__=='__main__':
    if len(sys.argv)==2 and sys.argv[1]=='--asset':make_asset()
    elif len(sys.argv)==5 and sys.argv[1]=='--render':print(json.dumps(render(sys.argv[2],sys.argv[3],sys.argv[4])))
    else:raise SystemExit('Expected --asset or --render CHECKOUT NAME PHASE')
