#!/usr/bin/env python3
"""Unretouched native before/after screens for batch four."""
from pathlib import Path
import json
from compare_home import compose, Feature

root=Path(__file__).resolve().parents[2]
batch=root/'qa/batch-04'
rows=[]
for name,unit,title in [('lyrics','C03','Lyrics'),('nine','C04','Nine'),('finishes','C05','Finishes'),('lamp','C06','Lamp'),('studio','C07','Studio drawing')]:
    before='classic-live.png' if name=='studio' else 'room-live.png'
    rows.append(compose(root,batch/'before'/name/before,batch/'after'/name/'classic-live.png',batch/'comparisons'/f'{name}.png',Feature(unit,title,name),390))
folder=batch/'comparisons'
(folder/'manifest.json').write_text(json.dumps({'processing':'Complete native screenshots, proportionally downscaled identically; no crops or retouching.','context':'C03–C06 pair the old Room controls with their new dedicated detail screens. C07 compares the full Studio. Authored fixtures exercise the actual production renderers.','comparisons':rows},indent=2)+'\n')
images=''.join(f'<section><h2>{title}</h2><img src="{name}.png" alt="{title}: before and after"></section>' for name,title in [('lyrics','C03 · Lyrics'),('nine','C04 · Nine'),('finishes','C05 · Finishes'),('lamp','C06 · Lamp'),('studio','C07 · Studio')])
(folder/'index.html').write_text('''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Tessera · Batch 4</title><style>body{margin:0;background:#0c100e;color:#efeade;font:16px system-ui}header{padding:36px 24px 12px;max-width:1200px;margin:auto}h1{font-size:40px;margin:0 0 14px}p{color:#a5ada5;max-width:760px;line-height:1.6}main{max-width:1600px;margin:auto;display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,620px),1fr));gap:24px;padding:24px}img{display:block;width:100%;height:auto}h2{font-size:16px;font-weight:500;color:#b5cbb9}</style><header><h1>Tessera · Before &amp; after</h1><p>Batch 4. Lyrics, Nine, Finishes and Lamp compare their former Room controls with their new detail views. Studio compares the full editor. Screenshots are unretouched; artwork and text are controlled QA fixtures.</p></header><main>'''+images+'</main></html>')
print(folder/'index.html')
