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
    /// Supersession by generation, not a lock: the old design refused new
    /// asks while one was in flight, and a fetch that lost its race left the
    /// flag stuck forever — every later track then showed no words at all.
    private var generation = 0

    func ask(track id: String, artist: String, title: String, album: String,
             duration: Double? = nil) {
        guard id != track else { return }
        track = id
        sheet = nil
        generation += 1
        let gen = generation
        Task { [weak self] in
            let found = await Self.fetch(artist: artist, title: title,
                                         album: album, duration: duration)
            await MainActor.run {
                guard let self, self.generation == gen else { return }
                self.sheet = found
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
        out.sort { $0.0 < $1.0 }
        // Lines sharing a timestamp (duets, ad-libs) collapse into one:
        // otherwise only the later of the pair ever shows and the other is
        // "skipped", which is exactly what it looked like.
        var merged: [(Double, String)] = []
        for (t, text) in out {
            if let last = merged.last, t - last.0 < 0.05 {
                merged[merged.count - 1].1 = last.1.isEmpty
                    ? text : last.1 + " " + text
            } else {
                merged.append((t, text))
            }
        }
        return merged
    }

    // MARK: render

    /// The brat behaviour on the sleeve: the line starts huge and steps
    /// down in size as words arrive and crowd it, lowercase, left-anchored,
    /// lettered over the cover dimmed to a quarter with its own shadow.
    /// Layout is recomputed for exactly the words visible so far, which is
    /// what makes the shrink happen live instead of being pre-decided.
    static let ramp = 0.12
    static let dim: Float = 0.26

    private static var layoutCache: [String: ([String], Int)] = [:]

    static func render(sheet: [(Double, String)], at t: Double,
                       over art: [UInt8],
                       ink: (UInt8, UInt8, UInt8)) -> [UInt8] {
        var px = art.map { UInt8(Float($0) * dim) }

        guard let idx = currentIndex(sheet, t) else { return px }
        let (t0, text) = sheet[idx]
        let t1 = idx + 1 < sheet.count ? sheet[idx + 1].0 : t0 + 6
        let tokens = letterableTokens(text)
        guard !tokens.isEmpty else { return px }

        // timing runs on the FULL line so sizes never change the rhythm
        let n = tokens.count
        let span = min(2.4, max(0.6, (t1 - t0) * 0.55))
        let step = span / Double(n)
        var visible = 0
        var newestK = 1.0
        for i in 0..<n {
            let born = t0 + Double(i) * step
            if t >= born {
                visible = i + 1
                newestK = min(1.0, (t - born) / ramp)
            }
        }
        guard visible > 0 else { return px }

        let key = "\(t0)|\(visible)|\(text.hashValue)"
        let (rows, scale): ([String], Int)
        if let hit = layoutCache[key] {
            (rows, scale) = hit
        } else {
            let laid = layout(tokens: Array(tokens.prefix(visible)))
            if layoutCache.count > 256 { layoutCache.removeAll() }
            layoutCache[key] = laid
            (rows, scale) = laid
        }
        guard !rows.isEmpty else { return px }

        let lineH = 7 * scale + 2
        var y = (64 - (rows.count * lineH - 2)) / 2
        var drawn = 0
        for row in rows {
            let words = row.split(separator: " ").map(String.init)
            let x = 2
            // shadow: the row's own footprint, darkened
            var mask = [UInt8](repeating: 0, count: 64 * 64 * 3)
            PixelDraw.text(&mask, row, x: x + 1, y: y + 1,
                           rgb: (255, 255, 255), scale: scale)
            for i in stride(from: 0, to: mask.count, by: 3) where mask[i] > 0 {
                px[i] = UInt8(Float(px[i]) * 0.3)
                px[i + 1] = UInt8(Float(px[i + 1]) * 0.3)
                px[i + 2] = UInt8(Float(px[i + 2]) * 0.3)
            }
            drawn += words.count
            let isLastRow = drawn >= visible
            let settled = isLastRow && words.count > 0
                ? words.dropLast().joined(separator: " ") : row
            if !settled.isEmpty {
                PixelDraw.text(&px, settled, x: x, y: y, rgb: ink, scale: scale)
            }
            if isLastRow, let last = words.last {
                let lx = x + (settled.isEmpty ? 0
                    : PixelFont.textWidth(settled, scale: scale) + 6 * scale)
                let k = Float(newestK)
                let voiced = (UInt8(Float(ink.0) * max(0.3, k)),
                              UInt8(Float(ink.1) * max(0.3, k)),
                              UInt8(Float(ink.2) * max(0.3, k)))
                PixelDraw.text(&px, last, x: lx, y: y, rgb: voiced, scale: scale)
            }
            y += lineH
        }
        return px
    }

    /// Biggest type the visible words allow: one line if any size holds it,
    /// then whole-word wraps, then the small hard-wrapped truth.
    static func layout(tokens: [String]) -> ([String], Int) {
        let joined = tokens.joined(separator: " ")
        for scale in [4, 3, 2, 1]
        where PixelFont.textWidth(joined, scale: scale) <= 60 {
            return ([joined], scale)
        }
        for scale in [3, 2, 1] {
            let rows = PixelFont.wrap(joined, maxWidth: 60, scale: scale)
            if rows.count * (7 * scale + 2) - 2 <= 60,
               rows.joined(separator: " ") == joined {
                return (rows, scale)
            }
        }
        return (Array(PixelFont.wrap(joined, maxWidth: 60, scale: 1).suffix(6)), 1)
    }

    static func letterableTokens(_ text: String) -> [String] {
        PixelFont.normalize(text.lowercased())
            .filter { PixelFont.cell($0) != nil || $0 == " " }
            .split(separator: " ").map(String.init)
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
