// What the numbers in the journal actually say.
//
// Everything below is counted from the journal, never estimated. Where the
// journal cannot support a claim, the line is absent rather than softened.

import SwiftUI

struct WornStats {
    let plays: Int              // every time a sleeve went up, repeats included
    let sleeves: Int            // distinct sleeves
    let artists: Int            // distinct artists
    let hours: [Double]         // 24 buckets, 0...1 against the busiest
    let busiest: Int?           // hour of day, nil when nothing to compare
    let topArtist: (name: String, plays: Int)?
    let longest: WornRun?       // the sleeve that stayed up longest in a row
    let days: Int

    var isEmpty: Bool { plays == 0 }

    static func read(_ runs: [WornRun]) -> WornStats {
        guard !runs.isEmpty else {
            return WornStats(plays: 0, sleeves: 0, artists: 0,
                             hours: Array(repeating: 0, count: 24), busiest: nil,
                             topArtist: nil, longest: nil, days: 0)
        }
        var buckets = [Double](repeating: 0, count: 24)
        var byArtist: [String: Int] = [:]
        var artistNames: [String: String] = [:]
        var sleeves = Set<String>()
        var dayKeys = Set<Int>()
        var plays = 0
        let cal = Calendar.current

        for run in runs {
            plays += run.count
            sleeves.insert(run.entry.sleeveKey)
            let artist = run.entry.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            if !artist.isEmpty {
                let key = ArchiveIndex.normalized(artist)
                byArtist[key, default: 0] += run.count
                if artistNames[key] == nil { artistNames[key] = artist }
            }
            let entries = run.occurrences.isEmpty ? Array(repeating: run.entry, count: run.count) : run.occurrences
            for entry in entries {
                buckets[cal.component(.hour, from: entry.date)] += 1
                dayKeys.insert(cal.ordinality(of: .day, in: .era, for: entry.date) ?? 0)
            }
        }

        let peak = buckets.max() ?? 0
        let norm = peak > 0 ? buckets.map { $0 / peak } : buckets
        // A busiest hour only means something once there is a shape to be
        // busiest within: one evening of listening has no daily pattern.
        let busiest = plays >= 12 && dayKeys.count > 1 ? buckets.firstIndex(of: peak) : nil
        let top = byArtist.max { a, b in
            a.value == b.value ? a.key > b.key : a.value < b.value
        }

        return WornStats(
            plays: plays,
            sleeves: sleeves.count,
            artists: byArtist.count,
            hours: norm,
            busiest: busiest,
            topArtist: top.flatMap { $0.value > 1 ? (name: artistNames[$0.key] ?? $0.key, plays: $0.value) : nil },
            longest: runs.filter { $0.count > 1 }.max { $0.count < $1.count },
            days: dayKeys.count
        )
    }
}

// MARK: - The band
//
// The hour band and the counted lines that drew these numbers left the app
// with the Archive redesign. Insights (ListeningStatsPage) charts them now.
// The marker stays because scripts/test_archive.py slices WornStats up to it.
