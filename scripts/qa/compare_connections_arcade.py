#!/usr/bin/env python3
"""Publish faithful native comparisons, state captures, and unsmoothed production pixels."""
from pathlib import Path
import html,json,shutil,hashlib
from PIL import Image,ImageDraw
from compare_home import compose,Feature
ROOT=Path(__file__).resolve().parents[2];Q=ROOT/'qa/batch-13';OUT=Q/'comparisons'
FEATURES=[('snake','G18','Snake'),('tetris','G19','Tetris'),('services','S01','Services'),('appleMusic','S02','Apple Music'),('spotify','S03','Spotify')]
def copy(p,name=None):
 target=OUT/(name or p.name);shutil.copy2(p,target);return target.name
def urls(value):
 if isinstance(value,dict):
  return {v for k,v in value.items() if k in ('url','mobbin_url') and isinstance(v,str) and v.startswith('https://')}|set().union(*(urls(v) for v in value.values()))
 if isinstance(value,list):return set().union(*(urls(v) for v in value)) if value else set()
 return set()
def main():
 OUT.mkdir(parents=True,exist_ok=True);sections=[];rows=[]
 for name,unit,title in FEATURES:
  before=Q/'before'/('services' if name=='appleMusic' else name)/'room-live.png';after=Q/'after'/name/'room-live.png'
  rows.append(compose(ROOT,before,after,OUT/(name+'.png'),Feature(unit,title,name),390))
  note='<p>Apple Music previously existed only as a row in Services; the left shows that original entry point.</p>' if name=='appleMusic' else ''
  sections.append(f'<section id="{name}"><small>{unit}</small><h2>{title}</h2>{note}<img src="{name}.png" alt="{title}: before left, after right" loading="lazy"></section>')
 states=[]
 for folder in sorted((Q/'after').iterdir()):
  if not folder.is_dir():continue
  for source in sorted(folder.glob('room-*.png')):
   if source.stem.endswith('-frame'):continue
   if folder.name in [v[0] for v in FEATURES] and source.stem=='room-live':continue
   name=copy(source,folder.name+'-'+source.name);label=(folder.name+' / '+source.stem.removeprefix('room-')).replace('-',' ')
   states.append(f'<details><summary>{html.escape(label)}</summary><img class="phone" src="{name}" loading="lazy" alt="Native {html.escape(label)}"></details>')
 sections.append('<section id="states"><small>ACTUAL NATIVE CAPTURES</small><h2>Every state has a place.</h2><p>Large text, connection failures, permission previews, pauses and endings. Apple Music previews are explicitly labelled and use authored local metadata.</p>'+''.join(states)+'</section>')
 pairs=[]
 for name in ['snake','tetris']:
  for phase in ['ready','playing','paused','lost']:
   details=[]
   for side in [64,192,512]:
    factor=max(1,384//side);size=side*factor;canvas=Image.new('RGB',(size*2+48,size+52),'#101315');d=ImageDraw.Draw(canvas)
    for i,version in enumerate(['before','after']):
     path=Q/'pixels'/f'{name}-{phase}-{version}-{side}.png';im=Image.open(path);assert im.size==(side,side)
     d.text((16+i*(size+16),15),version.upper()+f' / {side}px',fill='#c8d9c8');canvas.paste(im.resize((size,size),Image.Resampling.NEAREST),(16+i*(size+16),40));copy(path)
    filename=f'{name}-{phase}-{side}-pair.png';canvas.save(OUT/filename);pairs.append(filename)
    details.append(f'<details {"open" if side==64 else ""}><summary>{side} × {side} native pixels</summary><img class="pixels" src="{filename}" loading="lazy" alt="{name} {phase}: matched production renders"></details>')
   sections.append(f'<section><small>SHARED ARCADE COMPOSITION</small><h2>{name.title()} / {phase}</h2><p>Matched state and clock. Baseline games had no pause state; their clock is frozen for comparison. Before left, after right.</p>'+''.join(details)+'</section>')
 hardware=[]
 for name in ['snake','tetris']:
  paths=[Q/'hardware'/v/(name+'-live.png') for v in ['before','after']]
  if all(p.exists() for p in paths):
   im=Image.new('RGB',(816,438),'#101315');d=ImageDraw.Draw(im)
   for i,p in enumerate(paths):d.text((16+i*400,12),['BEFORE','AFTER'][i],fill='#c8d9c8');im.paste(Image.open(p).resize((384,384),Image.Resampling.NEAREST),(16+i*400,40))
   filename=name+'-hardware.png';im.save(OUT/filename);hardware.append(f'<h3>{name.title()}</h3><img class="pixels" src="{filename}" alt="Raw RGB from managed wall before and after">')
 if hardware:sections.append('<section><small>YOUR WALL</small><h2>Running on the managed service.</h2><p>Real runtime frames after actual moves. The wall returned to Off after each test. These are RGB captures, not photographs or LED colour certification.</p>'+''.join(hardware)+'</section>')
 refs=set()
 for p in Q.glob('references*.json'):refs.update(urls(json.loads(p.read_text())))
 sections.append('<section id="references"><small>RESEARCH APPLIED IN CODE</small><h2>References</h2><ul>'+''.join(f'<li><a href="{html.escape(u,quote=True)}" target="_blank" rel="noreferrer">{html.escape(u.removeprefix("https://"))}</a></li>' for u in sorted(refs))+'</ul></section>')
 receipts=[]
 for filename in ['validation.json','wall-deployment.json','phone-deployment.json','native-interactions.json']:
  p=Q/filename
  if p.exists():receipts.append('<a href="'+copy(p)+'">'+filename+'</a>')
 nav=''.join(f'<a href="#{n}">{t}</a>' for n,_,t in FEATURES)
 style='''<style>:root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;background:#101315;color:#efece3;font:16px system-ui}header,main{max-width:1050px;margin:auto;padding:40px 24px}small{color:#add2c5;letter-spacing:2px;font:11px monospace}h1{font-size:clamp(38px,6vw,70px);line-height:1.02;letter-spacing:-2px;font-weight:550}h2{font-size:32px;font-weight:550;letter-spacing:-1px}p,li{color:#a8aca6;line-height:1.7}p{max-width:740px}a{color:inherit;overflow-wrap:anywhere}nav{position:sticky;top:0;z-index:2;display:flex;gap:12px;overflow:auto;padding:18px 24px;background:#171b1df5;border-block:1px solid #ffffff15}nav a{flex:none;text-decoration:none;padding:8px 16px;border-radius:8px;background:#ffffff09}section{padding:22px 0 40px;border-bottom:1px solid #ffffff20;scroll-margin-top:90px}img{display:block;width:100%;height:auto;margin-top:24px}.phone{max-width:420px;margin:24px auto}.pixels{image-rendering:pixelated}summary{padding:20px 0;cursor:pointer;color:#add2c5}li{padding:6px 0;font-size:13px}footer{display:flex;gap:20px;flex-wrap:wrap;padding:30px 0;font-size:13px}a:focus-visible,summary:focus-visible{outline:2px solid #add2c5;outline-offset:5px}</style>'''
 page='<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Tessera · Pass 13</title>'+style+'<header><small>TESSERA / PASS 13 / G18 · G19 · S01 · S02 · S03</small><h1>Play a little.<br>Connect your world.</h1><p>Two arcade classics, one considered home for connections, and clearer paths from Apple Music and Spotify to your wall.</p><p>Full native screenshots, equally scaled: before left, after right. No screen is cropped or retouched. Service data uses controlled fixtures; no account credentials were changed for these captures.</p></header><nav>'+nav+'<a href="#states">More states</a><a href="#references">References</a></nav><main>'+''.join(sections)+'<footer>'+''.join(receipts)+'</footer></main></html>'
 (OUT/'index.html').write_text(page)
 (OUT/'manifest.json').write_text(json.dumps({'base':'8bf3600','units':[u for _,u,_ in FEATURES],'native':rows,'pixel_pairs':pairs,'states':len(states),'references':sorted(refs)},indent=2)+'\n')
 print(OUT/'index.html')
if __name__=='__main__':main()
