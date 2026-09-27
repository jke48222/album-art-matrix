#!/usr/bin/env python3
"""Render matched arcade states in baseline/current isolated production checkouts."""
from pathlib import Path
import sys,base64,json
from PIL import Image
import argparse
parser=argparse.ArgumentParser();parser.add_argument('--baseline',type=Path,required=True);args=parser.parse_args()
root=Path(__file__).resolve().parents[2];sys.path.insert(0,str(root/'scripts/qa'))
from arcade_games_fixtures import data
q=root/'qa/batch-13/pixels';q.mkdir(parents=True,exist_ok=True);rows=[]
for name in ['snake','tetris']:
 for phase in ['ready','playing','paused','lost']:
  for version,checkout in [('before',str(args.baseline)),('after',str(root))]:
   d=data(checkout,name,phase)
   for size in [64,192,512]:
    f=f'{name}-{phase}-{version}-{size}.png';Image.frombytes('RGB',(size,size),base64.b64decode(d['frames'][str(size)])).save(q/f);rows.append({'name':name,'phase':phase,'version':version,'size':size,'file':f})
   d.pop('frames');(q/f'{name}-{phase}-{version}.json').write_text(json.dumps(d,indent=2)+'\n')
(q/'manifest.json').write_text(json.dumps(rows,indent=2)+'\n');print(len(rows),'frames rendered')
