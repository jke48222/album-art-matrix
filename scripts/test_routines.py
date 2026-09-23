#!/usr/bin/env python3
"""Compile production wall routine clocks and test receipt/time-zone semantics."""
from pathlib import Path
import argparse,json,subprocess,tempfile
from test_playback_identity import declarations

parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--json',type=Path);args=parser.parse_args()
root=Path(__file__).resolve().parents[1];app=root/'tessera/Tessera'
source='import Foundation\n'+declarations(app/'WallLink.swift','struct WallState:','// MARK: - Session')+'\n'+declarations(app/'Video.swift','struct WallVideo:','// MARK: - Talking to the wall')
tests=r'''
import Foundation
@main struct RoutineTests {
 static func main() throws {
  var passed=0;var failures:[String]=[]
  func check(_ condition:Bool,_ name:String) { if condition {passed += 1} else {failures.append(name)} }
  let receipt=Date(timeIntervalSince1970:2_000_000_000)
  let wallEpoch=1_900_000_000.0
  let wall=WallState(json:["wall_time":wallEpoch,"wall_timezone":"America/New_York","wall_utc_offset_s":-14400,
    "timer_remaining_s":60,"timer_total_s":120,"timer_ends_at":wallEpoch+60,"timer_state":"counting",
    "sleep_state":"fading","sleep_remaining_s":1800,"sleep_total_s":1800,"sleep_ends_at":wallEpoch+1800,
    "alarm_next_at":wallEpoch+600,"wake_next_at":wallEpoch+1200,"wake_next_end_at":wallEpoch+2400],receivedAt:receipt)
  check(wall.wallClock(at:receipt)?.timeIntervalSince1970 == wallEpoch,"wall clock independent of phone skew")
  check(wall.wallClock(at:receipt.addingTimeInterval(13))?.timeIntervalSince1970 == wallEpoch+13,"wall clock progresses from receipt")
  check(wall.wallClock(at:receipt.addingTimeInterval(-30))?.timeIntervalSince1970 == wallEpoch,"receipt clock never extrapolates backwards")
  check(wall.routineTimeZone?.identifier == "America/New_York","IANA timezone retained")
  check(wall.timerSeconds(at:receipt)==60,"timer starts at exact receipt")
  check(wall.timerSeconds(at:receipt.addingTimeInterval(0.8))==60,"countdown ceilings fractions")
  check(wall.timerSeconds(at:receipt.addingTimeInterval(1.01))==59,"timer increments one second")
  check(wall.timerSeconds(at:receipt.addingTimeInterval(61))==0,"timer clamps at zero")
  check(wall.sleepSeconds(at:receipt.addingTimeInterval(60))==1740,"sleep uses wall deadline")
  check(wall.sleepTotal==1800,"sleep total decoded")
  check(wall.alarmNext?.timeIntervalSince1970==wallEpoch+600,"alarm next decoded")
  check(wall.wakeNextEnd?.timeIntervalSince1970==wallEpoch+2400,"wake end decoded")
  let legacy=WallState(json:["timer_remaining_s":5,"timer_total_s":10,"sleep_remaining_s":20],receivedAt:receipt)
  check(legacy.timerStatus=="counting","legacy timer active")
  check(legacy.timerSeconds(at:receipt.addingTimeInterval(2))==3,"legacy countdown anchored")
  check(legacy.sleepStatus=="fading","legacy sleep inferred")
  check(legacy.sleepSeconds(at:receipt.addingTimeInterval(2))==18,"legacy sleep anchored")
  check(legacy.routineTimeZone==nil,"older wall does not invent phone timezone")
  check(legacy.wallClock(at:receipt)==nil,"older wall does not invent wall time")
  let ring=WallState(json:["timer_remaining_s":0,"timer_state":"ringing","timer_kind":"alarm"],receivedAt:receipt)
  check(ring.timerRinging,"ring inferred from explicit status")
  check(ring.timerKind=="alarm","alarm distinguished from countdown")
  check(ring.timerSeconds(at:receipt)==0,"ring stays zero")
  let event=WallState(json:["timer_id":"event-b","timer_snoozed":true,"timer_ring_elapsed_s":12.5,"idle_active":"dim","away_active":true,"display_mode":"off","mode":"art"],receivedAt:receipt)
  check(event.timerEventID=="event-b" && event.timerSnoozed,"completion identity and snooze decoded")
  check(event.timerRingElapsed==12.5,"ring elapsed decoded")
  check(event.idleActive=="dim" && event.awayActive && event.displayedMode=="off" && event.mode=="art","automatic output does not overwrite selected mode")
  check(WallState(json:["timer_ring_elapsed_s":Double.nan]).timerRingElapsed==0,"nonfinite ring elapsed rejected")
  check(WallState(json:["timer_ring_elapsed_s":-3.0]).timerRingElapsed==0,"negative ring elapsed bounded")
  check(WallState(json:["mode":"clock"]).displayedMode=="clock","older wall output uses selected mode")
  let missing=WallState(json:[:],receivedAt:receipt)
  check(missing.timerSeconds(at:receipt)==nil,"no timer stays absent")
  check(missing.sleepSeconds(at:receipt)==nil,"no sleep stays absent")
  check(missing.timerStatus=="idle","no timer is idle")
  let completed=WallState(json:["sleep_state":"completed"],receivedAt:receipt)
  check(completed.sleepSeconds(at:receipt)==nil,"completion does not invent countdown")
  let offset=WallState(json:["wall_timezone":"unknown","wall_utc_offset_s":19800],receivedAt:receipt)
  check(offset.routineTimeZone?.secondsFromGMT(for:receipt)==19800,"fixed-offset timezone fallback")
  let invalid=WallState(json:["wall_time":Double.nan,"timer_ends_at":Double.infinity,
     "sun_factor":Double.nan,"wake_progress":Double.infinity,"wall_utc_offset_s":Int.min],receivedAt:receipt)
  check(invalid.wallTime==nil && invalid.timerEndsAt==nil,"invalid timestamps ignored")
  check(invalid.sunFactor==nil && invalid.wakeProgress==nil,"invalid fractions ignored")
  check(invalid.routineTimeZone==nil,"invalid offset cannot crash")
  let bounded=WallState(json:["sun_factor":2.0,"effective_brightness":-1.0,"wake_progress":1.5],receivedAt:receipt)
  check(bounded.sunFactor==1 && bounded.effectiveBrightness==0 && bounded.wakeProgress==1,"fractions bounded")
  for (payload,expected) in [("{}",true),("{\"rejected\":{}}",true),("{\"rejected\":[\"wake_time\"]}",false),("{\"rejected\":{\"wake_time\":\"bad\"}}",false),("{\"error\":\"failed\"}",false),("not json",false),("",true)] {
   check(WallAcknowledgement.accepted(Data(payload.utf8))==expected,"HTTP acknowledgement: " + payload)
  }
  let data=try JSONSerialization.data(withJSONObject:["passed":passed,"failed":failures.count,"failures":failures],options:.sortedKeys)
  print(String(decoding:data,as:UTF8.self));if !failures.isEmpty {exit(1)}
 }
}
'''
with tempfile.TemporaryDirectory(prefix='tessera-routines-') as folder:
 folder=Path(folder);(folder/'Models.swift').write_text(source);(folder/'Tests.swift').write_text(tests)
 binary=folder/'routines'
 subprocess.run(['xcrun','swiftc','-parse-as-library',str(folder/'Models.swift'),str(app/'Panel.swift'),str(folder/'Tests.swift'),'-o',str(binary)],check=True,cwd=root)
 result=subprocess.run([str(binary)],capture_output=True,text=True,check=True)
 data=json.loads(result.stdout)
 if args.json:args.json.parent.mkdir(parents=True,exist_ok=True);args.json.write_text(json.dumps(data,indent=2)+'\n')
 print(f"Routines: {data['passed']} passed; {data['failed']} failed")
