// The words, fetched and lettered, phone-side.
//
// Same source and same behaviour as brain/art/lyrics.py: LRCLIB by track,
// the current line only, words arriving one at a time across the front of
// the line's window, each with a short brightness ramp. The pixel font is
// ASCII, and half the world's music is not: characters the font cannot
// letter step aside, so a mixed-script line keeps its English on time and a
// line with nothing letterable shows the sleeve alone for its bar.

import Foundation
import MediaPlayer

@MainActor
final class LyricsBook {
    private(set) var track = ""
    private(set) var sheet: [(Double, String)]? = nil
    private var loading = false

    func ask(track id: String, artist: String, title: String, album: String,
             duration: Double? = nil) {
        guard id != track, !loading else { return }
        loading = true
        let old = track
        track = id
        sheet = nil
        Task { [weak self] in
            let found = await Self.fetch(artist: artist, title: title,
                                         album: album, duration: duration)
            await MainActor.run {
                guard let self, self.track == id else { return }
                self.sheet = found
                self.loading = false
                _ = old
            }
        }
    }

    // MARK: fetch

    static func fetch(artist: String, title: String, album: String,
                      duration: Double? = nil) async -> [(Double, String)]? {
        func request(_ path: String, _ items: [URLQueryItem]) async -> [[String: Any]] {
            var comps = URLComponents(string: "https://lrclib.net/api/\(path)")!
            comps.queryItems = items
            guard let url = comps.url else { return [] }
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            if let one = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return [one]
            }
            if let many = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return many
            }
            return []
        }

        var items: [URLQueryItem] = [
            .init(name: "artist_name", value: artist),
            .init(name: "track_name", value: title),
            .init(name: "album_name", value: album),
        ]
        if let duration { items.append(.init(name: "duration", value: String(Int(duration)))) }
        var hits = await request("get", items)
        if !(hits.first?["syncedLyrics"] is String) {
            hits = await request("search", [
                .init(name: "artist_name", value: artist),
                .init(name: "track_name", value: title),
            ])
        }
        // Among candidates, the one whose length matches the song is the one
        // whose TIMESTAMPS match the song: an album cut synced to a radio
        // edit drifts a little more every chorus.
        let synced = hits.filter { $0["syncedLyrics"] is String }
        let best: [String: Any]? = duration.flatMap { d in
            synced.min { a, b in
                let da = abs((a["duration"] as? Double ?? 1e9) - d)
                let db = abs((b["duration"] as? Double ?? 1e9) - d)
                return da < db
            }
        } ?? synced.first
        guard let raw = best?["syncedLyrics"] as? String else { return nil }
        let lines = parse(lrc: raw)
        return lines.isEmpty ? nil : lines
    }

    static func parse(lrc: String) -> [(Double, String)] {
        var out: [(Double, String)] = []
        let stamp = /\[(\d+):(\d+(?:\.\d+)?)\]/
        for raw in lrc.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let stamps = line.matches(of: stamp)
            guard !stamps.isEmpty else { continue }
            let text = line.replacing(stamp, with: "").trimmingCharacters(in: .whitespaces)
            for m in stamps {
                let t = (Double(m.output.1) ?? 0) * 60 + (Double(m.output.2) ?? 0)
                out.append((t, text))
            }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    // MARK: render

    /// The brat look: a flat field in the album's loudest voice, the line
    /// in lowercase filling from the left, black or white by what the field
    /// needs, words popping in one at a time. Big where the line is short.
    static let ramp = 0.12

    static func render(sheet: [(Double, String)], at t: Double,
                       bg voice: (Double, Double, Double),
                       ink chosen: (UInt8, UInt8, UInt8)? = nil) -> [UInt8] {
        // push the field toward its loudest self
        let ui = UIColor(red: voice.0, green: voice.1, blue: voice.2, alpha: 1)
        var h: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, a: CGFloat = 0
        ui.getHue(&h, saturation: &sat, brightness: &bri, alpha: &a)
        let loud = UIColor(hue: h, saturation: min(1, sat * 1.5 + 0.12),
                           brightness: min(1, bri * 1.25 + 0.18), alpha: 1)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        loud.getRed(&r, green: &g, blue: &b, alpha: &a)
        let bg = (UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let ink: (UInt8, UInt8, UInt8) = chosen
            ?? (lum > 0.45 ? (12, 12, 10) : (244, 241, 234))

        var px = [UInt8](repeating: 0, count: 64 * 64 * 3)
        for i in stride(from: 0, to: px.count, by: 3) {
            px[i] = bg.0; px[i + 1] = bg.1; px[i + 2] = bg.2
        }

        guard let idx = currentIndex(sheet, t) else { return px }
        let (t0, text) = sheet[idx]
        let t1 = idx + 1 < sheet.count ? sheet[idx + 1].0 : t0 + 6
        let (rows, scale) = layout(text)
        guard !rows.isEmpty else { return px }

        let tokens = rows.flatMap { $0.split(separator: " ") }
        let n = max(1, tokens.count)
        let span = min(2.4, max(0.6, (t1 - t0) * 0.55))
        let step = span / Double(n)

        let lineH = 7 * scale + 2
        var shown = 0
        var y = (64 - (rows.count * lineH - 2)) / 2
        for row in rows {
            let words = row.split(separator: " ").map(String.init)
            var visible = 0
            var newestK = 1.0
            for i in 0..<words.count {
                let born = t0 + Double(shown + i) * step
                if t >= born {
                    visible = i + 1
                    newestK = min(1.0, (t - born) / ramp)
                }
            }
            shown += words.count
            guard visible > 0 else { y += lineH; continue }
            let x = 2
            let settled = words.prefix(visible - 1).joined(separator: " ")
            if !settled.isEmpty {
                PixelDraw.text(&px, settled, x: x, y: y, rgb: ink, scale: scale)
            }
            let last = words[visible - 1]
            let lx = x + (settled.isEmpty ? 0
                : PixelFont.textWidth(settled, scale: scale) + 6 * scale)
            let k = visible == words.count ? newestK : 1.0
            let mixed = (UInt8(Double(ink.0) * k + Double(bg.0) * (1 - k)),
                         UInt8(Double(ink.1) * k + Double(bg.1) * (1 - k)),
                         UInt8(Double(ink.2) * k + Double(bg.2) * (1 - k)))
            PixelDraw.text(&px, last, x: lx, y: y, rgb: mixed, scale: scale)
            y += lineH
        }
        return px
    }

    /// Wrapped rows of the letterable, lowercased line, at the biggest scale
    /// whose block still fits the panel.
    static func layout(_ text: String) -> (rows: [String], scale: Int) {
        let kept = PixelFont.normalize(text.lowercased())
            .filter { PixelFont.cell($0) != nil || $0 == " " }
            .split(separator: " ").joined(separator: " ")
        guard !kept.isEmpty else { return ([], 1) }
        for scale in [2, 1] {
            let rows = PixelFont.wrap(kept, maxWidth: 60, scale: scale)
            if rows.count * (7 * scale + 2) - 2 <= 60 {
                return (rows, scale)
            }
        }
        return (Array(PixelFont.wrap(kept, maxWidth: 60, scale: 1).suffix(6)), 1)
    }

    private static func currentIndex(_ sheet: [(Double, String)], _ t: Double) -> Int? {
        guard let first = sheet.first, t >= first.0 else { return nil }
        var lo = 0, hi = sheet.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if sheet[mid].0 <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Wrapped rows of the letterable part of a line.
    private static func letterable(_ text: String) -> [String] {
        let kept = PixelFont.normalize(text)
            .filter { PixelFont.cell($0) != nil || $0 == " " }
            .split(separator: " ").joined(separator: " ")
        guard !kept.isEmpty else { return [] }
        // six rows is the panel's whole height at this leading; a line that
        // wants more gets its LAST six, because the end of a lyric line is
        // the part being sung when the cap matters
        return Array(PixelFont.wrap(kept, maxWidth: 60, scale: 1).suffix(6))
    }
}
