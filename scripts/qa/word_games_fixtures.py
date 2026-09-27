"""Reproducible, provider-free production word-game states for native and wall QA."""
from __future__ import annotations
import base64
import importlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

NAMES = ('connections', 'spellingbee', 'letterboxed', 'strands', 'crossword')
OPTIONS = {'connections':{'set':0,'seed':10}, 'spellingbee':{'seed':1},
           'letterboxed':{'seed':23}, 'strands':{'set':0,'seed':23}, 'crossword':{'set':0}}
STAMP = 1790469024


def build(name, phase='playing'):
    from brain.games import GAMES
    importlib.import_module('brain.games.'+name)
    game = GAMES[name](None, OPTIONS[name], ['You'])
    game.setup()
    def move(body):
        result=game.apply(body,'You')
        if result and result.get('error'):raise ValueError((name,phase,body,result))
    if phase not in ('ready','empty'):
        if name == 'connections':
            if phase == 'lost':
                for i in range(4):move({'words':game.groups[0][1][:3]+[game.groups[1][1][i]]})
            elif phase == 'won':
                for _,words in game.groups:move({'words':list(words)})
            else:
                move({'words':list(game.groups[0][1])})
                if phase == 'error':move({'words':game.groups[1][1][:3]+[game.groups[2][1][0]]})
                for word in game.groups[1][1][:2]:move({'pick':word})
        elif name == 'spellingbee':
            words = game.answers if phase == 'won' else ['acorn','action','raincoat']
            for word in words:move({'word':word})
        elif name == 'letterboxed':
            for word in list(game.par) if phase == 'won' else list(game.par)[:1]:move({'word':word})
        elif name == 'strands':
            words = list(game.words)+[game.spangram] if phase == 'won' else list(game.words)[:2]
            for word in words:move({'word':word})
            if phase == 'hint':
                from brain.games.words import common
                for word in common(4,8):
                    if word not in game.words and word != game.spangram and game._in_grid(word):
                        move({'word':word})
                        if len(game.extra)==3:break
                move({'hint':True})
        else:
            selected=game.slots if phase=='won' else [game.slots[0]]
            for slot in selected:
                if game.over:break
                move({'slot':slot['id'],'word':''.join(game.solution[c] for c in slot['cells'])})
            if phase=='error':move({'cell':[1,0],'letter':'x'});move({'check':True})
            if phase!='won':move({'choose':game.slots[1]['id']})
    game.started = STAMP-420
    game.finished = STAMP if game.over else None
    game.changed_at = time.monotonic()-20
    if hasattr(game,'shook_at'):game.shook_at=None
    return game


def render(root, name, phase):
    sys.path.insert(0,str(Path(root).resolve()))
    from brain.games import GAMES
    for module in ('wordle','sudoku','connections','spellingbee','letterboxed','strands','crossword','contexto','heardle','quiz','pictures','pictionary','twentyq','reaction','whistlebird','arcade'):
        importlib.import_module('brain.games.'+module)
    game=build(name,phase)
    status={'running':phase!='empty','seq':42,'session_id':'qa-words-001','on_wall':phase!='empty',
            'game':game.public() if phase!='empty' else None,'scores':{'You':{'played':12,'won':9,'streak':3,'best':5}},'voice_words':game.voice_words()[:100]}
    frames={str(size):base64.b64encode(game.frame_at(size,8).tobytes()).decode() for size in (64,192,512)}
    return {'name':name,'phase':phase,'status':status,'list':[cls.describe() for cls in GAMES.values()],'frames':frames}


def data(root,name,phase):
    command=[sys.executable,str(Path(__file__).resolve()),'--render',str(root),name,phase]
    result=subprocess.run(command,text=True,capture_output=True,timeout=75,env={**os.environ,'PYTHONHASHSEED':'0'})
    if result.returncode:raise RuntimeError(f'{name}/{phase} renderer failed in {root}: {result.stderr}')
    return json.loads(result.stdout)


def configure(wall,name,phase,renderer_root=None):
    root=Path(renderer_root) if renderer_root else Path(__file__).resolve().parents[2]
    result=data(root,name,phase)
    wall.studies['/game']=result['status'];wall.studies['/game/list']={'games':result['list']}
    wall.capture_frame=base64.b64decode(result['frames']['64'])
    wall.word_game_fixture={k:v for k,v in result.items() if k!='frames'}|{'renderer_root':str(root),'options':OPTIONS[name]}

if __name__=='__main__':
    if len(sys.argv)!=5 or sys.argv[1]!='--render':raise SystemExit('Expected --render CHECKOUT NAME PHASE')
    print(json.dumps(render(sys.argv[2],sys.argv[3],sys.argv[4])))
