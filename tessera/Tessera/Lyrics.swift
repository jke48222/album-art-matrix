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
import QuartzCore

/// The song's position as a clock worth trusting.
///
/// MPMusicPlayerController.currentPlaybackTime is the truth, delivered
/// badly: it crosses an XPC bridge, staircases, and can repeat itself for
/// most of a second before jumping. Rendering lyrics straight off it is why
/// nothing ever felt locked. This keeps its own monotonic clock anchored to
/// the player's samples: between samples time flows smoothly at 1x; when a
/// fresh sample disagrees a little, the anchor is SLEWED gently toward it
/// (a fixed fraction per reading, never a visible jump); when it disagrees
/// a lot, that is a seek, and the clock jumps with it.
@MainActor
final class SongClock {
    private var anchorTime: Double = 0
    private var anchorHost: Double = 0
    private var lastRaw: Double = -1
    private var music: MPMusicPlayerController { .systemMusicPlayer }

    func hardReset() { lastRaw = -1 }

    func now() -> Double {
        let raw = music.currentPlaybackTime
        let host = CACurrentMediaTime()
        guard music.playbackState == .playing else {
            anchorTime = raw
            anchorHost = host
            lastRaw = raw
            return raw
        }
        if lastRaw < 0 {
            anchorTime = raw
            anchorHost = host
            lastRaw = raw
            return raw
        }
        let predicted = anchorTime + (host - anchorHost)
        if raw != lastRaw {
            lastRaw = raw
            let diff = raw - predicted
            if abs(diff) > 0.9 {
                // a seek, or the player was wrenched: follow it at once
                anchorTime = raw
                anchorHost = host
            } else {
                // a small disagreement: lean toward it, never lurch
                anchorTime += diff * 0.12
            }
        }
        return anchorTime + (host - anchorHost)
    }
}

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
        // nil = transport failed (worth retrying); [] = answered, no rows
        func request(_ path: String, _ items: [URLQueryItem]) async -> [[String: Any]]? {
            var comps = URLComponents(string: "https://lrclib.net/api/\(path)")!
            comps.queryItems = items
            guard let url = comps.url else { return [] }
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
                return nil
            }
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            if let one = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return [one]
            }
            if let many = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return many
            }
            return []
        }

        // A network hiccup must not be remembered forever as "this song has
        // no words": transport errors retry with a breath between attempts.
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2 * attempt)) }

            var items: [URLQueryItem] = [
                .init(name: "artist_name", value: artist),
                .init(name: "track_name", value: title),
                .init(name: "album_name", value: album),
            ]
            if let duration { items.append(.init(name: "duration", value: String(Int(duration)))) }
            guard let direct = await request("get", items) else { continue }

            var candidates = direct.filter { $0["syncedLyrics"] is String }
            // The direct answer can still be the WRONG EDIT: a sheet synced
            // to the radio cut drifts a little more every chorus. When its
            // length disagrees with the song by more than a few seconds,
            // distrust it and search for a better one.
            if let d = duration, let hit = candidates.first,
               let hd = hit["duration"] as? Double, abs(hd - d) > 4 {
                candidates = []
            }
            if candidates.isEmpty {
                guard let found = await request("search", [
                    .init(name: "artist_name", value: artist),
                    .init(name: "track_name", value: title),
                ]) else { continue }
                candidates = found.filter { $0["syncedLyrics"] is String }
            }
            let best: [String: Any]? = duration.flatMap { d in
                candidates.min { a, b in
                    let da = abs((a["duration"] as? Double ?? 1e9) - d)
                    let db = abs((b["duration"] as? Double ?? 1e9) - d)
                    return da < db
                }
            } ?? candidates.first
            guard let raw = best?["syncedLyrics"] as? String else { return nil }
            let lines = parse(lrc: raw)
            return lines.isEmpty ? nil : lines
        }
        return nil
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
    /// The dimmed sleeve, computed once per track instead of 12k multiplies
    /// per tick.
    private static var dimCache: (key: String, px: [UInt8])? = nil
    /// Whole frames memoized on their visual state. Between word pops the
    /// picture does not change, and rendering an identical frame ten times a
    /// second was the lyric lag: every tick re-lettered, re-published, and
    /// dragged a full SwiftUI pass behind it. Now a tick that changes
    /// nothing costs a dictionary lookup, and equality upstream stops the
    /// republish entirely.
    private static var frameMemo: (key: String, px: [UInt8])? = nil

    static func render(sheet: [(Double, String)], at t: Double,
                       over art: [UInt8], artKey: String = "",
                       ink: (UInt8, UInt8, UInt8)) -> [UInt8] {
        let base: [UInt8]
        if let c = dimCache, c.key == artKey, !artKey.isEmpty {
            base = c.px
        } else {
            base = art.map { UInt8(Float($0) * dim) }
            if !artKey.isEmpty { dimCache = (artKey, base) }
        }
        var px = base

        guard let idx = currentIndex(sheet, t) else {
            // before the first vocal: the opening line waits, dim, so the
            // start of the song is never a surprise
            if let first = sheet.first {
                drawPreview(&px, first.1, ink: ink)
            }
            return px
        }
        let (t0, text) = sheet[idx]
        let t1 = idx + 1 < sheet.count ? sheet[idx + 1].0 : t0 + 6
        let nextText = idx + 1 < sheet.count ? sheet[idx + 1].1 : ""
        let tokens = letterableTokens(text)
        guard !tokens.isEmpty else {
            // an instrumental bar: only the coming line, waiting
            if !nextText.isEmpty { drawPreview(&px, nextText, ink: ink) }
            return px
        }

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

        // the frame's whole visual identity: line, words shown, and the
        // newest word's ramp bucketed to its handful of distinct steps
        let kBucket = newestK >= 1 ? 9 : Int(newestK * 8)
        let frameKey = "\(artKey)|\(idx)|\(visible)|\(kBucket)|\(nextText.hashValue)"
        if let memo = frameMemo, memo.key == frameKey { return memo.px }

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
        // the NEXT line rides beneath, dim and whole: fast sequences stop
        // reading as skipped because every line is on screen before its
        // moment arrives
        if !nextText.isEmpty { drawPreview(&px, nextText, ink: ink) }
        frameMemo = (frameKey, px)
        return px
    }

    /// The coming line, one small dim row at the panel's foot. Karaoke's
    /// whole trick, at 64 pixels: you read the future while singing the
    /// present.
    private static func drawPreview(_ px: inout [UInt8], _ text: String,
                                    ink: (UInt8, UInt8, UInt8)) {
        let tokens = letterableTokens(text)
        guard !tokens.isEmpty else { return }
        let joined = tokens.joined(separator: " ")
        let row = PixelFont.wrap(joined, maxWidth: 60, scale: 1).first ?? joined
        let x = (64 - min(60, PixelFont.textWidth(row, scale: 1))) / 2
        let y = 55
        var mask = [UInt8](repeating: 0, count: 64 * 64 * 3)
        PixelDraw.text(&mask, row, x: x + 1, y: y + 1, rgb: (255, 255, 255), scale: 1)
        for i in stride(from: 0, to: mask.count, by: 3) where mask[i] > 0 {
            px[i] = UInt8(Float(px[i]) * 0.35)
            px[i + 1] = UInt8(Float(px[i + 1]) * 0.35)
            px[i + 2] = UInt8(Float(px[i + 2]) * 0.35)
        }
        let dimInk = (UInt8(Float(ink.0) * 0.42),
                      UInt8(Float(ink.1) * 0.42),
                      UInt8(Float(ink.2) * 0.42))
        PixelDraw.text(&px, row, x: x, y: y, rgb: dimInk, scale: 1)
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
            if rows.count * (7 * scale + 2) - 2 <= 50,
               rows.joined(separator: " ") == joined {
                return (rows, scale)
            }
        }
        return (Array(PixelFont.wrap(joined, maxWidth: 60, scale: 1).suffix(5)), 1)
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
