import Foundation

struct GameClipOrigin: Hashable {
    let host: String
    let session: String
    let player: String
    let step: Int
}

/// Playback start/stop receipts stay ordered even if the screen closes during a request.
@MainActor
final class GameClipTransport {
    private struct Event {
        let host: String
        let session: String
        let player: String
        let move: [String: Any]
        let report: (String) -> Void
    }
    private var pending: [Event] = []
    private var running = false

    func send(host: String, session: String, player: String, move: [String: Any], report: @escaping (String) -> Void) {
        let event = Event(host: host, session: session, player: player, move: move, report: report)
        if let index = pending.firstIndex(where: { $0.host == host && $0.session == session && $0.player == player && ($0.move["step"] as? Int) == (move["step"] as? Int) }) {
            pending[index] = event
        } else { pending.append(event) }
        guard !running else { return }
        running = true
        Task {
            while !pending.isEmpty {
                let event = pending.removeFirst()
                do {
                    _ = try await GameLink.perform(host: event.host, "move", ["session_id": event.session, "player": event.player, "move": event.move], timeout: 3)
                } catch {
                    event.report(error.localizedDescription)
                }
            }
            running = false
        }
    }
}
