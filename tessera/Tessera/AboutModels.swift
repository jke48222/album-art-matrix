// What the About page says, worked out without SwiftUI.
//
// Foundation only, so scripts/test_about_models.swift can compile it with
// swiftc on the Mac together with HomeDesign.swift and WallGrid.swift. The
// page passes in what it read (the bundle, the link, /state's wall block,
// GET /tuning) and shows the words that come back.

import Foundation

/// The app's version as the bundle states it: "1.0 (1)".
enum AppVersion {
    static func display(_ info: [String: Any]?) -> String {
        let (version, build) = parts(info)
        switch (version, build) {
        case let (v?, b?) where b != v: return "\(v) (\(b))"
        case let (v?, _): return v
        case let (nil, b?): return "Build \(b)"
        default: return "Version unavailable"
        }
    }

    /// The same, read aloud: "Version 1.0, build 1".
    static func spoken(_ info: [String: Any]?) -> String {
        let (version, build) = parts(info)
        switch (version, build) {
        case let (v?, b?) where b != v: return "Version \(v), build \(b)"
        case let (v?, _): return "Version \(v)"
        case let (nil, b?): return "Build \(b)"
        default: return "Version unavailable"
        }
    }

    /// The Settings row and the masthead: "Version 1.0 (1)". display()
    /// already names itself when there is no version number ("Build 1",
    /// "Version unavailable"), so it is not prefixed a second time.
    static func detail(_ info: [String: Any]?) -> String {
        parts(info).0 == nil ? display(info) : "Version " + display(info)
    }

    /// The masthead's name and version as one VoiceOver stop:
    /// "Tessera, version 1.0, build 1".
    static func heading(_ info: [String: Any]?) -> String {
        let said = spoken(info)
        return "Tessera, " + said.prefix(1).lowercased() + said.dropFirst()
    }

    private static func parts(_ info: [String: Any]?) -> (String?, String?) {
        func clean(_ key: String) -> String? {
            guard let raw = info?[key] as? String else { return nil }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return (clean("CFBundleShortVersionString"), clean("CFBundleVersion"))
    }
}

/// The Panel tuning row's reading of GET /tuning: one read per visit, never
/// polled, and never shown while the wall is away, so a stale count is not
/// presented as current.
enum TuningPeek: Equatable {
    case waiting, reading, count(Int), unavailable, failed

    /// The brain sends bools as JSON true and false and numbers as ints or
    /// floats. A bool reads as 1 or 0 so a flipped switch is one step away
    /// from its default.
    static func numbers(_ raw: [String: Any]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (key, value) in raw {
            if let flag = value as? Bool { out[key] = flag ? 1 : 0 }
            else if let number = value as? Double { out[key] = number }
            else if let whole = value as? Int { out[key] = Double(whole) }
        }
        return out
    }

    /// How many values differ from their defaults by more than half a step.
    /// Names missing from either side are skipped, so an older brain with
    /// fewer knobs is never counted as changed.
    static func changed(values: [String: Double], defaults: [String: Double], steps: [String: Double]) -> Int {
        values.reduce(0) { total, entry in
            guard let fallback = defaults[entry.key] else { return total }
            let step = abs(steps[entry.key] ?? 0)
            return abs(entry.value - fallback) > max(step / 2, 1e-6) ? total + 1 : total
        }
    }

    /// The count from a GET /tuning body, or nil when values, defaults or
    /// knobs is missing. Every knob counts, the listening ones too, by the
    /// same rule as TuningStore.changedCount, so this row and the tuning
    /// page's own status line always give the same number. A knob without
    /// a step takes the store's 0.01.
    static func parse(_ json: [String: Any]) -> Int? {
        guard let rawValues = json["values"] as? [String: Any],
              let rawDefaults = json["defaults"] as? [String: Any],
              let knobs = json["knobs"] as? [[String: Any]] else { return nil }
        var steps: [String: Double] = [:]
        for knob in knobs {
            guard let name = knob["name"] as? String else { continue }
            steps[name] = (knob["step"] as? Double) ?? (knob["step"] as? Int).map(Double.init) ?? 0.01
        }
        let values = numbers(rawValues).filter { steps[$0.key] != nil }
        return changed(values: values, defaults: numbers(rawDefaults), steps: steps)
    }

    /// The row's subtitle. The counts use the tuning page's own words
    /// (TuningCopy.changed), so both pages say "settings".
    static func status(_ peek: TuningPeek, link: AboutFacts.Link) -> String {
        switch link {
        case .searching: return "Waiting for your wall"
        case .offline, .standIn: return "Needs your wall"
        case .live: break
        }
        switch peek {
        case .waiting, .reading: return "Reading your wall"
        case .count(0): return "All settings at their defaults"
        case .count(1): return "1 setting changed from its default"
        case .count(let n): return "\(n) settings changed from their defaults"
        case .unavailable: return "Not available on this wall"
        case .failed: return "Couldn’t read the tuning"
        }
    }

    /// The row opens only with a wall that has a tuning store. A failed read
    /// still opens it: the tuning page has its own retry.
    static func opens(_ peek: TuningPeek, link: AboutFacts.Link) -> Bool {
        link == .live && peek != .unavailable
    }
}

/// The wall facts, as pure functions of what the app knows.
enum AboutFacts {
    /// LinkState without SwiftUI.
    enum Link: Equatable { case live, searching, offline, standIn }

    /// The Wall row: its value and the smaller line under it. In order, the
    /// stand-in is always the phone's own preview. A live wall states its
    /// grid. A wall that is away shows the last size it stated. A phone that
    /// has never met a wall says so rather than presenting Panel.side's 192
    /// fallback as known.
    static func wallLine(link: Link, grid: WallGrid?, side: Int, learned: Bool,
                         previewSide: Int = 64, locale: Locale = .current) -> (value: String, subline: String?) {
        switch link {
        case .standIn:
            return ("\(previewSide) x \(previewSide) preview", "No wall connected")
        case .live:
            if let grid { return (grid.sizeText(locale: locale), grid.panelsText) }
            return (squareText(side, locale: locale), nil)
        case .searching, .offline:
            guard learned else { return ("Not connected yet", nil) }
            if let grid { return (grid.sizeText(locale: locale), "\(grid.panelsText), last known") }
            return (squareText(side, locale: locale), "Last known")
        }
    }

    /// The Size line of Copy details, shorter than the row.
    static func sizeLine(link: Link, grid: WallGrid?, side: Int, learned: Bool, previewSide: Int = 64) -> String {
        func panels(_ grid: WallGrid) -> String { grid.panels == 1 ? "one panel" : grid.panelsText }
        switch link {
        case .standIn:
            return "\(previewSide) x \(previewSide) preview, no wall connected"
        case .live:
            if let grid { return "\(grid.width) x \(grid.height), \(panels(grid))" }
            return "\(side) x \(side)"
        case .searching, .offline:
            guard learned else { return "not connected yet" }
            if let grid { return "\(grid.width) x \(grid.height), \(panels(grid)), last known" }
            return "\(side) x \(side), last known"
        }
    }

    /// ", last reply 12 minutes ago", added to "Offline" when the last
    /// successful reply is known and at least a minute old. Under a minute
    /// "Offline" stands alone: "just now" beside it read as if the wall
    /// were still answering.
    static func lastReply(_ lastSync: Date?, now: Date, locale: Locale = .current) -> String {
        guard let lastSync else { return "" }
        let seconds = now.timeIntervalSince(lastSync)
        if seconds < 60 { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return ", last reply " + formatter.localizedString(for: lastSync, relativeTo: now)
    }

    private static func squareText(_ side: Int, locale: Locale) -> String {
        WallGrid(cols: 1, rows: 1, tile: side).sizeText(locale: locale)
    }
}

/// The plain text Copy details puts on the pasteboard, for a support
/// message. It names the local wall address and nothing that identifies the
/// phone. Sizes use a plain "x".
enum AboutDetails {
    static func text(version: String, iOS: String, host: String, status: String,
                     size: String, design: String, opening: String) -> String {
        [
            "Tessera \(version)",
            "iOS \(iOS) on iPhone",
            "Wall: \(host)",
            "Status: \(status)",
            "Size: \(size)",
            "Design: \(design)",
            "Opening: \(opening)",
        ].joined(separator: "\n")
    }
}
