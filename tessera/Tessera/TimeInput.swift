import Foundation

/// Civil times belong to the wall. A fixed-zone editing date keeps the phone's
/// current time zone from silently moving a saved alarm while the owner travels.
enum TimeInput {
    static let editorZone = TimeZone(secondsFromGMT: 0)!
    static var editorCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = editorZone
        return calendar
    }

    static func seconds(minutes: String, seconds: String) -> Int? {
        let m = minutes.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = seconds.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty, !s.isEmpty, m.allSatisfy(\.isASCIIWholeNumber), s.allSatisfy(\.isASCIIWholeNumber),
              let minutes = Int(m), let seconds = Int(s), (0...180).contains(minutes), (0...59).contains(seconds) else { return nil }
        let duration = minutes * 60 + seconds
        return (6...10_800).contains(duration) ? duration : nil
    }

    static func clock(_ seconds: Int) -> String {
        let value = max(0, seconds)
        if value >= 3_600 { return String(format: "%d:%02d:%02d", value / 3_600, value / 60 % 60, value % 60) }
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    static func duration(_ seconds: Int) -> String {
        var components: [String] = []
        let value = max(0, seconds)
        if value >= 3_600 { components.append("\(value / 3_600) hour\(value / 3_600 == 1 ? "" : "s")") }
        if value / 60 % 60 > 0 { components.append("\(value / 60 % 60) minute\(value / 60 % 60 == 1 ? "" : "s")") }
        if value % 60 > 0 || components.isEmpty { components.append("\(value % 60) second\(value % 60 == 1 ? "" : "s")") }
        return components.joined(separator: ", ")
    }

    static func date(_ hhmm: String) -> Date {
        let pieces = hhmm.split(separator: ":", omittingEmptySubsequences: false)
        let hour = pieces.count == 2 ? Int(pieces[0]) : nil
        let minute = pieces.count == 2 ? Int(pieces[1]) : nil
        let valid = hour.map { (0...23).contains($0) } == true && minute.map { (0...59).contains($0) } == true
        return editorCalendar.date(from: DateComponents(year: 2001, month: 1, day: 1,
            hour: valid ? hour : 7, minute: valid ? minute : 0)) ?? Date(timeIntervalSince1970: 0)
    }

    static func civilTime(_ date: Date) -> String {
        let components = editorCalendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 7, components.minute ?? 0)
    }

    static func timeLabel(_ hhmm: String, twentyFour: Bool) -> String {
        let components = editorCalendar.dateComponents([.hour, .minute], from: date(hhmm))
        let hour = components.hour ?? 7, minute = components.minute ?? 0
        if twentyFour { return String(format: "%02d:%02d", hour, minute) }
        return String(format: "%d:%02d %@", hour % 12 == 0 ? 12 : hour % 12, minute, hour < 12 ? "AM" : "PM")
    }

    static func timeZone(identifier: String?, offset: Int?) -> TimeZone? {
        if let identifier, let zone = TimeZone(identifier: identifier) { return zone }
        if let offset, abs(offset) <= 18 * 3_600 { return TimeZone(secondsFromGMT: offset) }
        return nil
    }
}

private extension Character {
    var isASCIIWholeNumber: Bool { unicodeScalars.count == 1 && unicodeScalars.allSatisfy { (48...57).contains($0.value) } }
}
