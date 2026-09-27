import Foundation

/// Shared across navigation instances so returning to a round cancels its old pause intent.
@MainActor
final class GameArcadeLifecycle {
    static let shared = GameArcadeLifecycle()
    private var jobs: [String: (UUID, Task<Void, Never>)] = [:]
    private func key(_ host: String, _ session: String) -> String { "\(host)|\(session)" }
    func cancel(host: String, session: String?) {
        guard let session else { return }
        jobs.removeValue(forKey: key(host, session))?.1.cancel()
    }
    func pause(host: String, session: String, player: String, after pending: Task<GameStatus, Error>?) {
        let key = key(host, session)
        guard jobs[key] == nil else { return }
        let identity = UUID()
        let task = Task {
            defer { if jobs[key]?.0 == identity { jobs.removeValue(forKey: key) } }
            _ = try? await pending?.value
            guard !Task.isCancelled else { return }
            guard let fresh = await GameLink.status(host: host), !Task.isCancelled,
                  fresh.session_id == session, fresh.on_wall != false,
                  fresh.game?.state["phase"].string == "playing" else { return }
            _ = try? await GameLink.perform(host: host, "move", ["session_id": session, "player": player, "move": ["pause": true]], timeout: 2)
        }
        jobs[key] = (identity, task)
    }
}
