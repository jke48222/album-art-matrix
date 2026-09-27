#!/usr/bin/env python3
"""Compile the production lifecycle coordinator against a suspended transport."""
import subprocess,tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[1]
source='''import Foundation
struct Value { var string: String }
struct BoardState { subscript(_ key: String) -> Value { Value(string: "playing") } }
struct Board { var state = BoardState() }
struct GameStatus { var session_id: String? = "round"; var on_wall: Bool? = true; var game: Board? = Board() }
@MainActor enum GameLink {
    static var writes = 0
    static var hold = false
    static var waiting: CheckedContinuation<GameStatus?, Never>?
    static func status(host: String) async -> GameStatus? {
        if hold { return await withCheckedContinuation { waiting = $0 } }
        return GameStatus()
    }
    static func perform(host: String, _ action: String, _ body: [String: Any], timeout: Double) async throws -> GameStatus {
        precondition(body["session_id"] as? String == "round")
        precondition((body["move"] as? [String: Bool])?["pause"] == true)
        writes += 1; return GameStatus()
    }
}
@main struct Run {
    @MainActor static func main() async throws {
        let coordinator = GameArcadeLifecycle.shared
        let pending = Task<GameStatus, Error> { try await Task.sleep(for: .milliseconds(50)); return GameStatus() }
        coordinator.pause(host: "wall", session: "round", player: "You", after: pending)
        coordinator.cancel(host: "wall", session: "round")
        try await Task.sleep(for: .milliseconds(90))
        precondition(GameLink.writes == 0, "Returning before move ACK cancels pause")
        GameLink.hold = true
        coordinator.pause(host: "wall", session: "round", player: "You", after: nil)
        for _ in 0..<100 { if GameLink.waiting != nil { break }; try await Task.sleep(for: .milliseconds(2)) }
        precondition(GameLink.waiting != nil)
        coordinator.cancel(host: "wall", session: "round")
        GameLink.waiting?.resume(returning: GameStatus());GameLink.waiting = nil
        try await Task.sleep(for: .milliseconds(20))
        precondition(GameLink.writes == 0, "Returning during status read cancels pause")
        GameLink.hold = false
        coordinator.pause(host: "wall", session: "round", player: "You", after: nil)
        coordinator.pause(host: "wall", session: "round", player: "You", after: nil)
        try await Task.sleep(for: .milliseconds(30))
        precondition(GameLink.writes == 1, "Duplicate pause intents coalesce")
        coordinator.pause(host: "wall", session: "round", player: "You", after: nil)
        try await Task.sleep(for: .milliseconds(30))
        precondition(GameLink.writes == 2, "Completed intent permits later background event")
        print("Arcade lifecycle: cancellation, coalescing and rescheduling passed")
    }
}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'Fixture.swift').write_text(source)
 subprocess.run(['xcrun','swiftc','-parse-as-library',str(root/'tessera/Tessera/GameArcadeLifecycle.swift'),str(p/'Fixture.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
