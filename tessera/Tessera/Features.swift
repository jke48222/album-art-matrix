// The wall's features, each in its own place on the phone: a question for
// the wall and its answers, a note on the panel, a cover or a video by
// name, a song from the words you remember, the voice, HomeKit, the
// record shelf, and teaching the wall a song. Every page talks to the
// wall over its control port and shows what the wall says.

import SwiftUI

// Ask the wall and Notes live in AskNotePages.swift.

// Show me and Earworm live in DiscoveryPages.swift.

// MARK: - The voice

// MARK: - HomeKit

struct HomeKitPage: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    @State private var status: HomeKitStatus?
    @State private var busy = false

    var body: some View {
        SetupPage("HomeKit",
                  blurb: "The wall in the Home app, and so on Siri, the Watch and in Control Centre: a light (on, off, brightness, a colour for the lamp face), a television whose inputs are the faces and whose remote plays the games, and two sensors, sound in the room and music on the wall, for automations.") {
            SetupGroup("Pairing", note: status?.paired == true
                       ? "Paired. To pair again from scratch, remove the bridge in Home, then delete homekit.state on the Pi."
                       : "Open Home, add an accessory, and scan the code the wall shows on its panel. Say Add Anyway if Home calls it uncertified.") {
                SetupRow(title: status?.name ?? "Wall", subtitle: status?.paired == true ? "In your home." : "Not paired yet.") {
                    StateValue(status?.paired == true ? "Paired" : "Set up", done: status?.paired == true)
                }
                Rule()
                SetupRow(title: "Setup code", subtitle: status?.code ?? "") {
                    ActionPill(title: status?.showing_code == true ? "On the panel" : "Show on the panel", filled: status?.showing_code != true) { showCode() }
                }
            }
            .padding(.top, -12)
            if let faces = status?.faces, !faces.isEmpty {
                SetupGroup("The remote", note: "In Control Centre's remote, the arrows step through the faces, play and pause switch the wall off and on, info runs what is playing across the panel, the volume keys are the light. While a game is on, the arrows and select play it and back puts it down.") {
                    ForEach(Array(faces.enumerated()), id: \.offset) { i, f in
                        if i > 0 { Rule() }
                        SetupRow(title: f.name, subtitle: "Input \(f.id)") {
                            StateValue(wall.state.mode == f.mode ? "On the wall" : "", done: wall.state.mode == f.mode)
                        }
                    }
                }
            }
            if let e = status?.error { Problem(text: e) }
        }
        .task {
            while !Task.isCancelled {
                if let s = await HomeKitStatus.read(host: wall.host) { status = s }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private func showCode() {
        guard !busy else { return }
        busy = true
        let h = wall.host
        Task {
            _ = await VoiceStatus.post(host: h, path: "/homekit/show", body: [:])
            Taps.commit()
            if let s = await HomeKitStatus.read(host: h) { status = s }
            busy = false
        }
    }
}

struct HomeKitStatus: Decodable {
    struct Face: Decodable { var id: Int; var name: String; var mode: String }
    var enabled: Bool?
    var ready: Bool?
    var error: String?
    var name: String?
    var paired: Bool?
    var code: String?
    var showing_code: Bool?
    var faces: [Face]?

    static func read(host: String) async -> HomeKitStatus? {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/homekit") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 6
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(HomeKitStatus.self, from: data)
    }
}

// MARK: - Teach the wall a song

struct TeachPage: View {
    @Environment(WallSession.self) private var wall
    let accent: Color
    @State private var title = ""
    @State private var artist = ""
    @State private var busy = false
    @State private var problem: String?
    @State private var done: String?
    @State private var taught: TaughtList?
    @State private var forgetting: String?

    var body: some View {
        SetupPage("Teach the wall",
                  blurb: "The wall's own song library, asked before Shazam. It learns a song's preview when another source names it and the ear keeps missing it, learns the room's own hearing of a song after fifteen loud seconds, and learns any song you name here from its preview.") {
            SetupGroup("By name", note: "The song's preview is fetched from iTunes and fingerprinted on the wall.") {
                KeyField(placeholder: "Song title", text: $title)
                Rule()
                KeyField(placeholder: "Artist", text: $artist)
                Rule()
                SaveLine(title: busy ? "Learning" : "Teach it", enabled: !title.trimmingCharacters(in: .whitespaces).isEmpty && !artist.trimmingCharacters(in: .whitespaces).isEmpty && !busy,
                         busy: busy, done: done, accent: accent) { learn() }
            }
            .padding(.top, -12)
            Problem(text: problem)
            SetupGroup("Known", note: taughtNote) {
                ForEach(Array((taught?.songs ?? []).enumerated()), id: \.element.id) { i, song in
                    if i > 0 { Rule() }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title).font(.ui(15)).foregroundStyle(Ink.ink).lineLimit(1)
                            Text(song.artist + "  ·  " + how(song)).font(.ui(12)).foregroundStyle(Ink.dim).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        ActionPill(title: forgetting == song.id ? "Forgetting" : "Forget", filled: false) { forget(song.id) }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                if let list = await TaughtList.read(host: wall.host) { taught = list }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var taughtNote: String {
        guard let t = taught, !t.songs.isEmpty else { return "None yet." }
        return "\(t.songs.count) song\(t.songs.count == 1 ? "" : "s"), \(t.landmarks ?? 0) landmarks."
    }

    private func how(_ song: TaughtList.Song) -> String {
        let ways = song.how.map { $0 == "preview" ? "preview" : $0 == "ear" ? "the room" : "by name" }
        var line = "from " + ways.joined(separator: " and ")
        if song.matched > 0 { line += ", named \(song.matched)x" }
        return line
    }

    private func learn() {
        guard !busy else { return }
        busy = true
        problem = nil
        let h = wall.host, t = title.trimmingCharacters(in: .whitespaces), a = artist.trimmingCharacters(in: .whitespaces)
        Task {
            let (ok, why) = await TaughtList.learn(host: h, title: t, artist: a)
            problem = why
            if ok { done = "Learnt \(t)"; title = ""; artist = ""; Taps.commit() }
            if let list = await TaughtList.read(host: h) { taught = list }
            busy = false
        }
    }

    private func forget(_ id: String) {
        guard forgetting == nil else { return }
        forgetting = id
        let h = wall.host
        Task {
            _ = await TaughtList.forget(host: h, id: id)
            if let list = await TaughtList.read(host: h) { taught = list }
            forgetting = nil
            Taps.commit()
        }
    }
}

extension TaughtList {
    static func learn(host: String, title: String, artist: String) async -> (Bool, String?) {
        guard !host.isEmpty, let url = URL(string: "http://\(host)/teach/learn") else { return (false, "No wall.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["title": title, "artist": artist])
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (false, "The wall is not answering.") }
        if (resp as? HTTPURLResponse)?.statusCode == 200 { return (true, nil) }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (false, json["error"] as? String ?? "The wall could not learn it.")
    }
}
