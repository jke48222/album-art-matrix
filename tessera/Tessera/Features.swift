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

// Teach the wall lives in TeachPage.swift.
