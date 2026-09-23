import Charts
import SwiftUI

struct ListeningStatsPage: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var listening = ListeningStore.shared
    @State private var period = 0
    let runs: [WornRun]
    let accent: Color

    private var start: Date? { period == 0 ? Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date())) : nil }
    private var entries: [JournalEntry] {
        runs.flatMap { $0.occurrences.isEmpty ? Array(repeating: $0.entry, count: $0.count) : $0.occurrences }
            .filter { entry in start.map { entry.date >= $0 } ?? true }
    }
    private var stats: WornStats { WornStats.read(ArchiveIndex.collapse(entries)) }
    private var hours: [Int] {
        var buckets = Array(repeating: 0, count: 24)
        for entry in entries { buckets[Calendar.current.component(.hour, from: entry.date)] += 1 }
        return buckets
    }
    private var artists: [(String, Int)] {
        Dictionary(grouping: entries.filter { !ArchiveIndex.normalized($0.artist).isEmpty }, by: { ArchiveIndex.normalized($0.artist) })
            .map { ($0.value.first?.artist.trimmingCharacters(in: .whitespacesAndNewlines) ?? $0.key, $0.value.count) }
            .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("THE SHAPE OF YOUR LISTENING").font(.machine(8)).tracking(1).foregroundStyle(accent.toned(forDark: true))
                        Text("Your listening").font(.display(typeSize.isAccessibilitySize ? 20 : 35)).foregroundStyle(Ink.ink)
                    }
                    Picker("History period", selection: $period) {
                        Text("Past 7 days").tag(0)
                        Text("All history").tag(1)
                    }.pickerStyle(.segmented)
                    timeCard
                    HStack(alignment: .top, spacing: 0) {
                        metric("\(stats.plays)", "Appearances")
                        metric("\(stats.sleeves)", "Sleeves")
                        metric("\(stats.artists)", "Artists")
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Text("When the wall changes").font(.displayMid(23)).foregroundStyle(Ink.ink)
                        Text("Recorded appearances by time of day").font(.ui(12)).foregroundStyle(Ink.dim)
                        Chart(0..<24, id: \.self) { hour in
                            BarMark(x: .value("Hour", hour), y: .value("Appearances", hours[hour]))
                                .foregroundStyle(accent.toned(forDark: true)).cornerRadius(3)
                                .accessibilityLabel(hourLabel(hour)).accessibilityValue("\(hours[hour]) appearances")
                        }
                        .chartXScale(domain: -0.5...23.5)
                        .chartXAxis { AxisMarks(values: [0, 6, 12, 18]) { value in
                            AxisValueLabel { if let h = value.as(Int.self) { Text(hourLabel(h)).font(.machine(8)).foregroundStyle(Ink.dim) } }
                        } }
                        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in AxisGridLine().foregroundStyle(Ink.hairline); AxisValueLabel().foregroundStyle(Ink.dim) } }
                        .chartYScale(domain: 0...max(1, hours.max() ?? 1))
                        .frame(height: 150)
                    }
                    if artists.isEmpty {
                        Text("Your most-played artists will appear as the wall records new sleeves.").font(.ui(14)).foregroundStyle(Ink.dim)
                    } else {
                        VStack(alignment: .leading, spacing: 18) {
                            Text("On repeat").font(.displayMid(25)).foregroundStyle(Ink.ink)
                            ForEach(Array(artists.prefix(5).enumerated()), id: \.element.0) { index, artist in
                                HStack(spacing: 14) {
                                    Text(String(format: "%02d", index + 1)).font(.machine(11)).foregroundStyle(Ink.dim).frame(width: 28)
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(artist.0).font(.ui(16, .medium)).foregroundStyle(Ink.ink)
                                            Spacer(minLength: 8)
                                            Text("\(artist.1)").font(.machine(11)).foregroundStyle(Ink.dim)
                                        }
                                        GeometryReader { geometry in
                                            Capsule().fill(Ink.hairline)
                                            Capsule().fill(accent.toned(forDark: true)).frame(width: geometry.size.width * Double(artist.1) / Double(max(1, artists.first?.1 ?? 1)))
                                        }.frame(height: 3)
                                    }
                                }.accessibilityElement(children: .ignore).accessibilityLabel("\(index + 1), \(artist.0), \(artist.1) recorded appearances")
                            }
                        }
                    }
                    Text("Appearances count journal entries, including repeats. They aren’t full-song plays. History includes up to 200 wall entries plus records saved on this phone.")
                        .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }.padding(24)
            }.background(Ink.ground)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.frame(minHeight: 44) } }
        }.preferredColorScheme(.dark).tint(accent.toned(forDark: true))
    }

    private var timeCard: some View {
        let seconds = listening.seconds(since: start)
        return VStack(alignment: .leading, spacing: 12) {
            Label("Listening time", systemImage: "headphones").font(.ui(14, .medium)).foregroundStyle(Ink.dim)
            Text(duration(seconds)).font(.display(typeSize.isAccessibilitySize ? 26 : 46)).foregroundStyle(Ink.ink).monospacedDigit()
            Text("Measured while Tessera is open and connected. Pauses, seeks and time away aren’t counted.")
                .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            if listening.saveFailed { Text("This session couldn’t be saved yet.").font(.ui(12)).foregroundStyle(Ink.signal) }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.plaster, in: RoundedRectangle(cornerRadius: 24))
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.display(typeSize.isAccessibilitySize ? 18 : 29)).foregroundStyle(Ink.ink)
            Text(label).font(.ui(11)).foregroundStyle(Ink.dim)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
    private func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : seconds > 0 && minutes == 0 ? "<1m" : "\(minutes)m"
    }
    private func hourLabel(_ h: Int) -> String { h == 0 ? "12a" : h == 12 ? "12p" : h < 12 ? "\(h)a" : "\(h - 12)p" }
}
