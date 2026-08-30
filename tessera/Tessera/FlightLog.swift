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
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static var seeded = false

    static func note(_ category: String, _ message: String) {
        // continuity across launches: the first note of a session pulls the
        // previous session's tail back into the ring, so "done" after a
        // relaunch still hands over the whole story
        if !seeded {
            seeded = true
            let url = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("flightlog.txt")
            if let old = try? String(contentsOf: url, encoding: .utf8) {
                lines = old.split(separator: "\n").suffix(3000).map(String.init)
                lines.append("---- app launched ----")
            }
        }
        lines.append("\(day.string(from: Date())) [\(category)] \(message)")
        if lines.count > 6000 { lines.removeFirst(2000) }
        let now = CACurrentMediaTime()
        if now - lastFlush > 5 {
            lastFlush = now
            flush()
        }
    }

    static func flush() {
        let url = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("flightlog.txt")
        try? lines.joined(separator: "\n").write(
            to: url, atomically: true, encoding: .utf8)
    }
}
