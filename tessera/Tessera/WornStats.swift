// What the numbers in the journal actually say.
//
// The obvious move is four cards with big figures in them, and it would tell
// you nothing: "138 sleeves" is a number you cannot feel. The one honest
// question a wall's log can answer is *when the room is lit*, so that is the
// shape here: twenty-four columns, one per hour, drawn as emitters, lit by
// how much of your listening happened then. It is a small piece of the wall
// showing you your own day, made of the same material as everything else.
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
        var sleeves = Set<String>()
        var dayKeys = Set<Int>()
        var plays = 0
        let cal = Calendar.current

        for run in runs {
            plays += run.count
            sleeves.insert("\(run.entry.artist)|\(run.entry.title)")
            if !run.entry.artist.isEmpty {
                byArtist[run.entry.artist, default: 0] += run.count
            }
            let h = cal.component(.hour, from: run.entry.date)
            buckets[h] += Double(run.count)
            dayKeys.insert(cal.ordinality(of: .day, in: .era, for: run.entry.date) ?? 0)
        }

        let peak = buckets.max() ?? 0
        let norm = peak > 0 ? buckets.map { $0 / peak } : buckets
        // A busiest hour only means something once there is a shape to be
        // busiest within: one evening of listening has no daily pattern.
        let busiest = plays >= 12 ? buckets.firstIndex(of: peak) : nil
        let top = byArtist.max { a, b in
            a.value == b.value ? a.key > b.key : a.value < b.value
        }

        return WornStats(
            plays: plays,
            sleeves: sleeves.count,
            artists: byArtist.count,
            hours: norm,
            busiest: busiest,
            topArtist: top.flatMap { $0.value > 1 ? (name: $0.key, plays: $0.value) : nil },
            longest: runs.filter { $0.count > 1 }.max { $0.count < $1.count },
            days: dayKeys.count
        )
    }
}

// MARK: - The band

/// Twenty-four hours of the day as twenty-four lit columns.
struct WornClockBand: View {
    let stats: WornStats
    let accent: Color

    /// Columns are emitters, so they have to be round and they have to sit on
    /// an unlit lattice: an empty hour is a dark panel, not a missing bar.
    private let rows = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Canvas { ctx, size in
                let cw = size.width / 24
                let ch = size.height / CGFloat(rows)
                let d = min(cw, ch) * 0.62
                for h in 0..<24 {
                    let v = stats.hours[h]
                    // How many of the five emitters in the column are lit,
                    // and the top one is dimmer than full when it is partial:
                    // the resolution is five, the reading is continuous.
                    let exact = v * Double(rows)
                    for r in 0..<rows {
                        let fromBottom = rows - 1 - r
                        let strength: Double = {
                            let step = Double(fromBottom)
                            if exact >= step + 1 { return 1 }
                            if exact <= step { return 0 }
                            return exact - step
                        }()
                        let cx = CGFloat(h) * cw + cw / 2
                        let cy = CGFloat(r) * ch + ch / 2
                        let box = CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)
                        if strength <= 0.001 {
                            ctx.fill(Path(ellipseIn: box), with: .color(Ink.ink.opacity(0.06)))
                        } else {
                            ctx.fill(Path(ellipseIn: box),
                                     with: .color(accent.opacity(0.28 + 0.72 * strength)))
                        }
                    }
                }
            }
            .frame(height: 44)
            .drawingGroup()
            .accessibilityElement()
            .accessibilityLabel("When the wall is lit")
            .accessibilityValue(stats.busiest.map { "Busiest around \(hour($0))" } ?? "")

            // Only four marks. A full axis would be more information than the
            // thing above it carries.
            HStack(spacing: 0) {
                ForEach([0, 6, 12, 18], id: \.self) { h in
                    Text(hour(h))
                        .font(.machine(8))
                        .foregroundStyle(Ink.faint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityHidden(true)
        }
    }

    private func hour(_ h: Int) -> String {
        h == 0 ? "12a" : h == 12 ? "12p" : h < 12 ? "\(h)a" : "\(h - 12)p"
    }
}

/// The counted lines. Each is a sentence, because each is a fact, and a fact
/// with a unit reads better than a figure with a caption under it.
struct WornCount: View {
    let stats: WornStats
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(lines, id: \.self) { line in
                line.text(accent: accent)
            }
        }
    }

    private var lines: [CountLine] {
        var out: [CountLine] = []
        out.append(CountLine(
            lead: "\(stats.plays)",
            rest: stats.plays == 1 ? " time the wall changed" : " times the wall changed",
            tail: stats.days > 1 ? ", across \(stats.days) days" : nil
        ))
        if stats.sleeves != stats.plays {
            out.append(CountLine(lead: "\(stats.sleeves)",
                                 rest: " sleeves, \(stats.artists) artists", tail: nil))
        }
        if let top = stats.topArtist {
            out.append(CountLine(lead: top.name, rest: " the most, ",
                                 tail: "\(top.plays) times"))
        }
        if let long = stats.longest {
            out.append(CountLine(lead: long.entry.title, rest: " stayed up longest, ",
                                 tail: "\(long.count) in a row"))
        }
        if let b = stats.busiest {
            out.append(CountLine(lead: window(b), rest: " is when the wall is on most",
                                 tail: nil))
        }
        return out
    }

    private func window(_ h: Int) -> String {
        let f = { (x: Int) in x == 0 ? "12am" : x == 12 ? "12pm" : x < 12 ? "\(x)am" : "\(x - 12)pm" }
        return "\(f(h)) to \(f((h + 1) % 24))"
    }
}

private struct CountLine: Hashable {
    let lead: String
    let rest: String
    let tail: String?

    func text(accent: Color) -> some View {
        (Text(lead).font(.ui(14, .semibold)).foregroundStyle(accent)
         + Text(rest).font(.ui(14)).foregroundStyle(Ink.dim)
         + Text(tail ?? "").font(.ui(14)).foregroundStyle(Ink.faint))
            .fixedSize(horizontal: false, vertical: true)
    }
}
