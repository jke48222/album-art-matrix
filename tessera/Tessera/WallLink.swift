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

    var isLive: Bool { if case .live = self { true } else { false } }
}

// MARK: - Session

@MainActor
@Observable
final class WallSession {
    var state = WallState()
    var frame: Data? = nil            // 64*64*3 RGB888, pre-white-balance
    var link: LinkState = .searching
    var lastSync: Date? = nil

    // The simulator shares the Mac's network: localhost reaches a brain
    // running beside it. On device the wall's mDNS name is the default.
    #if targetEnvironment(simulator)
    @ObservationIgnored @AppStorage("wall.host") var host = "localhost:8788"
    #else
    @ObservationIgnored @AppStorage("wall.host") var host = "album-matrix.local:8788"
    #endif

    @ObservationIgnored private var pollTask: Task<Void, Never>? = nil
    @ObservationIgnored private var wasLive = false
    @ObservationIgnored private let http: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 5
        return URLSession(configuration: cfg)
    }()

    /// The frame is what changes; the settings are not. Poll them at
    /// different rates so the screen can answer the wall rather than a clock.
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if tick % 8 == 0 { await self.pollState() }   // every 2s
                await self.pullFrame()                        // every 250ms
                tick &+= 1
                try? await Task.sleep(for: .milliseconds(250))
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
            state = WallState(json: json)
            lastSync = Date()
            if !wasLive { Taps.found() }   // the lamp switched on
            wasLive = true
            link = .live
        } catch {
            if wasLive || linkIsSearching {
                link = .offline(since: lastSync ?? Date())
            }
            wasLive = false
        }
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
        guard let u = url("/frame"),
              let body = try? JSONSerialization.data(
                withJSONObject: ["px": Data(px).base64EncodedString()]
              ) else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        Task { [http] in
            if (try? await http.data(for: req)) == nil {
                await MainActor.run { Taps.error() }
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

        guard let u = url("/state"),
              let body = try? JSONSerialization.data(withJSONObject: merged) else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        Task { [http] in
            do {
                _ = try await http.data(for: req)
            } catch {
                await MainActor.run { Taps.error() }
            }
        }
    }
}
