import Foundation

@main struct SettingsCatalogChecks {
    static func main() throws {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ ok: Bool) { checks.append(["name": name, "passed": ok]) }
        check("Every route occurs exactly once in the grouped directory", Set(SettingsSection.allCases.flatMap(\.entries)).count == SettingsDestination.allCases.count && SettingsSection.allCases.flatMap(\.entries).count == SettingsDestination.allCases.count)
        check("Whitespace restores all settings", SettingsDestination.results(for: " \n  ") == SettingsDestination.allCases)
        check("Search titles before incidental aliases", SettingsDestination.results(for: "sleep").first == .sleep)
        for (query, route) in [("knock", SettingsDestination.hearing), ("whistle", .hearing), ("shazam", .hearing), ("brightness", SettingsDestination.light), ("timer", .time), ("snooze", .time), ("nothing playing", .idle), ("leave", .idle), ("off", .idle), ("CLAUDE", .ask), ("api key", .services), ("color", .colour), ("COLOUR", .colour), ("éárwörm", .earworm), ("ｔｉｍｅ", .time), ("ip address", .addresses), ("wifi password", .guests), ("temperature", .weather), ("dynamic island", .lockScreen), ("dead pixel", .panel), ("diagnostics", .health), ("expiry", .note), ("minute", .time), ("morning", .wake), ("night", .sun),
                              ("power", .health), ("undervoltage", .health), ("frozen", .health), ("temperature", .health),
                              ("local network", .addresses), ("waiting", .addresses), ("mac reporter", .services),
                              ("ipod", .design), ("classic", .design), ("room", .design), ("look", .design),
                              ("version", .about), ("opening", .about), ("first run", .about), ("tuning", .about), ("acknowledgements", .about),
                              ("widget", .widgets), ("home screen", .widgets), ("small medium", .widgets)] {
            check("Find \(route.rawValue) with \(query)", SettingsDestination.results(for: query).contains(route))
        }
        check("Temperature finds both the weather and the wall's health", Set(SettingsDestination.results(for: "temperature")).isSuperset(of: [.weather, .health]))
        check("App design leads the home section", SettingsSection.home.entries.first == .design)
        check("Home Screen sits right after Lock Screen", SettingsSection.home.entries.firstIndex(of: .widgets) == SettingsSection.home.entries.firstIndex(of: .lockScreen).map { $0 + 1 })
        check("Home Screen and Lock Screen are Apple's own names", SettingsDestination.widgets.title == "Home Screen" && SettingsDestination.lockScreen.title == "Lock Screen")
        check("The song library is named for what it holds", SettingsDestination.teach.title == "Song library" && SettingsDestination.results(for: "teach").contains(.teach))
        check("Connection keeps the addresses route", SettingsDestination(rawValue: "addresses") == .addresses && SettingsDestination.addresses.title == "Connection")
        check("New routes open by name", SettingsDestination(rawValue: "design") == .design && SettingsDestination(rawValue: "widgets") == .widgets)
        check("All query words must match the same destination", SettingsDestination.results(for: "camera snooze").isEmpty)
        check("Unknown query has an honest empty result", SettingsDestination.results(for: "zzzzqnone").isEmpty)
        check("All results have unique navigation identity", Set(SettingsDestination.results(for: "wall")).count == SettingsDestination.results(for: "wall").count)
        check("Route strings round-trip without alternate editors", SettingsDestination.allCases.allSatisfy { SettingsDestination(rawValue: $0.rawValue) == $0 })
        let failed = checks.filter { $0["passed"] as? Bool == false }.count
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: ["passed": checks.count - failed, "failed": failed, "checks": checks], options: [.sortedKeys]))
        if failed > 0 { exit(1) }
    }
}
