// The app's flight recorder.
//
// Born as a lyrics-only diagnostic that caught a three-second stall on a
// metronome, promoted to the whole app at the owner's call: they test by
// USING the thing, and every subsystem now leaves a trail. One ring, one
// file, pulled off the device when something felt wrong.
//
// Discipline: events, not chatter. Discrete moments (a mode change, a link
// transition, a stall, a fetch landing) get one line each; per-frame notes
// exist only where frames themselves were the mystery (lyrics). The ring
// keeps the last ~6000 lines and flushes every five seconds, so pulling
// the file always answers "what just happened", not "what happened at
// install time".

import Foundation
import QuartzCore

@MainActor
enum FlightLog {
    private static var lines: [String] = []
    private static var lastFlush: Double = 0
    /// Dated, because a log shared from the Connection page can span days
    /// and "09:14" alone no longer says which morning. A fixed locale and
    /// calendar keep the stamp the same whatever the phone is set to.
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static var seeded = false

    /// Documents/flightlog.txt, the file the Connection page shares.
    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("flightlog.txt")
    }

    static func note(_ category: String, _ message: String) {
        seed()
        lines.append("\(stamp.string(from: Date())) [\(category)] \(message)")
        if lines.count > 6000 { lines.removeFirst(2000) }
        let now = CACurrentMediaTime()
        if now - lastFlush > 5 {
            lastFlush = now
            flush()
        }
    }

    /// Writes the ring to disk. Seeds first: the ring is empty until the
    /// session's first note loads the file, and writing that empty ring
    /// used to erase the log it was meant to keep.
    static func flush() {
        seed()
        try? lines.joined(separator: "\n").write(
            to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Everything up to now on disk, for ShareLink. Nil when there is no
    /// log yet, so the page can hide the link rather than share nothing.
    static func prepareForShare() -> URL? {
        seed()
        guard !lines.isEmpty else { return nil }
        flush()
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    // Continuity across launches: the first touch of a session pulls the
    // previous session's tail back into the ring, so "done" after a relaunch
    // still hands over the whole story.
    private static func seed() {
        guard !seeded else { return }
        seeded = true
        if let old = try? String(contentsOf: fileURL, encoding: .utf8) {
            lines = old.split(separator: "\n").suffix(3000).map(String.init)
            lines.append("---- app launched ----")
        }
    }
}
