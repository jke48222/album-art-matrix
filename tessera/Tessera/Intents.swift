// Siri, Shortcuts, the Action button.
//
// A lamp across the room is something you talk to from the sofa. These are
// deliberately few: the things worth saying out loud, and nothing that needs
// a screen to make sense of.
//
// They write straight to the wall rather than going through the app, so they
// work whether or not it is running.

import AppIntents
import Foundation
import SwiftUI

enum WallMode: String, AppEnum {
    case art, spin, lamp, off

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Wall Mode" }
    static var caseDisplayRepresentations: [WallMode: DisplayRepresentation] = [
        .art: "Album art",
        .spin: "Spinning record",
        .lamp: "Lamp",
        .off: "Off",
    ]

    /// The brain's names, which are not the ones a person would say.
    var wire: String {
        switch self {
        case .art: "art"
        case .spin: "cd"
        case .lamp: "ambient"
        case .off: "off"
        }
    }
}

/// Where the wall lives, read from the same place the app stores it.
enum WallAddress {
    static var host: String {
        UserDefaults.standard.string(forKey: "wall.host") ?? "album-matrix.local:8788"
    }

    static func send(_ patch: [String: Any]) async throws {
        guard let url = URL(string: "http://\(host)/state"),
              let body = try? JSONSerialization.data(withJSONObject: patch) else {
            throw WallError.noWall
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 5
        _ = try await URLSession.shared.data(for: req)
    }

    enum WallError: Error, CustomLocalizedStringResourceConvertible {
        case noWall
        var localizedStringResource: LocalizedStringResource {
            "The wall is not answering."
        }
    }
}

struct SetWallModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set the wall"
    static let description = IntentDescription("Show album art, spin it, use it as a lamp, or turn it off.")

    @Parameter(title: "Show") var mode: WallMode

    static var parameterSummary: some ParameterSummary {
        Summary("Set the wall to \(\.$mode)")
    }

    func perform() async throws -> some IntentResult {
        try await WallAddress.send(["mode": mode.wire])
        return .result()
    }
}

struct SetBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Dim the wall"
    static let description = IntentDescription("Set how much light the wall gives off.")

    @Parameter(title: "Brightness", default: 60, inclusiveRange: (5, 100))
    var percent: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set the wall to \(\.$percent) percent")
    }

    func perform() async throws -> some IntentResult {
        try await WallAddress.send(["brightness": Double(percent) / 100])
        return .result()
    }
}

/// The one that earns its place: goodnight.
struct SleepWallIntent: AppIntent {
    static let title: LocalizedStringResource = "Fade the wall out"
    static let description = IntentDescription("Fade the wall down over time, then let it go dark.")

    @Parameter(title: "Over", default: 30, inclusiveRange: (1, 180))
    var minutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Fade the wall out over \(\.$minutes) minutes")
    }

    func perform() async throws -> some IntentResult {
        try await WallAddress.send(["sleep_fade_min": Double(minutes)])
        return .result()
    }
}

struct TesseraShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetWallModeIntent(),
            phrases: ["Set the wall in \(.applicationName)",
                      "\(.applicationName) the wall"],
            shortTitle: "Set the wall",
            systemImageName: "square.grid.2x2"
        )
        AppShortcut(
            intent: SleepWallIntent(),
            phrases: ["Fade the wall out in \(.applicationName)",
                      "Goodnight \(.applicationName)"],
            shortTitle: "Fade out",
            systemImageName: "moon"
        )
    }
}
