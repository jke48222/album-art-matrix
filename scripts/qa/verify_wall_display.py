#!/usr/bin/env python3
"""Exercise display modes on an explicitly named wall, restoring its prior view."""
import argparse
import base64
import hashlib
import json
import time
from pathlib import Path
from urllib.request import Request, urlopen
from PIL import Image

parser=argparse.ArgumentParser();parser.add_argument('--host',required=True);parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
base='http://'+args.host

def get(path):
    with urlopen(base+path,timeout=8) as response:return response.read()
def read(path):return json.loads(get(path))
def post(path,value):
    with urlopen(Request(base+path,data=json.dumps(value).encode(),headers={'Content-Type':'application/json'}),timeout=8) as response:return response.status

original=read('/state')
keys=['mode','effect','speed','finish','match_art','color','color2']
restore={key:original[key] for key in keys}
frame=get('/frame.raw')
original_frame=frame
if original['mode']=='frame':
    try: original_frame=base64.b64decode(read('/finishes')['clean'])
    except Exception: pass
results={}
try:
    post('/state',{'mode':'nine'})
    deadline=time.monotonic()+15
    while time.monotonic()<deadline:
        time.sleep(.5);current=get('/frame.raw')
        if current!=frame:break
    assert current!=frame and len(current)==len(frame),'Nine did not produce a frame'
    side=int((len(current)//3)**.5)
    Image.frombytes('RGB',(side,side),current).save(args.output/'nine-live.png')
    results['nine']={'frame_bytes':len(current),'different_from_previous_face':True,'sha256':hashlib.sha256(current).hexdigest()}
    shots=read('/finishes')
    assert set(shots)=={'clean','dither','poster'}
    assert all(len(base64.b64decode(value))==len(current) for value in shots.values())
    results['finishes']={'count':len(shots),'native_size':side}
    post('/state',{'mode':'ambient','effect':'gradient','speed':1})
    time.sleep(1);first=get('/frame.raw');time.sleep(.7);second=get('/frame.raw')
    assert first!=second,'Lamp is not animating'
    Image.frombytes('RGB',(side,side),second).save(args.output/'lamp-live.png')
    results['lamp']={'animated':True,'frame_bytes':len(second)}
    studies=read('/ambient/previews');assert len(studies)==9
    results['lamp_studies']={'count':9,'bytes_each':len(base64.b64decode(studies['solid']))}
    lyrics=read('/lyrics');assert lyrics['state'] in ('idle','loading','done','none','error')
    results['lyrics']={'endpoint':True,'state':lyrics['state'],'line_count':len(lyrics['lines'])}
finally:
    if restore['mode']=='frame':post('/frame',{'px':base64.b64encode(original_frame).decode()})
    post('/state',restore)
    time.sleep(1)
    restored=read('/state');assert all(restored[k]==v for k,v in restore.items())
    results['restored']={k:restored[k] for k in ['mode','effect','speed','finish']}
    (args.output/'checks.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results))
