"""Provider-free states made with real moves and production game renderers."""
from __future__ import annotations
import base64
import importlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from PIL import Image, ImageDraw

NAMES = ('contexto', 'sliding', 'reveal', 'reaction', 'whistlebird')
STAMP = 1790487819
ASSET = Path(__file__).resolve().parents[2] / 'qa/batch-11/fixture-sleeve.png'
OPTIONS = {'contexto': {'word':'guitar'}, 'sliding': {'seed':11,'grid':3},
           'reveal': {'seconds':30}, 'reaction': {'seed':11,'rounds':5}, 'whistlebird': {'seed':11}}


def make_asset():
    """Original geometric cover used only by QA; never a user's listening data."""
    ASSET.parent.mkdir(parents=True,exist_ok=True)
    image=Image.new('RGB',(512,512),'#123d42');d=ImageDraw.Draw(image)
    d.polygon([(0,350),(512,80),(512,512),(0,512)],fill='#dc6546')
    d.ellipse((104,72,422,390),fill='#eee6c8')
    for i in range(12):
        x=126+i*24
        d.line((x,94,x-48,366),fill='#123d42',width=8)
    d.rectangle((0,422,512,512),fill='#eee6c8')
    font_path=Path(__file__).resolve().parents[2]/'tessera/Tessera/Fonts/SpaceGrotesk-Bold.ttf'
    from PIL import ImageFont
    try:font=ImageFont.truetype(str(font_path),31)
    except OSError:font=ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',31)
    d.text((24,443),'PRISM STUDIES',font=font,fill='#123d42')
    image.save(ASSET)


def build(name, phase='playing'):
    from brain.games import GAMES
    module='pictures' if name in ('sliding','reveal') else name
    importlib.import_module('brain.games.'+module)
    options=dict(OPTIONS[name])
    if name in ('sliding','reveal'):
        options.update(image=str(ASSET),title='Prism Studies',album='Prism Studies',artist='Tessera Studio')
    if name=='reaction' and phase=='won':options['rounds']=1
    game=GAMES[name](None,options,['You']);game.setup()
    now=[100.0]
    if hasattr(game,'_clock'):game._clock=lambda:now[0]
    if name in ('reveal','whistlebird'):
        game.t0=game.last_t=now[0]
    def move(body):
        result=game.apply(body,'You')
        if result and result.get('error'):raise ValueError((name,phase,body,result))
    if phase not in ('ready','empty'):
        if name=='contexto':
            for word in ['table','music','piano']:move({'word':word})
            if phase=='won':move({'word':'guitar'})
            if phase=='lost':move({'give_up':True})
        elif name=='sliding':
            if phase=='won':
                game.tiles=list(range(game.n*game.n));game.gap=game.n*game.n-2
                game.tiles[-1],game.tiles[-2]=game.tiles[-2],game.tiles[-1]
                move({'tile':game.n*game.n-1})
            else:move({'tile':game._moves()[0]})
        elif name=='reveal':
            now[0]=115
            if phase=='won':move({'guess':'Prism Studies'})
            elif phase=='lost':now[0]=131;game.tick()
            else:move({'guess':'Night Window'})
        elif name=='reaction':
            move({'go':True})
            if phase=='red':now[0]=100.5
            elif phase=='green':now[0]=game.t_go+.1;game.tick()
            elif phase=='error':now[0]=100.2;move({'tap':True})
            else:now[0]=game.t_go+.238;game.tick();move({'tap':True})
        else:
            move({'y':.4});game.y=.4;game.target=.4;game.last_pitch_t=100
            game.pipes=[[.55,.35,False],[1.0,.65,False]];game.score=3
            if phase in ('won','lost'):game._die()
    game.started=STAMP-420;game.finished=STAMP if game.over else None
    game.changed_at=time.monotonic()-20
    return game


def render(root,name,phase):
    sys.path.insert(0,str(Path(root).resolve()))
    from brain.games import GAMES
    for module in ('wordle','sudoku','connections','spellingbee','letterboxed','strands','crossword','contexto','heardle','quiz','pictures','pictionary','twentyq','reaction','whistlebird','arcade'):
        importlib.import_module('brain.games.'+module)
    game=build(name,phase)
    public=game.public()
    status={'running':phase!='empty','seq':42,'session_id':'qa-motion-001','on_wall':phase!='empty',
            'game':public if phase!='empty' else None,'scores':{'You':{'played':12,'won':9,'streak':3,'best':5}},'voice_words':game.voice_words()[:100]}
    frames={str(side):base64.b64encode(game.frame_at(side,8).tobytes()).decode() for side in (64,192,512)}
    return {'name':name,'phase':phase,'status':status,'list':[c.describe() for c in GAMES.values()],'frames':frames}


def data(root,name,phase):
    result=subprocess.run([sys.executable,str(Path(__file__).resolve()),'--render',str(root),name,phase],text=True,capture_output=True,timeout=75,env={**os.environ,'PYTHONHASHSEED':'0'})
    if result.returncode:raise RuntimeError(f'{name}/{phase} renderer failed: {result.stderr}')
    return json.loads(result.stdout)


def configure(wall,name,phase,renderer_root=None):
    root=Path(renderer_root) if renderer_root else Path(__file__).resolve().parents[2]
    result=data(root,name,phase)
    wall.studies['/game']=result['status'];wall.studies['/game/list']={'games':result['list']}
    wall.capture_frame=base64.b64decode(result['frames']['64'])
    image=Image.frombytes('RGB',(512,512),base64.b64decode(result['frames']['512']))
    buffer=io.BytesIO();image.save(buffer,format='PNG');wall.covers['/game/frame.png']=buffer.getvalue()
    wall.motion_game_fixture={k:v for k,v in result.items() if k!='frames'}|{'renderer_root':str(root),'options':OPTIONS[name]}

if __name__=='__main__':
    if len(sys.argv)==2 and sys.argv[1]=='--asset':make_asset()
    elif len(sys.argv)==5 and sys.argv[1]=='--render':print(json.dumps(render(sys.argv[2],sys.argv[3],sys.argv[4])))
    else:raise SystemExit('Expected --asset or --render CHECKOUT NAME PHASE')
