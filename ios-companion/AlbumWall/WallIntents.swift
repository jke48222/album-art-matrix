// Siri / Shortcuts. "Hey Siri, wall off" from across the room — the
// intents talk straight to the brain with the stored host, no UI needed.
import AppIntents
import Foundation

enum WallMode: String, AppEnum {
    case art, spin, ambient, off

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Wall Mode")
    static let caseDisplayRepresentations: [WallMode: DisplayRepresentation] = [
        .art: "Art", .spin: "Spin", .ambient: "Ambient", .off: "Off",
    ]

    var apiValue: String { self == .spin ? "cd" : rawValue }
}

struct SetWallModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Wall Mode"
    static let description = IntentDescription("Switches what the album wall shows.")

    @Parameter(title: "Mode") var mode: WallMode

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let host = UserDefaults.standard.string(forKey: "wallHost")
            ?? "album-matrix.local:8788"
        guard let url = URL(string: "http://\(host)/state") else {
            return .result(dialog: "The wall host looks wrong.")
        }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: ["mode": mode.apiValue])
        do {
            _ = try await URLSession.shared.data(for: req)
        } catch {
            return .result(dialog: "The wall didn't answer.")
        }
        switch mode {
        case .off: return .result(dialog: "Wall's asleep.")
        case .art: return .result(dialog: "Showing the record.")
        case .spin: return .result(dialog: "Spinning.")
        case .ambient: return .result(dialog: "Lamp mode.")
        }
    }
}

struct WallShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetWallModeIntent(),
            phrases: [
                "Set \(.applicationName) mode",
                "Turn \(.applicationName) off",
                "\(.applicationName) mode",
            ],
            shortTitle: "Wall Mode",
            systemImageName: "square.grid.3x3")
    }
}
