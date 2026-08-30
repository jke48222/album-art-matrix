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
    private var stateAt: Double = 0
    private var statePlaying = true
    private var music: MPMusicPlayerController { .systemMusicPlayer }

    func hardReset() { lastRaw = -1; stateAt = 0 }

    func now() -> Double {
        let raw = music.currentPlaybackTime
        let host = CACurrentMediaTime()
        // playbackState is a second XPC hop; it changes on the scale of
        // taps, not frames, so half a second of trust is plenty
        if host - stateAt > 0.5 {
            statePlaying = music.playbackState == .playing
            stateAt = host
        }
        guard statePlaying else {
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

/// One synced line: its start, its text, and, when the sheet is Enhanced
/// LRC, the actual moment each word is sung.
struct LyricLine {
    let t: Double
    let text: String
    let words: [(Double, String)]?
}

@MainActor
final class LyricsBook {
    private(set) var track = ""
    private(set) var sheet: [LyricLine]? = nil
    /// The second voice: ad-libs and echoes, each with the window it owns.
    private(set) var adlibs: [(start: Double, end: Double, text: String)] = []
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
                if let found {
                    let split = Self.splitVoices(found)
                    self.sheet = split.mains
                    self.adlibs = split.adlibs
                } else {
                    self.sheet = nil
                    self.adlibs = []
                }
            }
        }
    }

    /// Two voices out of one sheet. A line living entirely in parentheses
    /// is the second singer; a trailing parenthetical on a main line is an
    /// echo that belongs to that line's moment. Each ad-lib owns a window
    /// from its stamp to the next event, so it plays under whatever the
    /// first voice is doing.
    static func splitVoices(_ lines: [LyricLine])
        -> (mains: [LyricLine], adlibs: [(Double, Double, String)]) {
        var mains: [LyricLine] = []
        var raw: [(Double, String)] = []      // adlib starts, windows later
        let paren = /\([^()]*\)/
        for line in lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            let groups = trimmed.matches(of: paren).map { String($0.output) }
            for g in groups where g.count > 2 {
                raw.append((line.t, g))
            }
            let main = trimmed.replacing(paren, with: " ")
                .split(separator: " ").joined(separator: " ")
            if !main.isEmpty {
                // word stamps survive only if the line kept all its words
                mains.append(LyricLine(t: line.t, text: main,
                                       words: main == trimmed ? line.words : nil))
            }
        }
        let everyStart = lines.map { $0.t }.sorted()
        let adlibs = raw.map { (t, text) -> (Double, Double, String) in
            let next = everyStart.first { $0 > t + 0.05 } ?? (t + 4)
            return (t, min(next, t + 6), text)
        }
        return (mains, adlibs)
    }

    // MARK: fetch

    static func fetch(artist: String, title: String, album: String,
                      duration: Double? = nil) async -> [LyricLine]? {
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

    static func parse(lrc: String) -> [LyricLine] {
        // The whole spec, because the spec is where the sync lives:
        // [offset:±ms] is a shift baked in by whoever synced the file
        // (positive = the lyrics belong EARLIER), and <mm:ss.xx> stamps are
        // Enhanced LRC's real word times.
        var off = 0.0
        if let m = lrc.firstMatch(of: /\[offset:\s*([+-]?\d+)\s*\]/.ignoresCase()) {
            off = (Double(m.output.1) ?? 0) / 1000.0
        }
        var out: [LyricLine] = []
        let stamp = /\[(\d+):(\d+(?:\.\d+)?)\]/
        let wordStamp = /<(\d+):(\d+(?:\.\d+)?)>/
        for raw in lrc.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let stamps = line.matches(of: stamp)
            guard !stamps.isEmpty else { continue }
            var text = line.replacing(stamp, with: "").trimmingCharacters(in: .whitespaces)
            var words: [(Double, String)]? = nil
            let wstamps = text.matches(of: wordStamp)
            if !wstamps.isEmpty {
                var built: [(Double, String)] = []
                var cursor = text.startIndex
                var pendingT: Double? = nil
                for m in wstamps {
                    let chunk = String(text[cursor..<m.range.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                    if let pt = pendingT, !chunk.isEmpty {
                        built.append((pt, chunk))
                    }
                    pendingT = (Double(m.output.1) ?? 0) * 60
                        + (Double(m.output.2) ?? 0) - off
                    cursor = m.range.upperBound
                }
                let tail = String(text[cursor...]).trimmingCharacters(in: .whitespaces)
                if let pt = pendingT, !tail.isEmpty { built.append((pt, tail)) }
                if !built.isEmpty {
                    words = built
                    text = built.map { $0.1 }.joined(separator: " ")
                }
            }
            for m in stamps {
                let t = (Double(m.output.1) ?? 0) * 60 + (Double(m.output.2) ?? 0) - off
                out.append(LyricLine(t: t, text: text, words: words))
            }
        }
        out.sort { $0.t < $1.t }
        var merged: [LyricLine] = []
        for line in out {
            if let last = merged.last, line.t - last.t < 0.05 {
                let joinedWords: [(Double, String)]? = {
                    if last.words == nil && line.words == nil { return nil }
                    return (last.words ?? []) + (line.words ?? [])
                }()
                merged[merged.count - 1] = LyricLine(
                    t: last.t,
                    text: (last.text + " " + line.text)
                        .trimmingCharacters(in: .whitespaces),
                    words: joinedWords)
            } else {
                merged.append(line)
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

    static func render(sheet: [LyricLine], at t: Double,
                       adlibs: [(start: Double, end: Double, text: String)] = [],
                       over art: [UInt8], artKey: String = "",
                       ink: (UInt8, UInt8, UInt8)) -> [UInt8] {
        // what the foot sings right now
        let liveAdlib = adlibs.first { t >= $0.start && t < $0.end }?.text
        // the foot takes the rows the whole ad-lib needs (up to two), and
        // the first voice's region gives way above it: clipping the second
        // singer mid-yeah was worse than a smaller headline
        let footRows: [String] = liveAdlib.map { adlib in
            Array(PixelFont.wrap(letterableTokens(adlib).joined(separator: " "),
                                 maxWidth: 60, scale: 1).prefix(3))
        } ?? []
        let footTop = footRows.isEmpty ? 64 : 64 - (footRows.count * 9 - 2) - 1
        let regionH = footRows.isEmpty ? 60 : footTop - 3
        let base: [UInt8]
        if let c = dimCache, c.key == artKey, !artKey.isEmpty {
            base = c.px
        } else {
            base = art.map { UInt8(Float($0) * dim) }
            if !artKey.isEmpty { dimCache = (artKey, base) }
        }
        var px = base

        guard let idx = currentIndex(sheet, t) else {
            drawFoot(&px, footRows, at: footTop, ink: ink)
            return px
        }
        let line = sheet[idx]
        let (t0, text) = (line.t, line.text)
        let t1 = idx + 1 < sheet.count ? sheet[idx + 1].t : t0 + 6
        let tokens = letterableTokens(text)
        guard !tokens.isEmpty else {
            drawFoot(&px, footRows, at: footTop, ink: ink)
            return px
        }

        // timing runs on the FULL line so sizes never change the rhythm
        let n = tokens.count
        let borns = birthTimes(tokens: tokens, t0: t0, t1: t1, words: line.words)
        var visible = 0
        var newestK = 1.0
        for i in 0..<n where t >= borns[i] {
            visible = i + 1
            newestK = min(1.0, (t - borns[i]) / ramp)
        }
        guard visible > 0 else { return px }

        // the frame's whole visual identity: line, words shown, and the
        // newest word's ramp bucketed to its handful of distinct steps
        let kBucket = newestK >= 1 ? 9 : Int(newestK * 8)
        let frameKey = "\(artKey)|\(idx)|\(visible)|\(kBucket)|\((liveAdlib ?? "").hashValue)"
        if let memo = frameMemo, memo.key == frameKey { return memo.px }

        let key = "\(t0)|\(visible)|\(text.hashValue)|\(regionH)"
        let (rows, scale): ([String], Int)
        if let hit = layoutCache[key] {
            (rows, scale) = hit
        } else {
            let laid = layout(tokens: Array(tokens.prefix(visible)), regionH: regionH)
            if layoutCache.count > 256 { layoutCache.removeAll() }
            layoutCache[key] = laid
            (rows, scale) = laid
        }
        guard !rows.isEmpty else { return px }

        let lineH = 7 * scale + 2
        // centred in the region the foot has left standing, NOT the panel:
        // centring on 64 was exactly how the two voices ended up on top of
        // each other whenever the second one sang
        var y = max(1, (regionH - (rows.count * lineH - 2)) / 2)
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
        // the foot belongs to the second voice, and to no one else: when
        // nobody is answering, it stays dark
        drawFoot(&px, footRows, at: footTop, ink: ink)
        frameMemo = (frameKey, px)
        return px
    }

    /// The second singer's rows at the panel's foot: whole, never clipped
    /// mid-word, parentheses kept because that is how the second voice
    /// writes. Empty rows mean nobody is answering.
    private static func drawFoot(_ px: inout [UInt8], _ rows: [String],
                                 at top: Int, ink: (UInt8, UInt8, UInt8)) {
        guard !rows.isEmpty else { return }
        var y = top
        for row in rows {
            let x = (64 - min(60, PixelFont.textWidth(row, scale: 1))) / 2
            var mask = [UInt8](repeating: 0, count: 64 * 64 * 3)
            PixelDraw.text(&mask, row, x: x + 1, y: y + 1,
                           rgb: (255, 255, 255), scale: 1)
            for i in stride(from: 0, to: mask.count, by: 3) where mask[i] > 0 {
                px[i] = UInt8(Float(px[i]) * 0.35)
                px[i + 1] = UInt8(Float(px[i + 1]) * 0.35)
                px[i + 2] = UInt8(Float(px[i + 2]) * 0.35)
            }
            let k: Float = 0.66
            PixelDraw.text(&px, row, x: x, y: y,
                           rgb: (UInt8(Float(ink.0) * k),
                                 UInt8(Float(ink.1) * k),
                                 UInt8(Float(ink.2) * k)), scale: 1)
            y += 9
        }
    }

    /// Biggest type the visible words allow: one line if any size holds it,
    /// then whole-word wraps, then the small hard-wrapped truth.
    static func layout(tokens: [String], regionH: Int = 60) -> ([String], Int) {
        let joined = tokens.joined(separator: " ")
        for scale in [4, 3, 2, 1]
        where PixelFont.textWidth(joined, scale: scale) <= 60
            && 7 * scale <= regionH {
            return ([joined], scale)
        }
        for scale in [3, 2, 1] {
            let rows = PixelFont.wrap(joined, maxWidth: 60, scale: scale)
            if rows.count * (7 * scale + 2) - 2 <= regionH - 2,
               rows.joined(separator: " ") == joined {
                return (rows, scale)
            }
        }
        let maxRows = max(1, (regionH - 2) / 9)
        return (Array(PixelFont.wrap(joined, maxWidth: 60, scale: 1).suffix(maxRows)), 1)
    }

    /// When each token arrives: the sheet's own Enhanced-LRC stamps when it
    /// has them, else a spread weighted by word length, because long words
    /// take longer to sing and equal steps never felt like the song.
    static func birthTimes(tokens: [String], t0: Double, t1: Double,
                           words: [(Double, String)]?) -> [Double] {
        if let words {
            let stamped = words.compactMap { (wt, wtxt) -> Double? in
                let kept = PixelFont.normalize(wtxt.lowercased())
                    .filter { PixelFont.cell($0) != nil || $0 == " " }
                    .trimmingCharacters(in: .whitespaces)
                return kept.isEmpty ? nil : wt
            }
            if stamped.count == tokens.count { return stamped }
        }
        let span = min(2.4, max(0.6, (t1 - t0) * 0.55))
        let weights = tokens.map { Double(max(2, $0.count)) }
        let total = weights.reduce(0, +)
        var borns: [Double] = []
        var acc = 0.0
        for w in weights {
            borns.append(t0 + span * acc / total)
            acc += w
        }
        return borns
    }

    static func letterableTokens(_ text: String) -> [String] {
        PixelFont.normalize(text.lowercased())
            .filter { PixelFont.cell($0) != nil || $0 == " " }
            .split(separator: " ").map(String.init)
    }

    private static func currentIndex(_ sheet: [LyricLine], _ t: Double) -> Int? {
        guard let first = sheet.first, t >= first.t else { return nil }
        var lo = 0, hi = sheet.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if sheet[mid].t <= t { lo = mid } else { hi = mid - 1 }
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
