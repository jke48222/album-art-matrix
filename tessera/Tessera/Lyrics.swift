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

    func ask(track id: String, artist: String, title: String, album: String) {
        guard id != track, !loading else { return }
        loading = true
        let old = track
        track = id
        sheet = nil
        Task { [weak self] in
            let found = await Self.fetch(artist: artist, title: title, album: album)
            await MainActor.run {
                guard let self, self.track == id else { return }
                self.sheet = found
                self.loading = false
                _ = old
            }
        }
    }

    // MARK: fetch

    static func fetch(artist: String, title: String, album: String) async -> [(Double, String)]? {
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

        var hits = await request("get", [
            .init(name: "artist_name", value: artist),
            .init(name: "track_name", value: title),
            .init(name: "album_name", value: album),
        ])
        if !(hits.first?["syncedLyrics"] is String) {
            hits = await request("search", [
                .init(name: "artist_name", value: artist),
                .init(name: "track_name", value: title),
            ])
        }
        guard let raw = hits.first(where: { $0["syncedLyrics"] is String })?["syncedLyrics"] as? String
        else { return nil }
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

    static let dim: Float = 0.26
    static let ramp = 0.16

    static func render(sheet: [(Double, String)], at t: Double,
                       over art: [UInt8],
                       ink: (UInt8, UInt8, UInt8)) -> [UInt8] {
        var px = art.map { UInt8(Float($0) * dim) }

        // the current line
        guard let idx = currentIndex(sheet, t) else { return px }
        let (t0, text) = sheet[idx]
        let t1 = idx + 1 < sheet.count ? sheet[idx + 1].0 : t0 + 6
        let rows = letterable(text)
        guard !rows.isEmpty else { return px }

        let tokens = rows.flatMap { $0.split(separator: " ") }
        let n = max(1, tokens.count)
        let span = min(2.4, max(0.6, (t1 - t0) * 0.55))
        let step = span / Double(n)

        var shown = 0
        var y = (64 - (rows.count * 9 - 2)) / 2
        for row in rows {
            var x = (64 - PixelFont.textWidth(row, scale: 1)) / 2
            for word in row.split(separator: " ").map(String.init) {
                let born = t0 + Double(shown) * step
                if t >= born {
                    let k = Float(min(1.0, (t - born) / ramp))
                    // shadow first: the word's own footprint, darkened
                    var mask = [UInt8](repeating: 0, count: 64 * 64 * 3)
                    PixelDraw.text(&mask, word, x: x + 1, y: y + 1,
                                   rgb: (255, 255, 255), scale: 1)
                    for i in stride(from: 0, to: mask.count, by: 3) where mask[i] > 0 {
                        px[i] = UInt8(Float(px[i]) * 0.25)
                        px[i + 1] = UInt8(Float(px[i + 1]) * 0.25)
                        px[i + 2] = UInt8(Float(px[i + 2]) * 0.25)
                    }
                    let voiced = (UInt8(Float(ink.0) * (0.25 + 0.75 * k)),
                                  UInt8(Float(ink.1) * (0.25 + 0.75 * k)),
                                  UInt8(Float(ink.2) * (0.25 + 0.75 * k)))
                    PixelDraw.text(&px, word, x: x, y: y, rgb: voiced, scale: 1)
                }
                shown += 1
                x += PixelFont.textWidth(word, scale: 1) + 6
            }
            y += 9
        }
        return px
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
            .filter { PixelFont.glyphs[$0] != nil || $0 == " " }
            .split(separator: " ").joined(separator: " ")
        guard !kept.isEmpty else { return [] }
        return Array(PixelFont.wrap(kept, maxWidth: 58, scale: 1).prefix(6))
    }
}
