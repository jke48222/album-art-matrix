// The connection check's measurements, and the run that ticks through them.
//
// Read only by design. The check sends three things: a read of this phone's
// network path, one TCP connect to the wall's address with no payload, and
// one GET /state. It never writes to the wall and never asks for /health,
// which runs vcgencmd on the Pi. It uses its own path monitor, connection and
// URLSession, not WallSession's, so it works in every link state, this phone
// only included, and cannot disturb the session's polling.

import Foundation
import Network
import SwiftUI

protocol ConnectionProbing: Sendable {
    func network() async -> NetworkReading
    func reach(host: String, port: Int, timeout: Duration) async -> ReachReading
    func ask(hostPort: String, timeout: Duration) async -> WallReading
}

/// Resumes a continuation exactly once, whichever of the connection's
/// callbacks, the timeout or a cancel gets there first.
private final class Once<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }

    func resume(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// Holds a connection or monitor for a cancel handler that may run on any
/// thread, before or after the operation has created it.
private final class Holder<Object: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private var object: Object?
    private var cancelled = false

    /// False when a cancel already came, so the caller stops at once.
    func set(_ value: Object) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        object = value
        return true
    }

    func cancel(_ body: (Object) -> Void) {
        lock.lock()
        cancelled = true
        let held = object
        lock.unlock()
        if let held { body(held) }
    }
}

struct LiveProbe: ConnectionProbing {
    /// This phone's path right now, from a one-shot path monitor.
    func network() async -> NetworkReading {
        let holder = Holder<NWPathMonitor>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<NetworkReading, Never>) in
                let once = Once(continuation)
                let monitor = NWPathMonitor()
                let queue = DispatchQueue(label: "tessera.connection.path")
                guard holder.set(monitor) else { once.resume(.other); return }
                monitor.pathUpdateHandler = { path in
                    once.resume(Self.reading(path))
                    monitor.cancel()
                }
                monitor.start(queue: queue)
                // The first update arrives at once. Should it not, the phone
                // is not asserted to be offline: the next steps say more.
                queue.asyncAfter(deadline: .now() + 2) {
                    once.resume(.other)
                    monitor.cancel()
                }
            }
        } onCancel: {
            holder.cancel { $0.cancel() }
        }
    }

    static func reading(_ path: NWPath) -> NetworkReading {
        guard path.status == .satisfied else { return .disconnected }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        if path.usesInterfaceType(.cellular) { return .cellular }
        return .other
    }

    /// One TCP connect to host:port, nothing sent. Waiting and failed are read
    /// the same way: NWConnection reports a refused port or a failed lookup
    /// as waiting, and only reading failed would sit out the whole timeout.
    func reach(host: String, port: Int, timeout: Duration) async -> ReachReading {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return .failed }
        let holder = Holder<NWConnection>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ReachReading, Never>) in
                let once = Once(continuation)
                let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
                let queue = DispatchQueue(label: "tessera.connection.reach")
                guard holder.set(connection) else { once.resume(.failed); return }
                @Sendable func finish(_ reading: ReachReading) {
                    once.resume(reading)
                    connection.cancel()
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        finish(.ready(remote: Self.remote(connection.currentPath?.remoteEndpoint)))
                    case .waiting(let error), .failed(let error):
                        finish(Self.reading(error, path: connection.currentPath))
                    case .cancelled:
                        once.resume(.failed)
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                queue.asyncAfter(deadline: .now() + seconds) { finish(.timedOut) }
            }
        } onCancel: {
            holder.cancel { $0.cancel() }
        }
    }

    /// The rule itself is ReachReading.failure, in ConnectionModels.swift,
    /// where scripts/test_connection_models.py checks it. This only takes the
    /// NWError apart.
    static func reading(_ error: NWError, path: NWPath?) -> ReachReading {
        let denied = path?.unsatisfiedReason == .localNetworkDenied
        switch error {
        case .dns(let code): return .failure(localNetworkDenied: denied, dns: code)
        case .posix(let code): return .failure(localNetworkDenied: denied, posix: code)
        default: return .failure(localNetworkDenied: denied)
        }
    }

    /// The number the connection reached, without an IPv6 %scope suffix,
    /// which is for this phone's routing and never part of an address.
    static func remote(_ endpoint: NWEndpoint?) -> String? {
        guard case .hostPort(let host, _)? = endpoint else { return nil }
        let text: String
        switch host {
        case .ipv4(let address): text = "\(address)"
        case .ipv6(let address): text = "\(address)"
        case .name(let name, _): text = name
        @unknown default: return nil
        }
        return text.split(separator: "%").first.map(String.init)
    }

    /// One GET /state, timed. The header lets a test fixture tell the
    /// check's read from the session's polling. The brain ignores it.
    func ask(hostPort: String, timeout: Duration) async -> WallReading {
        guard let url = URL(string: "http://\(hostPort)/state") else { return .failed }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = seconds
        configuration.timeoutIntervalForResource = seconds + 1
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("1", forHTTPHeaderField: "X-Tessera-Check")
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let (data, response) = try await session.data(for: request)
            let elapsed = clock.now - start
            let ms = Int((Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15).rounded())
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return .http(status) }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["mode"] is String else { return .notTessera }
            let name = ((json["wall"] as? [String: Any])?["name"] as? String)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
            return .tessera(ms: max(1, ms), name: name)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: return .timedOut
            case .appTransportSecurityRequiresSecureConnection: return .blocked
            default: return .failed
            }
        } catch {
            return .failed
        }
    }
}

extension LiveProbe {
    /// Whose temporary display holds the wall, from one GET
    /// /display-session: its purpose, "" when nothing holds it, nil when
    /// the read failed. Read only, like the check.
    static func displayHolder(hostPort: String) async -> String? {
        guard let url = URL(string: "http://\(hostPort)/display-session") else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 4
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let active = json["active"] as? Bool else { return nil }
        guard active else { return "" }
        return (json["purpose"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "check"
    }
}

/// This phone's network path, kept current while the page is open, for
/// row 01 before any check has run.
@MainActor @Observable final class NetworkWatcher {
    private(set) var reading: NetworkReading? = nil
    @ObservationIgnored private var monitor: NWPathMonitor?

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let reading = LiveProbe.reading(path)
            Task { @MainActor in self?.reading = reading }
        }
        monitor.start(queue: DispatchQueue(label: "tessera.connection.watch"))
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }
}

/// One run of the four-step check. Each row shows as running, then its
/// result, for at least 250 ms, so the ticks read one by one rather than
/// all landing in the same frame on a fast network.
@MainActor @Observable final class ConnectionCheckRun {
    private(set) var steps: [CheckStep] = []
    private(set) var running = false
    private(set) var finishedAt: Date? = nil
    /// The number row 03 reached, for the "Network address" fact.
    private(set) var remote: String? = nil
    private(set) var latencyMS: Int? = nil
    private(set) var wallName: String? = nil
    /// The address this run checked.
    private(set) var hostPort: String? = nil
    @ObservationIgnored private var task: Task<Void, Never>? = nil
    @ObservationIgnored private var generation = 0

    /// Whether the app's own session still reaches the wall, read when the
    /// run ends, so the spoken summary is the line the page shows.
    @ObservationIgnored private var isLive: @MainActor () -> Bool = { false }

    var hasResult: Bool { !steps.isEmpty }
    var summary: String { ConnectionCheck.summary(steps, ran: true, live: isLive()) }

    func start(hostPort: String, knownName: String?, probe: any ConnectionProbing,
               live: @escaping @MainActor () -> Bool = { false }) {
        cancel()
        clear()
        generation += 1
        let run = generation
        self.hostPort = hostPort
        isLive = live
        running = true
        let parts = WallAddressInput.split(hostPort)
        let host = parts?.host ?? LinkProblem.hostname(hostPort)
        let port = parts?.port ?? WallAddressInput.defaultPort
        task = Task { @MainActor [weak self] in
            await self?.walk(run: run, hostPort: hostPort, host: host, port: port, knownName: knownName, probe: probe)
        }
    }

    // The readings so far, for publish().
    @ObservationIgnored private var network: NetworkReading? = nil
    @ObservationIgnored private var reach: ReachReading? = nil
    @ObservationIgnored private var wallReading: WallReading? = nil
    @ObservationIgnored private var knownName: String? = nil

    private func walk(run: Int, hostPort: String, host: String, port: Int, knownName: String?,
                      probe: any ConnectionProbing) async {
        self.knownName = knownName
        guard let n = await measured(.phone, run: run, { await probe.network() }) else { return }
        network = n
        if n != .disconnected {
            guard let r = await measured(.permission, run: run, {
                await probe.reach(host: host, port: port, timeout: .seconds(5))
            }) else { return }
            reach = r
            // The same connection answered row 03, which gets its own beat.
            guard await measured(.address, run: run, { () }) != nil else { return }
            if case .ready(let found) = r {
                remote = found
                guard let w = await measured(.wall, run: run, {
                    await probe.ask(hostPort: hostPort, timeout: .seconds(4))
                }) else { return }
                wallReading = w
                if case .tessera(let ms, let name) = w {
                    latencyMS = ms
                    wallName = name
                }
            }
        }
        publish(nil, run: run)
        finish()
    }

    private func publish(_ current: CheckStep.Kind?, run: Int) {
        guard run == generation, let hostPort else { return }
        withAnimation(Motion.settle) {
            steps = ConnectionCheck.steps(hostPort: hostPort, network: network, reach: reach,
                                          wall: wallReading, knownName: knownName, running: current)
        }
    }

    /// A step's reading, shown as running for at least 250 ms. Nil when the
    /// run was stopped or replaced meanwhile.
    private func measured<T: Sendable>(_ kind: CheckStep.Kind, run: Int, _ read: () async -> T) async -> T? {
        publish(kind, run: run)
        let started = ContinuousClock.now
        let value = await read()
        let rest = Duration.milliseconds(250) - (ContinuousClock.now - started)
        if rest > .zero { try? await Task.sleep(for: rest) }
        return Task.isCancelled || run != generation ? nil : value
    }

    private func finish() {
        running = false
        finishedAt = Date()
        task = nil
        if ConnectionCheck.failed(steps) { Taps.error() } else { Taps.commit() }
        AccessibilityNotification.Announcement(summary).post()
    }

    /// Stop a run in progress. Rows that had not finished say so.
    func cancel() {
        guard running else { return }
        generation += 1
        task?.cancel()
        task = nil
        running = false
        steps = steps.map { step in
            guard step.status == .running || step.status == .waiting else { return step }
            var stopped = step
            stopped.status = .notChecked
            stopped.grade = "Not checked"
            stopped.detail = "The check was stopped."
            return stopped
        }
    }

    /// Forget the last run: the address or the link changed under it.
    func clear() {
        guard !running else { return }
        steps = []
        finishedAt = nil
        remote = nil
        latencyMS = nil
        wallName = nil
        hostPort = nil
        network = nil
        reach = nil
        wallReading = nil
    }
}

#if DEBUG
/// Fixed readings for captures and UI tests. The simulator never raises the
/// Local Network prompt, so denial can only be shown this way.
///
/// The readings are fixed, but the page around them is live, so a capture
/// pairs each scenario with a link that agrees with it. Against a fixture
/// that answers, a failed step reads beside "Connected", and the summary then
/// says Tessera still reaches the wall. For a screen that agrees throughout:
/// denied with -seed-wall-host 192.168.1.40:8788, deniedName with
/// -seed-wall-host qa-wall.local:8788, blocked with -seed-wall-host
/// album-matrix.lan:8788, and noNetwork, notFound and refused with the
/// fixture unavailable (POST /qa/available {"enabled": false}) before launch.
/// At the fixture's own 127.0.0.1, notFound reads as this device not
/// replying, since a number needs no lookup. The name path ("Not found")
/// needs a name, such as -seed-wall-host qa-wall.local:8788. A name the page
/// offers must be one this address answered with, so numericGone and the
/// steadier-address capture seed it with -seed-wall-name beside the host.
struct ScriptedProbe: ConnectionProbing {
    let networkReading: NetworkReading
    let reachReading: ReachReading?
    let wallReading: WallReading

    init?(scenario: String) {
        let found = ReachReading.ready(remote: "192.168.1.40")
        let answer = WallReading.tessera(ms: 38, name: "qa-wall")
        switch scenario {
        case "passed": (networkReading, reachReading, wallReading) = (.wifi, found, answer)
        case "cellular": (networkReading, reachReading, wallReading) = (.cellular, found, answer)
        case "noNetwork": (networkReading, reachReading, wallReading) = (.disconnected, found, answer)
        // deniedName reads the same as denied: the model maps a .local name's
        // policy-denied lookup to denied. Its capture pairs it with
        // -seed-wall-host qa-wall.local:8788, so the rows show a name.
        case "denied", "deniedName": (networkReading, reachReading, wallReading) = (.wifi, .denied, answer)
        case "notFound": (networkReading, reachReading, wallReading) = (.wifi, .notFound, answer)
        case "numericGone": (networkReading, reachReading, wallReading) = (.wifi, .timedOut, answer)
        case "refused": (networkReading, reachReading, wallReading) = (.wifi, .refused, answer)
        // Row 03 "No connection": the connect failed for another reason.
        case "noConnection": (networkReading, reachReading, wallReading) = (.wifi, .failed, answer)
        case "notTessera": (networkReading, reachReading, wallReading) = (.wifi, found, .notTessera)
        case "http": (networkReading, reachReading, wallReading) = (.wifi, found, .http(503))
        case "blocked": (networkReading, reachReading, wallReading) = (.wifi, found, .blocked)
        // Row 04 "No response": the 4-second wait ran out, or the
        // connection closed before the wall answered.
        case "noResponse": (networkReading, reachReading, wallReading) = (.wifi, found, .timedOut)
        case "closed": (networkReading, reachReading, wallReading) = (.wifi, found, .failed)
        case "slow": (networkReading, reachReading, wallReading) = (.wifi, found, .tessera(ms: 1900, name: "qa-wall"))
        // Holds at step 2 until stopped, for the running capture.
        case "running": (networkReading, reachReading, wallReading) = (.wifi, nil, answer)
        default: return nil
        }
    }

    func network() async -> NetworkReading {
        try? await Task.sleep(for: .milliseconds(400))
        return networkReading
    }

    func reach(host: String, port: Int, timeout: Duration) async -> ReachReading {
        try? await Task.sleep(for: .milliseconds(400))
        guard let reachReading else {
            try? await Task.sleep(for: .seconds(3600))
            return .failed
        }
        return reachReading
    }

    func ask(hostPort: String, timeout: Duration) async -> WallReading {
        try? await Task.sleep(for: .milliseconds(400))
        return wallReading
    }
}
#endif
