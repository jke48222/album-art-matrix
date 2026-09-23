#!/usr/bin/env python3
"""Exercise production routine APIs on a chosen wall; restore all touched settings."""
from __future__ import annotations
import argparse,base64,json,math,os,time
from pathlib import Path
from urllib.request import Request,urlopen
from PIL import Image
from brain.art.text_modes import Clock,Countdown
from brain.art.pipeline import apply_finish

parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--host',required=True);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
def request(path,body=None):
 req=Request('http://'+args.host+path,data=json.dumps(body).encode() if body is not None else None,headers={'Content-Type':'application/json'})
 with urlopen(req,timeout=10) as response:
  data=response.read();return data if path=='/frame.raw' else json.loads(data)
original=request('/state')
if original['mode'] in ('frame','clip','video','ticker','timer') or original.get('sleep_remaining_s') is not None or original.get('wake_active'):
 raise SystemExit('Preserve the active transient artwork/routine before testing.')
keys=('mode','finish','color','color2','match_art','brightness','clock_24h','sun','sun_night','alarm_enabled','alarm_time','wake_enabled','wake_time','wake_fade_min')
restore={key:original[key] for key in keys if key in original};checks=[]
def check(name,value):
 checks.append({'name':name,'passed':bool(value)})
 if not value:raise AssertionError(name)
def post(body):
 result=request('/state',body)
 if result.get('rejected'):raise AssertionError(str(result['rejected']))
 return result
def wait(predicate,seconds=8):
 deadline=time.monotonic()+seconds
 while time.monotonic()<deadline:
  state=request('/state')
  if predicate(state):return state
  time.sleep(.15)
 raise AssertionError('Wall state did not settle')
def save_frame(name):
 pixels=request('/frame.raw');side=math.isqrt(len(pixels)//3)
 Image.frombytes('RGB',(side,side),pixels).save(args.output/name);return pixels
try:
 os.environ['TZ']=original['wall_timezone'];time.tzset()
 check('Wall reports its configured IANA timezone',original['wall_timezone']=='America/New_York')
 check('Wall routine metadata contains finite time and effective brightness',math.isfinite(original['wall_time']) and math.isfinite(original['effective_brightness']))
 # Avoid a daily schedule interrupting a short test; the exact values are restored.
 post({'alarm_enabled':False,'wake_enabled':False,'mode':'clock','finish':'clean','color':'#e8b04b','color2':'#668fc1','match_art':False,'sun':'off','brightness':1.})
 side=math.isqrt(len(request('/frame.raw'))//3)
 for twenty_four in (True,False):
  at=1790163024.;payload={'face':'clock','twenty_four':twenty_four,'at':at};preview=request('/routines/preview',payload)
  pixels=base64.b64decode(preview['px'])
  check(('24' if twenty_four else '12')+' hour preview matches production bytes',pixels==Clock(side,'#e8b04b',twenty_four).frame_at(0,when=at).tobytes())
  Image.frombytes('RGB',(side,side),pixels).save(args.output/f'clock-preview-{24 if twenty_four else 12}.png')
 post({'clock_24h':False});check('12-hour format is acknowledged',request('/state')['clock_24h'] is False)
 post({'clock_24h':True});time.sleep(.3);check('Clock renders illuminated native wall pixels',any(save_frame('clock-live.png')))
 preview=request('/routines/preview',{'face':'timer','remaining_s':462,'total_s':600})
 check('Timer preview matches production bytes',base64.b64decode(preview['px'])==Countdown(side,'#e8b04b','#668fc1').frame_at(462,600).tobytes())
 check('Preview never starts a timer',request('/state')['mode']=='clock' and request('/state')['timer_state']=='idle')
 post({'timer_min':.1});running=wait(lambda s:s['timer_state']=='counting');check('Timer starts with correct total',running['timer_total_s']==6)
 first=running['timer_remaining_s'];time.sleep(1.2);second=request('/state')['timer_remaining_s'];check('Timer decreases over real elapsed time',second<first)
 save_frame('timer-live.png');ring=wait(lambda s:s['timer_state']=='ringing');check('Timer completion rings visibly',ring['timer_ringing']);save_frame('timer-ringing.png')
 post({'timer_min':0.});check('Stopping returns to previous clock face',request('/state')['mode']=='clock' and request('/state')['timer_state']=='idle')
 post({'mode':'ambient'});post({'timer_min':.1});post({'timer_min':0.,'mode':'clock'});check('Explicit clock destination wins cancellation',request('/state')['mode']=='clock')
 post({'sleep_fade_min':.2});state=wait(lambda s:s['sleep_state']=='fading');time.sleep(.5);dim=request('/state');check('Sleep reports active total and reduced brightness',state['sleep_total_s']==12 and dim['effective_brightness']<1)
 post({'sleep_fade_min':0.});cancel=wait(lambda s:s['sleep_state']=='cancelled');check('Cancel sleep restores selected brightness',cancel['effective_brightness']==1 and cancel['mode']=='clock')
 post({'sleep_fade_min':.025});done=wait(lambda s:s['sleep_state']=='completed' and s['mode']=='off');check('Sleep completion turns the wall off',done['effective_brightness']==0);time.sleep(.2);check('Sleeping wall is black',not any(save_frame('sleep-complete.png')))
 post({'mode':'clock','sun':'on','sun_night':.2});solar=wait(lambda s:s['sun_phase']!='off');check('Sun updates immediately after enabling',solar['sun_phase'] in ('day','dawn','dusk','night','polar_day','polar_night','location'))
 if solar['sun_phase']!='location':check('Solar output includes bounded factor',.2<=solar['sun_factor']<=1.)
 future=time.localtime(time.time()+600);wake_time=f'{future.tm_hour:02d}:{future.tm_min:02d}'
 post({'wake_enabled':True,'wake_time':wake_time,'wake_fade_min':10.});schedule=request('/state')
 check('Wake save returns future start and full-light endpoint',schedule['wake_next_at']>schedule['wall_time'] and abs(schedule['wake_next_end_at']-schedule['wake_next_at']-600)<.001)
 bad=request('/state',{'alarm_time':'¹²:00'});check('Malformed alarm time is rejected without crashing',bool(bad.get('rejected')))
finally:
 post({'timer_min':0.,'sleep_fade_min':0.,**restore})
 restored=request('/state');checks.append({'name':'Every touched user setting restored','passed':all(restored.get(k)==v for k,v in restore.items())})
 result={'checks':checks,'passed':sum(c['passed'] for c in checks),'failed':sum(not c['passed'] for c in checks),'restored_mode':restored['mode'],'limitations':['RGB and reported brightness verified; physical LED color needs in-person review.','Daily wake/alarm firing and DST transitions exercised with controlled backend clocks, not by changing physical wall time.']}
 (args.output/'checks.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
