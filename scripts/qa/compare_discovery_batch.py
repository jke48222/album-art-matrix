#!/usr/bin/env python3
"""Publish unretouched native capture comparisons and production RGB proofs."""
import html
import json
import shutil
from pathlib import Path
from compare_home import Feature, compose

root=Path(__file__).resolve().parents[2]
batch=root/'qa/batch-08';out=batch/'comparisons';out.mkdir(parents=True,exist_ok=True)
features=[('show','F03','Show me'),('earworm','F04','Earworm'),('imagine','F05','Imagine'),('voice','F06','Voice'),('hearing','F07','Hearing & gestures')]
rows=[];sections=[]
for name,unit,title in features:
    rows.append(compose(root,batch/'before'/name/'room-live.png',batch/'after'/name/'room-live.png',out/f'{name}.png',Feature(unit,title,name),390))
    extras=[]
    for state,label in [('room-large','Largest accessibility text'),('room-offline','Wall offline')]:
        target=f'{name}-{state}.png';shutil.copy2(batch/'after'/name/f'{state}.png',out/target)
        extras.append(f'<a href="{target}" target="_blank">{label} ↗</a>')
    sections.append(f'<section id="{name}"><small>{unit}</small><h2>{title}</h2><div class="links"><a href="{name}.png" target="_blank">Full comparison ↗</a>'+''.join(extras)+f'</div><img loading="lazy" src="{name}.png" alt="{title}: before left, after right"></section>')
wall=[]
for name,title in [('imagine-waiting','The first marks of an idea'),('imagine-partial','Colour arriving'),('imagine-done','The finished composition'),('earworm-result','An uninterrupted sleeve'),('voice-listening','Listening in light'),('voice-thinking','A moment to think'),('voice-answer','The answer on the wall')]:
    details=[]
    for side in (64,192,512):
        filename=f'{name}-{side}-comparison.png';shutil.copy2(batch/'wall'/filename,out/filename)
        details.append(f'<details {"open" if side==64 else ""}><summary>{side} × {side} native RGB pixels</summary><img loading="lazy" src="{filename}" alt="{title}, equal-size native pixel comparison"></details>')
    motion=batch/'wall'/f'{name}-motion-comparison.gif'
    if motion.exists():
        shutil.copy2(motion,out/motion.name)
        details.append(f'<details><summary>Play the four-second motion comparison</summary><img loading="lazy" src="{motion.name}" alt="{title}, before and after motion"></details>')
    note='The existing wall composition is preserved; the new native screen displays these same pixels.' if name.startswith('voice') or name in ('imagine-partial','imagine-done') else 'Production renderer output from the baseline and this pass, using the same controlled input.'
    wall.append(f'<section><small>PRODUCTION RENDERER</small><h2>{title}</h2><p>{note}</p>'+''.join(details)+'</section>')
states=[]
for folder in sorted((batch/'after').iterdir()):
    if '-' not in folder.name:continue
    image=folder/'room-live.png'
    if not image.exists():continue
    target='state-'+folder.name+'.png';shutil.copy2(image,out/target)
    title=html.escape(folder.name.replace('-',' ').title())
    states.append(f'<details><summary>{title}</summary><img loading="lazy" class="phone" src="{target}" alt="{title}: native iOS capture"></details>')
refs=set()
def find_urls(value):
    if isinstance(value,dict):
        for k,v in value.items():
            if k=='url' and isinstance(v,str):refs.add(v)
            else:find_urls(v)
    elif isinstance(value,list):
        for v in value:find_urls(v)
for file in batch.glob('references-*.json'):find_urls(json.loads(file.read_text()))
reference_links=''.join(f'<li><a href="{html.escape(url,quote=True)}" target="_blank" rel="noreferrer">{html.escape(url.replace("https://",""))} ↗</a></li>' for url in sorted(refs))
nav=''.join(f'<a href="#{name}">{title}</a>' for name,_,title in features)
style='''<style>:root{color-scheme:dark}*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:#101212;color:#eee7d9;font:16px system-ui}header,main{max-width:1040px;margin:auto;padding:42px 28px}small{font:11px monospace;letter-spacing:2px;color:#accfc5}h1{font-size:clamp(36px,6vw,68px);font-weight:550;letter-spacing:-2.5px;line-height:1.03;margin:20px 0}p{max-width:750px;color:#b8bbae;line-height:1.6}nav{position:sticky;top:0;z-index:2;display:flex;overflow:auto;gap:8px;padding:14px max(18px,calc((100vw - 984px)/2));background:#1a201ef5;backdrop-filter:blur(16px);border-block:1px solid #ffffff13}a{color:inherit}nav a{flex:none;border:1px solid #ffffff26;border-radius:10px;padding:12px;text-decoration:none;font-size:13px}a:hover,a:focus{color:#d5b7ef}.links{display:flex;gap:16px;flex-wrap:wrap;font-size:13px}section{scroll-margin-top:90px;padding:18px 0 36px;border-bottom:1px solid #ffffff19;margin-bottom:24px}h2{font-size:30px;letter-spacing:-.8px;font-weight:550;margin:10px 0}img{display:block;width:100%;height:auto;margin:24px 0 0}summary{padding:18px 0;cursor:pointer;color:#c7cfbd}.phone{max-width:420px;margin:20px auto 40px}footer,li{color:#afb2aa;font-size:13px;line-height:1.65;padding:8px 0}li a{overflow-wrap:anywhere}@media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}}</style>'''
page='''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Tessera · Pass 08</title>'''+style+'''<header><small>TESSERA / PASS 08 / F03–F07</small><h1>A little wonder.<br>A room that listens.</h1><p>Find a picture, place a half-remembered song, create a new world, or speak to the room. Five native destinations with clearer actions, expressive live feedback, and results you can trust.</p><p>Actual native app captures: before on the left, after on the right. Controlled local fixtures keep every comparison reproducible.</p></header><nav aria-label="Comparison sections">'''+nav+'<a href="#pixels">Wall pixels</a><a href="#states">More states</a><a href="#references">References</a></nav><main>'+''.join(sections)+'<div id="pixels">'+''.join(wall)+'</div><section id="states"><small>NATIVE STATES</small><h2>Results, progress and recovery.</h2>'+''.join(states)+'</section><section id="references"><small>RESEARCH APPLIED IN CODE</small><h2>References</h2><ul>'+reference_links+'''</ul></section><footer>The app is built from production Swift; renders come from production Python at true 64, 192 and 512 pixel resolutions. Screens are resized uniformly without retouching. QA artwork and provider responses are authored fixtures, with no paid inference. The final physical iPhone build is installed; opening it needs the phone unlocked. The wall was unreachable during this pass, so deployment and physical LED/microphone checks remain pending. Native captures verify rendering and API states; they do not certify touch interaction or spoken recognition.</footer></main></html>'''
(out/'index.html').write_text(page)
(out/'manifest.json').write_text(json.dumps({'base':'f31d1f1','processing':'Native app screenshots scaled equally, not retouched. Before left, after right.','comparisons':rows,'wall_manifest':'../wall/manifest.json','physical_wall':'unreachable; deployment pending','references':sorted(refs)},indent=2)+'\n')
print(out/'index.html')
