import Foundation

@main struct ArchiveTests {
    static func main() throws {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            let passed = condition()
            checks.append(["name": name, "passed": passed])
            if !passed { fputs("FAIL: \(name)\n", stderr) }
        }
        let noon = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        let ts = Int(noon.timeIntervalSince1970)
        let a = JournalEntry(ts: ts, title: "Quiet", artist: "Mira", album: "Dawn", artURL: "https://example.com/cover.jpg")
        var local = a; local.local = true
        let other = JournalEntry(ts: ts, title: "Quiet", artist: "June", album: "Dawn", artURL: nil)
        let merged = ArchiveIndex.merge([a, other], [local])
        check("Same-second songs by different artists survive merge", merged.count == 2)
        check("Remote duplicate wins and preserves artwork", merged.first { $0.artist == "Mira" } == a)
        check("Entry identities do not collide at one timestamp", Set(merged.map(\.identity)).count == 2)
        let earlier = JournalEntry(ts: ts - 3600, title: " QUIET ", artist: "mira", album: "Dawn", artURL: nil)
        let yesterday = JournalEntry(ts: ts - 86400, title: "Quiet", artist: "Mira", album: "Dawn", artURL: nil)
        let runs = ArchiveIndex.collapse([yesterday, earlier, a])
        check("Runs are sorted newest first", runs.first?.entry == a)
        check("Consecutive repeats combine within one day", runs.first?.count == 2)
        check("Day boundaries remain visible", runs.count == 2)
        check("All original timestamps survive collapse", runs.flatMap(\.occurrences).count == 3)
        check("Search matches every term across metadata", ArchiveIndex.matching(runs, query: " mira  dawn ").count == 2)
        check("Search rejects an absent term", ArchiveIndex.matching(runs, query: "mira rain").isEmpty)
        check("Empty search preserves results", ArchiveIndex.matching(runs, query: "  ") == runs)
        let stats = WornStats.read(runs)
        check("Appearances include repeats", stats.plays == 3)
        check("Album identity ignores song casing", stats.sleeves == 1)
        check("Artist counts normalize casing", stats.artists == 1)
        check("Hours retain earlier repeat timestamps", stats.hours[11] > 0 && stats.hours[12] > 0)
        check("Small samples do not invent a daily pattern", stats.busiest == nil)
        check("Empty history has no fake metrics", WornStats.read([]).plays == 0 && WornStats.read([]).topArtist == nil)

        var clock = ListeningClock()
        func observe(_ position: Double?, _ uptime: Double, _ playing: Bool = true, _ track: String = "song") -> Double {
            clock.observe(track: track, position: position, playing: playing, uptime: uptime)
        }
        check("First observation counts no unobserved time", observe(30, 100) == 0)
        var total = 0.0
        for tick in 1...90 { total += observe(30 + Double(tick), 100 + Double(tick)) }
        check("Ninety continuous seconds count exactly once", total == 90)
        check("Repeated timestamp counts nothing", observe(120, 190) == 0)
        check("Forward seek counts no time", observe(180, 191) == 0)
        check("Normal playback resumes after seek", observe(181, 192) == 1)
        check("Backward seek counts no time", observe(10, 193) == 0)
        check("Pause boundary counts no time", observe(10, 194, false) == 0)
        check("Paused interval counts no time", observe(10, 195, false) == 0)
        check("Resume does not include pause duration", observe(11, 196) == 0)
        check("Next resumed second counts", observe(12, 197) == 1)
        check("Missing position resets measurement", observe(nil, 198) == 0)
        check("Unknown gap is not credited", observe(15, 200) == 0)
        check("Background gap is not credited", observe(75, 260) == 0)
        check("New track has a fresh anchor", observe(0, 261, true, "next") == 0)
        check("Invalid time never enters ledger", observe(.nan, 262) == 0)
        check("Infinite uptime never enters ledger", observe(1, .infinity) == 0)
        _ = observe(10, 270); clock.suspend()
        check("Disconnect clears the clock anchor", observe(11, 271) == 0)
        check("Negative positions are rejected", observe(-1, 272) == 0)
        check("Empty identity is rejected", observe(0, 273, true, "") == 0)

        let entries: [[String: Any]] = [
            ["title": "Quiet", "artist": "Mira", "album": "Dawn", "ts": 10],
            ["title": "Quiet", "artist": "Mira", "album": "Dawn Deluxe", "ts": 20],
            ["title": "Quiet", "artist": "June", "album": "Dawn", "ts": 30]]
        check("Cover lookup preserves album edition", SleeveMatch.entry(in: entries, title: "Quiet", artist: "Mira", album: "Dawn")?["ts"] as? Int == 10)
        check("Unknown album uses latest matching song", SleeveMatch.entry(in: entries, title: "Quiet", artist: "Mira")?["ts"] as? Int == 20)
        check("Unmatched album never borrows another edition", SleeveMatch.entry(in: entries, title: "Quiet", artist: "Mira", album: "Live") == nil)
        check("Unicode canonical equivalents share identity", SleeveMatch.same("Cafe\u{301}", "Café"))
        let malformed = PressingChoice(kind: 999, colours: [[1], [.nan, 0, 0], [-1, 0.5, 2]], photo: "../private.jpg", label: 999)
        let safe = malformed.sanitized
        check("Corrupt palette rows are skipped safely", safe.colours == [[0, 0.5, 1]])
        check("Unknown pressing types reset automatically", safe.kind == nil && safe.label == nil)
        check("Photo traversal is rejected", safe.photo == nil)
        check("Empty palette uses sleeve colours", PressingChoice(colours: []).safeColours == nil)
        check("Valid photo basename survives", PressingChoice(photo: "record.jpg").sanitized.photo == "record.jpg")
        check("Valid pressing and label survive", PressingChoice(kind: 0, label: 4).sanitized == PressingChoice(kind: 0, label: 4))
        check("Palette is bounded to three inks", PressingChoice(colours: Array(repeating: [0, 1, 0], count: 100)).safeColours?.count == 3)
        let failures = checks.filter { !($0["passed"] as! Bool) }.count
        let report: [String: Any] = ["passed": checks.count - failures, "failed": failures, "checks": checks]
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
        if failures > 0 { exit(1) }
    }
}
