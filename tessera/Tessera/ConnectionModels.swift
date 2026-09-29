// What the Connection page knows and says, as plain values.
//
// Foundation only (no SwiftUI, no Network), so scripts/test_connection_models.py
// compiles this with LinkRecords.swift and checks every rule on the Mac: how
// an address is read, how the four-step check grades what it found, and the
// words the page uses for each state. ConnectionProbe.swift does the
// measuring. ConnectionPage.swift only draws what these return.

import Foundation

// MARK: - The wall's address

/// Reads what the owner typed into "host:port". Only three shapes of host
/// are taken: a DNS name, a dotted IPv4 number and an IPv6 number. Anything
/// else (a path, a login, a space) is refused rather than guessed at, since
/// the old field kept whatever was typed and dialled http://http://...
enum WallAddressInput {
    static let defaultPort = 8788

    /// "host:port", lowercased, IPv6 in brackets. Nil when it cannot be an
    /// address. A scheme and one trailing slash are forgiven, because that is
    /// how an address copied from a browser arrives.
    static func normalize(_ raw: String, defaultPort: Int = WallAddressInput.defaultPort) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["http://", "https://"] where text.lowercased().hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count))
        }
        if text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty,
              text.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }),
              !text.contains(where: { "@/?#\\".contains($0) }) else { return nil }
        guard let (host, port) = parts(text, defaultPort: defaultPort) else { return nil }
        return join(host, port)
    }

    /// The host and port of a normalised address. Nil for anything that is
    /// not one.
    static func split(_ hostPort: String) -> (host: String, port: Int)? {
        parts(hostPort, defaultPort: defaultPort)
    }

    /// A number rather than a name: dotted IPv4 or IPv6.
    static func isNumeric(_ host: String) -> Bool {
        ipv4(host) != nil || ipv6(bare(host)) != nil
    }

    /// This device itself. Local Network access does not apply to it.
    static func isLoopback(_ host: String) -> Bool {
        let h = bare(host).lowercased()
        if h == "localhost" || h == "localhost." { return true }
        if let v4 = ipv4(h) { return v4[0] == 127 }
        if let v6 = ipv6(h) { return v6 == [UInt8](repeating: 0, count: 15) + [1] }
        return false
    }

    /// On the home network, where iPhone asks for Local Network access: a
    /// .local name, a single-label name, a name under a suffix routers give
    /// their own network (.lan, .home, .home.arpa, .internal, .localdomain),
    /// and the private and link-local ranges. Loopback and public addresses
    /// are not.
    static func isLocal(_ host: String) -> Bool {
        let h = bare(host).lowercased()
        guard !isLoopback(h) else { return false }
        if let v4 = ipv4(h) {
            switch (v4[0], v4[1]) {
            case (10, _), (192, 168), (169, 254): return true
            case (172, let b): return (16...31).contains(b)
            default: return false
            }
        }
        if let v6 = ipv6(h) {
            return (v6[0] == 0xFE && v6[1] & 0xC0 == 0x80) || v6[0] & 0xFE == 0xFC
        }
        let name = h.hasSuffix(".") ? String(h.dropLast()) : h
        return !name.contains(".") || homeSuffixes.contains { name.hasSuffix($0) }
    }

    private static let homeSuffixes = [".local", ".lan", ".home", ".home.arpa", ".internal", ".localdomain"]

    /// App Transport Security (NSAllowsLocalNetworking) lets plain HTTP reach
    /// only .local names, single-label names and numbers. Any other name is
    /// refused by iPhone before a request leaves it, so the editor says so
    /// instead of saving an address that can never answer.
    static func isBlockedName(_ host: String) -> Bool {
        let h = bare(host).lowercased()
        guard !isNumeric(h), h != "localhost" else { return false }
        return h.contains(".") && !h.hasSuffix(".local")
    }

    /// "album-matrix.local:8788" from the wall's own name. Nil when the name
    /// cannot be a host (an empty one, say).
    static func named(_ name: String, port: Int) -> String? {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let host = label.hasSuffix(".local") ? label : label + ".local"
        return normalize("\(host):\(port)")
    }

    // MARK: Parsing

    private static func parts(_ text: String, defaultPort: Int) -> (host: String, port: Int)? {
        var host: Substring
        var portText: Substring? = nil
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            host = text[text.index(after: text.startIndex)..<close]
            let rest = text[text.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":") else { return nil }
                portText = rest.dropFirst()
            }
            guard ipv6(String(host)) != nil else { return nil }
        } else if text.filter({ $0 == ":" }).count > 1 {
            // A bare IPv6 number: every colon is part of it, so no port.
            guard ipv6(text) != nil else { return nil }
            host = Substring(text)
        } else {
            let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
            host = pieces[0]
            if pieces.count == 2 { portText = pieces[1] }
        }
        var port = defaultPort
        if let portText {
            guard !portText.isEmpty, portText.count <= 5, portText.allSatisfy(\.isASCIIDigit),
                  let value = Int(portText), (1...65535).contains(value) else { return nil }
            port = value
        }
        guard let clean = cleanHost(String(host)) else { return nil }
        return (clean, port)
    }

    /// The host in its one canonical spelling, or nil.
    private static func cleanHost(_ raw: String) -> String? {
        if raw.contains(":") {
            // IPv6, already checked. Kept as typed, lowercased.
            return ipv6(raw) != nil ? raw.lowercased() : nil
        }
        var name = raw.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty, name.count <= 253 else { return nil }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        // All digits means a number, and only a real one: 999.1.1.1 is not a
        // name that happens to be made of digits.
        if labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }) {
            guard let v4 = ipv4(name) else { return nil }
            return v4.map(String.init).joined(separator: ".")
        }
        for label in labels {
            guard (1...63).contains(label.count),
                  label.allSatisfy({ $0.isASCIIDigit || ("a"..."z").contains($0) || $0 == "-" }),
                  label.first != "-", label.last != "-" else { return nil }
        }
        // A top-level label is never all digits (RFC 3696), which is also
        // what keeps 1.2.3 from passing as a name.
        guard labels.last?.contains(where: { ("a"..."z").contains($0) }) == true else { return nil }
        return name
    }

    private static func join(_ host: String, _ port: Int) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    private static func bare(_ host: String) -> String {
        host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    }

    /// Four parts, each 0 to 255.
    private static func ipv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCIIDigit),
                  let value = Int(part), value <= 255 else { return nil }
            out.append(value)
        }
        return out
    }

    /// The 16 bytes of an IPv6 number, through the system's own parser.
    private static func ipv6(_ host: String) -> [UInt8]? {
        guard host.contains(":"), !host.contains("%") else { return nil }
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    // MARK: The editor's line under the field

    enum Draft: Equatable {
        case empty
        case invalid
        /// A name iPhone will not let Tessera reach (see isBlockedName).
        case blocked(host: String)
        case same(String)
        case valid(String)

        /// The address to save, when there is one.
        var address: String? {
            switch self {
            case .same(let a), .valid(let a): a
            case .empty, .invalid, .blocked: nil
            }
        }

        var line: String? {
            switch self {
            case .empty: nil
            case .invalid: "Use a name or number with an optional port, like album-matrix.local:8788."
            case .blocked(let host):
                "iPhone blocks plain connections to \(host). Use a name ending in .local or the wall\u{2019}s number."
            case .same: "This is the address in use."
            case .valid(let address): "Tessera will use \(address)."
            }
        }

        var isProblem: Bool {
            switch self {
            case .invalid, .blocked: true
            default: false
            }
        }
    }

    static func draft(_ raw: String, current: String) -> Draft {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        guard let address = normalize(raw), let host = split(address)?.host else { return .invalid }
        if isBlockedName(host) { return .blocked(host: host) }
        return address == current ? .same(address) : .valid(address)
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

// MARK: - How quickly the wall answered

enum LatencyGrade: Equatable {
    case quick, fine, slow

    init(ms: Int) {
        self = ms < 150 ? .quick : ms < 700 ? .fine : .slow
    }

    var word: String {
        switch self {
        case .quick: "Quick"
        case .fine: "Fine"
        case .slow: "Slow"
        }
    }

    /// "Quick, 38 ms", "Slow, 1.9 s".
    static func label(ms: Int) -> String {
        let grade = LatencyGrade(ms: ms)
        if ms >= 1000 {
            return "\(grade.word), " + String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), Double(ms) / 1000)
        }
        return "\(grade.word), \(ms) ms"
    }
}

// MARK: - What each step found

enum NetworkReading: Equatable {
    case wifi, wired, cellular
    /// Satisfied through something else: a VPN, the simulator, loopback.
    case other
    /// No usable path. Not called `none`, which an optional reading would
    /// silently take for nil.
    case disconnected
}

enum ReachReading: Equatable {
    /// The TCP connection opened. `remote` is the number it reached.
    case ready(remote: String?)
    /// Local Network access is off for Tessera.
    case denied
    case notFound
    /// Something is at the address, but nothing listens on the port.
    case refused
    case timedOut
    case failed

    /// How a connection that failed, or is waiting, reads. LiveProbe hands
    /// over the parts of its NWError that matter, so this rule is checked on
    /// the Mac without the Network framework or a phone that denies access.
    /// `dns` is a failed lookup's DNSServiceErrorType, `posix` a failed
    /// connect's code.
    static func failure(localNetworkDenied: Bool, dns: Int32? = nil, posix: POSIXErrorCode? = nil) -> ReachReading {
        if localNetworkDenied { return .denied }
        if let dns {
            // kDNSServiceErr_PolicyDenied: with Local Network off, a .local
            // name fails to resolve with this, not with "no such name".
            return dns == -65570 ? .denied : .notFound
        }
        switch posix {
        case .ECONNREFUSED?: return .refused
        // Nothing answers at the number: the same "no reply" as a timeout.
        case .ETIMEDOUT?, .EHOSTDOWN?, .EHOSTUNREACH?: return .timedOut
        default: return .failed
        }
    }
}

enum WallReading: Equatable {
    case tessera(ms: Int, name: String?)
    case notTessera
    case http(Int)
    /// iPhone refused the plain request (App Transport Security, -1022).
    case blocked
    case timedOut
    case failed
}

/// One of the four rows under "From this phone to the wall".
struct CheckStep: Equatable, Identifiable {
    enum Kind: String, CaseIterable { case phone, permission, address, wall }
    enum Status: Equatable { case waiting, running, passed, attention, failed, unknown, notChecked }

    /// Why a row failed, set on failed rows only. The summary and "What to
    /// try" read it, so the advice follows the step that actually stopped.
    enum Cause: Equatable {
        case noNetwork, denied, nameNotFound
        /// A number that did not reply, on the network or on this device.
        case noReply, noReplyHere
        case noConnection, notRunning, notTessera, httpError, blocked, noResponse

        /// A failure a second try can clear: a slow reply, a wall starting
        /// up, a network that dropped for a moment. Another device at the
        /// address, a blocked name or denied access stay the same.
        var isBrief: Bool {
            switch self {
            case .denied, .notTessera, .blocked: false
            default: true
            }
        }
    }

    var id: Kind
    var status: Status
    var grade: String
    var detail: String
    /// An address the row offers to switch to: the wall's name for a number
    /// that stopped answering (row 03), or an address iPhone allows for a
    /// blocked name (row 04).
    var suggestion: String? = nil
    var cause: Cause? = nil

    var number: String {
        switch id {
        case .phone: "01"
        case .permission: "02"
        case .address: "03"
        case .wall: "04"
        }
    }

    var title: String {
        switch id {
        case .phone: "This phone"
        case .permission: "Local network"
        case .address: "Wall address"
        case .wall: "The wall"
        }
    }

    /// 1 to 4.
    var position: Int { (CheckStep.Kind.allCases.firstIndex(of: id) ?? 0) + 1 }

    /// What VoiceOver reads for the row. The grade, the status and the
    /// detail can all say the same thing while a row runs ("Checking",
    /// "checking", "Checking..."), so a part that repeats the grade is left out.
    var spoken: String {
        var label = "\(title), \(grade)"
        let word = status.word
        if word.caseInsensitiveCompare(grade) != .orderedSame { label += ", \(word)" }
        label += "."
        let said = detail.trimmingCharacters(in: CharacterSet(charactersIn: ".\u{2026} "))
        if said.caseInsensitiveCompare(grade) != .orderedSame { label += " \(detail)" }
        return label
    }
}

extension CheckStep.Status {
    /// The status in a word, so colour and shape are never the only cue.
    var word: String {
        switch self {
        case .running: "checking"
        case .passed: "passed"
        case .attention: "note"
        case .failed: "failed"
        case .unknown: "unknown"
        case .waiting: "waiting"
        case .notChecked: "not checked"
        }
    }
}

/// The link as the Connection page tells it. WallSession's LinkState plus
/// the owner's choice of this phone, which LinkState alone cannot tell apart
/// from a stand-in that took over because no wall answered.
enum LinkKind: Equatable {
    case live(lightsOff: Bool)
    case searching
    case offline(since: Date)
    case noWallFound
    case phoneOnly

    /// Which state, without its values: check results are cleared when this
    /// changes, and not when the lights go off or the offline time moves.
    var key: String {
        switch self {
        case .live: "live"
        case .searching: "searching"
        case .offline: "offline"
        case .noWallFound: "noWallFound"
        case .phoneOnly: "phoneOnly"
        }
    }

    var isLive: Bool { if case .live = self { true } else { false } }
}

enum ConnectionCheck {
    // MARK: Before any check runs

    /// The four rows from what the session already knows, drawn before any
    /// check has run. Only row 01 is measured, by the page's path watcher.
    /// `problem` is the session's last failure: a wall that answered with an
    /// error is not graded "No response" under a headline that says it is
    /// not ready.
    static func passive(host hostPort: String, link: LinkKind, network: NetworkReading?, problem: LinkProblem? = nil,
                        now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> [CheckStep] {
        let host = WallAddressInput.split(hostPort)?.host ?? LinkProblem.hostname(hostPort)
        let unknown = "Run the check to find out."
        let answered: String? = switch problem {
        case .httpError?: "Not ready"
        case .refused?: "Not running"
        case .notTessera?: "Not a Tessera wall"
        default: nil
        }
        var steps = [phoneStep(network) ?? CheckStep(id: .phone, status: .notChecked, grade: "Not checked", detail: unknown)]
        switch link {
        case .live:
            steps.append(permissionPassed(host, remote: nil))
            steps.append(WallAddressInput.isNumeric(host)
                ? CheckStep(id: .address, status: .passed, grade: host, detail: "A number, so no lookup was needed.")
                : CheckStep(id: .address, status: .passed, grade: host, detail: "Run the check to see its network address."))
            steps.append(CheckStep(id: .wall, status: .passed, grade: "Responding", detail: "Tessera is running on the wall."))
        case .searching:
            steps.append(CheckStep(id: .permission, status: .notChecked, grade: "Not checked", detail: unknown))
            steps.append(CheckStep(id: .address, status: .notChecked, grade: "Not checked", detail: unknown))
            steps.append(CheckStep(id: .wall, status: .notChecked, grade: "Not checked", detail: unknown))
        case .offline(let since):
            steps.append(CheckStep(id: .permission, status: .notChecked, grade: "Not checked", detail: unknown))
            steps.append(CheckStep(id: .address, status: .notChecked, grade: "Not checked", detail: unknown))
            steps.append(CheckStep(id: .wall, status: .failed, grade: answered ?? "No response",
                                   detail: "Since \(clock(since, now: now, locale: locale, timeZone: timeZone))."))
        case .noWallFound:
            steps.append(CheckStep(id: .permission, status: .notChecked, grade: "Not checked", detail: unknown))
            steps.append(CheckStep(id: .address, status: .notChecked, grade: "Not checked", detail: unknown))
            steps.append(CheckStep(id: .wall, status: .failed, grade: answered ?? "Not found", detail: "Run the check to see where it stops."))
        case .phoneOnly:
            steps.append(CheckStep(id: .permission, status: .notChecked, grade: "Not checked", detail: unknown))
            steps.append(CheckStep(id: .address, status: .notChecked, grade: "Not checked", detail: unknown))
            steps.append(CheckStep(id: .wall, status: .notChecked, grade: "Not contacted", detail: unknown))
        }
        return steps
    }

    // MARK: After a check

    /// The rows for a check at `hostPort`, given what has been read so far.
    /// A nil reading has not arrived: the row named by `running` shows as
    /// running and the others as waiting. The first hard failure stops the
    /// check, and every row after it reads "Fix the step above first."
    static func steps(hostPort: String, network: NetworkReading?, reach: ReachReading?,
                      wall: WallReading?, knownName: String?, running: CheckStep.Kind? = nil) -> [CheckStep] {
        let split = WallAddressInput.split(hostPort)
        let host = split?.host ?? LinkProblem.hostname(hostPort)
        let port = split?.port ?? WallAddressInput.defaultPort
        let numeric = WallAddressInput.isNumeric(host)
        // Local Network access only governs the home network.
        let needsPermission = WallAddressInput.isLocal(host)

        var rows: [CheckStep] = []
        var stopped = false

        func pending(_ kind: CheckStep.Kind) -> CheckStep {
            if stopped {
                return CheckStep(id: kind, status: .notChecked, grade: "Not checked", detail: "Fix the step above first.")
            }
            if running == kind {
                return CheckStep(id: kind, status: .running, grade: "Checking", detail: runningDetail(kind))
            }
            return CheckStep(id: kind, status: .waiting, grade: "Waiting", detail: "Not checked yet.")
        }

        // 01 This phone
        if let network, let row = phoneStep(network) {
            rows.append(row)
            if network == .disconnected { stopped = true }
        } else {
            rows.append(pending(.phone))
        }

        // 02 Local network and 03 Wall address both come from one connection.
        guard let reach, !stopped else {
            return rows + [pending(.permission), pending(.address), pending(.wall)]
        }
        switch reach {
        case .denied:
            rows.append(CheckStep(id: .permission, status: .failed, grade: "Not allowed",
                                  detail: "Tessera needs Local Network access to reach the wall.", cause: .denied))
            stopped = true
        case .ready(let remote):
            // Judged on the number the connection reached: a name outside
            // .local can still lead to the home network.
            rows.append(permissionPassed(host, remote: remote))
        case .refused:
            rows.append(permissionPassed(host, remote: nil))
        case .notFound, .timedOut, .failed:
            // A lookup that failed or a connection that went unanswered does
            // not say whether access was the reason. Off the home network
            // the question does not arise.
            rows.append(needsPermission ? permissionUnknown(reach, numeric: numeric) : permissionPassed(host, remote: nil))
        }
        if stopped || running == .address {
            return rows + [pending(.address), pending(.wall)]
        }
        switch reach {
        case .ready(let remote):
            rows.append(addressFound(host: host, remote: remote))
        case .refused:
            rows.append(addressFound(host: host, remote: nil))
        case .notFound, .timedOut, .failed, .denied:
            rows.append(addressFailed(reach, host: host, port: port, numeric: numeric, knownName: knownName))
            stopped = true
            return rows + [pending(.wall)]
        }

        // 04 The wall
        if reach == .refused {
            rows.append(CheckStep(id: .wall, status: .failed, grade: "Not running",
                                  detail: "Something is at this address, but Tessera is not running on port \(port). It may still be starting.",
                                  cause: .notRunning))
        } else if let wall {
            var remote: String? = nil
            if case .ready(let found) = reach { remote = found }
            rows.append(wallStep(wall, port: port, remote: remote, knownName: knownName))
        } else {
            rows.append(pending(.wall))
        }
        return rows
    }

    /// The line above the rows. `live` is the session's own link: a check
    /// that stops while polling still reaches the wall says so, so a failed
    /// step never sits beside "Connected" unexplained.
    static func summary(_ steps: [CheckStep], ran: Bool, live: Bool = false) -> String {
        if let running = steps.first(where: { $0.status == .running }) {
            return "Checking step \(running.position) of 4\u{2026}"
        }
        guard ran else { return "What Tessera knows now. The check tests each step in turn." }
        if steps.contains(where: { $0.status == .waiting }) {
            return "Checking step \((steps.first { $0.status == .waiting }?.position) ?? 1) of 4\u{2026}"
        }
        if let failed = steps.first(where: { $0.status == .failed }) {
            let stopped = "Stopped at step \(failed.position)."
            guard live else { return stopped }
            // Only a failure a second try can clear was brief. Another
            // device answering, or a blocked name, is not a blip.
            if failed.cause?.isBrief ?? true {
                return stopped + " Tessera is still reaching the wall, so this may have been brief."
            }
            return stopped + " Tessera\u{2019}s regular connection still reaches a Tessera wall at this address. Check again."
        }
        if steps.contains(where: { $0.status == .notChecked }) {
            let first = steps.first { $0.status == .notChecked }?.position ?? 1
            return "Check stopped before step \(first)."
        }
        if let note = steps.first(where: { $0.status == .attention }) {
            return "The wall responded. Step \(note.position) has a note."
        }
        return "All four steps passed."
    }

    /// The wall answered as Tessera: the check reached it, whatever the notes.
    static func reachedWall(_ steps: [CheckStep]) -> Bool {
        guard let last = steps.last, last.id == .wall else { return false }
        return (last.status == .passed || last.status == .attention)
            && !steps.contains { $0.status == .failed || $0.status == .running || $0.status == .waiting }
    }

    /// True when a check has failed a step.
    static func failed(_ steps: [CheckStep]) -> Bool {
        steps.contains { $0.status == .failed }
    }

    /// Whether the name WallSession remembers came from the address in use.
    /// The session keeps the name of whichever wall answered last, and a new
    /// address has no name of its own until it answers. `history` is newest
    /// first: an answer since the last address change means the name
    /// belongs to this address. With no answer on record it may not.
    static func nameIsCurrent(_ history: [LinkEvent]) -> Bool {
        for event in history {
            switch event.kind {
            case .responding, .respondingAgain: return true
            case .address: return false
            default: continue
            }
        }
        return false
    }

    // MARK: Rows

    /// What a running row is doing, so its detail does not repeat the grade.
    private static func runningDetail(_ kind: CheckStep.Kind) -> String {
        switch kind {
        case .phone: "Reading this phone\u{2019}s network."
        case .permission: "Opening a connection to the wall."
        case .address: "Reading where the address leads."
        case .wall: "Asking the wall for its state."
        }
    }

    private static func phoneStep(_ network: NetworkReading?) -> CheckStep? {
        guard let network else { return nil }
        let now = "This phone\u{2019}s connection right now."
        switch network {
        case .wifi: return CheckStep(id: .phone, status: .passed, grade: "On Wi-Fi", detail: now)
        case .wired: return CheckStep(id: .phone, status: .passed, grade: "Wired", detail: now)
        case .other: return CheckStep(id: .phone, status: .passed, grade: "Connected", detail: now)
        case .cellular:
            return CheckStep(id: .phone, status: .attention, grade: "On mobile data",
                             detail: "The wall is usually only reachable on your home Wi-Fi.")
        case .disconnected:
            return CheckStep(id: .phone, status: .failed, grade: "No network", detail: "Turn on Wi-Fi, then check again.",
                             cause: .noNetwork)
        }
    }

    /// Row 02 once a connection opened or was refused. `remote` is the
    /// number it reached: album-matrix.lan at 192.168.1.40 is on the home
    /// network, whatever its name says.
    private static func permissionPassed(_ host: String, remote: String?) -> CheckStep {
        // A numbered address is judged on itself: it reaches only that
        // number. The resolved remote matters only for a name.
        let reached = WallAddressInput.isNumeric(host) ? host : (remote.flatMap { $0.isEmpty ? nil : $0 } ?? host)
        if WallAddressInput.isLoopback(reached) {
            return CheckStep(id: .permission, status: .passed, grade: "Not needed", detail: "This address is on this device.")
        }
        if !WallAddressInput.isLocal(reached) {
            return CheckStep(id: .permission, status: .passed, grade: "Not needed",
                             detail: "This address is outside your local network.")
        }
        return CheckStep(id: .permission, status: .passed, grade: "Allowed", detail: "The wall is reachable on this network.")
    }

    /// Row 02 when nothing answered on the home network: access may or may
    /// not be the reason, and the row says why it cannot tell.
    private static func permissionUnknown(_ reach: ReachReading, numeric: Bool) -> CheckStep {
        let why = switch reach {
        case .notFound: numeric ? "Nothing replied" : "The name was not found"
        case .timedOut: "Nothing replied"
        default: "The connection failed"
        }
        return CheckStep(id: .permission, status: .unknown, grade: "Could not tell",
                         detail: "\(why), so access could not be confirmed.")
    }

    private static func addressFound(host: String, remote: String?) -> CheckStep {
        if WallAddressInput.isNumeric(host) {
            return CheckStep(id: .address, status: .passed, grade: host, detail: "A number, so no lookup was needed.")
        }
        guard let remote, !remote.isEmpty else {
            return CheckStep(id: .address, status: .passed, grade: "Found", detail: "The name \(host) was found on this network.")
        }
        let whereFound = WallAddressInput.isLocal(remote) || WallAddressInput.isLoopback(remote) ? " on this network" : ""
        return CheckStep(id: .address, status: .passed, grade: "Found at \(remote)",
                         detail: "The name \(host) was found\(whereFound).")
    }

    private static func addressFailed(_ reach: ReachReading, host: String, port: Int,
                                      numeric: Bool, knownName: String?) -> CheckStep {
        if reach == .failed {
            return CheckStep(id: .address, status: .failed, grade: "No connection",
                             detail: "The connection to \(host) could not be opened.", cause: .noConnection)
        }
        // This device's own address: no network, no Wi-Fi and no lookup are
        // involved, and its number never changes, so there is no name to offer.
        if WallAddressInput.isLoopback(host) {
            return CheckStep(id: .address, status: .failed, grade: "No reply", detail: "Nothing responded at \(host).",
                             cause: .noReplyHere)
        }
        // A number needs no lookup, so it is never "not found".
        if numeric {
            var detail = "Nothing responded at \(host). The number may have changed."
            var suggestion: String? = nil
            if let knownName, let candidate = WallAddressInput.named(knownName, port: port) {
                detail += " Try \(candidate)."
                suggestion = candidate
            }
            return CheckStep(id: .address, status: .failed, grade: "No reply", detail: detail, suggestion: suggestion,
                             cause: .noReply)
        }
        return CheckStep(id: .address, status: .failed, grade: "Not found",
                         detail: "Nothing on this network responds to \(host). Check the wall has power and is on the same Wi-Fi.",
                         cause: .nameNotFound)
    }

    private static func wallStep(_ wall: WallReading, port: Int, remote: String?, knownName: String?) -> CheckStep {
        switch wall {
        case .tessera(let ms, _):
            let grade = LatencyGrade(ms: ms)
            return CheckStep(id: .wall, status: grade == .slow ? .attention : .passed, grade: LatencyGrade.label(ms: ms),
                             detail: grade == .slow ? "Tessera is running on the wall. Controls may feel late." : "Tessera is running on the wall.")
        case .notTessera:
            return CheckStep(id: .wall, status: .failed, grade: "Not a Tessera wall",
                             detail: "Something responded, but it is not a Tessera wall. Check the address.", cause: .notTessera)
        case .http(let code):
            return CheckStep(id: .wall, status: .failed, grade: "Error \(code)",
                             detail: "The wall reported a problem. Try again in a minute.", cause: .httpError)
        case .blocked:
            // An address iPhone allows: the wall's name, when it answered to
            // one, or the number row 03 found.
            let candidate = knownName.flatMap { WallAddressInput.named($0, port: port) }
                ?? remote.flatMap { found -> String? in
                    guard WallAddressInput.isNumeric(found) else { return nil }
                    return WallAddressInput.normalize(found.contains(":") ? "[\(found)]:\(port)" : "\(found):\(port)")
                }
            var detail = "iPhone only allows this kind of connection to .local names and numbers."
            if let candidate { detail += " Try \(candidate)." }
            return CheckStep(id: .wall, status: .failed, grade: "Blocked", detail: detail, suggestion: candidate, cause: .blocked)
        case .timedOut:
            return CheckStep(id: .wall, status: .failed, grade: "No response",
                             detail: "The wall did not respond within 4 seconds.", cause: .noResponse)
        case .failed:
            return CheckStep(id: .wall, status: .failed, grade: "No response",
                             detail: "The connection closed before the wall answered.", cause: .noResponse)
        }
    }

    // MARK: Time words

    /// "9:41 AM" today, "Sep 26, 9:41 AM" on an earlier day, in the phone's
    /// own 12 or 24 hour style.
    static func clock(_ date: Date, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let template = calendar.isDate(date, inSameDayAs: now) ? "jmm" : "MMMdjmm"
        return FormatterShelf.shared.date(template, locale: locale, timeZone: timeZone).string(from: date)
    }

    /// The day part alone ("Sep 26"), for a time column that puts the day
    /// above the time. Nil today.
    static func day(_ date: Date, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard !calendar.isDate(date, inSameDayAs: now) else { return nil }
        return FormatterShelf.shared.date("MMMd", locale: locale, timeZone: timeZone).string(from: date)
    }

    /// The Recent list's time column: the time today, the day alone before
    /// ("Sep 26"), so one earlier event does not widen the column for every
    /// row. VoiceOver hears the full clock.
    static func column(_ date: Date, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        day(date, now: now, locale: locale, timeZone: timeZone) ?? time(date, locale: locale, timeZone: timeZone)
    }

    /// The time alone ("9:41 AM").
    static func time(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        FormatterShelf.shared.date("jmm", locale: locale, timeZone: timeZone).string(from: date)
    }

    /// "1 hour", "2 hours", "3 days": how long something has lasted.
    static func duration(_ seconds: TimeInterval, locale: Locale = .current) -> String {
        FormatterShelf.shared.duration(locale: locale).string(from: max(60, seconds)) ?? ""
    }

    /// "just now" under a minute, then "12 minutes ago", "yesterday".
    static func relative(_ date: Date, now: Date = Date(), locale: Locale = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 60 else { return "just now" }
        return FormatterShelf.shared.relative(locale: locale).localizedString(for: date, relativeTo: now)
    }
}

/// Formatters, made once for each template, locale and time zone. Making one
/// costs about 80 microseconds, and the page draws up to 30 recent rows with
/// three times each whenever it redraws. Formatting with a kept DateFormatter
/// is thread safe, so only the shelf itself needs the lock.
private final class FormatterShelf: @unchecked Sendable {
    static let shared = FormatterShelf()
    private let lock = NSLock()
    private var dates: [String: DateFormatter] = [:]
    private var relatives: [String: RelativeDateTimeFormatter] = [:]
    private var durations: [String: DateComponentsFormatter] = [:]

    /// The hour cycle is part of the key: the owner can switch to 24 hour
    /// time while Tessera runs, and the locale's identifier stays the same.
    private func key(_ locale: Locale) -> String { "\(locale.identifier)|\(locale.hourCycle)" }

    func date(_ template: String, locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let key = "\(template)|\(key(locale))|\(timeZone.identifier)"
        lock.lock(); defer { lock.unlock() }
        if let kept = dates[key] { return kept }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        dates[key] = formatter
        return formatter
    }

    func duration(locale: Locale) -> DateComponentsFormatter {
        let key = key(locale)
        lock.lock(); defer { lock.unlock() }
        if let kept = durations[key] { return kept }
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 1
        durations[key] = formatter
        return formatter
    }

    func relative(locale: Locale) -> RelativeDateTimeFormatter {
        let key = key(locale)
        lock.lock(); defer { lock.unlock() }
        if let kept = relatives[key] { return kept }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        relatives[key] = formatter
        return formatter
    }
}

// MARK: - The page's words

/// The hero: one headline and one status line per state.
enum ConnectionWords {
    /// `problem` is the last failure. A wall that answered with an error, or
    /// an address where something else answers, is not called offline.
    static func headline(_ link: LinkKind, problem: LinkProblem? = nil) -> String {
        switch (link, problem) {
        // Something at the address answered, so it is not offline: the
        // reason line under it says what came back.
        case (.offline, .httpError?), (.noWallFound, .httpError?),
             (.offline, .refused?), (.noWallFound, .refused?): return "Wall not ready"
        case (.offline, .notTessera?), (.noWallFound, .notTessera?): return "No wall at this address"
        default: break
        }
        return switch link {
        case .live: "Connected"
        case .searching: "Looking for your wall"
        case .offline: "Wall offline"
        case .noWallFound: "No wall found"
        case .phoneOnly: "Using this phone"
        }
    }

    /// Offline, the time of the last good response under an hour ("No
    /// response since 8:04 PM"), then how long it has been ("No response for
    /// 2 hours"). Never "just now" beside a headline that says offline.
    static func status(_ link: LinkKind, host: String, problem: LinkProblem? = nil, now: Date = Date(),
                       locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        switch link {
        case .live(let off):
            off ? "Responding at \(host). The lights are off." : "Responding at \(host)"
        case .searching:
            "Trying \(host)"
        case .offline(let since):
            offlineStatus(since: since, problem: problem, now: now, locale: locale, timeZone: timeZone)
        case .noWallFound:
            "Showing a preview on this phone. Tessera keeps checking for the wall in the background."
        case .phoneOnly:
            "Tessera is not contacting the wall. Changes apply only to the preview on this phone."
        }
    }

    private static func offlineStatus(since: Date, problem: LinkProblem?, now: Date, locale: Locale, timeZone: TimeZone) -> String {
        let lead = switch problem {
        case .httpError?, .refused?: "No normal response"
        case .notTessera?: "No response from the wall"
        default: "No response"
        }
        let gap = now.timeIntervalSince(since)
        guard gap >= 3600 else {
            return "\(lead) since \(ConnectionCheck.clock(since, now: now, locale: locale, timeZone: timeZone))"
        }
        return "\(lead) for \(ConnectionCheck.duration(gap, locale: locale))"
    }

    /// Shown under the status only where it explains the state: offline, and
    /// the stand-in that took over because no wall answered. This phone only
    /// never asks, so an old reason there would read as the cause.
    static func showsReason(_ link: LinkKind) -> Bool {
        switch link {
        case .offline, .noWallFound: true
        default: false
        }
    }

    /// Under the wall's picture: whose frame it is. A phone-drawn face while
    /// the wall is away is a preview, not the wall's last frame.
    static func caption(_ link: LinkKind, frameFromPhone: Bool, mode: String) -> String {
        switch link {
        case .live: return mode == "off" ? "LIGHTS OFF" : "LIVE"
        case .noWallFound, .phoneOnly: return "PREVIEW"
        case .offline, .searching:
            let drawnHere = ["ambient", "ticker", "timer", "cd", "nine", "lyrics"].contains(mode)
            if frameFromPhone { return "PREVIEW" }
            if case .offline = link, drawnHere { return "PREVIEW" }
            return "LAST FRAME"
        }
    }

    /// The action under the hero and its footnote.
    static func primary(_ link: LinkKind) -> String {
        switch link {
        case .live: "Check the connection"
        case .searching: "Looking\u{2026}"
        case .offline, .noWallFound: "Look for the wall again"
        case .phoneOnly: "Connect to the wall"
        }
    }

    static func footnote(_ link: LinkKind) -> String {
        switch link {
        case .live: "The check only reads from the wall. Nothing on the wall changes."
        case .searching: "Tessera is asking the wall for its state."
        case .offline: "Tessera keeps trying on its own. The check shows where the connection stops."
        // The status line above already says Tessera keeps checking.
        case .noWallFound: "The check shows where the connection stops."
        // Under "Check each step": the check leaves this phone in charge.
        case .phoneOnly: "The check only reads from the wall. Changes stay on this phone until you connect."
        }
    }

    /// Under "Waiting to send", once for every row.
    static func waitingNote(_ link: LinkKind) -> String {
        switch link {
        case .live: "Send now to try again."
        case .phoneOnly: "Sends when you connect to the wall."
        case .searching, .offline, .noWallFound: "Sends as soon as the wall responds."
        }
    }

    /// "Your Mac", in the order its facts decide it.
    static func macDetail(live: Bool, loaded: Bool, available: Bool, endpoint: String?, answering: Bool?) -> String {
        guard live else { return "Unknown until the wall responds" }
        guard loaded else { return "Checking\u{2026}" }
        guard available else { return "Not available on this wall" }
        guard let endpoint, !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Not connected" }
        switch answering {
        case true?: return "Connected"
        case false?: return "Not responding"
        case nil: return "Address saved, not checked yet"
        }
    }

    /// The glow's holder, when another screen's display holds the wall.
    static func occupant(_ purpose: String) -> String {
        switch purpose {
        case "calibration": "True colour is measuring the wall."
        case "guests": "A guest code is on the wall."
        case "panel": "A panel check is on the wall."
        case "onboarding": "Setup is showing a glow on the wall."
        case "identify": "Another glow is on the wall."
        case "tuning": "Panel tuning is showing a test pattern."
        default: "Another screen is using the wall."
        }
    }

    /// A run of copy, or one wall address from it.
    struct Piece: Equatable {
        var text: String
        var isAddress: Bool
    }

    /// A sentence cut where it holds a wall address. An address has no
    /// spaces to wrap at, so at accessibility sizes a Text wider than its
    /// line breaks it letter by letter. The page gives each address piece a
    /// line of its own that shrinks to fit, and the words around it wrap as
    /// usual. Punctuation stays with the word it follows.
    static func addressPieces(_ sentence: String) -> [Piece] {
        var pieces: [Piece] = []
        var words: [Substring] = []
        func flush() {
            guard !words.isEmpty else { return }
            pieces.append(Piece(text: words.joined(separator: " "), isAddress: false))
            words = []
        }
        for word in sentence.split(separator: " ") {
            if isAddress(word) {
                flush()
                pieces.append(Piece(text: String(word), isAddress: true))
            } else {
                words.append(word)
            }
        }
        flush()
        return pieces
    }

    /// The same copy with a word joiner (U+2060) after every hyphen, so a line
    /// never breaks inside a name like album-matrix.local or at "Wi-Fi". The
    /// joiner is invisible and needs no glyph. Switzer has no non-breaking
    /// hyphen (U+2011), which would fall back to another face.
    static func unbreakable(_ text: String) -> String {
        text.replacingOccurrences(of: "-", with: "-\u{2060}")
    }

    /// "album-matrix.local:8788." and "192.168.1.40" are addresses. "Wi-Fi.",
    /// "9:41", "1.9" and ".local" are not: a word needs a dot or a colon and
    /// must read as a whole address once its punctuation is set aside.
    static func isAddress(_ word: Substring) -> Bool {
        let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,:()"))
        guard bare.contains(".") || bare.contains(":") else { return false }
        return WallAddressInput.normalize(bare) != nil
    }
}

/// "What to try" when the wall is away, led by what the last failure says.
enum ConnectionAdvice {
    struct Step: Equatable {
        var symbol: String
        var title: String
        var detail: String
    }

    static let power = Step(symbol: "powerplug", title: "Power",
                            detail: "Check that the wall is plugged in and switched on.")
    static let wifi = Step(symbol: "wifi", title: "Same Wi-Fi",
                           detail: "Join this phone to the Wi-Fi the wall uses. Guest networks often keep devices apart.")
    static let minute = Step(symbol: "clock", title: "Give it a minute",
                             detail: "After a power cut or a restart, the wall can take a minute or two to come back.")
    static let restart = Step(symbol: "arrow.clockwise", title: "Restart the wall",
                              detail: "Unplug the wall for ten seconds, then plug it back in.")
    static let permission = Step(symbol: "lock.shield", title: "Local Network access",
                                 detail: "In iPhone Settings, under Tessera, turn on Local Network.")
    static let address = Step(symbol: "character.cursor.ibeam", title: "Change the address",
                              detail: "Use a name ending in .local or the wall\u{2019}s number, under Wall address.")

    /// From the session's last failure, before any check.
    static func steps(for problem: LinkProblem?) -> [Step] {
        switch problem {
        // Something answered at the address: Tessera is starting or stopped.
        // The phone reaches it, so Wi-Fi advice would be wrong.
        case .refused?: [minute, restart]
        // The wall answered with an error: it is on and on the network.
        case .httpError?: [minute, restart]
        // Something else answers at the address: the wall may have a new one.
        case .notTessera?: [address, power, wifi]
        case .noPath?: [wifi, permission, power]
        // The wall took the connection and closed it: it is on the network,
        // and may be restarting.
        case .dropped?: [minute, restart]
        case .blockedName?: [address, power, wifi]
        default: [power, wifi, minute]
        }
    }

    /// From the step a check stopped at, which knows more than the last
    /// failure: denied access leads with Local Network, a reply leaves out
    /// Wi-Fi, and this device's own address needs neither power nor Wi-Fi.
    static func steps(for cause: CheckStep.Cause) -> [Step] {
        switch cause {
        case .noNetwork: [wifi, power, minute]
        case .denied: [permission, wifi, power]
        case .nameNotFound: [power, wifi, minute]
        // A number that stopped answering may have changed.
        case .noReply: [power, address, wifi]
        case .noReplyHere: [minute, address]
        case .noConnection: [wifi, power, minute]
        case .notRunning, .httpError, .noResponse: [minute, restart]
        case .notTessera: [address, power]
        case .blocked: [address]
        }
    }

    /// The list the page shows: a finished check's failed step first, else
    /// the session's last failure.
    static func steps(for problem: LinkProblem?, check: [CheckStep]?) -> [Step] {
        if let cause = check?.first(where: { $0.status == .failed })?.cause { return steps(for: cause) }
        return steps(for: problem)
    }
}
