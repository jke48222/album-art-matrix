#!/usr/bin/env python3
"""Compile production ordered input buffering and verify delayed-network semantics."""
import subprocess,tempfile,json
from pathlib import Path
root=Path(__file__).resolve().parents[1]
checks='''import Foundation
var q = GameCommandBuffer()
func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
check(q.offer(["dir":"up"],session:"a",now:1),"accept first turn")
check(q.offer(["dir":"left"],session:"a",now:1.1),"accept second turn")
check(q.take(session:"a",now:1.2)?["dir"] as? String == "up","first turn retained")
check(q.take(session:"a",now:1.3)?["dir"] as? String == "left","second turn retained")
_ = q.offer(["move":"rotate"],session:"a",now:2)
_ = q.offer(["move":"rotate"],session:"a",now:2.1)
check(q.take(session:"a",now:2.2) != nil && q.take(session:"a",now:2.2) != nil,"repeated rotations are distinct")
_ = q.offer(["dir":"up"],session:"a",now:3)
check(q.take(session:"a",now:3.7) == nil,"stale input expires")
_ = q.offer(["dir":"up"],session:"a",now:4)
check(q.take(session:"b",now:4.1) == nil,"session switch discards old controls")
for i in 0..<4 { check(q.offer(["move":i],session:"b",now:5),"queue accepts four") }
check(!q.offer(["move":5],session:"b",now:5),"queue bounded")
check(q.offer(["pause":true],session:"b",now:5.1),"pause displaces waiting input")
check(q.take(session:"b",now:6.0)?["pause"] as? Bool == true,"pause first")
check(q.take(session:"b",now:5.2) == nil,"movement backlog cleared")
_ = q.offer(["start":true],session:"b",now:6)
_ = q.offer(["start":true],session:"b",now:6.1)
check(q.take(session:"b",now:6.2) != nil && q.take(session:"b",now:6.2) == nil,"duplicate starts coalesced")
_ = q.offer(["move":"left"],session:"b",now:7);q.clear()
check(q.take(session:"b",now:7.1) == nil,"lifecycle clear")
print("Ordered command buffer: all assertions passed")
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'main.swift').write_text(checks)
 subprocess.run(['xcrun','swiftc',str(root/'tessera/Tessera/GameCommandBuffer.swift'),str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
