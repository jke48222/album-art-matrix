// Wall control client — talks to the brain's control API on the Pi
// (brain/control.py, port 8788). GET /state on appear and on a 5s poll,
// POST partial patches as controls change. The brain re-renders instantly
// (dirty event). Also: journal history, replays, and raw 64x64 frames
// (doodles, photos).
import Combine
import Foundation
import SwiftUI
import UIKit
import UserNotifications

struct WallState: Codable {
    var mode = "art"
    var brightness = 1.0
    var rpm = 7.5
    var effect = "rainbow"
    var color = "#4060ff"
    var color2 = "#ff2080"
    var speed = 1.0
    var match_art = false
    var finish = "clean"
    var ticker_text = "HELLO"
    var ticker_loop = true
    var clock_24h = true
    var now_showing: [String: String]? = nil
    var art_colors: [String]? = nil
    var sleep_remaining_s: Int? = nil

    init() {}

    /// Tolerant decode: a brain that predates newer keys (match_art, finish,
    /// …) still parses — the app degrades field by field, never to
    /// "unreachable".
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decode(String.self, forKey: .mode)) ?? "art"
        brightness = (try? c.decode(Double.self, forKey: .brightness)) ?? 1.0
        rpm = (try? c.decode(Double.self, forKey: .rpm)) ?? 7.5
        effect = (try? c.decode(String.self, forKey: .effect)) ?? "rainbow"
        color = (try? c.decode(String.self, forKey: .color)) ?? "#4060ff"
        color2 = (try? c.decode(String.self, forKey: .color2)) ?? "#ff2080"
        speed = (try? c.decode(Double.self, forKey: .speed)) ?? 1.0
        match_art = (try? c.decode(Bool.self, forKey: .match_art)) ?? false
        finish = (try? c.decode(String.self, forKey: .finish)) ?? "clean"
        ticker_text = (try? c.decode(String.self, forKey: .ticker_text)) ?? "HELLO"
        ticker_loop = (try? c.decode(Bool.self, forKey: .ticker_loop)) ?? true
        clock_24h = (try? c.decode(Bool.self, forKey: .clock_24h)) ?? true
        now_showing = try? c.decode([String: String].self, forKey: .now_showing)
        art_colors = try? c.decode([String].self, forKey: .art_colors)
        sleep_remaining_s = try? c.decode(Int.self, forKey: .sleep_remaining_s)
    }
}

struct JournalEntry: Codable, Identifiable {
    let ts: Int
    let title: String
    let artist: String
    let album: String?
    let art_url: String?
    var id: Int { ts }
}

private struct JournalResponse: Codable {
    let entries: [JournalEntry]
}

final class WallAPI: ObservableObject {
    @Published var state = WallState()
    @Published var reachable = false
    @Published var journal: [JournalEntry] = []
    @Published var lastSentFrame: UIImage? = nil   // what /frame last showed
    @Published var wallFrame: UIImage? = nil       // the wall's actual pixels

    @AppStorage("wallHost") var wallHost = "album-matrix.local:8788"

    private var pending: Task<Void, Never>?
    private var queued: [String: Any] = [:]
    private var poll: Timer?

    init() {
        poll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) {
            [weak self] _ in self?.refresh()
        }
    }

    private func url(_ path: String) -> URL? {
        URL(string: "http://\(wallHost)\(path)")
    }

    func refresh() {
        guard let url = url("/state") else { return }
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 4)) {
            [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let data,
                      let s = try? JSONDecoder().decode(WallState.self, from: data)
                else { self?.linkDropped(); return }
                self?.state = s
                self?.reachable = true
                LiveActivityManager.lastMode = s.mode
                SharedSnapshot.write(title: s.now_showing?["title"],
                                     artist: s.now_showing?["artist"],
                                     mode: s.mode, host: self?.wallHost,
                                     rpm: s.rpm)
                self?.fetchWallFrame()
            }
        }.resume()
    }

    /// One quiet local notification when the wall stops answering.
    private func linkDropped() {
        let was = reachable
        reachable = false
        guard was, UserDefaults.standard.bool(forKey: "linkAlerts") else { return }
        let content = UNMutableNotificationContent()
        content.title = "Lost the wall"
        content.body = "\(wallHost) isn't answering. Pushes queue until it's back."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "wall-link-drop",
                                  content: content, trigger: nil))
    }

    /// The wall's actual current pixels — the honest panel preview.
    private func fetchWallFrame() {
        guard let url = url("/frame.raw") else { return }
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 4)) {
            [weak self] data, resp, _ in
            guard let data, data.count == 64 * 64 * 3,
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let img = UIImage.fromRGB64(data) else { return }
            DispatchQueue.main.async {
                self?.wallFrame = img
                SharedSnapshot.write(frame: img, frameIsWall: true)
            }
        }.resume()
    }

    /// Send a partial patch. Debounced slightly so slider drags don't flood.
    /// Patches COALESCE: a mode tap landing inside a color drag's debounce
    /// window must not delete the color patch, so superseding a pending send
    /// merges the intent instead of dropping it.
    func send(_ patch: [String: Any], debounce: Bool = false) {
        queued.merge(patch) { _, new in new }
        pending?.cancel()
        pending = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }   // superseded; intent stays queued
            }
            await self?.flushQueued()
        }
    }

    @MainActor
    private func flushQueued() async {
        let body = queued
        queued = [:]
        guard !body.isEmpty else { return }
        let ok = await post(path: "/state", body: body)
        if !ok && Task.isCancelled {
            // cancelled mid-flight by a newer send: nothing was confirmed,
            // so keep the intent (newer values win over the re-queued ones)
            queued.merge(body) { cur, _ in cur }
        }
    }

    func replay(_ entry: JournalEntry) {
        Task { await post(path: "/replay", body: ["ts": entry.ts]) }
    }

    /// px: exactly 64*64*3 raw RGB bytes. preview: same pixels as an image.
    @discardableResult
    func sendFrame(_ px: Data, preview: UIImage?) -> Task<Bool, Never> {
        guard px.count == 64 * 64 * 3 else { return Task { false } }
        lastSentFrame = preview
        return Task { await post(path: "/frame",
                                 body: ["px": px.base64EncodedString()]) }
    }

    /// frames: each exactly 64*64*3 raw RGB. The wall loops them at fps.
    @discardableResult
    func sendClip(_ frames: [Data], fps: Int, preview: UIImage?) -> Task<Bool, Never> {
        guard !frames.isEmpty, frames.allSatisfy({ $0.count == 64 * 64 * 3 })
        else { return Task { false } }
        lastSentFrame = preview
        return Task {
            await post(path: "/clip", body: [
                "fps": fps,
                "frames": frames.map { $0.base64EncodedString() },
            ])
        }
    }

    func fetchJournal() {
        guard let url = url("/journal?limit=60") else { return }
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 4)) {
            [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let data,
                      let r = try? JSONDecoder().decode(JournalResponse.self, from: data)
                else { return }
                self?.journal = r.entries
            }
        }.resume()
    }

    @MainActor
    @discardableResult
    private func post(path: String, body: [String: Any]) async -> Bool {
        guard let url = url(path) else { return false }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req)
        else {
            // a send superseded mid-flight is not the wall going away
            if !Task.isCancelled { reachable = false }
            return false
        }
        // The wall answered, so the link is up even if it rejected the body.
        reachable = true
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let s = try? JSONDecoder().decode(WallState.self, from: data)
        else { return false }   // an error body must not read as fresh state
        state = s
        // the wall re-renders on the change; pull its new pixels shortly
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.fetchWallFrame()
        }
        return true
    }
}

// ---- Color <-> "#rrggbb" helpers ---------------------------------------
extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: String(hex.dropFirst())).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xff) / 255,
                  green: Double((v >> 8) & 0xff) / 255,
                  blue: Double(v & 0xff) / 255)
    }

    var hexString: String {
        let (r, g, b) = rgb888
        return String(format: "#%02x%02x%02x", Int(r), Int(g), Int(b))
    }

    /// getRed returns EXTENDED sRGB, so a vivid P3 pick can land outside
    /// 0...1 — clamp before UInt8 or the conversion traps mid-brushstroke.
    var rgb888: (UInt8, UInt8, UInt8) {
        let c = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        func b8(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, v * 255))) }
        return (b8(r), b8(g), b8(b))
    }
}

extension WallState {
    /// The ink the wall itself would use: the first art colour when matching,
    /// else the chosen color, as raw RGB bytes.
    var inkRGB: (UInt8, UInt8, UInt8) {
        let hex = (match_art ? art_colors?.first : nil) ?? color
        var v: UInt64 = 0
        Scanner(string: String(hex.dropFirst())).scanHexInt64(&v)
        return (UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff),
                UInt8(v & 0xff))
    }
}
