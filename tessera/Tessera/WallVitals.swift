// Wall health without SwiftUI: one /health reading, what it means, and every
// sentence the Wall health page and its Settings row say about it.
//
// Foundation only, so scripts/test_wall_vitals.swift compiles it with swiftc
// and checks each rule against the same authored readings the QA wall serves
// (scripts/qa/health_fixtures.json). HealthPage.swift only draws what this
// file decides.

import Foundation

// MARK: - The reading

/// One reading of /health. Every key but fps and uptime_s is optional: an
/// older brain sends fewer of them, and a brain on a Mac has no thermometer,
/// throttle bits, panel program or /proc. Absent stays absent, so its row or
/// tile is left out rather than guessed.
struct Vitals: Equatable {
    struct TempSample: Equatable {
        /// Seconds before the reading, on the brain's own clock.
        var ageS: Double
        var celsius: Double
    }

    /// The Pi firmware's throttle bits. now and ever keep their old meaning
    /// (any of under-voltage, capped or throttled), so an old phone reading a
    /// new brain is unchanged. The per-bit keys are new, and `detailed` says
    /// whether this brain sent them.
    struct Throttle: Equatable {
        var now = false
        var ever = false
        var raw: String?
        var detailed = false
        var undervoltNow = false, cappedNow = false, throttledNow = false, softTempNow = false
        var undervoltEver = false, cappedEver = false, throttledEver = false, softTempEver = false
    }

    /// The hand-off to the program that drives the panels.
    struct RendererStatus: Equatable {
        var attached: Bool
        var connects: Int?
        /// How long the panel program has been gone. nil while attached.
        var detachedS: Double?
        /// How long the oldest picture not yet taken has waited. nil when
        /// nothing is waiting.
        var pendingS: Double?
    }

    struct MemoryReading: Equatable {
        var totalMB: Int
        var availableMB: Int
    }

    struct StorageReading: Equatable {
        var totalGB: Double
        var freeGB: Double
    }

    /// pace()'s last measurement. Only paced faces (Spin, Lamp, the ticker)
    /// make one, so fpsAgeS says how old it is.
    var fps: Double
    var fpsAgeS: Double?
    var fpsTarget: Double?
    /// Frames the brain drew and handed to the panel program per second over
    /// the last few seconds, before repeats are dropped. 0 on a still face.
    var sentFps: Double?
    var tempC: Double?
    /// Oldest first, one a minute. nil when the brain sends no temp_log at
    /// all (an older brain), empty when it has no sensor or no sample yet.
    var tempLog: [TempSample]?
    var throttle: Throttle?
    /// The wall's software, since it last started.
    var uptimeS: Int
    /// The computer, since it last booted.
    var bootS: Int?
    var loopAgeS: Double?
    var renderer: RendererStatus?
    var memory: MemoryReading?
    var storage: StorageReading?
    var mode: String?
    /// When this phone received it. The page's freshness and the Settings
    /// row both read this, so they always describe the same reading.
    var receivedAt: Date

    /// Fails only when the body is not a JSON object. Every key is optional:
    /// fps and uptime_s fall back to 0, everything else to absent.
    init?(json: Any, receivedAt: Date = Date()) {
        guard let json = json as? [String: Any] else { return nil }
        fps = VitalsJSON.number(json["fps"]) ?? 0
        fpsAgeS = VitalsJSON.number(json["fps_age_s"])
        fpsTarget = VitalsJSON.number(json["fps_target"])
        sentFps = VitalsJSON.number(json["sent_fps"])
        tempC = VitalsJSON.number(json["temp_c"])
        if let log = json["temp_log"] as? [Any] {
            tempLog = log.compactMap { entry -> TempSample? in
                guard let pair = entry as? [Any], pair.count >= 2,
                      let age = VitalsJSON.number(pair[0]), let celsius = VitalsJSON.number(pair[1]) else { return nil }
                return TempSample(ageS: age, celsius: celsius)
            }.sorted { $0.ageS > $1.ageS }
        } else {
            tempLog = nil
        }
        if let bits = json["throttled"] as? [String: Any] {
            var throttle = Throttle(now: VitalsJSON.bool(bits["now"]) ?? false,
                                    ever: VitalsJSON.bool(bits["ever"]) ?? false,
                                    raw: bits["raw"] as? String)
            if let undervolt = VitalsJSON.bool(bits["undervolt_now"]) {
                throttle.detailed = true
                throttle.undervoltNow = undervolt
                throttle.cappedNow = VitalsJSON.bool(bits["capped_now"]) ?? false
                throttle.throttledNow = VitalsJSON.bool(bits["throttled_now"]) ?? false
                throttle.softTempNow = VitalsJSON.bool(bits["soft_temp_now"]) ?? false
                throttle.undervoltEver = VitalsJSON.bool(bits["undervolt_ever"]) ?? false
                throttle.cappedEver = VitalsJSON.bool(bits["capped_ever"]) ?? false
                throttle.throttledEver = VitalsJSON.bool(bits["throttled_ever"]) ?? false
                throttle.softTempEver = VitalsJSON.bool(bits["soft_temp_ever"]) ?? false
            }
            self.throttle = throttle
        } else {
            throttle = nil
        }
        uptimeS = max(0, HealthFormat.whole(VitalsJSON.number(json["uptime_s"]) ?? 0))
        bootS = VitalsJSON.number(json["boot_s"]).map { max(0, HealthFormat.whole($0)) }
        loopAgeS = VitalsJSON.number(json["loop_age_s"])
        if let r = json["renderer"] as? [String: Any], let attached = VitalsJSON.bool(r["attached"]) {
            renderer = RendererStatus(attached: attached,
                                      connects: VitalsJSON.number(r["connects"]).map(HealthFormat.whole),
                                      detachedS: VitalsJSON.number(r["detached_s"]),
                                      pendingS: VitalsJSON.number(r["pending_s"]))
        } else {
            renderer = nil
        }
        if let m = json["memory"] as? [String: Any],
           let total = VitalsJSON.number(m["total_mb"]), let available = VitalsJSON.number(m["available_mb"]) {
            memory = MemoryReading(totalMB: HealthFormat.whole(total), availableMB: HealthFormat.whole(available))
        } else {
            memory = nil
        }
        if let s = json["storage"] as? [String: Any],
           let total = VitalsJSON.number(s["total_gb"]), let free = VitalsJSON.number(s["free_gb"]) {
            storage = StorageReading(totalGB: total, freeGB: free)
        } else {
            storage = nil
        }
        mode = json["mode"] as? String
        self.receivedAt = receivedAt
    }

    /// GET /health, 200 only. Never cached, since a cached reading would be
    /// reported as a fresh one.
    static func read(host: String) async -> Vitals? {
        guard let url = URL(string: "http://\(host)/health") else { return nil }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return Vitals(json: json)
    }
}

/// JSONSerialization hands booleans back as NSNumber too, and `true as?
/// Double` is 1. Numbers and booleans are told apart here so a bool never
/// reads as a temperature.
private enum VitalsJSON {
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !isBool(number) else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, isBool(number) else { return nil }
        return number.boolValue
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

// MARK: - Rules

/// Every threshold in one place, so they can be tuned without hunting.
/// Each is applied to the value the page shows (a temperature is judged in
/// whole degrees), so what is on screen and how it is judged always agree.
enum HealthRules {
    /// Whole degrees Celsius. The Pi 5 slows itself at 80.
    static let warm = 70
    static let hot = 80
    /// A slowdown at or above this temperature is put down to heat.
    static let heatCause = 75
    /// The drawing loop reports every pass. An artwork fetch can hold it for
    /// up to 15 seconds a phase, so a stall is called only well past that.
    static let loopStall = 45.0
    /// Seconds the panel program may be gone, or a picture may wait, before
    /// it is a problem. A restart takes a few seconds, so this is not one.
    static let rendererLimit = 30.0
    /// Seconds after the software starts during which a missing panel
    /// program is the boot race, not a fault.
    static let startupGrace = 60
    /// A paced frame rate this old still describes what is on the wall.
    static let pacedLive = 12.0
    /// Behind when the paced rate is under this share of the target.
    static let behind = 0.8
    /// Fewer frames a second than this is a still picture.
    static let still = 0.5
    /// Megabytes free.
    static let memoryWatch = 120
    static let memoryAct = 60
    /// Gigabytes free.
    static let storageWatch = 1.0
    static let storageAct = 0.25
    /// A reading older than this is stale.
    static let staleAfter: TimeInterval = 30
    static let poll: TimeInterval = 10
    /// Samples needed before the temperature trace is drawn.
    static let traceMinimum = 3
    /// A log reaching back this far covers the last hour.
    static let hour: TimeInterval = 55 * 60
}

// MARK: - Words

enum HealthFormat {
    /// A whole number from a reading, cut toward zero like Int(_:). Int(_:)
    /// traps outside Int's range, and a reading is only checked for being
    /// finite, so a value past any real one (a trillion) is held there
    /// instead of crashing the app. Every Double to Int in this file goes
    /// through here.
    static func whole(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value, -1e12), 1e12))
    }

    static func plural(_ count: Int, _ unit: String) -> String {
        "\(count) \(unit)\(count == 1 ? "" : "s")"
    }

    /// "less than a minute", "1 minute", "5 hours, 12 minutes", "3 days, 4 hours".
    /// A zero second unit is left off: "12 days", not "12 days, 0 hours".
    static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "less than a minute" }
        if s < 3600 { return plural(s / 60, "minute") }
        if s < 86400 {
            let minutes = (s % 3600) / 60
            return plural(s / 3600, "hour") + (minutes > 0 ? ", " + plural(minutes, "minute") : "")
        }
        let hours = (s % 86400) / 3600
        return plural(s / 86400, "day") + (hours > 0 ? ", " + plural(hours, "hour") : "")
    }

    /// "just now" under 10 seconds, then "25 seconds ago", "1 minute ago",
    /// "3 hours ago", "12 days ago".
    static func ago(_ seconds: Double) -> String {
        let s = max(0, whole(seconds))
        if s < 10 { return "just now" }
        if s < 60 { return plural(s, "second") + " ago" }
        if s < 3600 { return plural(s / 60, "minute") + " ago" }
        if s < 86400 { return plural(s / 3600, "hour") + " ago" }
        return plural(s / 86400, "day") + " ago"
    }

    /// Megabytes, or gigabytes from 1 GB up.
    static func megabytes(_ mb: Int) -> String {
        mb >= 1024 ? gigabytes(Double(mb) / 1024) : "\(grouped(max(0, mb))) MB"
    }

    /// Whole gigabytes from 10, one decimal under 10, megabytes under 1 GB.
    /// The brain rounds storage to a tenth of a gigabyte, so megabytes made
    /// from it are rounded to the nearest 10 rather than claiming more.
    static func gigabytes(_ gb: Double) -> String {
        let tenths = (gb * 10).rounded() / 10
        if tenths >= 10 { return "\(grouped(whole(gb.rounded()))) GB" }
        if tenths >= 1 { return String(format: "%.1f GB", tenths) }
        let mb = whole((max(0, gb) * 1024 / 10).rounded()) * 10
        return "\(grouped(mb)) MB"
    }

    /// The temperature as the page shows it, in whole degrees.
    static func celsius(_ value: Double) -> Int { whole(value.rounded()) }

    /// One to nine in words, larger numbers as digits.
    static func word(_ count: Int, capitalized: Bool = false) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        guard words.indices.contains(count) else { return "\(count)" }
        let word = words[count]
        return capitalized ? word.prefix(1).uppercased() + word.dropFirst() : word
    }

    private static func grouped(_ value: Int) -> String {
        let digits = String(value)
        guard digits.count > 3 else { return digits }
        var out = ""
        for (index, character) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return out
    }
}

// MARK: - What a reading means

enum HealthLevel: Int, Comparable {
    case steady, watch, act

    static func < (lhs: HealthLevel, rhs: HealthLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var name: String {
        switch self {
        case .steady: "steady"
        case .watch: "watch"
        case .act: "act"
        }
    }
}

/// The named parts of the wall the page reports on.
enum HealthPart: String, CaseIterable, Identifiable {
    case loop, panels, power, heat, speed, frames, memory, storage, uptime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .loop: "Picture updates"
        case .panels: "Panels"
        case .power: "Power"
        case .heat: "Temperature"
        case .speed: "Processor speed"
        case .frames: "Frame rate"
        case .memory: "Memory"
        case .storage: "Storage"
        case .uptime: "Running for"
        }
    }

    /// The symbol beside the part's row.
    var rowSymbol: String {
        switch self {
        case .loop: "arrow.triangle.2.circlepath"
        case .panels: "square.grid.3x3"
        case .power: "bolt"
        case .heat: "thermometer.medium"
        case .speed: "gauge.with.dots.needle.50percent"
        case .frames: "speedometer"
        case .memory: "memorychip"
        case .storage: "internaldrive"
        case .uptime: "clock"
        }
    }

    /// The symbol on the part's notice when something is wrong with it.
    var noticeSymbol: String {
        switch self {
        case .loop: "pause.rectangle"
        case .panels: "square.grid.3x3"
        case .power: "bolt.trianglebadge.exclamationmark"
        case .heat: "thermometer.high"
        case .speed: "tortoise"
        case .frames: "speedometer"
        case .memory: "memorychip"
        case .storage: "internaldrive"
        case .uptime: "clock"
        }
    }

    /// The checks list, top to bottom. Temperature and frame rate are tiles.
    static let rows: [HealthPart] = [.power, .speed, .panels, .loop, .memory, .storage, .uptime]
    /// Most urgent first, within a level.
    static let priority: [HealthPart] = [.loop, .panels, .power, .heat, .speed, .memory, .storage, .frames, .uptime]
}

/// Something worth saying: a problem (act) or a thing to keep an eye on (watch).
struct HealthFinding: Identifiable, Equatable {
    let part: HealthPart
    let level: HealthLevel
    /// The page's headline when this finding leads it.
    let verdict: String
    let noticeTitle: String
    let noticeDetail: String
    let rowValue: String
    /// The Settings row's line.
    let short: String
    /// The detail when the page cannot act on the wall (a last reading),
    /// for a notice whose own detail points at a button that is then gone.
    var readOnlyDetail: String? = nil
    var id: HealthPart { part }
}

/// A row in the checks list.
struct HealthCheck: Identifiable, Equatable {
    let part: HealthPart
    let value: String
    let subtitle: String?
    let explanation: String
    var id: HealthPart { part }
    var title: String { part.title }
}

/// One reading, judged. Built once per reading, so the hero, the notices,
/// the tiles, the rows and the Settings line all say the same thing.
struct HealthReport: Equatable {
    struct Temperature: Equatable {
        enum Status: Equatable {
            case normal, warm, hot
            var word: String {
                switch self {
                case .normal: "Normal"
                case .warm: "Warm"
                case .hot: "Hot"
                }
            }
        }
        let celsius: Int
        let status: Status
        /// Oldest first, ending with this reading at age 0. Empty until the
        /// log has enough samples to draw.
        let trace: [Vitals.TempSample]
        /// "LAST HOUR", or "LAST 12 MIN" while the log is younger than that.
        let window: String?
        /// The same window in words, "the last hour" or "the last 12 minutes".
        let windowWords: String?
        /// Whole degrees, over the samples and this reading.
        let low: Int?
        let high: Int?
        /// The log exists but is still too short for a trace.
        let collecting: Bool
        /// The brain sends no log at all (an older brain).
        let noHistory: Bool

        /// The sentence under the value when there is no trace to draw.
        var note: String? {
            collecting ? Self.collectingNote : noHistory ? Self.noHistoryNote : nil
        }

        /// The status word, or nil on a last reading where "Normal" would
        /// sound like the wall now. Warm and hot stay, as the notices do.
        func statusWord(lastReading: Bool) -> String? {
            lastReading && status == .normal ? nil : status.word
        }

        var rangeCaption: String? {
            guard let low, let high else { return nil }
            return low == high ? "STEADY AT \(low)°C" : "\(low) TO \(high)°C"
        }

        var rangeWords: String? {
            guard let low, let high, let windowWords else { return nil }
            return low == high ? "Steady at \(low)°C in \(windowWords)." : "Between \(low) and \(high)°C in \(windowWords)."
        }

        static let collectingNote = "A trace appears after a few minutes."
        static let noHistoryNote = "No history from this wall."

        var accessibilityValue: String { accessibilityValue(lastReading: false) }

        /// On a last reading "normal" is left out, as it is on screen.
        func accessibilityValue(lastReading: Bool) -> String {
            var text = "\(celsius) degrees Celsius"
            if let word = statusWord(lastReading: lastReading) { text += ", \(word.lowercased())" }
            text += "."
            if let low, let high, let windowWords {
                text += low == high ? " Steady at \(low) over \(windowWords)." : " Between \(low) and \(high) over \(windowWords)."
            } else if let note {
                text += " " + note
            }
            return text
        }
    }

    struct Frames: Equatable {
        enum Kind: Equatable {
            /// A paced animation measured in the last few seconds.
            case paced
            /// A moving face without pacing: frames handed to the panels.
            case unpaced
            case still
            /// A brain that sends only fps, which may be an old measurement.
            case legacy
            /// The drawing loop has stopped.
            case stopped
            /// The panel program has not connected since the software
            /// started, so no frame reaches the panels yet.
            case starting
        }
        let kind: Kind
        /// The number shown, or nil when a word is shown instead.
        let perSecond: Int?
        /// "Still" or "Stopped" in place of a number.
        let word: String?
        /// "Smooth" or "Behind", for paced readings only.
        let status: String?
        let behind: Bool
        let target: Int?
        /// The meter's fill, paced readings with a target only.
        let fraction: Double?
        /// Mono captions, one per line.
        let captions: [String]
        /// A sentence under the value.
        let note: String?
        /// The captions as words, for accessibility sizes.
        let words: String?
        let accessibilityValue: String

        static let stillNote = "The picture is not changing, so no new frames are drawn."
        static let legacyNote = "It may be from an earlier animation."
        static let unpacedNote = "This picture has no target rate."
        static let startingNote = "No frames reach the panels until they connect."
        static let recent = "LAST FEW SECONDS"
        static let measured = "LAST MEASURED"

        /// On a last reading the window would sound like the wall now, and
        /// the eyebrow above already says whose reading it is, so only the
        /// target stays. With no target, the number is called what it is,
        /// so the tile is never left with a bare number.
        func captions(lastReading: Bool) -> [String] {
            guard lastReading, captions.contains(Self.recent) else { return captions }
            let kept = captions.filter { $0 != Self.recent }
            return kept.isEmpty ? [Self.measured] : kept
        }

        /// "Smooth" on a last reading would sound like the wall now, so it
        /// goes. "Behind" stays, as its notice does.
        func statusWord(lastReading: Bool) -> String? {
            lastReading && !behind ? nil : status
        }

        func words(lastReading: Bool) -> String? {
            guard lastReading, let words, words.hasPrefix("Over the last few seconds") else { return words }
            return target.map { "Target \($0)." } ?? "Last measured."
        }
    }

    let vitals: Vitals
    /// Act findings, then watch findings, most urgent first within each.
    let problems: [HealthFinding]
    /// The rows that passed, in list order. A part with a finding is not
    /// repeated here.
    let checks: [HealthCheck]
    let level: HealthLevel
    let verdict: String
    let summary: String
    let landingLine: String
    /// Where the readings come from. It speaks of power only when the
    /// reading has a power row.
    let footnote: String
    let temperature: Temperature?
    let frames: Frames

    var acts: Int { problems.filter { $0.level == .act }.count }
    var watches: Int { problems.filter { $0.level == .watch }.count }
    var lead: HealthPart? { problems.first?.part }

    init(vitals v: Vitals) {
        vitals = v
        var findings: [HealthFinding] = []
        var rows: [HealthPart: HealthCheck] = [:]
        let celsius = v.tempC.map(HealthFormat.celsius)
        let hotNow = (celsius ?? 0) >= HealthRules.hot
        var loopStopped = false
        var panelsStopped = false
        /// The panel program has not connected yet since the software started.
        var panelsStarting = false
        /// The processor is slowed now and the slowdown is put down to heat.
        var heatSlowed = false
        /// The processor is slowed now, for any reason, low power included.
        var speedSlowed = false

        // Picture updates: the drawing loop's heartbeat.
        if let age = v.loopAgeS {
            if age >= HealthRules.loopStall {
                loopStopped = true
                let seconds = HealthFormat.whole(age.rounded())
                let span = seconds < 60 ? HealthFormat.plural(seconds, "second") : HealthFormat.duration(seconds)
                findings.append(HealthFinding(
                    part: .loop, level: .act, verdict: "Picture updates stopped.", noticeTitle: "Picture updates stopped",
                    noticeDetail: "The panels are showing the last picture and have not updated for \(span). Turn the wall off at the plug for ten seconds, then on again.",
                    rowValue: "Stopped", short: "Picture updates stopped"))
            }
            rows[.loop] = HealthCheck(part: .loop, value: "Running", subtitle: nil,
                                      explanation: "The loop that draws each picture reports in every few seconds. If it stops, the panels keep the last picture.")
        }

        // Panels: the hand-off to the panel program. Missing while the
        // software starts is the boot race, and a restart takes seconds,
        // so only a long absence or a long wait is a problem.
        if let r = v.renderer {
            let starting = !r.attached && v.uptimeS < HealthRules.startupGrace
            panelsStarting = starting
            let gone = r.attached ? 0 : (r.detachedS ?? Double(v.uptimeS))
            let waiting = r.pendingS ?? 0
            if starting {
                findings.append(HealthFinding(
                    part: .panels, level: .watch, verdict: "Worth a look.", noticeTitle: "Panels starting",
                    noticeDetail: "The wall’s software started \(HealthFormat.ago(Double(v.uptimeS))) and is still connecting to the panels. This can take up to a minute.",
                    rowValue: "Starting", short: "Panels starting"))
            } else if v.uptimeS >= HealthRules.startupGrace && (gone >= HealthRules.rendererLimit || waiting >= HealthRules.rendererLimit) {
                // The page offers a restart right under this notice, so the
                // advice starts there and keeps the plug for when it fails.
                let what = "The program that drives the panels is not taking new pictures, so they may be dark or frozen."
                panelsStopped = true
                findings.append(HealthFinding(
                    part: .panels, level: .act, verdict: "Panels not updating.", noticeTitle: "Panels not receiving pictures",
                    noticeDetail: what + " Restart the panel program below. If the panels stay dark, turn the wall off at the plug for ten seconds, then on again.",
                    rowValue: "Not updating", short: "Panels not receiving pictures",
                    readOnlyDetail: what + " Turn the wall off at the plug for ten seconds, then on again."))
            }
            rows[.panels] = HealthCheck(part: .panels, value: r.attached ? "Connected" : "Reconnecting", subtitle: nil,
                                        explanation: "The wall’s software hands each picture to a separate program that drives the panels. This shows whether that hand-off is working.")
            // "Picture updates: Running" under "Panels not updating." reads
            // as a contradiction, so it is not listed as passing then.
            if panelsStopped { rows[.loop] = nil }
        }

        // Power, from the per-bit throttle keys. An older brain sends only
        // now and ever, which cannot tell power from heat, so no row.
        if let t = v.throttle, t.detailed {
            if t.undervoltNow {
                findings.append(HealthFinding(
                    part: .power, level: .act, verdict: "Low on power.", noticeTitle: "Low on power",
                    noticeDetail: "The computer is getting too little power, so it runs slower and may restart. Check the supply that feeds the computer and its cable.",
                    rowValue: "Too low", short: "Low on power"))
            } else if t.undervoltEver {
                let since = v.bootS.map { " " + HealthFormat.ago(Double($0)) } ?? ""
                findings.append(HealthFinding(
                    part: .power, level: .watch, verdict: "Worth a look.", noticeTitle: "Power dipped earlier",
                    noticeDetail: "The computer’s power dropped too low at least once since it started\(since). If it happens again, check the supply that feeds the computer.",
                    rowValue: "Dipped earlier", short: "Power dipped earlier"))
            }
            rows[.power] = HealthCheck(part: .power, value: "Steady", subtitle: nil,
                                       explanation: "Measured where power enters the computer. It does not measure the panels’ power.")
        }

        // Heat, judged in the whole degrees the tile shows.
        if let celsius {
            if celsius >= HealthRules.hot {
                findings.append(HealthFinding(
                    part: .heat, level: .act, verdict: "Running hot.", noticeTitle: "Running hot",
                    noticeDetail: "The processor is at \(celsius)°C. At 80°C and above it runs slower to cool down. Give the back of the wall more room for air.",
                    rowValue: "\(celsius)°C", short: "Running hot, \(celsius)°C"))
            } else if celsius >= HealthRules.warm {
                findings.append(HealthFinding(
                    part: .heat, level: .watch, verdict: "Worth a look.", noticeTitle: "Running warm",
                    noticeDetail: "The processor is at \(celsius)°C. It slows down at 80°C.",
                    rowValue: "\(celsius)°C", short: "Running warm, \(celsius)°C"))
            }
        }

        // Processor speed. One rule for now and for earlier: low power now
        // is the power problem, heat at 80°C is the heat problem, and any
        // other slowdown is put down to heat only when the bits or the
        // temperature say so.
        if let t = v.throttle {
            let slowedNow = t.detailed ? (t.cappedNow || t.throttledNow || t.softTempNow) : t.now
            let coveredElsewhere = (t.detailed && t.undervoltNow) || hotNow
            speedSlowed = slowedNow || (t.detailed && t.undervoltNow)
            if slowedNow && !coveredElsewhere {
                let heat = t.detailed && (t.softTempNow || (celsius ?? 0) >= HealthRules.heatCause)
                heatSlowed = heat
                findings.append(HealthFinding(
                    part: .speed, level: .act, verdict: "Slowed down.", noticeTitle: "Slowed down",
                    noticeDetail: heat
                        ? "The processor is running slower than normal to stay cool. Give the back of the wall more room for air."
                        : "The processor is running slower than normal. Heat or low power can cause this.",
                    rowValue: "Slowed down", short: "Slowed down"))
            }
            // Slowed now for low power or heat belongs to that problem's
            // notice, so no row claims the speed is normal. At 80°C the
            // Pi slows itself whatever the bits last said, and the hot
            // notice says so, so no row claims full speed there either.
            // Low power now says the computer runs slower, so neither does
            // a low power reading without a slowdown bit.
            if !slowedNow && !hotNow && !(t.detailed && t.undervoltNow) {
                let slowedEver = t.detailed ? (t.cappedEver || t.throttledEver || t.softTempEver) : t.ever
                var subtitle: String?
                if slowedEver {
                    if t.detailed && t.softTempEver && !t.undervoltEver { subtitle = "While it was hot. Normal now." }
                    else if t.detailed && t.undervoltEver && !t.softTempEver { subtitle = "While power was low. Normal now." }
                    else { subtitle = "Heat or low power, at least once since the computer started. Normal now." }
                }
                rows[.speed] = HealthCheck(
                    part: .speed, value: slowedEver ? "Slowed earlier" : "Full speed", subtitle: subtitle,
                    explanation: t.detailed
                        ? "The processor runs slower when it gets too hot or too little power. Above 80°C it slows to cool down."
                        : "The processor runs slower when it gets too hot or too little power. This wall’s software does not report which.")
            }
        }

        if let m = v.memory {
            let free = HealthFormat.megabytes(m.availableMB), total = HealthFormat.megabytes(m.totalMB)
            if m.availableMB < HealthRules.memoryAct {
                findings.append(HealthFinding(
                    part: .memory, level: .act, verdict: "Almost out of memory.", noticeTitle: "Almost out of memory",
                    noticeDetail: "\(free) of \(total) is free. Turning the wall off and on again frees memory.",
                    rowValue: "\(free) free", short: "Almost out of memory"))
            } else if m.availableMB < HealthRules.memoryWatch {
                findings.append(HealthFinding(
                    part: .memory, level: .watch, verdict: "Worth a look.", noticeTitle: "Memory running low",
                    noticeDetail: "\(free) of \(total) is free.", rowValue: "\(free) free", short: "Memory running low"))
            }
            rows[.memory] = HealthCheck(part: .memory, value: "\(free) free", subtitle: nil,
                                        explanation: "Memory the wall’s software can still use, out of \(total) in total.")
        }

        if let s = v.storage {
            let free = HealthFormat.gigabytes(s.freeGB)
            if s.freeGB < HealthRules.storageAct {
                findings.append(HealthFinding(
                    part: .storage, level: .act, verdict: "Storage nearly full.", noticeTitle: "Storage nearly full",
                    noticeDetail: "\(free) is left. Settings and artwork may stop saving.",
                    rowValue: "\(free) free", short: "Storage nearly full"))
            } else if s.freeGB < HealthRules.storageWatch {
                findings.append(HealthFinding(
                    part: .storage, level: .watch, verdict: "Worth a look.", noticeTitle: "Storage getting full",
                    noticeDetail: "\(free) is left.", rowValue: "\(free) free", short: "Storage getting full"))
            }
            rows[.storage] = HealthCheck(part: .storage, value: "\(free) free", subtitle: nil,
                                         explanation: "Space left for settings, saved artwork and the listening history.")
        }

        // Frame rate: a paced reading is live for a few seconds only. When
        // the loop has stopped or the panels take no pictures, no frame
        // reaches the wall, whatever the last count says.
        let halted = loopStopped || panelsStopped
        let paced = !halted && (v.fpsAgeS.map { $0 <= HealthRules.pacedLive } ?? false)
        let shownFps = HealthFormat.whole(v.fps.rounded())
        let target = v.fpsTarget.flatMap { $0 > 0 ? HealthFormat.whole($0.rounded()) : nil }
        let behind = paced && target.map { Double(shownFps) < HealthRules.behind * Double($0) } == true
        if behind, let target {
            // Heat is named only when the tile beside this notice is not
            // Normal, so the two never disagree.
            let cause = (celsius ?? 0) >= HealthRules.warm || heatSlowed ? "Heat or a busy processor can cause this."
                : speedSlowed ? "A slowed processor can cause this." : "A busy processor can cause this."
            findings.append(HealthFinding(
                part: .frames, level: .watch, verdict: "Worth a look.", noticeTitle: "Frame rate behind",
                noticeDetail: "Animations are running at \(shownFps) frames a second, below the target of \(target). " + cause,
                rowValue: "\(shownFps) a second", short: "Frame rate behind"))
        }

        let secondsUp = v.uptimeS
        var uptimeNote = "Since the software last started"
        if let boot = v.bootS, boot - secondsUp > 300 {
            uptimeNote = "Computer on for \(HealthFormat.duration(boot))."
        }
        rows[.uptime] = HealthCheck(part: .uptime, value: HealthFormat.duration(secondsUp), subtitle: uptimeNote,
                                    explanation: "How long the wall’s software has run since it last started. Updates, restarts and power cuts start it again.")

        let order = HealthPart.priority
        func rank(_ finding: HealthFinding) -> Int { order.firstIndex(of: finding.part) ?? order.count }
        problems = findings.sorted { ($0.level, -rank($0)) > ($1.level, -rank($1)) }
        let flagged = Set(problems.map(\.part))
        checks = HealthPart.rows.compactMap { part in flagged.contains(part) ? nil : rows[part] }
        level = problems.first?.level ?? .steady

        let acts = problems.filter { $0.level == .act }.count
        let watches = problems.count - acts
        func things(_ count: Int, more: Bool) -> String {
            "\(HealthFormat.word(count, capitalized: true))\(more ? " more" : "") \(count == 1 ? "thing" : "things") to keep an eye on."
        }
        // Power is only claimed when the per-bit keys say it was measured:
        // a Mac reports neither, an older brain cannot tell power from heat.
        let reportsPower = v.throttle?.detailed == true
        let reportsHeat = v.tempC != nil || v.throttle != nil
        switch acts {
        case 0 where watches == 0:
            verdict = "Running well."
            if reportsPower {
                summary = "The computer’s power, heat and picture updates are normal."
            } else if reportsHeat {
                summary = v.throttle != nil
                    ? "Heat and picture updates are normal. This wall’s software does not report power separately."
                    : "Heat and picture updates are normal. This computer does not report power."
            } else {
                summary = "Picture updates are normal. This computer does not report power or heat."
            }
        case 0:
            verdict = "Worth a look."
            summary = things(watches, more: false) + " Everything else is normal."
        case 1:
            verdict = problems[0].verdict
            summary = "One problem needs attention. " + (watches == 0 ? "What to do is below." : things(watches, more: true))
        default:
            verdict = "Needs attention."
            summary = "\(HealthFormat.word(acts, capitalized: true)) problems, most urgent first."
                + (watches == 0 ? "" : " " + things(watches, more: true))
        }
        footnote = "Readings come from the computer behind the panels and update every 10 seconds while this page is open."
            + (reportsPower ? " The power reading is taken at the computer, not at the panels." : "")
        if let lead = problems.first {
            landingLine = lead.short
        } else {
            landingLine = celsius.map { "Running well, \($0)°C" } ?? "Running well"
        }

        temperature = v.tempC.map { current in
            let shown = HealthFormat.celsius(current)
            // A processor slowed to stay cool is never called Normal beside
            // the notice that says so, whatever the degrees.
            let status: Temperature.Status = shown >= HealthRules.hot ? .hot
                : shown >= HealthRules.warm || heatSlowed ? .warm : .normal
            guard let log = v.tempLog else {
                // An older brain keeps no log: no trace, and no caption
                // promising one, only a line saying there is none.
                return Temperature(celsius: shown, status: status, trace: [], window: nil, windowWords: nil,
                                   low: nil, high: nil, collecting: false, noHistory: true)
            }
            guard log.count >= HealthRules.traceMinimum else {
                return Temperature(celsius: shown, status: status, trace: [], window: nil, windowWords: nil,
                                   low: nil, high: nil, collecting: true, noHistory: false)
            }
            let trace = log + [Vitals.TempSample(ageS: 0, celsius: current)]
            let oldest = log.map(\.ageS).max() ?? 0
            let minutes = max(1, HealthFormat.whole((oldest / 60).rounded()))
            let hour = oldest >= HealthRules.hour
            let degrees = trace.map { HealthFormat.celsius($0.celsius) }
            return Temperature(celsius: shown, status: status, trace: trace,
                               window: hour ? "LAST HOUR" : "LAST \(minutes) MIN",
                               windowWords: hour ? "the last hour" : "the last \(HealthFormat.plural(minutes, "minute"))",
                               low: degrees.min(), high: degrees.max(), collecting: false, noHistory: false)
        }

        if halted {
            frames = Frames(kind: .stopped, perSecond: nil, word: "Stopped", status: nil, behind: false, target: nil,
                            fraction: nil, captions: [], note: nil, words: nil, accessibilityValue: "Stopped")
        } else if panelsStarting {
            // Whatever the brain draws goes nowhere yet, so a number here
            // would read as a slow wall beside the notice that explains it.
            frames = Frames(kind: .starting, perSecond: nil, word: "Starting", status: nil, behind: false, target: nil,
                            fraction: nil, captions: [], note: Frames.startingNote, words: nil,
                            accessibilityValue: "Starting. " + Frames.startingNote)
        } else if paced {
            var captions = [Frames.recent]
            if let target { captions.append("TARGET \(target)") }
            frames = Frames(kind: .paced, perSecond: shownFps, word: nil, status: behind ? "Behind" : "Smooth",
                            behind: behind, target: target,
                            fraction: target.map { min(1, max(0, v.fps / Double($0))) },
                            captions: captions, note: nil,
                            words: target.map { "Over the last few seconds, target \($0)." } ?? "Over the last few seconds.",
                            accessibilityValue: "\(shownFps) a second" + (target.map { behind ? ", behind the target of \($0)" : ", target \($0)" } ?? ""))
        } else if let sent = v.sentFps {
            if sent < HealthRules.still {
                // The note says what the number would have: no caption,
                // so a narrow tile stays about as tall as its neighbour.
                frames = Frames(kind: .still, perSecond: nil, word: "Still", status: nil, behind: false, target: nil,
                                fraction: nil, captions: [], note: Frames.stillNote, words: nil,
                                accessibilityValue: "Still. " + Frames.stillNote)
            } else {
                let shown = HealthFormat.whole(sent.rounded())
                // No status word and no meter, so the note says why: there
                // is no rate to measure this number against.
                frames = Frames(kind: .unpaced, perSecond: shown, word: nil, status: nil, behind: false, target: nil,
                                fraction: nil, captions: [Frames.recent], note: Frames.unpacedNote, words: "Over the last few seconds.",
                                accessibilityValue: "\(shown) a second. " + Frames.unpacedNote)
            }
        } else {
            let still = v.fps < HealthRules.still
            frames = Frames(kind: .legacy, perSecond: still ? nil : shownFps, word: still ? "Still" : nil, status: nil,
                            behind: false, target: nil, fraction: nil, captions: [Frames.measured],
                            note: Frames.legacyNote, words: "Last measured.",
                            accessibilityValue: (still ? "Still" : "\(shownFps) a second") + ", last measured. " + Frames.legacyNote)
        }
    }
}

// MARK: - The page's state

/// The link as the health page needs it. The stand-in carries whether the
/// owner chose it: only then is looking for the wall offered, because the
/// automatic stand-in is already looking.
enum HealthLink: Equatable {
    case live, searching, offline
    case standIn(chosen: Bool)
}

/// What the page shows, from the link, the reading and the last attempts.
/// Kept here so the stale and failure rules are checked without a screen.
struct HealthScreen: Equatable {
    enum Phase: Equatable { case loading, unreadable, report, stale, offline, searching, standIn }
    enum Dot: Equatable {
        case level(HealthLevel)
        /// No live reading behind the words.
        case quiet
        case progress
    }

    let phase: Phase
    let verdict: String
    let summary: String
    let dot: Dot
    let freshness: String?
    /// The reading to show below the hero, if any.
    let report: HealthReport?
    /// The report is a last reading: stale or offline.
    let dimmed: Bool
    let lookAgain: Bool
    let addressLink: Bool
    /// "Check now" or "Try again". nil when the page cannot read (not live).
    let check: String?

    /// - lastFailed: the latest read did not answer.
    /// - manualFailed: a Check now or pull to refresh failed since the last
    ///   answer. One failed background poll is a hiccup, so only this or
    ///   an old reading makes the page stale.
    /// - attempted: a read has finished since the page started polling,
    ///   so a reading carried in from Settings is not called stale before
    ///   the page has had its own chance to check.
    init(link: HealthLink, report: HealthReport?, now: Date, lastFailed: Bool, manualFailed: Bool,
         checking: Bool, attempted: Bool) {
        let age = report.map { now.timeIntervalSince($0.vitals.receivedAt) } ?? 0
        // A last reading is never "just now": beside "No new reading." or
        // "Can’t reach the wall." that would read as the wall answering.
        let since = age < 10 ? "a few seconds ago" : HealthFormat.ago(age)
        func lastReading(_ report: HealthReport, offline: Bool) -> String {
            // Offline within the minute, the reading is from the moment
            // before the wall stopped answering, and says so.
            var text = offline && age < 60 ? "Last reading before the connection dropped" : "Last reading \(since)"
            let acts = report.acts
            if acts > 0 { text += ". It showed \(HealthFormat.word(acts)) \(acts == 1 ? "problem" : "problems")." }
            return text
        }
        var lookAgain = false, addressLink = false, dimmed = false
        var shown: HealthReport?
        var freshness: String?
        var check: String?
        switch link {
        case .searching:
            phase = .searching; dot = .progress
            verdict = "Looking for your wall."; summary = "Readings appear when it answers."
        case .standIn(let chosen):
            // The automatic stand-in is looking for the wall, as the
            // searching state is, so it shows the same spinner.
            phase = .standIn; dot = chosen ? .quiet : .progress; lookAgain = chosen
            verdict = "No wall connected."
            summary = chosen
                ? "Tessera is running on this phone for now. Health readings come from the computer behind a wall."
                : "Tessera is running on this phone while it looks for your wall."
        case .offline:
            phase = .offline; dot = .quiet; lookAgain = true; addressLink = true
            verdict = "Can’t reach the wall."; summary = "Health readings need the wall on the same network as this phone."
            if let report { shown = report; dimmed = true; freshness = lastReading(report, offline: true) }
        case .live:
            check = "Check now"
            if let report {
                shown = report
                if manualFailed || (attempted && age > HealthRules.staleAfter) {
                    phase = .stale; dot = .quiet; dimmed = true
                    verdict = "No new reading."
                    summary = "The wall is connected, but the latest check got no reply. The last reading is below."
                    freshness = lastReading(report, offline: false)
                } else {
                    phase = .report; dot = .level(report.level)
                    verdict = report.verdict; summary = report.summary
                    freshness = lastFailed ? "Could not check. Last reading \(since)." : "Checked \(HealthFormat.ago(age))"
                }
            } else if lastFailed && !checking {
                // The button under the summary says what to do, so the
                // summary does not say it again.
                phase = .unreadable; dot = .quiet; check = "Try again"
                verdict = "No reading."
                summary = "The wall is connected, but its health reading did not arrive."
            } else {
                // The first read: the dot is already a spinner, so there is
                // no Check now and no second "Checking…" beside it. A retry
                // from No reading keeps its button, so the control just
                // tapped stays put and VoiceOver keeps its place.
                check = lastFailed ? "Try again" : nil
                phase = .loading; dot = .progress
                verdict = "Checking the wall."
                summary = "Reading power, heat and picture updates from the computer behind the panels."
            }
        }
        self.report = shown
        self.dimmed = dimmed
        self.freshness = freshness
        self.lookAgain = lookAgain
        self.addressLink = addressLink
        self.check = check
    }

    /// The checks list's header when nothing is wrong. On a last reading
    /// the eyebrow sits above the tiles, well away from this list, so the
    /// header says again that these are the last reading, not the wall now.
    var checksHeader: String { dimmed ? "Checks at last reading" : "All checks" }

    /// The button over the checks that passed when there are problems. On
    /// a last reading "all normal" would read as the wall now.
    var othersTitle: String { dimmed ? "Other checks at last reading" : "Other checks, all normal" }

    /// Whether a problem's notice carries its title. A lone problem is
    /// already the page's headline ("Low on power."), so its notice gives
    /// only what to do, and the same words are not said twice in a row.
    func titlesNotice(_ finding: HealthFinding) -> Bool {
        guard phase == .report, let report, report.acts == 1, finding.level == .act else { return true }
        return report.problems.first?.part != finding.part
    }

    /// A notice's detail. On a last reading the page cannot act on the wall,
    /// so advice pointing at a button on the page is left out.
    func detail(for finding: HealthFinding) -> String {
        phase == .report ? finding.noticeDetail : finding.readOnlyDetail ?? finding.noticeDetail
    }
}

// MARK: - Restarting the panel program

/// POST /tuning/restart, offered only when the panels stop taking pictures.
/// The brain relaunches the panel program itself (systemd brings it back),
/// which needs no privileges it does not already have.
enum PanelProgram {
    enum Answer: Equatable {
        case relaunching, notRunning, couldNotLook
        /// 409: a restart is already under way.
        case busy
        /// 503: this wall has no tuning store to restart from.
        case unsupported
        case noAnswer
    }

    /// Reads the brain's `said`, which names what it did.
    static func answer(status: Int?, said: String?) -> Answer {
        switch status {
        case 200:
            guard let said else { return .noAnswer }
            if said.hasPrefix("renderer relaunching") { return .relaunching }
            if said == "the renderer was not running" { return .notRunning }
            return .couldNotLook
        case 409: return .busy
        case 503: return .unsupported
        default: return .noAnswer
        }
    }

    static func restart(host: String) async -> (answer: Answer, said: String?) {
        guard let url = URL(string: "http://\(host)/tuning/restart") else { return (.noAnswer, nil) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return (.noAnswer, nil) }
        let status = (response as? HTTPURLResponse)?.statusCode
        let said = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["said"] as? String
        return (answer(status: status, said: said), said)
    }

    /// The line under the restart button once the page has read the wall
    /// again. nil when the panels are taking pictures again: the page's new
    /// verdict says so.
    static func note(_ answer: Answer, stillFailing: Bool) -> String? {
        let plug = "Turn the wall off at the plug for ten seconds, then on again."
        switch answer {
        case .relaunching:
            return stillFailing ? "The panel program was restarted, but the panels have not picked up yet. If this lasts, turn the wall off at the plug for ten seconds, then on again." : nil
        case .notRunning: return "The panel program was not running, so there was nothing to restart. " + plug
        case .couldNotLook: return "The wall could not find the panel program. " + plug
        case .busy: return "The panel program is already restarting. Try again in a moment."
        case .unsupported: return "This wall cannot restart the panel program. " + plug
        case .noAnswer: return "The wall did not confirm the restart. Try again in a moment."
        }
    }
}

// MARK: - Authored readings

#if DEBUG
/// scripts/qa/health_fixtures.json, the authored readings the QA wall
/// serves, for captures that skip the network (-health-fixture). The block
/// below is written by `scripts/test_wall_vitals.py --write-fixtures`, and
/// that test fails if the two ever differ.
enum HealthFixtures {
    static func json(_ name: String) -> [String: Any]? { all[name] as? [String: Any] }

    static func vitals(_ name: String, receivedAt: Date = Date()) -> Vitals? {
        json(name).flatMap { Vitals(json: $0, receivedAt: receivedAt) }
    }

    private static let all: [String: Any] =
        (try? JSONSerialization.jsonObject(with: Data(source.utf8))) as? [String: Any] ?? [:]

    // BEGIN health_fixtures.json
    static let names = ["steady", "warm", "hot", "slowed", "slowed-earlier", "undervolt", "undervolt-earlier", "panels-off", "panels-starting", "stalled", "memory-low", "memory-critical", "storage-low", "animating", "unpaced", "still", "behind", "collecting", "mac", "legacy", "several"]

    private static let source = #"""
    {
    "steady":{"fps":59.6,"fps_age_s":2.1,"fps_target":60.0,"sent_fps":59.8,"temp_c":54.2,"temp_log":[[3547.0,55.3],[3487.0,55.6],[3427.0,55.2],[3367.0,55.3],[3307.0,55.3],[3247.0,54.6],[3187.0,54.5],[3127.0,54.3],[3067.0,53.4],[3007.0,53.1],[2947.0,52.9],[2887.0,52.0],[2827.0,51.8],[2767.0,51.6],[2707.0,50.8],[2647.0,50.8],[2587.0,50.9],[2527.0,50.4],[2467.0,50.7],[2407.0,51.0],[2347.0,50.8],[2287.0,51.3],[2227.0,51.9],[2167.0,51.8],[2107.0,52.6],[2047.0,53.2],[1987.0,53.3],[1927.0,54.0],[1867.0,54.6],[1807.0,54.5],[1747.0,55.1],[1687.0,55.4],[1627.0,55.1],[1567.0,55.4],[1507.0,55.5],[1447.0,54.9],[1387.0,55.0],[1327.0,54.8],[1267.0,54.0],[1207.0,53.8],[1147.0,53.5],[1087.0,52.6],[1027.0,52.4],[967.0,52.1],[907.0,51.3],[847.0,51.2],[787.0,51.1],[727.0,50.5],[667.0,50.7],[607.0,50.8],[547.0,50.5],[487.0,51.0],[427.0,51.3],[367.0,51.3],[307.0,52.0],[247.0,52.5],[187.0,52.6],[127.0,53.4],[67.0,53.9],[7.0,54.2]],"throttled":{"now":false,"ever":false,"raw":"0x0","undervolt_now":false,"capped_now":false,"throttled_now":false,"soft_temp_now":false,"undervolt_ever":false,"capped_ever":false,"throttled_ever":false,"soft_temp_ever":false},"uptime_s":273600,"boot_s":1036800,"loop_age_s":0.8,"renderer":{"attached":true,"connects":1,"detached_s":null,"pending_s":null},"memory":{"total_mb":990,"available_mb":412},"storage":{"total_gb":29.1,"free_gb":11.4},"quiet_s":null,"idle":null,"mode":"cd","ytdlp":null},
    "warm":{"fps":59.6,"fps_age_s":2.1,"fps_target":60.0,"sent_fps":59.8,"temp_c":74.3,"temp_log":[[3547.0,60.0],[3487.0,60.5],[3427.0,60.5],[3367.0,60.4],[3307.0,60.5],[3247.0,61.0],[3187.0,61.5],[3127.0,61.5],[3067.0,61.3],[3007.0,61.5],[2947.0,62.1],[2887.0,62.5],[2827.0,62.4],[2767.0,62.3],[2707.0,62.6],[2647.0,63.2],[2587.0,63.5],[2527.0,63.4],[2467.0,63.3],[2407.0,63.7],[2347.0,64.3],[2287.0,64.5],[2227.0,64.4],[2167.0,64.4],[2107.0,64.8],[2047.0,65.4],[1987.0,65.5],[1927.0,65.4],[1867.0,65.5],[1807.0,66.0],[1747.0,66.5],[1687.0,66.6],[1627.0,66.4],[1567.0,66.6],[1507.0,67.2],[1447.0,67.6],[1387.0,67.7],[1327.0,67.6],[1267.0,67.8],[1207.0,68.4],[1147.0,68.8],[1087.0,68.8],[1027.0,68.7],[967.0,69.1],[907.0,69.7],[847.0,70.1],[787.0,70.0],[727.0,70.0],[667.0,70.4],[607.0,71.1],[547.0,71.4],[487.0,71.3],[427.0,71.4],[367.0,71.9],[307.0,72.6],[247.0,72.8],[187.0,72.8],[127.0,73.1],[67.0,73.8],[7.0,74.3]],"throttled":{"now":false,"ever":false,"raw":"0x0","undervolt_now":false,"capped_now":false,"throttled_now":false,"soft_temp_now":false,"undervolt_ever":false,"capped_ever":false,"throttled_ever":false,"soft_temp_ever":false},"uptime_s":273600,"boot_s":1036800,"loop_age_s":0.8,"renderer":{"attached":true,"connects":1,"detached_s":null,"pending_s":null},"memory":{"total_mb":990,"available_mb":412},"storage":{"total_gb":29.1,"free_gb":11.4},"quiet_s":null,"idle":null,"mode":"cd","ytdlp":null},
    "hot":{"fps":59.6,"fps_age_s":2.1,"fps_target":60.0,"sent_fps":59.8,"temp_c":82.4,"temp_log":[[3547.0,66.0],[3487.0,66.5],[3427.0,66.6],[3367.0,66.5],[3307.0,66.6],[3247.0,67.2],[3187.0,67.6],[3127.0,67.7],[3067.0,67.6],[3007.0,67.8],[2947.0,68.4],[2887.0,68.8],[2827.0,68.8],[2767.0,68.7],[2707.0,69.0],[2647.0,69.6],[2587.0,69.9],[2527.0,69.9],[2467.0,69.8],[2407.0,70.3],[2347.0,70.9],[2287.0,71.1],[2227.0,71.0],[2167.0,71.1],[2107.0,71.5],[2047.0,72.1],[1987.0,72.3],[1927.0,72.2],[1867.0,72.3],[1807.0,72.9],[1747.0,73.4],[1687.0,73.5],[1627.0,73.4],[1567.0,73.6],[1507.0,74.2],[1447.0,74.7],[1387.0,74.8],[1327.0,74.7],[1267.0,75.0],[1207.0,75.6],[1147.0,76.1],[1087.0,76.1],[1027.0,76.1],[967.0,76.4],[907.0,77.1],[847.0,77.5],[787.0,77.5],[727.0,77.5],[667.0,78.0],[607.0,78.7],[547.0,79.0],[487.0,79.0],[427.0,79.1],[367.0,79.7],[307.0,80.4],[247.0,80.7],[187.0,80.7],[127.0,81.0],[67.0,81.8],[7.0,82.4]],"throttled":{"now":false,"ever":false,"raw":"0x80008","undervolt_now":false,"capped_now":false,"throttled_now":false,"soft_temp_now":true,"undervolt_ever":false,"capped_ever":false,"throttled_ever":false,"soft_temp_ever":true},"uptime_s":273600,"boot_s":1036800,"loop_age_s":0.8,"renderer":{"attached":true,"connects":1,"detached_s":null,"pending_s":null},"memory":{"total_mb":990,"available_mb":412},"storage":{"total_gb":29.1,"free_gb":11.4},"quiet_s":null,"idle":null,"mode":"cd","ytdlp":null},
    "slowed":{"fps":59.6,"fps_age_s":2.1,"fps_target":60.0,"sent_fps":59.8,"temp_c":68.4,"temp_log":[[3547.0,62.0],[3487.0,62.4],[3427.0,62.3],[3367.0,62.1],[3307.0,62.1],[3247.0,62.5],[3187.0,62.8],[3127.0,62.7],[3067.0,62.5],[3007.0,62.6],[2947.0,63.0],[2887.0,63.3],[2827.0,63.1],[2767.0,62.9],[2707.0,63.1],[2647.0,63.5],[2587.0,63.7],[2527.0,63.5],[2467.0,63.3],[2407.0,63.6],[2347.0,64.0],[2287.0,64.1],[2227.0,63.9],[2167.0,63.8],[2107.0,64.1],[2047.0,64.5],[1987.0,64.6],[1927.0,64.3],[1867.0,64.3],[1807.0,64.7],[1747.0,65.1],[1687.0,65.0],[1627.0,64.8],[1567.0,64.8],[1507.0,65.2],[1447.0,65.6],[1387.0,65.5],[1327.0,65.2],[1267.0,65.4],[1207.0,65.8],[1147.0,66.1],[1087.0,66.0],[1027.0,65.8],[967.0,66.0],[907.0,66.4],[847.0,66.7],[787.0,66.5],[727.0,66.3],[667.0,66.6],[607.0,67.1],[547.0,67.2],[487.0,67.0],[427.0,66.9],[367.0,67.3],[307.0,67.8],[247.0,67.9],[187.0,67.7],[127.0,67.7],[67.0,68.2],[7.0,68.4]],"throttled":{"now":false,"ever":false,"raw":"0x80008","undervolt_now":false,"capped_now":false,"throttled_now":false,"soft_temp_now":true,"undervolt_ever":false,"capped_ever":false,"throttled_ever":false,"soft_temp_ever":true},"uptime_s":273600,"boot_s":1036800,"loop_age_s":0.8,"renderer":{"attached":true,"connects":1,"detached_s":null,"pending_s":null},"memory":{"total_mb":990,"available_mb":412},"storage":{"total_gb":29.1,"free_gb":11.4},"quiet_s":null,"idle":null,"mode":"cd","ytdlp":null},
    "slowed-earlier":{"fps":59.6,"fps_age_s":2.1,"fps_target":60.0,"sent_fps":59.8,"temp_c":58.1,"temp_log":[[3547.0,59.7],[3487.0,60.2],[3427.0,60.0],[3367.0,60.4],[3307.0,60.6],[3247.0,60.1],[3187.0,60.2],[3127.0,60.1],[3067.0,59.4],[3007.0,59.2],[2947.0,59.0],[2887.0,58.1],[2827.0,57.9],[2767.0,57.6],[2707.0,56.7],[2647.0,56.5],[2587.0,56.4],[2527.0,55.7],[2467.0,55.7],[2407.0,55.8],[2347.0,55.4],[2287.0,55.7],[2227.0,56.1],[2167.0,55.9],[2107.0,56.5],[2047.0,57.1],[1987.0,57.1],[1927.0,57.9],[1867.0,58.5],[1807.0,58.5],[1747.0,59.2],[1687.0,59.8],[1627.0,59.7],[1567.0,60.2],[1507.0,60.5],[1447.0,60.2],[1387.0,60.4],[1327.0,60.4],[1267.0,59.8],[1207.0,59.8],[1147.0,59.6],[1087.0,58.7],[1027.0,58.6],[967.0,58.2],[907.0,57.3],[847.0,57.2],[787.0,56.9],[727.0,56.1],[667.0,56.1],[607.0,56.0],[547.0,55.4],[487.0,55.7],[427.0,55.8],[367.0,55.6],[307.0,56.1],[247.0,56.5],[187.0,56.5],[127.0,57.2],[67.0,57.8],[7.0,58.1]],"throttled":{"now":false,"ever":false,"raw":"0x80000","undervolt_now":false,"capped_now":false,"throttled_now":false,"soft_temp_now":false,"undervolt_ever":false,"capped_ever":false,"throttled_ever":false,"soft_temp_ever":true},"uptime_s":273600,"boot_s":1036800,"loop_age_s":0.8,"renderer":{"attached":true,"connects":1,"detached_s":null,"pending_s":null},"memory":{"total_mb":990,"available_mb":412},"storage":{"total_gb":29.1,"free_gb":11.4},"quiet_s":null,"idle":null,"mode":"cd","ytdlp":null},
    "undervolt":{"fps":59.6,"fps_age_s":2.1,"fps_target":60.0,"sent_fps":59.8,"temp_c":54.2,"temp_log":[[3547.0,55.3],[3487.0,55.6],[3427.0,55.2],[3367.0,55.3],[3307.0,55.3],[3247.0,54.6],[3187.0,54.5],[3127.0,54.3],[3067.0,53.4],[3007.0,53.1],[2947.0,52.9],[2887.0,52.0],[2827.0,51.8],[2767.0,51.6],[2707.0,50.8],[2647.0,50.8],[2587.0,50.9],[2527.0,50.4],[2467.0,50.7],[2407.0,51.0],[2347.0,50.8],[2287.0,51.3],[2227.0,51.9],[2167.0,51.8],[2107.0,52.6],[2047.0,53.2],[1987.0,53.3],[1927.0,54.0],[1867.0,54.6],[1807.0,54.5],[1747.0,55.1],[1687.0,55.4],[1627.0,55.1],[1567.0,55.4],[1507.0,55.5],[1447.0,54.9],[1387.0,55.0],[1327.0,54.8],[1267.0,54.0],[1207.0,53.8],[1147.0,53.5],[1087.0,52.6],[1027.0,52.4],[967.0,52.1],[907.0,51.3],[847.0,51.2],[787.0,51.1],[727.0,50.5],[667.0,50.7],[607.0,50.8],[547.0,50.5],[487.0,51.0],[427.0,51.3],[367.0,51.3],[307.0,52.0],[247.0,52.5],[187.0,52.6],[127.0,53.4],[67.0,53.9],[7.0,54.2]],"throttled":{"now":true,"ever":true,"raw":"0x50005","undervolt_now":true,"capped_now":false,"throttled_now":true,"soft_temp_now":false,"undervolt_ever":true,"capped_ever":false,"throttled_ever":true,"soft_temp_ever":false},"uptime_s":273600,"boot_s":1036800,"loop_age_s":0.8,"renderer":{"attached":true,"connects":1,"detached_s":null,"pending_s":null},"memory":{"total_mb":990,"available_mb":412},"storage":{"total_gb":29.1,"free_gb":11.4},"quiet_s":null,"idle":null,"mode":"cd","ytdlp":null},
    "undervolt-earlier":{"fps":59.6,"fps_age_s":2.1,"fps_target":60.0,"sent_fps":59.8,"temp_c":54.2,"temp_log":[[3547.0,55.3],[3487.0,55.6],[3427.0,55.2],[3367.0,55.3],[3307.0,55.3],[3247.0,54.6],[3187.0,54.5],[3127.0,54.3],[3067.0,53.4],[3007.0,53.1],[2947.0,52.9],[2887.0,52.0],[2827.0,51.8],[2767.0,51.6],[2707.0,50.8],[2647.0,50.8],[2587.0,50.9],[2527.0,50.4],[2467.0,50.7],[2407.0,51.0],[2347.0,50.8],[2287.0,51.3],[2227.0,51.9],[2167.0,51.8],[2107.0,52.6],[2047.0,53.2],[1987.0,53.3],[1927.0,54.0],[1867.0,54.6],[1807.0,54.5],[1747.0,55.1],[1687.0,55.4],[1627.0,55.1],[1567.0,55.4],[1507.0,55.5],[1447.0,54.9],[1387.0,55.0],[1327.0,54.8],[1267.0,54.0],[1207.0,53.8],[1147.0,53.5],[1087.0,52.6],[1027.0,52.4],[967.0,52.1],[907.0,51.3],[847.0,51.2],[787.0,51.1],[727.0,50.5],[667.0,50.7],[607.0,50.8],[547.0,50.5],[487.0,51.0],[427.0,51.3],[367.0,51.3],[307.0,52.0],[247.0,52.5],[187.0,52.6],[127.0,53.4],[67.0,53.9],[7.0,54.2]],"throttled":{"now":false,"ever":true,"raw":"0x50000","undervolt_now":false,"capped_now":false,"throttled_now":false,"soft_temp_now":false,"undervolt_ever":true,"capped_ever":false,"throttled_ever":true,"soft_temp_ever":false},"uptime_s":273600,"boot_s":1036800,"loop_age_s":0.8,"renderer":{"attached":true,"connects":1,"detached_s":null,"pending_s":null},"memory":{"total_mb":990,"available_mb":412},"storage":{"total_gb":29.1,"free_gb":11.4},"quiet_s":null,"idle":null,"mode":"cd","ytdlp":null},
    "panels-off":{"fps":59.6,"fps_age_s":48.0,"fps_target":60.0,"sent_fps":0.0,"temp_c":54.2,"temp_log":[[3547.0,55.3],[3487.0,55.6],[3427.0,55.2],[3367.0,55.3],[3307.0,55.3],[3247.0,54.6],[3187.0,54.5],[3127.0,54.3],[3067.0,53.4],[3007.0,53.1],[2947.0,52.9],[2887.0,52.0],[2827.0,51.8],[2767.0,51.6],[2707.0,50.8],[2647.0,50.8],[2587.0,50.9],[2527.0,50.4],[2467.0,50.7],[2407.0,51.0],[2347.0,50.8],[2287.0,51.3],[2227.0,51.9],[2167.0,51.8],[2107.0,52.6],[2047.0,53.2],[1987.0,53.3],[1927.0,54.0],[1867.0,54.6],[1807.0,54.5],[1747.0,55.1],[1687.0,55.4],[1627.0,55.1],[1567.0,55.4],[1507.0,55.5],[1447.0,54.9],[1387.0,55.0],[1327.0,54.8],[1267.0,54.0],[1207.0,53.8],[1147.0,53.5],[1087.0,52.6],[1027.0,52.4],[967.0,52.1],[907.0,51.3],[847.0,51.2],[787.0,51.1],[727.0,50.5],[667.0,50.7],[607.0,50.8],[547.0,50.5],[487.0,51.0],[427.0,51.3],[367.0,51.3],[307.0,52.0],[247.0,52.5],[187.0,52.6],[127.0,53.4],[67.0,53.9],[7.0,54.2]],"throttled":{"now":false,"ever":false,"raw":"0x0","undervolt_now":false,"capped_now":false,"throttled_now":false,"soft_temp_now":false,"undervolt_ever":false,"capped_ever":false,"throttled_ever":false,"soft_temp_ever":false},"uptime_s":273600,"boot_s":1036800,"loop_age_s":0.8,"renderer":{"attached":false,"connects":1,"detached_s":45.0,"pending_s":44.8},"memory":{"total_mb":990,"available_mb":412},"storage":{"total_gb":29.1,"free_gb":11.4},"quiet_s":null,"idle":null,"mode":"cd","ytdlp":null},
    "panels-starting":{"fps":0.0,"fps_age_s":null,"fps_target":60.0,"sent_fps":2.0,"temp_c":47.9,"temp_log":[[7.0,47.9]],"throttled":{"now":false,"ever":false,"raw":"0x0","undervolt_now":false,"capped_now":false,"throttled_now":false,"soft_temp_now":false,"undervolt_ever":false,"capped_ever":false,"throttled_ever":false,"soft_temp_ever":false},"uptime_s":12,"boot_s":40,"loop_age_s":0.4,"renderer":{"attached":false,"connects":0,"detached_s":12.0,"pending_s":11.6},"memory":{"total_mb":990,"available_mb":598},"storage":{"total_gb":29.1,"free_gb":11.4},"quiet_s":null,"idle":null,"mode":"art","ytdlp":null},
    "stalled":{"fps":59.6,"fps_age_s":140.2,"fps_target":60.0,"sent_fps":0.0,"temp_c":54.2,"temp_log":[[3547.0,55.3],[3487.0,55.6],[3427.0,55.2],[3367.0,55.3],[3307.0,55.3],[3247.0,54.6],[3187.0,54.5],[3127.0,54.3],[3067.0,53.4],[3007.0,53.1],[2947.0,52.9],[2887.0,52.0],[2827.0,51.8],[2767.0,51.6],[2707.0,50.8],[2647.0,50.8],[2587.0,50.9],[2527.0,50.4],[2467.0,50.7],[2407.0,51.0],[2347.0,50.8],[2287.0,51.3],[2227.0,51.9],[2167.0,51.8],[2107.0,52.6],[2047.0,53.2],[1987.0,53.3],[1927.0,54.0],[1867.0,54.6],[1807.0,54.5],[1747.0,55.1],[1687.0,55.4],[1627.0,55.1],[1567.0,55.4],[1507.0,55.5],[1447.0,54.9],[1387.0,55.0],[1327.0,54.8],[1267.0,54.0],[1207.0,53.8],[1147.0,53.5],[1087.0,52.6],[1027.0,52.4],[967.0,52.1],[907.0,51.3],[847.0,51.2],[787.0,51.1],[727.0,50.5],[667.0,50.7],[607.0,50.8],[547.0,50.5],[487.0,51.0],[427.0,51.3],[367.0,51.3],[307.0,52.0],[247.0,52.5],[187.0,52.6],[127.0,53.4],[67.0,53.9],[7.0,54.2]],"throttled":{"now":false,"ever":false,"raw":"0x0","undervolt_now":false,"capped_now":false,"throttled_now":false,"soft_temp_now":false,"undervolt_ever":false,"capped_ever":false,"throttled_ever":false,"soft_temp_ever":false},"uptime_s":273600,"boot_s":1036800,"loop_age_s":131.4,"renderer":{"attached":true,"connects":1,"detached_s":null,"pending_s":null},"memory":{"total_mb":990,"available_mb":412},"storage":{"total_gb":29.1,"free_gb":11.4},"quiet_s":null,"idle":null,"mode":"cd","ytdlp":null},
    "memory-low":{"fps":59.6,"fps_age_s":2.1,"fps_target":60.0,"sent_fps":59.8,"temp_c":54.2,"temp_log":[[3547.0,55.3],[3487.0,55.6],[3427.0,55.2],[3367.0,55.3],[3307.0,55.3],[3247.0,54.6],[3187.0,54.5],[3127.0,54.3],[3067.0,53.4],[3007.0,53.1],[2947.0,52.9],[2887.0,52.0],[2827.0,51.8],[2767.0,51.6],[2707.0,50.8],[2647.0,50.8],[2587.0,50.9],[2527.0,50.4],[2467.0,50.7],[2407.0,51.0],[2347.0,50.8],[2287.0,51.3],[2227.0,51.9],[2167.0,51.8],[2107.0,52.6],[2047.0,53.2],[1987.0,53.3],[1927.0,54.0],[1867.0,54.6],[1807.0,54.5],[1747.0,55.1],[1687.0,55.4],[1627.0,55.1],[1567.0,55.4],[1507.0,55.5],[1447.0,54.9],[1387.0,55.0],[1327.0,54.8],[1267.0,54.0],[1207.0,53.8],[1147.0,53.5],[1087.0,52.6],[1027.0,52.4],[967.0,52.1],[907.0,51.3],[847.0,51.2],[787.0,51.1],[727.0,50.5],[667.0,50.7],[607.0,50.8],[547.0,50.5],[487.0,51.0],[427.0,51.3],[367.0,51.3],[307.0,52.0],[247.0,52.5],[187.0,52.6],[127.0,53.4],[67.0,53.9],[7.0,54.2]],"throttled":{"now":false,"ever":false,"raw":"0x0","undervolt_now":false,"capped_now":false,"throttled_now":false,"soft_temp_now":false,"undervolt_ever":false,"capped_ever":false,"throttled_ever":false,"soft_temp_ever":false},"uptime_s":273600,"boot_s":1036800,"loop_age_s":0.8,"renderer":{"attached":true,"connects":1,"detached_s":null,"pending_s":null},"memory":{"total_mb":990,"available_mb":96},"storage":{"total_gb":29.1,"free_gb":11.4},"quiet_s":null,"idle":null,"mode":"cd","ytdlp":null},
    "memory-critical":{"fps":59.6,"fps_age_s":2.1,"fps_target":60.0,"sent_fps":59.8,"temp_c":54.2,"temp_log":[[3547.0,55.3],[3487.0,55.6],[3427.0,55.2],[3367.0,55.3],[3307.0,55.3],[3247.0,54.6],[3187.0,54.5],[3127.0,54.3],[3067.0,53.4],[3007.0,53.1],[2947.0,52.9],[2887.0,52.0],[2827.0,51.8],[2767.0,51.6],[2707.0,50.8],[2647.0,50.8],[2587.0,50.9],[2527.0,50.4],[2467.0,50.7],[2407.0,51.0],[2347.0,50.8],[2287.0,51.3],[2227.0,51.9],[2167.0,51.8],[2107.0,52.6],[2047.0,53.2],[1987.0,53.3],[1927.0,54.0],[1867.0,54.6],[1807.0,54.5],[1747.0,55.1],[1687.0,55.4],[1627.0,55.1],[1567.0,55.4],[1507.0,55.5],[1447.0,54.9],[1387.0,55.0],[1327.0,54.8],[1267.0,54.0],[1207.0,53.8],[1147.0,53.5],[1087.0,52.6],[1027.0,52.4],[967.0,52.1],[907.0,51.3],[847.0,51.2],[787.0,51.1],[727.0,50.5],[667.0,50.7],[607.0,50.8],[547.0,50.5],[487.0,51.0],[427.0,51.3],[367.0,51.3],[307.0,52.0],[247.0,52.5],[187.0,52.6],[127.0,53.4],[67.0,53.9],[7.0,54.2]],"throttled":{"now":false,"ever":false,"raw":"0x0","undervolt_now":false,"capped_now":false,"throttled_now":false,"soft_temp_now":false,"undervolt_ever":false,"capped_ever":false,"throttled_ever":false,"soft_temp_ever":false},"uptime_s":273600,"boot_s":1036800,"loop_age_s":0.8,"renderer":{"attached":true,"connects":1,"detached_s":null,"pending_s":null},"memory":{"total_mb":990,"available_mb":48},"storage":{"total_gb":29.1,"free_gb":11.4},"quiet_s":null,"idle":null,"mode":"cd","ytdlp":null},
    "storage-low":{"fps":59.6,"fps_age_s":2.1,"fps_target":60.0,"sent_fps":59.8,"temp_c":54.2,"temp_log":[[3547.0,55.3],[3487.0,55.6],[3427.0,55.2],[3367.0,55.3],[3307.0,55.3],[3247.0,54.6],[3187.0,54.5],[3127.0,54.3],[3067.0,53.4],[3007.0,53.1],[2947.0,52.9],[2887.0,52.0],[2827.0,51.8],[2767.0,51.6],[2707.0,50.8],[2647.0,50.8],[2587.0,50.9],[2527.0,50.4],[2467.0,50.7],[2407.0,51.0],[2347.0,50.8],[2287.0,51.3],[2227.0,51.9],[2167.0,51.8],[2107.0,52.6],[2047.0,53.2],[1987.0,53.3],[1927.0,54.0],[1867.0,54.6],[1807.0,54.5],[1747.0,55.1],[1687.0,55.4],[1627.0,55.1],[1567.0,55.4],[1507.0,55.5],[1447.0,54.9],[1387.0,55.0],[1327.0,54.8],[1267.0,54.0],[1207.0,53.8],[1147.0,53.5],[1087.0,52.6],[1027.0,52.4],[967.0,52.1],[907.0,51.3],[847.0,51.2],[787.0,51.1],[727.0,50.5],[667.0,50.7],[607.0,50.8],[547.0,50.5],[487.0,51.0],[427.0,51.3],[367.0,51.3],[307.0,52.0],[247.0,52.5],[187.0,52.6],[127.0,53.4],[67.0,53.9],[7.0,54.2]],"throttled":{"now":false,"ever":false,"raw":"0x0","undervolt_now":false,"capped_now":false,"throttled_now":false,"soft_temp_now":false,"undervolt_ever":false,"capped_ever":false,"throttled_ever":false,"soft_temp_ever":false},"uptime_s":273600,"boot_s":1036800,"loop_age_s":0.8,"renderer":{"attached":true,"connects":1,"detached_s":null,"pending_s":null},"memory":{"total_mb":990,"available_mb":412},"storage":{"total_gb":29.1,"free_gb":0.8},"quiet_s":null,"idle":null,"mode":"cd","ytdlp":null},
    "animating":{"fps":60.0,"fps_age_s":0.9,"fps_target":60.0,"sent_fps":60.1,"temp_c":54.2,"temp_log":[[3547.0,55.3],[3487.0,55.6],[3427.0,55.2],[3367.0,55.3],[3307.0,55.3],[3247.0,54.6],[3187.0,54.5],[3127.0,54.3],[3067.0,53.4],[3007.0,53.1],[2947.0,52.9],[2887.0,52.0],[2827.0,51.8],[2767.0,51.6],[2707.0,50.8],[2647.0,50.8],[2587.0,50.9],[2527.0,50.4],[2467.0,50.7],[2407.0,51.0],[2347.0,50.8],[2287.0,51.3],[2227.0,51.9],[2167.0,51.8],[2107.0,52.6],[2047.0,53.2],[1987.0,53.3],[1927.0,54.0],[1867.0,54.6],[1807.0,54.5],[1747.0,55.1],[1687.0,55.4],[1627.0,55.1],[1567.0,55.4],[1507.0,55.5],[1447.0,54.9],[1387.0,55.0],[1327.0,54.8],[1267.0,54.0],[1207.0,53.8],[1147.0,53.5],[1087.0,52.6],[1027.0,52.4],[967.0,52.1],[907.0,51.3],[847.0,51.2],[787.0,51.1],[727.0,50.5],[667.0,50.7],[607.0,50.8],[547.0,50.5],[487.0,51.0],[427.0,51.3],[367.0,51.3],[307.0,52.0],[247.0,52.5],[187.0,52.6],[127.0,53.4],[67.0,53.9],[7.0,54.2]],"throttled":{"now":false,"ever":false,"raw":"0x0","undervolt_now":false,"capped_now":false,"throttled_now":false,"soft_temp_now":false,"undervolt_ever":false,"capped_ever":false,"throttled_ever":false,"soft_temp_ever":false},"uptime_s":273600,"boot_s":1036800,"loop_age_s":0.8,"renderer":{"attached":true,"connects":1,"detached_s":null,"pending_s":null},"memory":{"total_mb":990,"available_mb":412},"storage":{"total_gb":29.1,"free_gb":11.4},"quiet_s":null,"idle":null,"mode":"ambient","ytdlp":null},
    "unpaced":{"fps":59.6,"fps_age_s":340.0,"fps_target":60.0,"sent_fps":12.0,"temp_c":54.2,"temp_log":[[3547.0,55.3],[3487.0,55.6],[3427.0,55.2],[3367.0,55.3],[3307.0,55.3],[3247.0,54.6],[3187.0,54.5],[3127.0,54.3],[3067.0,53.4],[3007.0,53.1],[2947.0,52.9],[2887.0,52.0],[2827.0,51.8],[2767.0,51.6],[2707.0,50.8],[2647.0,50.8],[2587.0,50.9],[2527.0,50.4],[2467.0,50.7],[2407.0,51.0],[2347.0,50.8],[2287.0,51.3],[2227.0,51.9],[2167.0,51.8],[2107.0,52.6],[2047.0,53.2],[1987.0,53.3],[1927.0,54.0],[1867.0,54.6],[1807.0,54.5],[1747.0,55.1],[1687.0,55.4],[1627.0,55.1],[1567.0,55.4],[1507.0,55.5],[1447.0,54.9],[1387.0,55.0],[1327.0,54.8],[1267.0,54.0],[1207.0,53.8],[1147.0,53.5],[1087.0,52.6],[1027.0,52.4],[967.0,52.1],[907.0,51.3],[847.0,51.2],[787.0,51.1],[727.0,50.5],[667.0,50.7],[607.0,50.8],[547.0,50.5],[487.0,51.0],[427.0,51.3],[367.0,51.3],[307.0,52.0],[247.0,52.5],[187.0,52.6],[127.0,53.4],[67.0,53.9],[7.0,54.2]],"throttled":{"now":false,"ever":false,"raw":"0x0","undervolt_now":false,"capped_now":false,"throttled_now":false,"soft_temp_now":false,"undervolt_ever":false,"capped_ever":false,"throttled_ever":false,"soft_temp_ever":false},"uptime_s":273600,"boot_s":1036800,"loop_age_s":0.8,"renderer":{"attached":true,"connects":1,"detached_s":null,"pending_s":null},"memory":{"total_mb":990,"available_mb":412},"storage":{"total_gb":29.1,"free_gb":11.4},"quiet_s":null,"idle":null,"mode":"lyrics","ytdlp":null},
    "still":{"fps":59.6,"fps_age_s":1800.0,"fps_target":60.0,"sent_fps":0.0,"temp_c":54.2,"temp_log":[[3547.0,55.3],[3487.0,55.6],[3427.0,55.2],[3367.0,55.3],[3307.0,55.3],[3247.0,54.6],[3187.0,54.5],[3127.0,54.3],[3067.0,53.4],[3007.0,53.1],[2947.0,52.9],[2887.0,52.0],[2827.0,51.8],[2767.0,51.6],[2707.0,50.8],[2647.0,50.8],[2587.0,50.9],[2527.0,50.4],[2467.0,50.7],[2407.0,51.0],[2347.0,50.8],[2287.0,51.3],[2227.0,51.9],[2167.0,51.8],[2107.0,52.6],[2047.0,53.2],[1987.0,53.3],[1927.0,54.0],[1867.0,54.6],[1807.0,54.5],[1747.0,55.1],[1687.0,55.4],[1627.0,55.1],[1567.0,55.4],[1507.0,55.5],[1447.0,54.9],[1387.0,55.0],[1327.0,54.8],[1267.0,54.0],[1207.0,53.8],[1147.0,53.5],[1087.0,52.6],[1027.0,52.4],[967.0,52.1],[907.0,51.3],[847.0,51.2],[787.0,51.1],[727.0,50.5],[667.0,50.7],[607.0,50.8],[547.0,50.5],[487.0,51.0],[427.0,51.3],[367.0,51.3],[307.0,52.0],[247.0,52.5],[187.0,52.6],[127.0,53.4],[67.0,53.9],[7.0,54.2]],"throttled":{"now":false,"ever":false,"raw":"0x0","undervolt_now":false,"capped_now":false,"throttled_now":false,"soft_temp_now":false,"undervolt_ever":false,"capped_ever":false,"throttled_ever":false,"soft_temp_ever":false},"uptime_s":273600,"boot_s":1036800,"loop_age_s":0.8,"renderer":{"attached":true,"connects":1,"detached_s":null,"pending_s":null},"memory":{"total_mb":990,"available_mb":412},"storage":{"total_gb":29.1,"free_gb":11.4},"quiet_s":null,"idle":null,"mode":"art","ytdlp":null},
    "behind":{"fps":41.2,"fps_age_s":3.0,"fps_target":60.0,"sent_fps":41.5,"temp_c":54.2,"temp_log":[[3547.0,55.3],[3487.0,55.6],[3427.0,55.2],[3367.0,55.3],[3307.0,55.3],[3247.0,54.6],[3187.0,54.5],[3127.0,54.3],[3067.0,53.4],[3007.0,53.1],[2947.0,52.9],[2887.0,52.0],[2827.0,51.8],[2767.0,51.6],[2707.0,50.8],[2647.0,50.8],[2587.0,50.9],[2527.0,50.4],[2467.0,50.7],[2407.0,51.0],[2347.0,50.8],[2287.0,51.3],[2227.0,51.9],[2167.0,51.8],[2107.0,52.6],[2047.0,53.2],[1987.0,53.3],[1927.0,54.0],[1867.0,54.6],[1807.0,54.5],[1747.0,55.1],[1687.0,55.4],[1627.0,55.1],[1567.0,55.4],[1507.0,55.5],[1447.0,54.9],[1387.0,55.0],[1327.0,54.8],[1267.0,54.0],[1207.0,53.8],[1147.0,53.5],[1087.0,52.6],[1027.0,52.4],[967.0,52.1],[907.0,51.3],[847.0,51.2],[787.0,51.1],[727.0,50.5],[667.0,50.7],[607.0,50.8],[547.0,50.5],[487.0,51.0],[427.0,51.3],[367.0,51.3],[307.0,52.0],[247.0,52.5],[187.0,52.6],[127.0,53.4],[67.0,53.9],[7.0,54.2]],"throttled":{"now":false,"ever":false,"raw":"0x0","undervolt_now":false,"capped_now":false,"throttled_now":false,"soft_temp_now":false,"undervolt_ever":false,"capped_ever":false,"throttled_ever":false,"soft_temp_ever":false},"uptime_s":273600,"boot_s":1036800,"loop_age_s":0.8,"renderer":{"attached":true,"connects":1,"detached_s":null,"pending_s":null},"memory":{"total_mb":990,"available_mb":412},"storage":{"total_gb":29.1,"free_gb":11.4},"quiet_s":null,"idle":null,"mode":"cd","ytdlp":null},
    "collecting":{"fps":59.6,"fps_age_s":2.1,"fps_target":60.0,"sent_fps":59.8,"temp_c":51.6,"temp_log":[[67.0,51.2],[7.0,51.6]],"throttled":{"now":false,"ever":false,"raw":"0x0","undervolt_now":false,"capped_now":false,"throttled_now":false,"soft_temp_now":false,"undervolt_ever":false,"capped_ever":false,"throttled_ever":false,"soft_temp_ever":false},"uptime_s":140,"boot_s":180,"loop_age_s":0.8,"renderer":{"attached":true,"connects":1,"detached_s":null,"pending_s":null},"memory":{"total_mb":990,"available_mb":412},"storage":{"total_gb":29.1,"free_gb":11.4},"quiet_s":null,"idle":null,"mode":"cd","ytdlp":null},
    "mac":{"fps":59.6,"fps_age_s":2.1,"fps_target":60.0,"sent_fps":59.8,"temp_c":null,"temp_log":[],"throttled":null,"uptime_s":273600,"boot_s":null,"loop_age_s":0.8,"renderer":null,"memory":null,"storage":{"total_gb":460.4,"free_gb":182.7},"quiet_s":null,"idle":null,"mode":"cd","ytdlp":null},
    "legacy":{"fps":59.6,"temp_c":54.2,"throttled":{"now":false,"ever":true},"uptime_s":273600,"loop_age_s":0.8,"quiet_s":null,"idle":null,"mode":"cd","ytdlp":null},
    "several":{"fps":59.6,"fps_age_s":2.1,"fps_target":60.0,"sent_fps":59.8,"temp_c":54.2,"temp_log":[[3547.0,55.3],[3487.0,55.6],[3427.0,55.2],[3367.0,55.3],[3307.0,55.3],[3247.0,54.6],[3187.0,54.5],[3127.0,54.3],[3067.0,53.4],[3007.0,53.1],[2947.0,52.9],[2887.0,52.0],[2827.0,51.8],[2767.0,51.6],[2707.0,50.8],[2647.0,50.8],[2587.0,50.9],[2527.0,50.4],[2467.0,50.7],[2407.0,51.0],[2347.0,50.8],[2287.0,51.3],[2227.0,51.9],[2167.0,51.8],[2107.0,52.6],[2047.0,53.2],[1987.0,53.3],[1927.0,54.0],[1867.0,54.6],[1807.0,54.5],[1747.0,55.1],[1687.0,55.4],[1627.0,55.1],[1567.0,55.4],[1507.0,55.5],[1447.0,54.9],[1387.0,55.0],[1327.0,54.8],[1267.0,54.0],[1207.0,53.8],[1147.0,53.5],[1087.0,52.6],[1027.0,52.4],[967.0,52.1],[907.0,51.3],[847.0,51.2],[787.0,51.1],[727.0,50.5],[667.0,50.7],[607.0,50.8],[547.0,50.5],[487.0,51.0],[427.0,51.3],[367.0,51.3],[307.0,52.0],[247.0,52.5],[187.0,52.6],[127.0,53.4],[67.0,53.9],[7.0,54.2]],"throttled":{"now":true,"ever":true,"raw":"0x50005","undervolt_now":true,"capped_now":false,"throttled_now":true,"soft_temp_now":false,"undervolt_ever":true,"capped_ever":false,"throttled_ever":true,"soft_temp_ever":false},"uptime_s":273600,"boot_s":1036800,"loop_age_s":0.8,"renderer":{"attached":true,"connects":1,"detached_s":null,"pending_s":null},"memory":{"total_mb":990,"available_mb":48},"storage":{"total_gb":29.1,"free_gb":11.4},"quiet_s":null,"idle":null,"mode":"cd","ytdlp":null}
    }
    """#
    // END health_fixtures.json
}
#endif
