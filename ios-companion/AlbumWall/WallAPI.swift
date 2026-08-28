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
    @Published var lastSentData: Data? = nil       // its raw bytes, for re-sends
    @Published var wallFrame: UIImage? = nil       // the wall's actual pixels

    @AppStorage("wallHost") var wallHost = "album-matrix.local:8788"

    private var pending: Task<Void, Never>?
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
    func send(_ patch: [String: Any], debounce: Bool = false) {
        pending?.cancel()
        pending = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
            }
            await self?.post(path: "/state", body: patch)
        }
    }

    func replay(_ entry: JournalEntry) {
        Task { await post(path: "/replay", body: ["ts": entry.ts]) }
    }

    /// px: exactly 64*64*3 raw RGB bytes. preview: same pixels as an image.
    func sendFrame(_ px: Data, preview: UIImage?) {
        guard px.count == 64 * 64 * 3 else { return }
        lastSentFrame = preview
        lastSentData = px
        Task { await post(path: "/frame", body: ["px": px.base64EncodedString()]) }
    }

    /// frames: each exactly 64*64*3 raw RGB. The wall loops them at fps.
    func sendClip(_ frames: [Data], fps: Int, preview: UIImage?) {
        guard !frames.isEmpty, frames.allSatisfy({ $0.count == 64 * 64 * 3 })
        else { return }
        lastSentFrame = preview
        lastSentData = frames[0]
        Task {
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
    private func post(path: String, body: [String: Any]) async {
        guard let url = url(path) else { return }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let s = try? JSONDecoder().decode(WallState.self, from: data)
        else { reachable = false; return }
        state = s
        reachable = true
        // the wall re-renders on the change; pull its new pixels shortly
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.fetchWallFrame()
        }
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
        let c = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02x%02x%02x",
                      Int(round(r * 255)), Int(round(g * 255)),
                      Int(round(b * 255)))
    }
}
