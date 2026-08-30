// What the app saw, when there was no wall to ask.
//
// The wall keeps the real journal, and it keeps the frames' source art as
// URLs it can refetch. The stand-in has neither: the artwork it uses comes
// from this phone's own library and has no address anywhere. So when the app
// is running its own wall, it keeps its own record, and it keeps the actual
// frame rather than a way to find one later.
//
// Twelve kilobytes a sleeve, a hundred and twenty sleeves, so about a
// megabyte and a half at the ceiling. That is small enough not to think
// about and large enough that the Archive, the counts and the panel's
// backwards drag all have something real to work on before any hardware
// exists.

import Foundation

@MainActor
enum LocalJournal {
    private static let limit = 120

    private struct Row: Codable {
        var ts: Int
        var title: String
        var artist: String
        var album: String
    }

    private static var dir: URL? = {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let d = base.appendingPathComponent("worn", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static var indexURL: URL? { dir?.appendingPathComponent("index.json") }
    private static func frameURL(_ ts: Int) -> URL? {
        dir?.appendingPathComponent("\(ts).raw")
    }

    /// In-memory copy of the index, so the Archive is not re-reading a file
    /// on every redraw.
    private static var rows: [Row]? = nil

    private static func loadRows() -> [Row] {
        if let rows { return rows }
        guard let url = indexURL, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Row].self, from: data) else {
            rows = []
            return []
        }
        rows = decoded
        return decoded
    }

    /// Record a sleeve. Repeats of the thing already on top are ignored: the
    /// stand-in re-reads now-playing every couple of seconds and every one of
    /// those is the same track, not another wearing of it.
    static func append(title: String?, artist: String?, album: String?, frame: [UInt8]) {
        let t = title ?? ""
        guard !t.isEmpty, frame.count == 64 * 64 * 3 else { return }
        var all = loadRows()
        if let last = all.last, last.title == t, last.artist == (artist ?? "") { return }

        let ts = Int(Date().timeIntervalSince1970)
        all.append(Row(ts: ts, title: t, artist: artist ?? "", album: album ?? ""))
        var dead: [URL] = []
        while all.count > limit {
            let gone = all.removeFirst()
            if let url = frameURL(gone.ts) { dead.append(url) }
        }
        rows = all
        // The disk work happens OFF the main thread: writing 12KB plus the
        // index synchronously froze a Studio push for half a second, and
        // the flight recorder has the receipt.
        let frameData = Data(frame)
        let frameDst = frameURL(ts)
        let indexDst = indexURL
        let indexData = try? JSONEncoder().encode(all)
        Task.detached(priority: .utility) {
            if let frameDst { try? frameData.write(to: frameDst, options: .atomic) }
            for url in dead { try? FileManager.default.removeItem(at: url) }
            if let indexDst, let indexData {
                try? indexData.write(to: indexDst, options: .atomic)
            }
        }
    }

    /// Newest first, in the shape the Archive already speaks.
    static func entries() -> [JournalEntry] {
        loadRows().reversed().map {
            JournalEntry(ts: $0.ts, title: $0.title, artist: $0.artist,
                         album: $0.album, artURL: nil, local: true)
        }
    }

    static func frame(_ ts: Int) -> [UInt8]? {
        guard let url = frameURL(ts), let data = try? Data(contentsOf: url),
              data.count == 64 * 64 * 3 else { return nil }
        return [UInt8](data)
    }

    static var isEmpty: Bool { loadRows().isEmpty }
}
