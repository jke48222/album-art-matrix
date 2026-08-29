// The wall, addressable from outside the app.
//
// Siri, Shortcuts, the Action button, and the keys on the widget and the
// Dynamic Island all land here. These write straight to the wall rather than
// going through the app's session, so they work whether or not it is running.
//
// This file is compiled into both the app and the widget extension, and the
// reason is a real one: a widget button can only fire an intent the
// extension itself contains. The mode intent conforms to LiveActivityIntent,
// which makes the system run it IN THE APP'S PROCESS rather than in the
// widget's — a widget extension is never allowed to touch the local network
// (TN3179), and the app is. It genuinely does update the Live Activity too,
// so the conformance is not even a trick.

import AppIntents
import Foundation
import WidgetKit

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

/// Where the wall lives. The app mirrors its host into the shared group so
/// the widget's intents read the same address the app dials; standard
/// defaults are the fallback for the app process itself.
enum WallAddress {
    static let group = "group.com.jalenedusei.tessera"

    static var host: String {
        UserDefaults(suiteName: group)?.string(forKey: "wall.host")
            ?? UserDefaults.standard.string(forKey: "wall.host")
            ?? "album-matrix.local:8788"
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
        // The widget shows the wall's mode; it just changed. Its provider
        // fetches live state, so a reload is all the truth needs.
        WidgetCenter.shared.reloadAllTimelines()
    }

    enum WallError: Error, CustomLocalizedStringResourceConvertible {
        case noWall
        var localizedStringResource: LocalizedStringResource {
            "The wall is not answering."
        }
    }
}

/// LiveActivityIntent so a widget key runs it in the app's process; see the
/// header comment for why that is load-bearing and not a preference.
struct SetWallModeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Set the wall"
    static let description = IntentDescription("Show album art, spin it, use it as a lamp, or turn it off.")

    @Parameter(title: "Show") var mode: WallMode

    init() {}
    init(mode: WallMode) { self.mode = mode }

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

/// "Hey Siri, wall timer, ten minutes" from the kitchen, hands in the dough.
/// This is the use the whole timer mode was built for.
struct StartWallTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a wall timer"
    static let description = IntentDescription("Count down on the wall, in big lit digits. The border drains as time runs.")

    @Parameter(title: "Minutes", default: 10, inclusiveRange: (1, 180))
    var minutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Count down \(\.$minutes) minutes on the wall")
    }

    func perform() async throws -> some IntentResult {
        try await WallAddress.send(["timer_min": Double(minutes)])
        return .result()
    }
}
