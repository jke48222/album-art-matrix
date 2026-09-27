#!/usr/bin/env python3
"""Capture both production implementations at native LED resolutions."""
from __future__ import annotations
import argparse
import base64
import hashlib
import json
import sys
from pathlib import Path
from PIL import Image, ImageDraw
from party_games_fixtures import data, NAMES, OPTIONS

ROOT = Path(__file__).resolve().parents[2]
STAGES = {name: ['playing', 'won'] for name in NAMES}
STAGES['heardle'] += ['ready','lost']
STAGES['twentyq'] += ['loading','error']
STAGES['quiz'] += ['answer']
STAGES['pictionary'] += ['loading','error','lost']
STAGES['pong'] += ['ready']

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--baseline', type=Path, required=True)
    p.add_argument('--output', type=Path, default=ROOT/'qa/batch-12/puzzles')
    a=p.parse_args(); a.output.mkdir(parents=True, exist_ok=True)
    records=[]; strips=[]
    for name, stages in STAGES.items():
        for stage in stages:
            pair={}
            for version, checkout in [('before',a.baseline),('after',ROOT)]:
                result=data(checkout,name,stage)
                state={k:v for k,v in result.items() if k!='frames'}
                (a.output/f'{name}-{stage}-{version}.json').write_text(json.dumps(state,indent=2)+'\n')
                for side in [64,192,512]:
                    raw=base64.b64decode(result['frames'][str(side)])
                    image=Image.frombytes('RGB',(side,side),raw)
                    filename=f'{name}-{stage}-{version}-{side}.png'
                    image.save(a.output/filename)
                    records.append({'game':name,'state':stage,'version':version,'side':side,'file':filename,'rgb_sha256':hashlib.sha256(raw).hexdigest()})
                    if side==192:pair[version]=image
            strip=Image.new('RGB',(800,434),(11,10,9));draw=ImageDraw.Draw(strip)
            for x, version in [(8,'before'),(408,'after')]:
                draw.text((x+8,12),f'{name.upper()} / {stage} - {version.upper()}',fill=(234,228,216))
                strip.paste(pair[version].resize((384,384),Image.Resampling.NEAREST),(x,40))
            strip.save(a.output/f'{name}-{stage}-comparison.png'); strips.append(strip)
            print(name,stage,flush=True)
    contact=Image.new('RGB',(800,len(strips)*434),(11,10,9))
    for i,strip in enumerate(strips):contact.paste(strip,(0,i*434))
    contact.save(a.output/'contact-sheet.png')
    manifest={'baseline':'8251028 + qa/batch-12/baseline-wall.patch (actual deployed files)',
              'sizes':[64,192,512],'options':OPTIONS,'frames':records,'cases':sum(len(v) for v in STAGES.values()),
              'notes':['Actual production renderers; deterministic data/time; original authored sleeve.',
                       'Before baseline uses the actual deployed wall files, including their prior source detail limit.',
                       'The phone places input controls outside the shared board.']}
    (a.output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
if __name__=='__main__':main()
