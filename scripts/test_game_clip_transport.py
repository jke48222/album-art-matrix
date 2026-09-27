#!/usr/bin/env python3
"""Compile the real playback transport and exercise ordering across suspension."""
import argparse,json,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
SWIFT=r'''
import Foundation
@MainActor enum GameLink {
    static var calls: [[String: Any]] = []
    static var gate: CheckedContinuation<Void, Never>?
    static var rejectFirst = false
    static func perform(host: String, _ action: String, _ body: [String: Any], timeout: Double) async throws -> Bool {
        calls.append(body)
        if calls.count == 1 { await withCheckedContinuation { gate = $0 } }
        if rejectFirst && calls.count == 1 { throw URLError(.timedOut) }
        return true
    }
}
@main struct Main {
    @MainActor static func main() async {
        var count = 0
        func expect(_ value: Bool) { if !value { fatalError("Playback ordering regression") }; count += 1 }
        let queue = GameClipTransport()
        var failures = [String]()
        queue.send(host: "wall", session: "round-a", player: "You", move: ["played": true, "step": 0]) { failures.append($0) }
        while GameLink.gate == nil { await Task.yield() }
        queue.send(host: "wall", session: "round-a", player: "You", move: ["played": true, "step": 0, "position": 0.5]) { failures.append($0) }
        queue.send(host: "wall", session: "round-a", player: "You", move: ["played": false, "step": 0]) { failures.append($0) }
        queue.send(host: "second-wall", session: "round-b", player: "Guest", move: ["played": true, "step": 0]) { failures.append($0) }
        expect(GameLink.calls.count == 1)
        GameLink.rejectFirst = true
        GameLink.gate?.resume(); GameLink.gate = nil
        for _ in 0..<1000 { await Task.yield(); if GameLink.calls.count == 3 { break } }
        expect(GameLink.calls.count == 3)
        expect((GameLink.calls[1]["move"] as? [String: Any])?["played"] as? Bool == false)
        expect(GameLink.calls[1]["session_id"] as? String == "round-a")
        expect(GameLink.calls[2]["session_id"] as? String == "round-b")
        expect((GameLink.calls[2]["move"] as? [String: Any])?["played"] as? Bool == true)
        expect(failures.count == 1)
        print("{\"passed\":true,\"assertions\":\(count)}")
    }
}
'''
def main():
    p=argparse.ArgumentParser();p.add_argument('--json',type=Path);a=p.parse_args()
    with tempfile.TemporaryDirectory() as tmp:
        d=Path(tmp);(d/'test.swift').write_text(SWIFT)
        subprocess.run(['xcrun','swiftc','-parse-as-library',str(ROOT/'tessera/Tessera/GameClipTransport.swift'),str(d/'test.swift'),'-o',str(d/'test')],check=True)
        result=subprocess.check_output([str(d/'test')],text=True);record=json.loads(result);print(result.strip())
        if a.json:a.json.write_text(json.dumps(record,indent=2)+'\n')
if __name__=='__main__':main()
