// The wall's tuning store, as the phone sees it: every knob the wall
// describes in GET /tuning, the renderer's real state, and one write at a time.
//
// The wall owns the list. The store draws whatever comes back, so a knob added
// to the brain shows up on the phone without the app changing, and an older
// brain that sends only names and ranges still reads: titles fall back to the
// knob's own name, groups to a built-in table, and a restart to a 7 s guess.
//
// Foundation only, so scripts/test_tuning_store.py can compile it whole on the
// Mac, with AboutModels.swift for TuningPeek.numbers. The page hands in its
// own log (FlightLog in the app).
//
// HearingPage, TeachPage and VoicePage read knobs, values, defaults, problem
// and busy, and call load(host:), send(_:_:isBool:) and reset(). Those keep
// their meaning: every failed write sets `problem` as well as the row's own
// problem, so a page that only checks `problem` never reports a refused write
// as saved.

import Foundation
import Observation

struct Knob: Identifiable, Equatable {
    let name: String
    let group: String
    let kind: String        // int | float | bool
    let min: Double
    let max: Double
    let step: Double
    let restart: Bool       // the panel goes down and comes back for this one
    let note: String
    var label: String? = nil
    var unit: String? = nil
    /// Where a change shows: now, restart, sleeves, next_sleeve, next_video,
    /// video or listening. Older brains do not say, so it follows restart.
    var applies: String = "now"
    var id: String { name }

    /// The wall's label, or "low_blue" as "Low blue" from an older brain.
    var title: String {
        if let label, !label.isEmpty { return label }
        let words = name.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    var isBool: Bool { kind == "bool" }
    /// How many values the knob can take.
    var positions: Int { step > 0 ? Int(((max - min) / step).rounded()) + 1 : 1 }
    /// A handful of whole numbers reads better as choices than as a rail.
    /// Today that is only Row addressing, 0 to 7.
    var isChoice: Bool { kind == "int" && positions <= 8 }

    init(name: String, group: String, kind: String, min: Double, max: Double, step: Double,
         restart: Bool, note: String, label: String? = nil, unit: String? = nil, applies: String? = nil) {
        self.name = name; self.group = group; self.kind = kind
        self.min = min; self.max = max; self.step = step
        self.restart = restart; self.note = note
        self.label = label; self.unit = unit
        self.applies = applies ?? (restart ? "restart" : "now")
    }

    /// The wall's words are set with the app's curly apostrophe, so a note
    /// such as "the panel's driver" matches the page's own copy.
    init?(json k: [String: Any]) {
        guard let name = k["name"] as? String else { return nil }
        let restart = k["restart"] as? Bool ?? false
        self.init(name: name, group: k["group"] as? String ?? "Other", kind: k["kind"] as? String ?? "float",
                  min: TuningStore.number(k["min"]) ?? 0, max: TuningStore.number(k["max"]) ?? 1,
                  step: TuningStore.number(k["step"]) ?? 0.01, restart: restart,
                  note: TuningCopy.typographic(k["note"] as? String ?? ""),
                  label: (k["label"] as? String).map(TuningCopy.typographic), unit: k["unit"] as? String,
                  applies: k["applies"] as? String)
    }

    /// GET /state's panel_brightness, drawn as a knob for a brain that does
    /// not list it in /tuning yet. The copy is the brain's own.
    static let ceiling = Knob(name: "panel_brightness", group: "Panel", kind: "int", min: 1, max: 254, step: 1,
                              restart: false, note: "The most light the panel is allowed to give. The Light setting dims within this.",
                              label: "Brightness ceiling", unit: "/254", applies: "now")
}

/// One heading on the tuning page. key is the knob's group field.
struct TuningGroup: Identifiable, Equatable {
    let key: String
    let title: String
    let summary: String
    /// "picture" or "listening", the page's two tabs.
    let tab: String
    /// The test pattern that shows this group's knobs best, or "wall" for the
    /// wall's own picture. nil for the microphone's knobs.
    let pattern: String?
    var id: String { key }

    init(key: String, title: String, summary: String, tab: String, pattern: String?) {
        self.key = key; self.title = title; self.summary = summary; self.tab = tab; self.pattern = pattern
    }

    init?(json g: [String: Any]) {
        guard let key = g["key"] as? String else { return nil }
        self.init(key: key, title: TuningCopy.typographic(g["title"] as? String ?? key),
                  summary: TuningCopy.typographic(g["summary"] as? String ?? ""),
                  tab: g["tab"] as? String == "listening" ? "listening" : "picture", pattern: g["pattern"] as? String)
    }

    /// The brain's groups, for a brain too old to send them. The copy is the
    /// same as brain/tuning.py GROUPS.
    static let builtIn: [TuningGroup] = [
        TuningGroup(key: "Panel", title: "Panel drive", summary: "How the panel is scanned and how bright it may go. Settings with a Restarts panel badge turn the panel off for a few seconds.", tab: "picture", pattern: "darkSteps"),
        TuningGroup(key: "Colour", title: "Colour", summary: "The balance of red, green and blue on every picture.", tab: "picture", pattern: "bars"),
        TuningGroup(key: "Dark end", title: "Dark end", summary: "How the dimmest levels are drawn, where the panel has the fewest steps.", tab: "picture", pattern: "darkColours"),
        TuningGroup(key: "Sharpness", title: "Sharpness", summary: "Sharpening after album art and video are scaled to the panel.", tab: "picture", pattern: "wall"),
        TuningGroup(key: "Video", title: "Video", summary: "How clips are brightened and how their shadows are drawn.", tab: "picture", pattern: "wall"),
        TuningGroup(key: "Shelf", title: "Shelf", summary: "Marks on album art from your Discogs collection.", tab: "picture", pattern: "wall"),
        TuningGroup(key: "Hearing", title: "Hearing", summary: "Song recognition, knocks and whistles through the microphone.", tab: "listening", pattern: nil),
        TuningGroup(key: "Voice", title: "Voice", summary: "The wake word and the speech model.", tab: "listening", pattern: nil),
    ]

    /// Every group the knobs use, in the given order, with any the list does
    /// not name added at the end on the picture tab.
    static func covering(_ knobs: [Knob], listed: [TuningGroup]) -> [TuningGroup] {
        let used = Set(knobs.map(\.group))
        var out = listed.filter { used.contains($0.key) }
        for key in knobs.map(\.group) where !out.contains(where: { $0.key == key }) {
            out.append(TuningGroup(key: key, title: key, summary: "", tab: "picture", pattern: nil))
        }
        return out
    }
}

/// The renderer, as GET /tuning reports it. unknown is an older brain that
/// does not say.
enum RendererState: String, Equatable {
    case running, starting, restarting, stalled, stopped, absent, unknown
    /// The panel is dark and will come back by itself.
    var comingBack: Bool { self == .restarting || self == .starting }
}

/// The last launch flag written, so a panel that does not come back can be
/// put back exactly as it was. Never the brightness ceiling, which is not a
/// launch flag and cannot stop the panel.
struct TuningRevert: Equatable {
    let name: String
    let previous: Double
}

/// Why the panel last restarted, so its return can be named.
enum TuningRestartCause: Equatable { case setting, reset, restart }

/// The copy that belongs to the store's answers. The page's own states are
/// written in PanelTuningPage.
enum TuningCopy {
    static let refused = "The wall did not accept this value. It is still using the one shown."
    static let restarting = "The panel is still restarting. Try again in a moment."
    static let notConfirmed = "The change was not confirmed. The value shown is the last one the wall reported."
    static let resetNotConfirmed = "The reset was not confirmed. The values shown are what the wall reports now."
    static let unsupported = "tuning is not available on this wall"

    /// "3 settings changed from their defaults".
    static func changed(_ count: Int) -> String {
        switch count {
        case 0: "All settings at their defaults"
        case 1: "1 setting changed from its default"
        default: "\(count) settings changed from their defaults"
        }
    }

    /// "40 seconds ago", "1 minute ago". Written out rather than formatted,
    /// so the status line reads the same on every phone.
    static func ago(_ seconds: TimeInterval) -> String {
        let s = Swift.max(0, Int(seconds.rounded(.down)))
        if s < 5 { return "just now" }
        if s < 60 { return "\(s) seconds ago" }
        let m = s / 60
        if m < 60 { return m == 1 ? "1 minute ago" : "\(m) minutes ago" }
        let h = m / 60
        return h == 1 ? "1 hour ago" : "\(h) hours ago"
    }

    /// Where a change shows, for the knobs where that is not "at once".
    static func applies(_ applies: String) -> String? {
        switch applies {
        case "sleeves": "Shows on album art. Test patterns do not use it."
        case "next_sleeve": "Album art changes from the next song. Video changes at once."
        case "next_video": "Applies from the next video."
        case "video": "Shows while a video plays."
        default: nil
        }
    }

    /// A group's scope lines, one per row in order, with a line left off
    /// where the row just above already says the same. A run of album art
    /// knobs says "Shows on album art" once, on its first row.
    static func scopes(_ lines: [String?]) -> [String?] {
        lines.indices.map { i in i > 0 && lines[i] == lines[i - 1] ? nil : lines[i] }
    }

    /// Text from the wall, set with the curly apostrophe the app's own copy
    /// uses, so one page never mixes the two.
    static func typographic(_ text: String) -> String {
        text.replacingOccurrences(of: "'", with: "\u{2019}")
    }

    /// Start over, before it is asked. restarts is false when there is no
    /// panel program for a reset to restart.
    static func startOver(restarts: Bool) -> String {
        "Every panel and listening setting goes back to what the wall shipped with."
            + (restarts ? " The panel restarts once." : "") + " Your True colour correction stays as it is."
    }

    /// The Start over question. It names only what a reset really changes:
    /// named holds the settings worth naming, as title and default, that
    /// are off their default now. With nothing off its default it says so
    /// rather than offering to put anything back.
    static func resetQuestion(anyChanged: Bool, restarts: Bool, named: [(title: String, value: String)]) -> String {
        var out: [String] = []
        if anyChanged {
            out.append("Return every panel and listening setting to its default?")
            if restarts { out.append("The panel restarts once.") }
        } else {
            out.append("Every setting is already at its default.")
            out.append(restarts ? "Returning to defaults only restarts the panel." : "Returning to defaults changes nothing.")
        }
        out.append("Your True colour correction stays as it is.")
        if let first = named.first {
            let rest = named.dropFirst().map { " and \($0.title) to \($0.value)" }.joined()
            out.append("\(first.title) goes back to \(first.value)\(rest).")
        }
        return out.joined(separator: " ")
    }
}

@MainActor
@Observable
final class TuningStore {
    var knobs: [Knob] = []
    var values: [String: Double] = [:]
    var defaults: [String: Double] = [:]
    private(set) var groups: [TuningGroup] = []
    /// {knob: why it does nothing on this wall}, one reason each.
    private(set) var inactive: [String: String] = [:]
    /// The last failure of any kind, for pages that show one line. The tuning
    /// page reads rowProblems for writes and its own states for reads.
    var problem: String?
    private(set) var rowProblems: [String: String] = [:]
    private(set) var renderer: RendererState = .unknown
    /// How long the panel has been without a renderer, from the brain.
    private(set) var rendererDownSeconds: Double?
    /// An older brain said restarting with no renderer state: assume the 7 s
    /// the page used to wait.
    private(set) var legacyRestartUntil: Date?
    /// When the renderer came back from a restart or a start.
    private(set) var justBack: Date?
    private(set) var justBackCause: TuningRestartCause?
    private(set) var lastRevert: TuningRevert?
    private(set) var lastRead: Date?
    /// Quiet reads that failed in a row since the last one that answered.
    private(set) var readFailures = 0
    /// The last load did not get the knobs (and it was not "unsupported").
    private(set) var readFailed = false
    /// The wall answered 503 "tuning is not available on this wall" before
    /// any read succeeded. Cleared by the next answer with knobs.
    private(set) var unsupported = false
    private(set) var reading = false
    private(set) var resetting = false
    private(set) var restartAsked = false
    /// A write is on its way or queued.
    private(set) var sending = false
    /// A finger (or a VoiceOver adjustment still waiting to commit) is on a
    /// control. Refreshes wait, so the finger's value is never overwritten.
    var holding = false
    /// Each committed write, renderer transition and reset, one line each.
    @ObservationIgnored var log: (String) -> Void = { _ in }

    /// Reset or restart in flight. Old pages disable their controls on this.
    var busy: Bool { resetting || restartAsked }

    private var host = ""
    private var connection = UUID()
    private var requestRevision = 0
    private var queued: [(key: String, patch: [String: Any])] = []
    private var cause: TuningRestartCause?
    private var downSince: Date?
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// The renderer as the page should treat it: the brain's state, or the
    /// legacy guess for a brain that does not report one.
    var panelState: RendererState {
        if renderer != .unknown { return renderer }
        if let until = legacyRestartUntil, until > Date() { return .restarting }
        return .unknown
    }

    /// Knobs moved off their default by more than half a step.
    var changedCount: Int { knobs.filter(isChanged).count }

    func changed(in group: String) -> Int { knobs.filter { $0.group == group && isChanged($0) }.count }

    func isChanged(_ knob: Knob) -> Bool {
        guard let v = values[knob.name], let d = defaults[knob.name] else { return false }
        return abs(v - d) > Swift.max(knob.step / 2, 1e-6)
    }

    // MARK: Reading

    /// The page opening, a pull to refresh, or another wall. A new host
    /// forgets everything the old one said.
    func load(host: String) async {
        if self.host != host {
            self.host = host; connection = UUID(); queued = []
            knobs = []; values = [:]; defaults = [:]; groups = []; inactive = [:]; problem = nil
            rowProblems = [:]; renderer = .unknown; rendererDownSeconds = nil; legacyRestartUntil = nil
            justBack = nil; justBackCause = nil; lastRevert = nil; lastRead = nil
            readFailures = 0; readFailed = false; unsupported = false; cause = nil; downSince = nil
        } else if sending || busy {
            // A GET may reach the wall before the in-flight write commits.
            // Keep the confirmed write response as the source of truth.
            return
        }
        reading = true
        defer { reading = false }
        await read(quiet: false)
    }

    /// The page's poll: skipped while anything is being written or held,
    /// and a failure never clears what was read, it is only counted.
    func refresh(host: String) async {
        guard host == self.host else { await load(host: host); return }
        guard !sending, !busy, !holding, !reading else { return }
        await read(quiet: true)
    }

    private func read(quiet: Bool) async {
        guard !host.isEmpty else {
            if !quiet { problem = "No address for the wall yet." }
            return
        }
        let expectedHost = host, expectedConnection = connection
        requestRevision += 1
        let revision = requestRevision
        // A load may try twice. A quiet refresh is tried again next poll.
        for attempt in 0..<(quiet ? 1 : 2) {
            let answer = await exchange("/tuning", body: nil, timeout: 6)
            guard host == expectedHost, connection == expectedConnection,
                  requestRevision == revision, !Task.isCancelled else { return }
            switch answer {
            case .answered(200, let json?) where json["values"] != nil && json["knobs"] != nil:
                take(json)
                return
            case .answered(503, let json) where (json?["error"] as? String) == TuningCopy.unsupported && lastRead == nil:
                unsupported = true
                if !quiet { problem = "Tuning is not available on this wall." }
                return
            case .silent where attempt == 0 && !quiet:
                continue
            case .answered(let status, let json):
                failRead(quiet: quiet, reason: (json?["error"] as? String).map(TuningCopy.typographic)
                         ?? (status == 200 ? "The wall sent no settings." : "The wall said \(status)."))
                return
            case .silent:
                failRead(quiet: quiet, reason: nil)
                return
            }
        }
    }

    private func failRead(quiet: Bool, reason: String?) {
        readFailures += 1
        guard !quiet else { return }
        readFailed = true
        problem = reason ?? "The wall is not answering."
    }

    // MARK: Writing

    /// One knob, to the wall. The wall answers with everything it now holds,
    /// so the page shows what the wall took rather than what was asked.
    func send(_ name: String, _ value: Double, isBool: Bool = false) async {
        guard value.isFinite else { return }
        await send(patch: [name: isBool ? (value > 0.5) as Any : value as Any], for: name)
    }

    /// Several knobs in one POST /tuning, so a group of launch flags costs a
    /// single restart. rowKey replaces a queued write for the same row.
    func send(patch: [String: Any], for rowKey: String) async {
        guard !busy, !patch.isEmpty else { return }
        queued.removeAll { $0.key == rowKey }
        queued.append((rowKey, patch))
        guard !sending else { return }
        sending = true
        defer {
            sending = false
            let waiting = idleWaiters; idleWaiters.removeAll()
            for waiter in waiting { waiter.resume() }
        }
        while !queued.isEmpty {
            let next = queued.removeFirst()
            await write(next.patch)
        }
    }

    /// Returns once no write is on its way, so a caller can let go of the
    /// value it showed only when the wall's answer is in.
    func idle() async {
        guard sending else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// Put back the last launch flag written, after a panel that has not
    /// come back. Only that key, so nothing else is disturbed.
    func revert() async {
        guard let revert = lastRevert, let knob = knobs.first(where: { $0.name == revert.name }) else { return }
        await send(revert.name, revert.previous, isBool: knob.isBool)
        await idle()
        if let now = values[revert.name], abs(now - revert.previous) < 1e-9 { lastRevert = nil }
    }

    /// Read requests can retry once. Writes are sent once and show the wall's
    /// actual response. Repeating a timed-out write could apply it twice.
    private func write(_ body: [String: Any]) async {
        guard !host.isEmpty else { problem = "No address for the wall yet."; return }
        let expectedHost = host, expectedConnection = connection
        requestRevision += 1
        let revision = requestRevision
        let before = values
        // A write sent while a finger is down is one of a drag's live
        // writes, up to eight a second. The flight log keeps events, not
        // chatter, so only the release is logged (here, or through
        // noteCommitted when the last live write already carried it).
        let live = holding
        let answer = await exchange("/tuning", body: body, timeout: 8)
        guard host == expectedHost, connection == expectedConnection, requestRevision == revision else { return }
        let keys = body.keys.sorted()
        // What went wrong, for which rows, and whether to read the wall once
        // to show what it actually holds. The problem is set after that
        // read, which would otherwise clear it.
        var failure: String?
        var failed: [String] = []
        var reread = false
        switch answer {
        case .answered(200, let json?) where json["values"] != nil:
            take(json)
            let rejected = Set(json["rejected"] as? [String] ?? [])
            for key in keys where !rejected.contains(key) { rowProblems[key] = nil }
            failed = keys.filter(rejected.contains)
            if !failed.isEmpty { failure = TuningCopy.refused; reread = true }
            record(keys.filter { !rejected.contains($0) }, before: before, live: live)
        case .answered(409, let json?) where json["values"] != nil:
            // Another phone restarted the panel. The body is the wall's
            // values, so the rows show what it holds.
            take(json)
            failure = (json["error"] as? String).map(TuningCopy.typographic) ?? TuningCopy.restarting
            failed = keys
        case .answered:
            // 400 or any 5xx: the wall answered and took nothing.
            failure = TuningCopy.refused
            failed = keys; reread = true
        case .silent:
            failure = TuningCopy.notConfirmed
            failed = keys; reread = true
        }
        if reread {
            await read(quiet: true)
            guard host == expectedHost, connection == expectedConnection else { return }
        }
        guard let failure else { return }
        for key in failed { rowProblems[key] = failure }
        problem = failure
    }

    /// A flight log line per committed knob, and the launch flag to offer to
    /// put back if the panel does not return. A drag's live writes are not
    /// logged. Launch flags never write live, so they are always logged.
    private func record(_ keys: [String], before: [String: Double], live: Bool = false) {
        var restarted = false
        for key in keys {
            guard let value = values[key] else { continue }
            let knob = knobs.first { $0.name == key }
            let restart = knob?.restart == true
            if restart || !live {
                log("\(key)=\(Self.plain(value, bool: knob?.isBool == true))\(restart ? " restart" : "")")
            }
            if restart, let previous = before[key], abs(previous - value) > 1e-9 {
                lastRevert = TuningRevert(name: key, previous: previous)
                restarted = true
            }
        }
        if restarted { cause = .setting }
    }

    /// A drag let go on the value its last live write already landed, so
    /// no release write is sent. Logs that value, one line for the drag.
    func noteCommitted(_ name: String) {
        guard let value = values[name] else { return }
        let knob = knobs.first { $0.name == name }
        log("\(name)=\(Self.plain(value, bool: knob?.isBool == true))")
    }

    /// POST /tuning/reset. True once the wall has taken it.
    @discardableResult func reset() async -> Bool {
        guard !sending, !busy else { return false }
        resetting = true
        defer { resetting = false }
        requestRevision += 1
        let revision = requestRevision, expectedHost = host
        let answer = await exchange("/tuning/reset", body: [:], timeout: 10)
        guard host == expectedHost, requestRevision == revision else { return false }
        switch answer {
        case .answered(200, let json?) where json["values"] != nil:
            cause = .reset
            take(json)
            rowProblems = [:]
            lastRevert = nil
            log("reset")
            return true
        case .answered(409, let json?) where json["values"] != nil:
            take(json)
            problem = (json["error"] as? String).map(TuningCopy.typographic) ?? TuningCopy.restarting
        default:
            // Read first: taking the wall's answer clears the problem.
            await read(quiet: true)
            problem = TuningCopy.resetNotConfirmed
        }
        return false
    }

    /// POST /tuning/restart, for a panel that has not come back.
    @discardableResult func restartPanel() async -> Bool {
        guard !sending, !busy else { return false }
        restartAsked = true
        defer { restartAsked = false }
        requestRevision += 1
        let revision = requestRevision, expectedHost = host
        let answer = await exchange("/tuning/restart", body: [:], timeout: 10)
        guard host == expectedHost, requestRevision == revision else { return false }
        switch answer {
        case .answered(200, let json?) where json["values"] != nil:
            cause = .restart
            take(json)
            log("restart: \(json["said"] as? String ?? "asked")")
            return true
        case .answered(409, let json?) where json["values"] != nil:
            take(json)
            problem = (json["error"] as? String).map(TuningCopy.typographic) ?? TuningCopy.restarting
        default:
            await read(quiet: true)
            problem = TuningCopy.notConfirmed
        }
        return false
    }

    // MARK: Taking the wall's answer

    private func take(_ json: [String: Any]) {
        if let list = json["knobs"] as? [[String: Any]] { knobs = list.compactMap(Knob.init(json:)) }
        if let v = json["values"] as? [String: Any] { values = Self.numbers(v) }
        if let d = json["defaults"] as? [String: Any] { defaults = Self.numbers(d) }
        let listed = (json["groups"] as? [[String: Any]])?.compactMap(TuningGroup.init(json:)) ?? TuningGroup.builtIn
        groups = TuningGroup.covering(knobs, listed: listed)
        inactive = (json["inactive"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? String).map(TuningCopy.typographic) }
        var next = RendererState.unknown
        if let r = json["renderer"] as? [String: Any] {
            next = RendererState(rawValue: r["state"] as? String ?? "") ?? .unknown
            rendererDownSeconds = Self.number(r["down_s"])
            legacyRestartUntil = nil
        } else if json["restarting"] as? Bool == true {
            legacyRestartUntil = Date().addingTimeInterval(7)
        }
        move(to: next)
        lastRead = Date()
        readFailures = 0
        readFailed = false
        unsupported = false
        problem = nil
    }

    private func move(to next: RendererState) {
        let was = renderer
        if next.comingBack && !was.comingBack { downSince = Date() }
        // A panel that stalled or stopped and then runs again has come back
        // too. Treating only restarting and starting as a return would leave
        // cause and downSince set, so a later unrelated start would announce
        // the old cause and a later stall would offer an old launch flag.
        if (was.comingBack || was == .stalled || was == .stopped) && next == .running {
            let took = downSince.map { Date().timeIntervalSince($0) }
            justBack = Date()
            justBackCause = cause
            log(took.map { String(format: "renderer back after %.1f s", $0) } ?? "renderer back")
            cause = nil; downSince = nil
            if justBackCause != .setting { lastRevert = nil }
            // "Still restarting" was true when it was said, and is not now.
            rowProblems = rowProblems.filter { $0.value != TuningCopy.restarting }
        }
        if next == .stalled && was != .stalled { log("renderer stalled") }
        if next == .stopped && was != .stopped { log("renderer not running") }
        renderer = next
    }

    // MARK: Numbers

    /// /tuning's values and defaults as numbers. The About page counts
    /// changes from the same answer, so both read it through one function.
    static func numbers(_ raw: [String: Any]) -> [String: Double] { TuningPeek.numbers(raw) }

    nonisolated static func number(_ value: Any?) -> Double? {
        // A JSON number bridges to Bool only when it is exactly 0 or 1, and
        // then it maps to the same number, so Bool can safely go first.
        if let b = value as? Bool { return b ? 1 : 0 }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }

    /// The knob's value as the rows show it: decimals from the step's own
    /// decimal places, and the unit joined without a space when it is "/255"
    /// or "%". Bools read On and Off.
    func format(value: Double, knob: Knob) -> String { Self.format(value, knob: knob) }

    nonisolated static func format(_ value: Double, knob: Knob) -> String {
        if knob.isBool { return value > 0.5 ? "On" : "Off" }
        let number = String(format: "%.\(decimals(knob.step))f", value)
        guard let unit = knob.unit, !unit.isEmpty else { return number }
        return unit.hasPrefix("/") || unit.hasPrefix("%") ? number + unit : number + " " + unit
    }

    /// What VoiceOver says: "12 out of 255", "60 percent".
    nonisolated static func spoken(_ value: Double, knob: Knob) -> String {
        if knob.isBool { return value > 0.5 ? "On" : "Off" }
        let number = String(format: "%.\(decimals(knob.step))f", value)
        guard let unit = knob.unit, !unit.isEmpty else { return number }
        return number + " " + spokenUnit(unit)
    }

    nonisolated static func spokenUnit(_ unit: String) -> String {
        if unit.hasPrefix("/") { return "out of " + unit.dropFirst() }
        switch unit {
        case "%": return "percent"
        case "ns": return "nanoseconds"
        case "dB": return "decibels"
        case "s": return "seconds"
        case "px": return "pixels"
        default: return unit
        }
    }

    /// The value kept on the knob's range and rounded to its step's
    /// decimals, so a sum of steps reads 0.25 rather than 0.25000000000000006.
    nonisolated static func clamped(_ value: Double, knob: Knob) -> Double {
        let places = pow(10, Double(decimals(knob.step)))
        return (Swift.min(knob.max, Swift.max(knob.min, value)) * places).rounded() / places
    }

    /// One VoiceOver swipe on a rail: a step up or down, kept on the range.
    /// Here rather than in the rail so scripts/test_tuning_store.py checks
    /// the same math the rail and the -tuning-adjust hook use.
    nonisolated static func stepped(_ value: Double, up: Bool, knob: Knob) -> Double {
        clamped(up ? value + knob.step : value - knob.step, knob: knob)
    }

    /// 1 or more gives 0, 0.5 and 0.1 give 1, 0.05 and 0.01 give 2.
    nonisolated static func decimals(_ step: Double) -> Int {
        guard step > 0, step < 1 else { return 0 }
        for places in 1...3 {
            let scaled = step * pow(10, Double(places))
            if abs(scaled - scaled.rounded()) < 1e-6 { return places }
        }
        return 3
    }

    /// For the flight log: no unit, bools as 1 and 0.
    private static func plain(_ value: Double, bool: Bool) -> String {
        if bool { return value > 0.5 ? "1" : "0" }
        return value == value.rounded() ? String(Int(value)) : String(value)
    }

    // MARK: HTTP

    private enum Answer { case answered(Int, [String: Any]?), silent }

    private func exchange(_ path: String, body: [String: Any]?, timeout: TimeInterval) async -> Answer {
        guard let url = URL(string: "http://\(host)\(path)") else { return .silent }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return .silent }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return .answered((response as? HTTPURLResponse)?.statusCode ?? 0, json)
    }
}
