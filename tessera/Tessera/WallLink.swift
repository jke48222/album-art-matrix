// The wall link: one protocol, transports behind it. LAN ships first; MQTT and
// BLE arrive later behind the same seam. The UI never speaks a transport, it
// speaks LinkState, and the state chip always tells the truth about which one
// is carrying.

import Foundation
import SwiftUI

// MARK: - Models

/// GET /state, decoded tolerantly: unknown keys ignored, missing keys defaulted,
/// so an older or newer brain never blanks the app.
struct WallState: Equatable {
    var mode: String = "art"          // art | cd | ambient | off | frame | ticker | clock | clip
    var brightness: Double = 1.0      // 0.05...1.0
    var rpm: Double = 7.5
    var effect: String = "rainbow"
    var finish: String = "clean"
    var matchArt: Bool = false
    var color: String = "#e8b04b"
    var title: String? = nil
    var artist: String? = nil
    var album: String? = nil
    var artColors: [String] = []
    var sleepRemaining: Int? = nil

    init() {}

    init(json: [String: Any]) {
        mode = json["mode"] as? String ?? "art"
        brightness = json["brightness"] as? Double ?? 1.0
        rpm = json["rpm"] as? Double ?? 7.5
        effect = json["effect"] as? String ?? "rainbow"
        finish = json["finish"] as? String ?? "clean"
        matchArt = json["match_art"] as? Bool ?? false
        color = json["color"] as? String ?? "#e8b04b"
        if let now = json["now_showing"] as? [String: Any] {
            title = now["title"] as? String
            artist = now["artist"] as? String
            album = now["album"] as? String
        }
        artColors = json["art_colors"] as? [String] ?? []
        sleepRemaining = json["sleep_remaining_s"] as? Int
    }
}

enum LinkState: Equatable {
    case searching
    case live                 // LAN, answering
    case offline(since: Date) // cached truth, stamped
    case standIn              // no wall anywhere; the app is running one

    var isLive: Bool { if case .live = self { true } else { false } }
    /// True when what is on screen is the app's own, not a wall's.
    var isStandIn: Bool { if case .standIn = self { true } else { false } }
}

// MARK: - Session

@MainActor
@Observable
final class WallSession {
    var state = WallState()
    var frame: Data? = nil            // 64*64*3 RGB888, pre-white-balance
    var link: LinkState = .searching
    var lastSync: Date? = nil
    /// What you asked for while the wall was not listening.
    let outbox = Outbox()

    /// A wall of our own, for when there is not one yet. Everything
    /// downstream takes frames and state without knowing the difference.
    @ObservationIgnored private let standIn = StandIn()
    @ObservationIgnored private var misses = 0

    // The simulator shares the Mac's network: localhost reaches a brain
    // running beside it. On device the wall's mDNS name is the default.
    #if targetEnvironment(simulator)
    @ObservationIgnored @AppStorage("wall.host") var host = "localhost:8788"
    #else
    @ObservationIgnored @AppStorage("wall.host") var host = "album-matrix.local:8788"
    #endif

    @ObservationIgnored private var pollTask: Task<Void, Never>? = nil
    @ObservationIgnored private var wasLive = false
    /// Keys written locally and not yet echoed back. A /state poll must not
    /// clobber them: the brain persists asynchronously, so between the tap and
    /// the next poll the wall can still be reporting the old value, and the
    /// control would visibly snap back. This is what made the lamp buttons
    /// look like they were fighting the finger.
    @ObservationIgnored private var pending: [String: Date] = [:]

    /// Hold a locally chosen value until the wall reports the same thing.
    private func keep<T: Equatable>(_ key: String, _ incoming: inout T, _ local: T) {
        guard holding(key) else { return }
        if incoming == local { pending.removeValue(forKey: key) } else { incoming = local }
    }

    private func keepNear(_ key: String, _ incoming: inout Double, _ local: Double, _ eps: Double) {
        guard holding(key) else { return }
        if abs(incoming - local) < eps { pending.removeValue(forKey: key) } else { incoming = local }
    }

    private func holding(_ key: String) -> Bool {
        guard let at = pending[key] else { return false }
        if Date().timeIntervalSince(at) > 4 {        // give up; trust the wall
            pending.removeValue(forKey: key)
            return false
        }
        return true
    }
    @ObservationIgnored private let http: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 5
        return URLSession(configuration: cfg)
    }()

    /// The frame is what changes; the settings are not. Poll them at
    /// different rates so the screen can answer the wall rather than a clock,
    /// and follow the frame harder when the wall is actually animating.
    ///
    /// The wall runs its animated modes at ~115 fps. The phone cannot and
    /// should not mirror that: each new frame costs a 4,096-emitter raster.
    /// 8 fps is enough for a spinning disc to read as spinning, and a static
    /// sleeve does not need even that.
    func start() {
        // A cold launch away from the wall should show the last wall we saw,
        // stamped, rather than a dark rectangle pretending to be the truth.
        if frame == nil {
            let cached = WallSnapshot.read()
            if let px = cached.px {
                frame = Data(px)
                state.title = cached.title
                state.artist = cached.artist
                state.mode = cached.mode
                link = .offline(since: cached.updated ?? Date())
            }
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if self.link.isStandIn {
                    self.tickStandIn()
                    tick &+= 1
                    try? await Task.sleep(for: .milliseconds(125))
                    continue
                }
                let animating = ["cd", "ambient", "ticker", "clip"].contains(self.state.mode)
                if tick % 16 == 0 { await self.pollState() }          // 2s
                if animating || tick % 2 == 0 { await self.pullFrame() }
                tick &+= 1
                try? await Task.sleep(for: .milliseconds(125))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func url(_ path: String) -> URL? { URL(string: "http://\(host)\(path)") }

    func poll() async { await pollState() }

    func pollState() async {
        guard let stateURL = url("/state") else { return }
        do {
            let (data, _) = try await http.data(from: stateURL)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw URLError(.cannotParseResponse)
            }
            let reconnected = !wasLive
            var fresh = WallState(json: json)

            // Anything still in flight keeps the value the finger chose, and
            // stops being held the moment the wall agrees.
            let mine = state
            keep("mode", &fresh.mode, mine.mode)
            keep("effect", &fresh.effect, mine.effect)
            keep("finish", &fresh.finish, mine.finish)
            keep("match_art", &fresh.matchArt, mine.matchArt)
            keepNear("rpm", &fresh.rpm, mine.rpm, 0.01)
            keepNear("brightness", &fresh.brightness, mine.brightness, 0.001)

            state = fresh
            lastSync = Date()
            if reconnected { Taps.found() }   // the lamp switched on
            wasLive = true
            link = .live
            if reconnected { flushOutbox() }
            WallSnapshot.write(px: frame.map { [UInt8]($0) }, title: state.title,
                               artist: state.artist, mode: state.mode, host: host)
        } catch {
            misses += 1
            // Three misses is about six seconds of asking. After that, stop
            // showing an empty room and run a wall instead. Anything the app
            // has genuinely seen before is still worth showing as offline.
            if lastSync == nil, misses >= 3 {
                enterStandIn()
            } else if wasLive || linkIsSearching {
                link = .offline(since: lastSync ?? Date())
            }
            wasLive = false
        }
    }

    // MARK: - Stand-in

    private func enterStandIn() {
        guard !link.isStandIn else { return }
        standIn.refreshNowPlaying()
        state = standIn.state
        link = .standIn
    }

    /// Leave the stand-in and go looking again. The next successful poll
    /// takes over completely.
    func lookForWallAgain() {
        misses = 0
        link = .searching
        Task { await pollState() }
    }

    private func tickStandIn() {
        standIn.refreshNowPlaying()
        var s = standIn.state
        s.brightness = state.brightness      // keep whatever the finger set
        standIn.apply(["brightness": s.brightness])
        state = s
        frame = standIn.frame()
    }

    private var linkIsSearching: Bool { if case .searching = link { true } else { false } }

    private func pullFrame() async {
        guard let frameURL = url("/frame.raw") else { return }
        if let (data, resp) = try? await http.data(from: frameURL),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           data.count == 64 * 64 * 3 {
            // Only publish when the bytes actually changed. Two identical
            // frames must leave the screen perfectly still.
            if data != frame { frame = data }
        }
    }

    /// Put a moving thing on the wall. The brain loops it until a mode
    /// change; up to 240 frames at up to 24 fps is its whole appetite.
    func pushClip(_ frames: [[UInt8]], fps: Double) {
        let valid = frames.filter { $0.count == 64 * 64 * 3 }.prefix(240)
        guard !valid.isEmpty,
              let u = url("/clip"),
              let body = try? JSONSerialization.data(withJSONObject: [
                  "fps": min(24, max(1, fps)),
                  "frames": valid.map { Data($0).base64EncodedString() },
              ]) else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        Task { [http] in
            if (try? await http.data(for: req)) == nil {
                await MainActor.run { Taps.error() }
            } else {
                await MainActor.run { Taps.landed() }
            }
        }
    }

    /// Wear a journal entry again. The wall pins it for ten minutes so the
    /// currently playing track does not immediately steamroll it.
    func replay(ts: Int) {
        guard let u = url("/replay"),
              let body = try? JSONSerialization.data(withJSONObject: ["ts": ts]) else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        Task { [http] in
            if let (_, resp) = try? await http.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                await MainActor.run { Taps.landed() }
            } else {
                await MainActor.run { Taps.error() }
            }
        }
    }

    /// Put a flat field on the wall for a panel check, through the brain's
    /// own /frame endpoint (base64 of 64*64*3 raw RGB, mode becomes "frame").
    func pushFlat(r: UInt8, g: UInt8, b: UInt8) {
        var px = [UInt8](repeating: 0, count: 64 * 64 * 3)
        for i in stride(from: 0, to: px.count, by: 3) {
            px[i] = r; px[i + 1] = g; px[i + 2] = b
        }
        pushFrame(px)
    }

    /// Put an exact 64x64 frame on the wall. What you drew is what it lights.
    func pushFrame(_ px: [UInt8]) {
        guard px.count == 64 * 64 * 3 else { return }
        if link.isStandIn {
            frame = Data(px)                 // it lands on the stand-in wall
            Taps.landed()
            return
        }
        guard let u = url("/frame"),
              let body = try? JSONSerialization.data(
                withJSONObject: ["px": Data(px).base64EncodedString()]
              ) else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        Task { [http, weak self] in
            if (try? await http.data(for: req)) == nil {
                await MainActor.run {
                    self?.outbox.add(frame: px)
                    Taps.error()
                }
            }
        }
    }

    /// POST a partial state patch. Optimistic locally, honest on failure:
    /// the next poll re-syncs whatever the wall actually accepted.
    func send(_ patch: [String: Any]) {
        // optimistic merge so controls answer instantly
        var merged = patch
        if let m = merged["mode"] as? String { state.mode = m }
        if let b = merged["brightness"] as? Double { state.brightness = b }
        if let r = merged["rpm"] as? Double { state.rpm = r }
        if let e = merged["effect"] as? String { state.effect = e }
        if let f = merged["finish"] as? String { state.finish = f }
        if let ma = merged["match_art"] as? Bool { state.matchArt = ma }
        merged.removeValue(forKey: "_local")
        for key in merged.keys { pending[key] = Date() }

        if link.isStandIn {
            standIn.apply(merged)
            state = standIn.state
            return
        }

        guard let u = url("/state"),
              let body = try? JSONSerialization.data(withJSONObject: merged) else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        Task { [http, weak self] in
            do {
                _ = try await http.data(for: req)
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    // Intent survives the network. It goes out when the wall
                    // answers again, and the UI says so in the meantime.
                    self.outbox.add(patch: merged)
                    Taps.error()
                }
            }
        }
    }

    /// Everything queued while the wall was away, in one pass, settings first
    /// so a frame is not immediately overwritten by a mode change.
    private func flushOutbox() {
        guard !outbox.isEmpty else { return }
        let patch = outbox.patch
        let frame = outbox.frame
        outbox.clear()
        if !patch.isEmpty { send(patch as [String: Any]) }
        if let frame { pushFrame(frame) }
        Taps.landed()
    }
}
