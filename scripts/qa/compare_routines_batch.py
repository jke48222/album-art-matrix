#!/usr/bin/env python3
"""Build the native before/after gallery for the five routine review units."""
import json,shutil
from pathlib import Path
from compare_home import compose,Feature
root=Path(__file__).resolve().parents[2];batch=root/'qa/batch-06';folder=batch/'comparisons';folder.mkdir(parents=True,exist_ok=True)
features=[('clock','clock','R01','Clock'),('timer','timer','R02','Timer'),('clock','alarm','R02','Daily alarm'),('sun','sun','R03','Follow the sun'),('sleep','sleep','R04','Sleep'),('wake','wake','R05','Wake up')]
rows=[]
for before,name,unit,title in features:
 rows.append(compose(root,batch/'before'/before/'room-live.png',batch/'after'/name/'room-live.png',folder/(name+'.png'),Feature(unit,title,name),390))
(folder/'manifest.json').write_text(json.dumps({'processing':'Unretouched native screenshots, equally scaled. Before left, after right.','baseline':'48663e6 with DEBUG-only navigation to existing routine pages.','comparisons':rows},indent=2)+'\n')
nav=''.join(f'<a href="#{name}">{title}</a>' for _,name,_,title in features)
sections=''.join(f'<section id="{name}"><small>{unit}</small><h2>{title}</h2><a class="full" href="{name}.png" target="_blank">Open full comparison ↗</a><img loading="lazy" src="{name}.png" alt="{title}: before left and after right"></section>' for _,name,unit,title in features)
render_cards=[]
for face,title in [('clock-24','Clock'),('timer','Countdown'),('ringing','Time is up')]:
 links=[]
 for side in (64,192,512):
  name=f'{face}-{side}-comparison.png';shutil.copy2(batch/'renders'/name,folder/name)
  links.append(f'<details {"open" if side==64 else ""}><summary>{side} × {side} pixels</summary><img loading="lazy" src="{name}" alt="{title} actual {side} pixel output, before and after"></details>')
 render_cards.append(f'<section><small>PRODUCTION RGB</small><h2>{title} on the wall</h2>'+''.join(links)+'</section>')
(folder/'index.html').write_text('''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Tessera · Pass 06</title><style>
:root{color-scheme:dark}*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:#0c0e12;color:#f0ebde;font:16px system-ui}header{max-width:1040px;padding:60px 28px 30px;margin:auto}small{font:11px monospace;letter-spacing:2px;color:#ddbd87}h1{font-size:clamp(32px,6vw,64px);letter-spacing:-2px;line-height:1.03;font-weight:550;margin:20px 0}p{max-width:750px;color:#b0b1b9;line-height:1.6}nav{position:sticky;top:0;z-index:2;display:flex;overflow:auto;gap:8px;padding:14px max(18px,calc((100vw - 984px)/2));background:#17191ff0;backdrop-filter:blur(20px);border-block:1px solid #ffffff12}a{color:inherit}nav a{flex:none;border:1px solid #ffffff24;border-radius:8px;padding:12px;text-decoration:none;font-size:13px}nav a:hover,nav a:focus{background:#ddbd87;color:#111217}main{max-width:1040px;padding:0 28px 60px;margin:auto}section{scroll-margin-top:90px;padding-top:38px;border-bottom:1px solid #ffffff1c}section img{display:block;width:100%;height:auto;margin:20px 0 32px}h2{font-size:28px;font-weight:500;letter-spacing:-.6px;margin:10px 0}.full,footer{font-size:13px;color:#b0b1b9}footer{padding:26px 0;line-height:1.6}summary{padding:15px 0;cursor:pointer}@media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}}</style><header><small>TESSERA / PASS 06 / R01–R05</small><h1>Time, in light.</h1><p>Clock, Timer and Alarm share one workspace. Sun, Sleep and Wake show their light plans and the wall’s actual state. These are native app captures; controls remain outside the wall artwork.</p></header><nav aria-label="Feature comparisons">'''+nav+'<a href="#pixels">Wall pixels</a></nav><main>'+sections+'<div id="pixels">'+''.join(render_cards)+'''</div><footer>Before left, after right. Controlled screen fixtures use the same values. Production renderer comparisons use matched time and duration at 64, 192 and 512 pixels, enlarged without smoothing. Sun/Sleep/Wake diagrams describe brightness plans; they do not replace the current artwork. Live wall checks restored the original display and every touched schedule setting. Physical LED colour and touch feel still need in-person review.</footer></main></html>''')
print(folder/'index.html')
