#!/usr/bin/env python3
"""Matched production renderer studies; artwork and lyric text are QA fixtures."""
from pathlib import Path
import importlib.util
import json
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFont
root=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(root))
from brain.art.nine import compose
from brain.art.lyrics import LyricSheet, LyricCanvas
from brain.art.effects import Ambient
from brain.art.pipeline import apply_finish
from capture_home import artwork

out=root/'qa/batch-04/renders';out.mkdir(parents=True,exist_ok=True)
base=Image.frombytes('RGB',(64,64),artwork())
covers=[base.transpose(Image.Transpose.FLIP_LEFT_RIGHT) if i%2 else base for i in range(9)]
sheet=LyricSheet([(0,'a little colour in the quiet',[(0,'a'),(.5,'little'),(1,'colour'),(2,'in'),(3,'the'),(4,'quiet')])])
manifest=[]
for side in [64,192,512]:
    products={'nine':compose(covers,side),'lyrics':LyricCanvas(side,base,sheet).frame_at(4.4)}
    for effect in ['solid','breathe','pulse','rainbow','gradient','plaid','weave','deco','snake']:
        products['lamp-'+effect]=Ambient(side,effect,'#e5a343','#215059',1).frame_at(8)
    art=base.resize((side,side),Image.Resampling.LANCZOS)
    for finish in ['clean','dither','poster']: products['finish-'+finish]=apply_finish(art,finish)
    for name,img in products.items():
        path=out/f'{name}-{side}.png';img.save(path)
        manifest.append({'feature':name,'size':side,'image':path.name,'time':4.4 if name=='lyrics' else 8 if name.startswith('lamp') else None})
for feature in ['nine','lyrics']:
    code=subprocess.check_output(['git','show',f'3651079:brain/art/{feature}.py'],cwd=root,text=True)
    namespace={'__name__':'brain.art.legacy_'+feature,'__package__':'brain.art'}
    exec(compile(code,'legacy-'+feature,'exec'),namespace)
    for side in [64,192]:
        old=namespace['compose'](covers,side) if feature=='nine' else namespace['LyricCanvas'](side,base,sheet).frame_at(4.4)
        old.save(out/f'{feature}-before-{side}.png')
        new=Image.open(out/f'{feature}-{side}.png')
        panel=Image.new('RGB',(816,450),'#101512');draw=ImageDraw.Draw(panel)
        draw.text((16,12),f'{feature.upper()}  {side} x {side}    BEFORE / AFTER',fill='#f4f1ea')
        panel.paste(old.resize((384,384),Image.Resampling.NEAREST),(16,46))
        panel.paste(new.resize((384,384),Image.Resampling.NEAREST),(416,46))
        panel.save(out/f'{feature}-comparison-{side}.png')
(out/'manifest.json').write_text(json.dumps({'source':'Production Python renderers, authored QA fixtures; no physical LED color claims. RGB images use nearest-neighbor enlargement in comparison sheets.','frames':manifest},indent=2)+'\n')
print(out)
