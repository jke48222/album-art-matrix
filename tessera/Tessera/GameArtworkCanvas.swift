import SwiftUI

private struct GameSessionKey: EnvironmentKey {
    static let defaultValue: String? = nil
}
extension EnvironmentValues {
    var gameSessionID: String? {
        get { self[GameSessionKey.self] }
        set { self[GameSessionKey.self] = newValue }
    }
}

/// The same production composition as the LEDs, rendered from its source at 512px.
struct GameArtworkCanvas: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.gameSessionID) private var session
    let game: GameStatus.Game
    var onAvailabilityChange: ((Bool) -> Void)? = nil
    @State private var artwork: UIImage?
    @State private var loadedSession: String?
    @State private var unavailable = false

    private struct Revision: Equatable {
        let sequence: Int
        let step: Int?
        let over: Bool
    }
    @State private var wanted: Revision?
    private var revision: Revision { Revision(sequence: game.seq, step: game.state["frame_step"].int, over: game.over) }
    private var transportID: String { "\(wall.host)|\(session ?? "")|\(wall.link.isLive)" }
    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle().fill(Ink.plaster)
            if let artwork {
                Image(uiImage: artwork).resizable().interpolation(.high).scaledToFit()
            } else {
                VStack(spacing: 12) {
                    if unavailable { Image(systemName: "photo").font(.system(size: 30)) }
                    else { ProgressView().tint(Ink.dim) }
                    Text(unavailable ? "Waiting for artwork" : "Preparing your board")
                        .font(.ui(14)).foregroundStyle(Ink.dim)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if unavailable && artwork != nil {
                Label("Last saved board", systemImage: "wifi.slash")
                    .font(.ui(11, .semibold)).padding(8)
                    .background(Ink.ground.opacity(0.94), in: Capsule()).padding(10)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
        .onChange(of: revision) { _, next in
            wanted = next
            onAvailabilityChange?(false)
        }
        .task(id: transportID) {
            let expectedSession = session, host = wall.host
            wanted = revision
            onAvailabilityChange?(false)
            let identity = "\(host)|\(expectedSession ?? "")"
            if loadedSession != identity { artwork = nil; loadedSession = identity }
            guard let expectedSession, wall.link.isLive else { unavailable = true; return }
            var delivered: Revision?
            var failures = 0
            while !Task.isCancelled {
                guard let requestRevision = wanted else { return }
                if delivered == requestRevision {
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                guard var url = URLComponents(string: "http://\(host)/game/frame.png") else { unavailable = true; return }
                // Sliding hit regions must use these exact pixels. Timed reveal
                // frames may advance within a sequence; they have no tile targets.
                url.queryItems = [URLQueryItem(name: "side", value: "512"), URLQueryItem(name: "session_id", value: expectedSession), URLQueryItem(name: "seq", value: String(requestRevision.sequence))]
                guard let target = url.url else { unavailable = true; return }
                do {
                    var request = URLRequest(url: target)
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    request.timeoutInterval = 4
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard !Task.isCancelled, session == expectedSession, wall.host == host else { return }
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                          data.count < 2_000_000, let image = UIImage(data: data),
                          image.size == CGSize(width: 512, height: 512) else { throw URLError(.cannotDecodeContentData) }
                    if wanted?.sequence == requestRevision.sequence {
                        artwork = image; unavailable = false
                        onAvailabilityChange?(true)
                    }
                    delivered = requestRevision; failures = 0
                } catch {
                    guard !Task.isCancelled, session == expectedSession, wall.host == host else { return }
                    unavailable = true; failures = min(4, failures + 1)
                    // Retry while visible even if the board sequence never changes.
                    // One request at a time avoids starving slow timed-image loads.
                    try? await Task.sleep(for: .seconds(Double(failures) * 0.5))
                }
            }
        }
    }
}
