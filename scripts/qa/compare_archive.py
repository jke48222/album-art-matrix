#!/usr/bin/env python3
"""Pair batch-three native captures without cropping or retouching screenshots."""
from pathlib import Path
import json
from compare_home import compose, Feature


def main():
    root=Path(__file__).resolve().parents[2]
    batch=root/'qa/batch-03'
    pairs=[
        ('a03-room','A03','Room spacing','room-live.png','room-live.png'),
        ('icons','X01','Shared control icons','icons/room-live.png','icons/room-live.png'),
        ('a08-archive','A08','Archive','archive/classic-live.png','archive/classic-live.png'),
        ('a09-insights','A09','Listening insights','archive/classic-live.png','insights/classic-live.png'),
        ('a10-pressings','A10','Pressings & labels','pressing/room-live.png','pressing/room-live.png'),
        ('c01-artwork','C01','Album art · new detail view','room-live.png','album/room-live.png'),
        ('c02-spin','C02','Spin · new detail view','spin/room-live.png','spin/room-live.png'),
    ]
    results=[]
    for name,unit,title,before,after in pairs:
        result=compose(root,batch/'before'/before,batch/'after'/after,batch/'comparisons'/f'{name}.png',Feature(unit,title,after),390)
        results.append(result)
    (batch/'comparisons/manifest.json').write_text(json.dumps({'processing':'Same proportional downscale for each full screenshot; no retouching or content overlays.',
        'new_screen_context':'A09 compares the old embedded Archive stats with the new insights page; C01 compares the old home artwork with its new dedicated view; C02 compares old controls with the new Spin detail.',
        'comparisons':results},indent=2)+'\n')
    images=''.join(f'<section><img src="{name}.png" alt="Before and after: {title}" loading="lazy"></section>' for name,_,title,_,_ in pairs)
    (batch/'comparisons/index.html').write_text('<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Tessera — Batch 3 comparisons</title><style>body{margin:0;background:#0b0a09;color:#eae4d8;font:16px system-ui}main{max-width:1600px;margin:auto;display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,620px),1fr));gap:24px;padding:24px}img{display:block;width:100%;height:auto}h1,p{padding:0 24px}p{color:#aaa390}</style><h1>Tessera · Before &amp; after</h1><p>Native app captures. New detail screens are paired with their previous home or controls. Fixtures are labeled in capture manifests.</p><main>'+images+'</main></html>')
    print(batch/'comparisons/index.html')

if __name__=='__main__': main()
