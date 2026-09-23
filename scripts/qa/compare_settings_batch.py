#!/usr/bin/env python3
"""Native before/after gallery, matched wall pixels, and captured edge states."""
import json,shutil
from pathlib import Path
from compare_home import compose,Feature

root=Path(__file__).resolve().parents[2];batch=root/'qa/batch-07';out=batch/'comparisons';out.mkdir(parents=True,exist_ok=True)
features=[('settings','D02','Settings'),('timer','R02','Timer complete'),('alarm','R02','Alarm & snooze'),('idle','R06','Between songs'),('ask','F01','Ask the wall'),('note','F02','Notes')]
rows=[];sections=[]
for name,unit,title in features:
 rows.append(compose(root,batch/'before'/name/'room-live.png',batch/'after'/name/'room-live.png',out/(name+'.png'),Feature(unit,title,name),390))
 extras=[]
 for state,label in [('room-large','Largest accessibility text'),('room-offline','Wall offline')]:
  target=f'{name}-{state}.png';shutil.copy2(batch/'after'/name/(state+'.png'),out/target)
  extras.append(f'<a href="{target}" target="_blank">{label} ↗</a>')
 sections.append(f'<section id="{name}"><small>{unit}</small><h2>{title}</h2><p class="links"><a href="{name}.png" target="_blank">Full comparison ↗</a>'+''.join(extras)+f'</p><img loading="lazy" src="{name}.png" alt="{title}, before left and after right"></section>')
render_sections=[]
for name,title in [('timer-complete','A timer, completed'),('alarm-ringing','Your daily cue'),('alarm-snoozed','Five more minutes')]:
 details=[]
 for side in (64,192,512):
  filename=f'{name}-{side}-comparison.png';shutil.copy2(batch/'endings'/filename,out/filename)
  details.append(f'<details {"open" if side==64 else ""}><summary>{side} × {side} native pixels</summary><img loading="lazy" src="{filename}" alt="{title}, matched native output"></details>')
 motion=batch/'endings'/f'{name}-motion.gif'
 if motion.exists():
  shutil.copy2(motion,out/motion.name)
  details.append(f'<details><summary>Watch the light settle · 12 seconds</summary><img class="motion" loading="lazy" src="{motion.name}" alt="Slow completion choreography"></details>')
 render_sections.append(f'<section><small>PRODUCTION RGB</small><h2>{title}</h2>'+''.join(details)+'</section>')
states=[]
for name,title in [('settings-search','Search by intention'),('settings-empty','No search results'),('settings-bottom','Care & connection'),('ask-answer','An answer, kept here'),('ask-thinking','Thinking'),('ask-key','Connect a service'),('note-draft','Actual ticker preview'),('note-active','A note on the wall'),('completion-entry','One route to the controls')]:
 source=batch/'after'/name/'room-live.png'
 if not source.exists():continue
 target='state-'+name+'.png';shutil.copy2(source,out/target)
 states.append(f'<details><summary>{title}</summary><img class="state" loading="lazy" src="{target}" alt="{title}, native iOS capture"></details>')
nav=''.join(f'<a href="#{name}">{title}</a>' for name,_,title in features)
(out/'manifest.json').write_text(json.dumps({'base':'cb5acad','processing':'Native screenshots equally scaled with no retouching; before left, after right.','comparisons':rows,'wall':'Matched production renderer output enlarged with nearest-neighbour sampling.'},indent=2)+'\n')
(out/'index.html').write_text('''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Tessera · Pass 07</title><style>
:root{color-scheme:dark}*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:#101212;color:#eee7d9;font:16px system-ui}header,main{max-width:1040px;margin:auto;padding:42px 28px}small{font:11px monospace;letter-spacing:2px;color:#e5be83}h1{font-size:clamp(36px,6vw,68px);font-weight:550;letter-spacing:-2.5px;line-height:1.03;margin:20px 0}p{max-width:730px;color:#b8bbae;line-height:1.6}nav{position:sticky;top:0;z-index:2;display:flex;overflow:auto;gap:8px;padding:14px max(18px,calc((100vw - 984px)/2));background:#1a201ef5;backdrop-filter:blur(16px);border-block:1px solid #ffffff13}a{color:inherit}nav a{flex:none;border:1px solid #ffffff26;border-radius:10px;padding:12px;text-decoration:none;font-size:13px}a:hover,a:focus{color:#e5be83}.links{display:flex;gap:16px;flex-wrap:wrap;font-size:13px}section{scroll-margin-top:90px;padding:18px 0 36px;border-bottom:1px solid #ffffff19;margin-bottom:24px}h2{font-size:30px;letter-spacing:-.8px;font-weight:550;margin:10px 0}img{display:block;width:100%;height:auto;margin:24px 0 0}summary{padding:18px 0;cursor:pointer;color:#c7cfbd}.motion{max-width:384px}.state{max-width:420px;margin:20px auto 40px}footer{color:#afb2aa;font-size:13px;line-height:1.65;padding:25px 0}@media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}}</style><header><small>TESSERA / PASS 07 / FIVE REVIEW UNITS</small><h1>A place for everything.<br>A better last moment.</h1><p>Settings becomes a searchable home for the whole wall. Timers and alarms get distinct light ceremonies, with repeat and snooze. Quiet moments, Ask and Notes now carry their own visual character and clearer, more reliable controls.</p><p>Actual native captures: before on the left, after on the right.</p></header><nav aria-label="Comparisons">'''+nav+'<a href="#pixels">Wall pixels</a><a href="#states">More states</a></nav><main>'+''.join(sections)+'<div id="pixels">'+''.join(render_sections)+'</div><section id="states"><small>NATIVE STATES</small><h2>Ready, thinking, offline, and in between.</h2>'+''.join(states)+'''</section><footer>Native screens use isolated, controlled fixtures. Wall comparisons show identical time and duration at true 64, 192 and 512 pixel resolutions, enlarged without smoothing. Hardware verification exercises acknowledged actions on the managed wall service and restores touched settings. Provider failure and concurrency cases use controlled responses; no paid live inference is needed. Physical LED colour, spoken audio and touch feel still need an in-person check.</footer></main></html>''')
print(out/'index.html')
