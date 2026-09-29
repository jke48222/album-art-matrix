// The link's memory: why the wall last failed to answer, what happened to
// the connection recently, and how to name what is waiting in the outbox.
//
// Foundation only, so the Connection model tests compile it with swiftc on
// the Mac beside ConnectionModels.swift. WallSession keeps the live values
// (lastProblem, history). The Connection page, the settings detail and the
// flight recorder read them from there, so every surface says the same thing.

import Foundation

// MARK: - Why the last poll failed

enum LinkProblem: String, Codable, Equatable {
    case timedOut, nameNotFound, refused, noPath, dropped, httpError, notTessera, blockedName, other

    /// URLSession's error for a failed GET /state, with the status when the
    /// wall answered at all. A non-2xx status wins over the error it caused.
    static func from(_ error: Error, status: Int?) -> LinkProblem {
        if let status, !(200..<300).contains(status) { return .httpError }
        let ns = error as NSError
        // JSONSerialization's "not JSON" (NSPropertyListReadCorruptError)
        if ns.domain == NSCocoaErrorDomain, ns.code == 3840 { return .notTessera }
        guard ns.domain == NSURLErrorDomain else { return .other }
        switch ns.code {
        case NSURLErrorTimedOut: return .timedOut
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return .nameNotFound
        case NSURLErrorCannotConnectToHost: return .refused
        case NSURLErrorNotConnectedToInternet: return .noPath
        // The wall accepted the connection and closed it before answering:
        // a path exists, so Wi-Fi and permission advice would be wrong.
        case NSURLErrorNetworkConnectionLost: return .dropped
        case NSURLErrorCannotParseResponse: return .notTessera
        // App Transport Security allows plain HTTP only to .local names and
        // numbers (NSAllowsLocalNetworking), so any other name can never work.
        case NSURLErrorAppTransportSecurityRequiresSecureConnection: return .blockedName
        default: return .other
        }
    }

    /// The reason line on the Connection page: "Last try: ...".
    func sentence(host: String, status: Int?) -> String {
        "Last try: " + body(host: host, status: status)
    }

    /// The same reason on its own, for the history's "Wall stopped
    /// responding" detail.
    func reason(host: String, status: Int?) -> String {
        let text = body(host: host, status: status)
        guard !text.hasPrefix("iPhone"), let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private func body(host: String, status: Int?) -> String {
        let name = Self.hostname(host)
        switch self {
        case .timedOut: return "no response within 3 seconds."
        case .nameNotFound: return "the name \(name) was not found."
        case .refused: return "the address was reachable, but Tessera was not running there."
        case .noPath: return "no network path to the wall. Check Wi-Fi and Local Network access."
        case .dropped: return "the connection closed before the wall answered."
        case .httpError:
            return status.map { "the wall reported an error (HTTP \($0))." } ?? "the wall reported an error."
        case .notTessera: return "the reply was not from a Tessera wall."
        case .blockedName:
            return "iPhone blocks plain connections to \(name). Use a name ending in .local or the wall\u{2019}s number."
        case .other: return "the connection failed."
        }
    }

    /// "album-matrix.local:8788" to "album-matrix.local", "[fe80::1]:8788"
    /// to "fe80::1". A bare IPv6 address has several colons and is kept.
    static func hostname(_ hostPort: String) -> String {
        if hostPort.hasPrefix("["), let close = hostPort.firstIndex(of: "]") {
            return String(hostPort[hostPort.index(after: hostPort.startIndex)..<close])
        }
        let parts = hostPort.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2 ? String(parts[0]) : hostPort
    }
}

// MARK: - What happened to the connection

struct LinkEvent: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case responding, respondingAgain, stopped, looking, noWallFound, phoneOnly, address
        case waiting, sent, notSent, discarded

        /// A change to the link itself, as opposed to the outbox. The
        /// reconnect rule reads only these, so a "Changes waiting" logged
        /// while the wall was away cannot hide that it had stopped.
        var isLink: Bool {
            switch self {
            case .responding, .respondingAgain, .stopped, .looking, .noWallFound, .phoneOnly, .address: true
            case .waiting, .sent, .notSent, .discarded: false
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var at: Date
    var detail: String?

    init(kind: Kind, at: Date = Date(), detail: String? = nil) {
        self.kind = kind
        self.at = at
        self.detail = detail
    }

    var sentence: String {
        switch kind {
        case .responding: "Wall responding"
        case .respondingAgain: "Wall responding again"
        case .stopped: "Wall stopped responding"
        case .looking: "Looked for the wall"
        case .noWallFound: "No wall found, preview on this phone"
        case .phoneOnly: "Switched to this phone only"
        case .address: "Address changed"
        case .waiting: "Changes waiting to send"
        case .sent: "Sent after reconnecting"
        case .notSent: "Not everything was sent"
        case .discarded: "Discarded changes that were waiting"
        }
    }
}

/// The recent connection history, newest first, kept across launches.
struct LinkHistory: Codable, Equatable {
    static let key = "connection.history"
    static let limit = 30

    private(set) var events: [LinkEvent] = []

    init(events: [LinkEvent] = []) {
        self.events = Array(events.sorted { $0.at > $1.at }.prefix(Self.limit))
    }

    var latest: LinkEvent? { events.first }
    /// The newest event that changed the link, skipping outbox events.
    var latestLink: LinkEvent? { events.first { $0.kind.isLink } }

    /// Kept in time order, not arrival order: "stopped responding" is logged
    /// three misses late but stamped when the wall went quiet, and must sit
    /// before anything that happened in between.
    mutating func append(_ event: LinkEvent) {
        let index = events.firstIndex { $0.at <= event.at } ?? events.endIndex
        events.insert(event, at: index)
        if events.count > Self.limit { events.removeLast(events.count - Self.limit) }
    }

    /// What to log when the wall answers after not answering: "responding
    /// again" after it stopped or was looked for, "responding" after an
    /// address change, this phone only, no wall found, or no history at
    /// all. Nothing when the last link event already says it responds, so
    /// a relaunch or a blip shorter than three misses logs nothing.
    var answerKind: LinkEvent.Kind? {
        switch latestLink?.kind {
        case .stopped?, .looking?: .respondingAgain
        case nil, .address?, .phoneOnly?, .noWallFound?: .responding
        default: nil
        }
    }

    static func load(from defaults: UserDefaults) -> LinkHistory {
        guard let data = defaults.data(forKey: key),
              let history = try? JSONDecoder().decode(LinkHistory.self, from: data) else { return LinkHistory() }
        return LinkHistory(events: history.events)
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// When "Wall stopped responding" is logged: at the third miss in a row
/// while offline, and once per stretch in which the wall answered. A phone
/// waking from sleep misses once or twice before Wi-Fi is back, which is not
/// the wall stopping, and a look from offline that fails three more times is
/// the same outage, not a second one.
struct LinkEpisode: Equatable {
    private(set) var answered = false

    /// A poll succeeded.
    mutating func answer() { answered = true }

    /// The owner chose this phone or a new address: whatever happens next
    /// is not this wall stopping.
    mutating func reset() { answered = false }

    /// A poll failed, and `misses` counts them in a row. True exactly once
    /// per outage, when "stopped" should be logged.
    mutating func miss(_ misses: Int, offline: Bool) -> Bool {
        guard misses == 3, answered, offline else { return false }
        answered = false
        return true
    }
}

// MARK: - Naming what is waiting

/// The outbox in the owner’s words: "Display mode and brightness", "A picture".
enum OutboxWords {
    /// Names in the order they are listed. A key takes the first entry that
    /// names it exactly, then the first whose prefix it has.
    private static let table: [(name: String, keys: Set<String>, prefix: String?)] = [
        ("display mode", ["mode"], nil),
        ("brightness", ["brightness"], nil),
        ("lamp effect", ["effect"], nil),
        ("lamp colour", ["color", "color2", "match_art"], nil),
        ("record finish", ["finish"], nil),
        ("record speed", ["rpm"], nil),
        ("record face", ["spin_face"], nil),
        ("speed", ["speed"], nil),
        ("ticker text", [], "ticker_"),
        ("clock style", ["clock_24h"], nil),
        ("between songs", ["idle", "away"], nil),
        ("wake up", [], "wake_"),
        ("colour balance", [], "wb_"),
        ("follow the sun", ["sun", "sun_night"], nil),
        ("location", ["lat", "lon"], nil),
        ("weather place", ["place"], nil),
        ("weather units", ["weather_units"], nil),
        ("lyrics timing", ["lyric_offset"], nil),
        ("timer", ["timer_min"], nil),
    ]
    private static let unknown = "a setting"

    /// Distinct names for these keys, in table order, any unknown key last.
    static func names(keys: [String]) -> [String] {
        var found = Set<Int>()
        var other = false
        for key in keys {
            if let i = table.firstIndex(where: { $0.keys.contains(key) })
                ?? table.firstIndex(where: { entry in entry.prefix.map { key.hasPrefix($0) } ?? false }) {
                found.insert(i)
            } else {
                other = true
            }
        }
        return found.sorted().map { table[$0].name } + (other ? [unknown] : [])
    }

    /// "Brightness", "Display mode and brightness", "5 settings", "A
    /// picture", "Display mode, brightness and a picture". Empty when
    /// nothing is given.
    static func describe(keys: [String], frame: Bool, clip: Bool, sentenceCase: Bool = true) -> String {
        let names = names(keys: keys)
        var items = names.count >= 3 ? ["\(names.count) settings"] : names
        if frame { items.append("a picture") }
        if clip { items.append("a clip") }
        guard let last = items.last else { return "" }
        let text = items.count == 1 ? last : items.dropLast().joined(separator: ", ") + " and " + last
        guard sentenceCase, let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// "1 change waiting", "3 changes waiting": distinct names, plus one
    /// each for a picture and a clip.
    static func count(keys: [String], frame: Bool, clip: Bool) -> String {
        let n = names(keys: keys).count + (frame ? 1 : 0) + (clip ? 1 : 0)
        return n == 1 ? "1 change waiting" : "\(n) changes waiting"
    }
}
