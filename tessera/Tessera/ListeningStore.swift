import Foundation
import Observation

@MainActor @Observable
final class ListeningStore {
    static let shared = ListeningStore()
    private(set) var days: [String: Double] = [:]
    private(set) var saveFailed = false
    @ObservationIgnored private var clock = ListeningClock()
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var dirty = false
    private let file: URL?

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        file = directory?.appendingPathComponent("listening-v1.json")
        if let file, let bytes = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String: Double].self, from: bytes) {
            days = saved.filter { $0.value.isFinite && $0.value >= 0 && $0.value <= 86400 }
        }
    }

    var total: Double { days.values.reduce(0, +) }
    var today: Double { days[Self.dayKey(Date()), default: 0] }

    func observe(state: WallState, connected: Bool, now: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime) {
        guard connected else { clock.suspend(); return }
        let key = SleeveMatch.key(title: state.title ?? "", artist: state.artist ?? "")
        let seconds = clock.observe(track: (state.title ?? "").isEmpty ? "" : key,
                                    position: state.songPosition(at: now), playing: state.songPlaying, uptime: uptime)
        guard seconds > 0 else { return }
        let day = Self.dayKey(now)
        days[day] = min(86400, days[day, default: 0] + seconds)
        if days.count > 730, let oldest = days.keys.sorted().first { days.removeValue(forKey: oldest) }
        dirty = true
        if now.timeIntervalSince(lastSave) >= 30 { save() }
    }

    func seconds(since date: Date?) -> Double {
        guard let date else { return total }
        let lower = Self.dayKey(date)
        return days.filter { $0.key >= lower }.values.reduce(0, +)
    }

    func suspend() { clock.suspend(); save() }

    private func save() {
        guard dirty, let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = try JSONEncoder().encode(days)
            try bytes.write(to: file, options: .atomic)
            lastSave = Date(); dirty = false; saveFailed = false
        } catch { saveFailed = true }
    }

    private static func dayKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
