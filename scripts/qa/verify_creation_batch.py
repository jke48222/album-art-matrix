#!/usr/bin/env python3
"""Verify creation bytes on an explicitly selected wall and restore its display."""
import argparse,base64,json,time
from pathlib import Path
from urllib.request import Request,urlopen
from PIL import Image
from brain.art.text_modes import Ticker,Crawl

parser=argparse.ArgumentParser();parser.add_argument('--host',required=True);parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
root=Path(__file__).resolve().parents[2]
def request(path,body=None):
 req=Request('http://'+args.host+path,data=json.dumps(body).encode() if body is not None else None,headers={'Content-Type':'application/json'})
 with urlopen(req,timeout=10) as response:
  data=response.read()
  return data if path=='/frame.raw' else json.loads(data)
original=request('/state')
keys=('mode','finish','speed','ticker_text','ticker_style','ticker_colors','ticker_loop','color','color2','match_art')
restore={key:original[key] for key in keys if key in original}
if original['mode'] in ('frame','clip','video','ticker'):
 raise SystemExit('A transient creation is on the wall; postpone this check to preserve its exact playback.')
checks=[]
def check(name,value):
 checks.append({'name':name,'passed':bool(value)})
 if not value: raise AssertionError(name)
def frame_file(name,pixels):
 side=int((len(pixels)//3)**.5);Image.frombytes('RGB',(side,side),pixels).save(args.output/name)
def wait_for(pixels):
 for _ in range(30):
  actual=request('/frame.raw')
  if actual==pixels:return actual
  time.sleep(.1)
 return actual
try:
 side=int((len(request('/frame.raw'))//3)**.5)
 request('/state',{'finish':'clean'})
 lettering=(root/f'qa/batch-05/renders/lettering-{side}.rgb').read_bytes()
 request('/frame',{'px':base64.b64encode(lettering).decode()})
 actual=wait_for(lettering);check('Lettering wall RGB exactly equals native Swift output',actual==lettering);frame_file('lettering-wall.png',actual)
 with Image.open(root/f'qa/batch-05/media-tests/framing-wall-{side}.png') as image: photo=image.convert('RGB').tobytes()
 request('/frame',{'px':base64.b64encode(photo).decode()})
 actual=wait_for(photo);check('Photo wall RGB exactly equals native crop preview',actual==photo);frame_file('photo-wall.png',actual)
 request('/clip',{'fps':4,'frames':[base64.b64encode(p).decode() for p in (lettering,photo)]})
 seen=set()
 for _ in range(16):
  seen.add(request('/frame.raw'));time.sleep(.08)
 check('Both animation frames reach the wall without changed pixels',lettering in seen and photo in seen)
 for style in ('across','up','tilt'):
  body={'text':'MAKE LIGHT\nI ❤️ YOU','style':style,'colors':['#e8b04b']*4,'color':'#f4f1ea','speed':1.0,'phase':.45}
  preview=request('/ticker/preview',body);actual=base64.b64decode(preview['px'])
  renderer=Ticker(side,body['text'],color=body['color'],colors=body['colors'],loop=False) if style=='across' else Crawl(side,body['text'],color=body['color'],colors=body['colors'],loop=False,tilt=style=='tilt')
  check(style+' preview is byte-identical to deployed production renderer',actual==renderer.frame_at(preview['time']).tobytes())
  frame_file('ticker-'+style+'.png',actual)
  request('/state',{'mode':'ticker','ticker_text':body['text'],'ticker_style':style,'ticker_loop':True,'ticker_colors':body['colors'],'color':body['color'],'match_art':False,'speed':1.0})
  check(style+' accepted by live wall',request('/state')['ticker_style']==style)
  time.sleep(1.2)
  check(style+' live wall produces illuminated text',any(request('/frame.raw')))
finally:
 request('/state',restore)
 restored=request('/state')
 checks.append({'name':'Original wall settings restored','passed':all(restored.get(k)==v for k,v in restore.items())})
 result={'checks':checks,'passed':sum(c['passed'] for c in checks),'failed':sum(not c['passed'] for c in checks),'restored_mode':restored['mode'],'physical_limit':'Native RGB verified; physical LED colour and touch feel require user review.'}
 (args.output/'checks.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
