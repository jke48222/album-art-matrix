#!/usr/bin/env python3
"""Check acknowledged endings/notes on a wall and restore every touched setting."""
from __future__ import annotations
import argparse,base64,json,math,time,subprocess,shlex
from datetime import datetime,timezone,timedelta
from pathlib import Path
from urllib.request import Request,urlopen
from urllib.error import HTTPError
from PIL import Image
from brain.art.text_modes import Countdown


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host',required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--ssh-host',help='Run the same HTTP requests through an existing SSH connection')
    parser.add_argument('--skip-daily-alarm',action='store_true',help='A daily cue has already been exercised today')
    args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    checks=[];limitations=[]
    def request(path,body=None,allow_error=False):
        if args.ssh_host:
            payload = base64.b64encode(json.dumps(body).encode()).decode() if body is not None else None
            script = "import base64,json;from urllib.request import Request,urlopen;from urllib.error import HTTPError\n"
            script += f"data=base64.b64decode({payload!r}) if {payload!r} is not None else None\n"
            script += f"r=Request('http://127.0.0.1:8788'+{path!r},data=data,headers={{'Content-Type':'application/json'}})\n"
            script += "try:\n r=urlopen(r,timeout=12)\nexcept HTTPError as e:\n r=e\nprint(json.dumps({'status':r.code,'data':base64.b64encode(r.read()).decode()}))"
            reply=subprocess.run(['ssh','-o','ConnectTimeout=8','-o','ControlMaster=auto','-o','ControlPersist=600','-o','ControlPath=/tmp/tessera-batch07-ssh.sock',args.ssh_host,'python3 -c '+shlex.quote(script)],capture_output=True,text=True,check=True,timeout=25)
            response=json.loads(reply.stdout);code=response['status'];data=base64.b64decode(response['data'])
            if code>=400 and not allow_error:raise RuntimeError(f'HTTP {code} from {path}')
            result=data if path=='/frame.raw' else json.loads(data)
            return (code,result) if allow_error else result
        req=Request('http://'+args.host+path,data=json.dumps(body).encode() if body is not None else None,headers={'Content-Type':'application/json'})
        try:
            with urlopen(req,timeout=12) as response:data=response.read();code=response.status
        except HTTPError as error:
            if not allow_error:raise
            data=error.read();code=error.code
        result=data if path=='/frame.raw' else json.loads(data)
        return (code,result) if allow_error else result
    def check(name,value):
        checks.append({'name':name,'passed':bool(value)})
        if not value:raise AssertionError(name)
    def post(body):
        result=request('/state',body)
        if result.get('rejected'):raise AssertionError(result['rejected'])
        return result
    def wait(predicate,seconds=8):
        end=time.monotonic()+seconds
        while time.monotonic()<end:
            s=request('/state')
            if predicate(s):return s
            time.sleep(.15)
        checks.append({'name':'Await expected wall state','passed':False,'last':{k:s.get(k) for k in ('mode','timer_state','display_mode')}})
        raise AssertionError('Wall state failed to settle')
    def frame(name):
        data=request('/frame.raw');side=math.isqrt(len(data)//3)
        Image.frombytes('RGB',(side,side),data).save(args.output/name);return data
    original=request('/state')
    original_note=request('/note')
    if original['mode'] in ('frame','clip','video','ticker','timer') or original.get('sleep_remaining_s') is not None or original.get('wake_active') or original_note.get('active'):
        raise SystemExit('Active transient content: preserve it before running wall verification.')
    keys=('mode','finish','color','color2','match_art','brightness','sun','sun_night','alarm_enabled','alarm_time','wake_enabled','wake_time','wake_fade_min','idle','away','ticker_text','ticker_style','ticker_colors','ticker_loop','speed')
    restore={k:original[k] for k in keys if k in original}
    (args.output/'original-settings.json').write_text(json.dumps(restore,indent=2)+'\n')
    try:
        post({'mode':'clock','finish':'clean','color':'#e8b04b','color2':'#668fc1','match_art':False,'sun':'off','brightness':1.,'alarm_enabled':False,'wake_enabled':False,'away':'stay','idle':'hold'})
        side=math.isqrt(len(request('/frame.raw'))//3)
        for kind in ('countdown','alarm'):
            reply=request('/routines/preview',{'face':'timer','remaining_s':-2.5,'total_s':600,'kind':kind})
            pixels=base64.b64decode(reply['px'])
            expected=Countdown(side,'#e8b04b','#668fc1').frame_at(-2.5,600,kind=kind).tobytes()
            check(kind+' ending preview matches exact production RGB',pixels==expected)
            Image.frombytes('RGB',(side,side),pixels).save(args.output/(kind+'-preview.png'))
        check('Read-only completion previews do not start a timer',request('/state')['timer_state']=='idle')
        post({'timer_min':.1})
        ring=wait(lambda s:s['timer_state']=='ringing',10)
        check('Six-second countdown reaches its identified ending',bool(ring.get('timer_id')) and ring['timer_kind']=='countdown')
        check('Completion is illuminated on the actual wall',any(frame('timer-complete-live.png')))
        old_id=ring['timer_id'];post({'timer_action':'repeat','timer_id':old_id})
        repeated=wait(lambda s:s['timer_state']=='counting')
        check('Repeat retains original duration with a new event ID',repeated['timer_total_s']==6 and repeated['timer_id']!=old_id)
        stale=request('/state',{'timer_action':'stop','timer_id':old_id})
        check('Delayed old Stop cannot stop the repeat',bool(stale.get('rejected')) and request('/state')['timer_id']==repeated['timer_id'])
        mixed=request('/state',{'timer_action':'stop','timer_id':repeated['timer_id'],'brightness':.5})
        check('Mixed timer action rejects atomically',bool(mixed.get('rejected')) and request('/state')['timer_id']==repeated['timer_id'] and request('/state')['brightness']==1.)
        post({'timer_action':'stop','timer_id':repeated['timer_id']})
        check('Done restores the previous face',wait(lambda s:s['timer_state']=='idle')['mode']=='clock')
        current=request('/state');zone=timezone(timedelta(seconds=current['wall_utc_offset_s']))
        local=datetime.fromtimestamp(current['wall_time'],zone)
        # Firing a test daily cue consumes today's alarm. Only do it when the
        # user's original alarm is disabled or its time has already passed.
        original_alarm=original.get('alarm_time','07:00')
        if not args.skip_daily_alarm and (not original.get('alarm_enabled') or original_alarm<local.strftime('%H:%M')):
            cue=local.strftime('%H:%M');post({'alarm_time':cue,'alarm_enabled':True})
            alarm=wait(lambda s:s['timer_state']=='ringing' and s['timer_kind']=='alarm')
            check('Daily alarm creates a distinct event',bool(alarm.get('timer_id')))
            check('Alarm frame is illuminated',any(frame('alarm-ringing-live.png')))
            post({'timer_action':'snooze','timer_id':alarm['timer_id']})
            snooze=wait(lambda s:s['timer_state']=='counting')
            check('Snooze schedules five minutes and preserves alarm kind',snooze['timer_kind']=='alarm' and snooze['timer_total_s']==300 and snooze['timer_snoozed'] and snooze['timer_id']!=alarm['timer_id'])
            check('Snooze preserves the daily schedule',snooze['alarm_enabled'] and snooze['alarm_time']==cue)
            time.sleep(.2);frame('alarm-snooze-live.png')
            post({'timer_action':'stop','timer_id':snooze['timer_id']})
            check('Stop alarm restores the preceding face',request('/state')['mode']=='clock')
            post({'alarm_enabled':False})
        else:limitations.append('Daily alarm firing skipped on this run because it was already checked today or a future user alarm must be preserved.')
        first=request('/note',{'text':'A LITTLE LIGHT','minutes':.5})
        check('New note is acknowledged with its own identity',first.get('shown') is True and bool(first.get('id')))
        time.sleep(.3);check('Note renders on actual wall',any(frame('note-live.png')))
        second=request('/note',{'text':'TAKE YOUR TIME','minutes':.5})
        check('Replacing a note gives it a new identity',second.get('id')!=first.get('id'))
        code,reply=request('/note',{'clear':True,'id':first['id']},True)
        check('Old note Take down rejects without deleting replacement',code==409 and request('/note').get('id')==second['id'])
        code,reply=request('/note',{'text':'BAD DURATION','minutes':float('nan')},True)
        check('Nonfinite note duration is rejected without replacing it',code==400 and request('/note').get('id')==second['id'])
        reply=request('/note',{'clear':True,'id':second['id']})
        check('Take down confirms removal',reply.get('cleared') is True and request('/note').get('active') is False)
        check('Taking down a note restores the original clock face',request('/state')['mode']=='clock')
        expiring=request('/note',{'text':'UNTIL NEXT TIME','minutes':.5})
        check('Temporary note duration is reported',0<request('/note')['seconds_left']<=30)
        wait(lambda s:s['mode']=='clock',34)
        check('Note expiry returns automatically and clears active receipt',not request('/note').get('active'))
        post({'mode':'off','idle':'ambient','away':'off'})
        time.sleep(.4)
        off=request('/state')
        check('Explicit Off stays Off when the app contacts the wall',off['mode']=='off' and off['display_mode']=='off')
        check('Off reports zero effective brightness',off['effective_brightness']==0.)
        check('Off output contains no residual light',not any(frame('off-live.png')))
        code,reply=request('/ask',{'text':'','reply':'text'},True)
        check('Empty Ask fails before a paid request',code==400)
        ask=request('/ask');check('Ask reports explicit pending state',isinstance(ask.get('pending'),bool))
        limitations.append('No live inference charge was made. Ask inference failure/busy behavior is tested with controlled provider responses.')
    finally:
        note=request('/note')
        if note.get('active') and note.get('id'):request('/note',{'clear':True,'id':note['id']})
        post({'timer_min':0.,**restore})
        restored=request('/state')
        checks.append({'name':'Every touched setting restored','passed':all(restored.get(k)==v for k,v in restore.items())})
        result={'passed':sum(c['passed'] for c in checks),'failed':sum(not c['passed'] for c in checks),'checks':checks,'restored_mode':restored['mode'],'limitations':limitations+['Native RGB does not certify physical LED colour; inspect the panel in person.']}
        (args.output/'checks.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))
    return 1 if result['failed'] else 0

if __name__=='__main__':raise SystemExit(main())
