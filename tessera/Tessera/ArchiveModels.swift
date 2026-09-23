import Foundation

struct JournalEntry: Equatable {
    let ts: Int
    let title: String
    let artist: String
    let album: String
    let artURL: String?
    var local = false
    var date: Date { Date(timeIntervalSince1970: TimeInterval(ts)) }
    var identity: String { "\(ts)|\(ArchiveIndex.normalized(artist))|\(ArchiveIndex.normalized(title))|\(ArchiveIndex.normalized(album))" }
    var sleeveKey: String { ArchiveIndex.normalized(artist) + "|" + ArchiveIndex.normalized(album.isEmpty ? title : album) }
}

struct WornRun: Identifiable, Equatable {
    let entry: JournalEntry
    let count: Int
    let lastTs: Int
    var occurrences: [JournalEntry] = []
    var id: String { entry.identity }
}

enum ArchiveIndex {
    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func merge(_ remote: [JournalEntry], _ local: [JournalEntry]) -> [JournalEntry] {
        var rows: [String: JournalEntry] = [:]
        // A server entry wins a duplicate, preserving a usable artwork URL.
        for entry in local + remote { rows[entry.identity] = entry }
        return rows.values.sorted { $0.ts == $1.ts ? $0.identity < $1.identity : $0.ts > $1.ts }
    }

    static func collapse(_ entries: [JournalEntry], calendar: Calendar = .current) -> [WornRun] {
        var result: [WornRun] = []
        for entry in entries.sorted(by: { $0.ts > $1.ts }) {
            if let last = result.last,
               normalized(last.entry.title) == normalized(entry.title),
               last.entry.sleeveKey == entry.sleeveKey,
               last.entry.local == entry.local,
               calendar.isDate(last.entry.date, inSameDayAs: entry.date) {
                result[result.count - 1] = WornRun(entry: last.entry, count: last.count + 1,
                                                  lastTs: entry.ts, occurrences: last.occurrences + [entry])
            } else {
                result.append(WornRun(entry: entry, count: 1, lastTs: entry.ts, occurrences: [entry]))
            }
        }
        return result
    }

    static func matching(_ runs: [WornRun], query: String) -> [WornRun] {
        let words = normalized(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return runs }
        return runs.filter { run in
            let text = normalized([run.entry.title, run.entry.artist, run.entry.album].joined(separator: " "))
            return words.allSatisfy { text.localizedStandardContains($0) }
        }
    }
}
