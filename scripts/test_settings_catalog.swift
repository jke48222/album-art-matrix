import Foundation

@main struct SettingsCatalogChecks {
    static func main() throws {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ ok: Bool) { checks.append(["name": name, "passed": ok]) }
        check("Every route occurs exactly once in the grouped directory", Set(SettingsSection.allCases.flatMap(\.entries)).count == SettingsDestination.allCases.count && SettingsSection.allCases.flatMap(\.entries).count == SettingsDestination.allCases.count)
        check("Whitespace restores all settings", SettingsDestination.results(for: " \n  ") == SettingsDestination.allCases)
        check("Search titles before incidental aliases", SettingsDestination.results(for: "sleep").first == .sleep)
        for (query, route) in [("knock", SettingsDestination.hearing), ("whistle", .hearing), ("shazam", .hearing), ("brightness", SettingsDestination.light), ("timer", .time), ("snooze", .time), ("nothing playing", .idle), ("leave", .idle), ("off", .idle), ("CLAUDE", .ask), ("api key", .services), ("color", .colour), ("COLOUR", .colour), ("éárwörm", .earworm), ("ｔｉｍｅ", .time), ("ip address", .addresses), ("wifi password", .guests), ("temperature", .weather), ("dynamic island", .lockScreen), ("dead pixel", .panel), ("diagnostics", .health), ("expiry", .note), ("minute", .time), ("morning", .wake), ("night", .sun)] {
            check("Find \(route.rawValue) with \(query)", SettingsDestination.results(for: query).contains(route))
        }
        check("All query words must match the same destination", SettingsDestination.results(for: "camera snooze").isEmpty)
        check("Unknown query has an honest empty result", SettingsDestination.results(for: "zzzzqnone").isEmpty)
        check("All results have unique navigation identity", Set(SettingsDestination.results(for: "wall")).count == SettingsDestination.results(for: "wall").count)
        check("Route strings round-trip without alternate editors", SettingsDestination.allCases.allSatisfy { SettingsDestination(rawValue: $0.rawValue) == $0 })
        let failed = checks.filter { $0["passed"] as? Bool == false }.count
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: ["passed": checks.count - failed, "failed": failed, "checks": checks], options: [.sortedKeys]))
        if failed > 0 { exit(1) }
    }
}
