// Search is one clear sentence and two physical verbs: put the sleeve on
// the wall, or play the video. Earworm stays nearby because it begins with
// words rather than a title. Results live on the wall, not in phone state.
import SwiftUI

private struct DiscoverReply: Decodable {
    struct Alternative: Decodable, Identifiable {
        var title: String
        var artist: String
        var art_url: String?
        var id: String { title + "|" + artist }
    }
    var title: String?
    var artist: String?
    var confidence: Double?
    var shown: Bool?
    var started: Bool?
    var problem: String?
    var alternatives: [Alternative]?
}

struct DiscoverPage: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    @State private var query = ""
    @State private var remembered = ""
    @State private var reply: DiscoverReply?
    @State private var busy: String?
    @State private var problem: String?

    var body: some View {
        SetupPage("Find something", blurb: "A cover by name, a video to play, or a song from the words still in your head.") {
            SetupGroup("Sleeve or video", note: "Show keeps a cover on the wall for ten minutes. Play sends the first matching YouTube video to the existing wall player and phone speaker.") {
                TextField("Blond cover or Gameboy video", text: $query)
                    .font(.ui(16)).textInputAutocapitalization(.never)
                    .padding(.horizontal, 16).frame(minHeight: 52)
                Rule()
                HStack(spacing: 10) {
                    discoverButton("Show sleeve", symbol: "photo", action: "show")
                    discoverButton("Play video", symbol: "play.fill", action: "play")
                }.padding(16)
            }

            SetupGroup("Words you remember", note: "Claude proposes a real song, then the wall finds its catalogue sleeve. Low confidence shows two choices.") {
                TextField("hello from the other side", text: $remembered, axis: .vertical)
                    .font(.ui(16)).lineLimit(2...5).padding(16)
                Rule()
                SaveLine(title: "Find the song", enabled: !remembered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                         busy: busy == "earworm", done: nil, accent: accent) { send("earworm", text: remembered) }
            }

            if let reply, let title = reply.title {
                SetupGroup("Best match", note: reply.confidence.map { "Claude confidence \(Int($0 * 100))%. The catalogue supplies the sleeve." }) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(.displayMid(24)).foregroundStyle(Ink.ink)
                        Text(reply.artist ?? "").font(.ui(14)).foregroundStyle(Ink.dim)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    if let alternatives = reply.alternatives, !alternatives.isEmpty {
                        Rule()
                        ForEach(alternatives) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.ui(15)).foregroundStyle(Ink.ink)
                                Text(item.artist).font(.ui(12)).foregroundStyle(Ink.dim)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        }
                    }
                }
            }
            Problem(text: problem ?? reply?.problem)
        }
    }

    private func discoverButton(_ title: String, symbol: String, action: String) -> some View {
        Button { send(action, text: query) } label: {
            HStack(spacing: 8) {
                if busy == action { ProgressView().controlSize(.small) }
                else { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
                Text(title).font(.ui(14, .semibold)).lineLimit(1)
            }
            .foregroundStyle(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Ink.faint : Ink.ground)
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(Capsule().fill(query.isEmpty ? Ink.plaster : accent))
        }
        .buttonStyle(PressStyle(scale: 0.97))
        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy != nil)
    }

    private func send(_ action: String, text: String) {
        guard busy == nil else { return }
        busy = action
        Task {
            defer { busy = nil }
            guard let url = URL(string: "http://\(wall.host)/\(action)") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = action == "play" ? 20 : 8
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject:
                [action == "earworm" ? "text" : "query": text.trimmingCharacters(in: .whitespacesAndNewlines)])
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                reply = try JSONDecoder().decode(DiscoverReply.self, from: data)
                problem = reply?.problem
                Taps.commit()
            } catch { problem = "The wall could not finish that search. Try again." }
        }
    }
}

struct RoomDiscoverBar: View {
    @Environment(WallSession.self) private var wall
    let ink: Color
    let accent: Color
    @State private var query = ""
    @State private var busy = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(ink.opacity(0.65))
            TextField("Show a cover", text: $query)
                .font(.ui(13)).foregroundStyle(ink).submitLabel(.search)
                .onSubmit { send("show") }
            if busy { ProgressView().controlSize(.mini).tint(ink) }
            Button { send("show") } label: { Image(systemName: "photo").frame(width: 28, height: 28) }
            Button { send("play") } label: { Image(systemName: "play.fill").frame(width: 28, height: 28) }
        }
        .foregroundStyle(ink)
        .padding(.leading, 12).padding(.trailing, 5).frame(height: 38)
        .overlay(Capsule().stroke(ink.opacity(0.24), lineWidth: 1))
    }

    private func send(_ action: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            guard let url = URL(string: "http://\(wall.host)/\(action)") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": text])
            _ = try? await URLSession.shared.data(for: request)
            Taps.commit()
        }
    }
}
