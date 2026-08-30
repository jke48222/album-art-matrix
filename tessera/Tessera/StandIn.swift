// A wall that does not exist yet.
//
// The panels are on the bench and nothing is assembled, so with no wall to
// answer, Tessera runs one itself. The stand-in holds the same state and
// produces the same 12,288-byte frames, which means every screen, control,
// gesture and animation works with no hardware anywhere: nothing downstream
// knows or cares where a frame came from.
//
// It shows what is actually playing on this phone, so the thing being stood
// in for is the real thing, only smaller. The app never claims this is a
// wall: the link chip says stand-in, and Setup says what it is.
//
// Frame generation mirrors brain/art/, deliberately: same disc, same
// effects, same names. When the wall exists, the wall's own renders are the
// truth and this is only what fills the gap.

import AVFoundation
import Foundation
import SwiftUI
import UIKit
import MediaPlayer

@MainActor
final class StandIn {
    private(set) var state = WallState()
    private var started = Date()
    private var timer: (end: Date, total: Double, ret: String)? = nil
    private var snakeGame: SnakeGame? = nil
    private var snakeTicked = Date()
    private var mover: TextMover? = nil
    private var moverKey = ""
    private var moverT0 = Date()
    private var nineFrame: [UInt8]? = nil
    private var nineBuiltFor: Int? = nil
    private let lyricsBook = LyricsBook()
    private let songClock = SongClock()
    private var art: [UInt8]?          // 64x64x3 of whatever is playing
    private var artColors: [String] = []
    private var lastArtKey = ""
    private var pushed: [UInt8]? = nil                    // a frame the user put up
    private var clip: (frames: [[UInt8]], fps: Double)? = nil
    private var clipStarted = Date()
    private var sleepUntil: Date? = nil
    private var sleepTotal: TimeInterval = 0

    init() {
        state.mode = "art"
        state.brightness = 1.0
        state.effect = "plaid"
        state.matchArt = true
    }

    /// Every key send() can carry. Dropping one here made the control snap
    /// back after its success haptic, which is worse than not having it.
    func apply(_ patch: [String: Any]) {
        if let v = patch["timer_min"] as? Double {
            if v > 0 {
                let ret = timer?.ret
                    ?? (["timer", "frame", "clip"].contains(state.mode) ? "clock" : state.mode)
                timer = (Date().addingTimeInterval(v * 60), v * 60, ret)
                state.mode = "timer"
                state.timerTotal = Int(v * 60)
            } else {
                let ret = timer?.ret ?? "clock"
                timer = nil
                state.timerRemaining = nil
                state.timerTotal = nil
                if state.mode == "timer" { state.mode = ret }
            }
        }
        if let v = patch["mode"] as? String { state.mode = v }
        if let v = patch["brightness"] as? Double { state.brightness = v }
        if let v = patch["rpm"] as? Double { state.rpm = v }
        if let v = patch["effect"] as? String { state.effect = v }
        if let v = patch["finish"] as? String { state.finish = v }
        if let v = patch["match_art"] as? Bool { state.matchArt = v }
        if let v = patch["color"] as? String { state.color = v }
        if let v = patch["color2"] as? String { state.color2 = v }
        if let v = patch["ticker_text"] as? String { state.tickerText = v }
        if let v = patch["ticker_loop"] as? Bool { state.tickerLoop = v }
        if let v = patch["ticker_style"] as? String { state.tickerStyle = v }
        if let v = patch["ticker_colors"] as? [String] { state.tickerColors = v }
        if let v = patch["clock_24h"] as? Bool { state.clock24h = v }
        if let v = patch["idle"] as? String { state.idle = v }
        if let v = (patch["sleep_fade_min"] as? NSNumber)?.doubleValue {
            if v > 0 {
                sleepTotal = v * 60
                sleepUntil = Date().addingTimeInterval(sleepTotal)
            } else {
                sleepUntil = nil
                state.sleepRemaining = nil
            }
        }
    }

    /// A pushed frame is content, same as on the real wall: hold it in mode
    /// "frame" until something else is chosen, never let the art tick
    /// overwrite it.
    func push(frame px: [UInt8]) {
        pushed = px
        state.mode = "frame"
        state.shownSeq &+= 1
        // A drawing is a face the wall wore: it belongs to the history the
        // panel scrubs through, stamped with when it went up.
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        LocalJournal.append(title: "From the Studio",
                            artist: fmt.string(from: Date()),
                            album: "", frame: px)
    }

    func push(clip frames: [[UInt8]], fps: Double) {
        clip = (frames, min(24, max(1, fps)))
        clipStarted = Date()
        state.mode = "clip"
        state.shownSeq &+= 1
    }

    // MARK: - Now playing, from this phone

    /// The system music player knows what is playing; artwork comes with it.
    /// Nothing is invented: with no track and no permission, the stand-in
    /// draws its own thing and says nothing about music.
    func refreshNowPlaying() {
        guard MPMediaLibrary.authorizationStatus() == .authorized else {
            if art == nil { makeFallbackArt() }
            return
        }
        let item = MPMusicPlayerController.systemMusicPlayer.nowPlayingItem
        guard let item else {
            if art == nil { makeFallbackArt() }
            return
        }
        let key = "\(item.persistentID)"
        state.title = item.title
        state.artist = item.artist
        state.album = item.albumTitle
        guard key != lastArtKey else { return }
        lastArtKey = key
        songClock.hardReset()        // a new track is a new zero

        if let image = item.artwork?.image(at: CGSize(width: 256, height: 256)),
           let cg = image.cgImage, let px = Clip.square64(cg) {
            art = px
            artColors = Self.chroma(px)
            state.artColors = artColors
            state.shownSeq &+= 1        // a new sleeve is an arrival here too
            // With no wall there is no journal, so the app keeps one. This is
            // what makes the Archive, the counts and the panel's backwards
            // drag all work before anything is built.
            LocalJournal.append(title: state.title, artist: state.artist,
                                album: state.album, frame: px)
        } else {
            makeFallbackArt()
        }
    }

    /// The completion matters: the caller usually wants to start the push the
    /// moment access lands, and firing it before the grant resolves leaves the
    /// push dead until the next tap.
    static func requestMusicAccess(then done: @escaping () -> Void = {}) {
        MPMediaLibrary.requestAuthorization { _ in
            DispatchQueue.main.async { done() }
        }
    }

    /// Something to look at when there is no track and no library access: a
    /// field the wall's own palette, not a picture pretending to be a sleeve.
    private func makeFallbackArt() {
        var px = [UInt8](repeating: 0, count: 64 * 64 * 3)
        for y in 0..<64 {
            for x in 0..<64 {
                let o = (y * 64 + x) * 3
                let d = hypot(Double(x - 32), Double(y - 32)) / 32
                let v = max(0, 1 - d)
                px[o] = UInt8(min(255, 232 * v * v))
                px[o + 1] = UInt8(min(255, 176 * v * v))
                px[o + 2] = UInt8(min(255, 75 * v * v))
            }
        }
        art = px
        artColors = ["#e8b04b", "#8a5a2a"]
        state.artColors = artColors
        state.title = nil
        state.artist = nil
    }

    // MARK: - Frames

    func frame() -> Data {
        let t = Date().timeIntervalSince(started)
        var px: [UInt8]
        switch state.mode {
        case "off":    px = [UInt8](repeating: 0, count: 64 * 64 * 3)
        case "cd":     px = disc(t)
        case "ambient": px = ambient(t)
        case "timer":   px = countdownFrame()
        case "ticker":  px = letteringFrame()
        case "nine":    px = nineGrid()
        case "lyrics":  px = lyricsFrame()
        case "frame":  px = pushed ?? art ?? [UInt8](repeating: 0, count: 64 * 64 * 3)
        case "clip":
            if let c = clip, !c.frames.isEmpty {
                let i = Int(Date().timeIntervalSince(clipStarted) * c.fps)
                px = c.frames[i % c.frames.count]
            } else {
                px = art ?? [UInt8](repeating: 0, count: 64 * 64 * 3)
            }
        case "ticker": px = ticker(t)
        case "clock":  px = clock()
        default:       px = finished(art) ?? [UInt8](repeating: 0, count: 64 * 64 * 3)
        }

        // The sleep fade, same shape as the wall's: dim toward off across the
        // window, then off. Brightness itself stays where the finger left it.
        if let until = sleepUntil {
            let left = until.timeIntervalSinceNow
            if left <= 0 {
                sleepUntil = nil
                state.sleepRemaining = nil
                state.mode = "off"
                px = [UInt8](repeating: 0, count: 64 * 64 * 3)
            } else {
                state.sleepRemaining = Int(left)
                let fade = sleepTotal > 0 ? min(1, max(0, left / sleepTotal)) : 1
                for i in px.indices { px[i] = UInt8(Double(px[i]) * fade) }
            }
        }
        return Data(px)
    }

    // MARK: - Ticker and clock, the wall's text modes at phone cost

    private func inkBytes() -> (UInt8, UInt8, UInt8) {
        let hex = (state.matchArt ? artColors.first : nil) ?? state.color
        guard let c = rgb(hex) else { return (232, 176, 75) }
        return (UInt8(c.0 * 255), UInt8(c.1 * 255), UInt8(c.2 * 255))
    }

    private func stamp(_ text: String, into px: inout [UInt8], x: Int, y: Int,
                       rgb ink: (UInt8, UInt8, UInt8), scale: Int) {
        var cx = x
        for ch in text {
            let (rows, gw, adv) = PixelFont.cell(ch) ?? (PixelFont.box, 5, 6)
            for (ry, mask) in rows.enumerated() {
                for rx in 0..<gw where mask & (1 << (gw - 1 - rx)) != 0 {
                    for sy in 0..<scale {
                        for sx in 0..<scale {
                            let xx = cx + rx * scale + sx
                            let yy = y + ry * scale + sy
                            guard (0..<64).contains(xx), (0..<64).contains(yy) else { continue }
                            let o = (yy * 64 + xx) * 3
                            px[o] = ink.0; px[o + 1] = ink.1; px[o + 2] = ink.2
                        }
                    }
                }
            }
            cx += adv * scale
        }
    }

    private func ticker(_ t: Double) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 64 * 64 * 3)
        let text = PixelFont.normalize(state.tickerText.isEmpty ? "?" : state.tickerText)
        let w = PixelFont.textWidth(text, scale: 2)
        let travel = w + 64 + 4
        var off = Int(t * 18)                       // the wall's px/s at speed 1
        off = state.tickerLoop ? off % travel : min(off, travel)
        stamp(text, into: &px, x: 64 - off, y: (64 - 14) / 2, rgb: inkBytes(), scale: 2)
        return px
    }

    private func clock() -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 64 * 64 * 3)
        let now = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
        var hour = now.hour ?? 0
        var suffix: String? = nil
        if !state.clock24h {
            suffix = hour < 12 ? "AM" : "PM"
            hour = hour % 12 == 0 ? 12 : hour % 12
        }
        let hh = String(format: "%02d", hour)
        let mm = String(format: "%02d", now.minute ?? 0)
        let ink = inkBytes()
        let digitsW = PixelFont.textWidth(hh, scale: 2)
        let x = (64 - (digitsW * 2 + 10)) / 2
        let y = (64 - 14) / 2 - (suffix != nil ? 4 : 0)
        stamp(hh, into: &px, x: x, y: y, rgb: ink, scale: 2)
        if (now.second ?? 0) % 2 == 0 {             // the blinking colon
            let cx = x + digitsW + 4, cy = y + 4
            for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1),
                             (0, 6), (1, 6), (0, 7), (1, 7)] {
                let o = ((cy + dy) * 64 + cx + dx) * 3
                px[o] = ink.0; px[o + 1] = ink.1; px[o + 2] = ink.2
            }
        }
        stamp(mm, into: &px, x: x + digitsW + 10, y: y, rgb: ink, scale: 2)
        if let suffix {
            let sw = PixelFont.textWidth(suffix, scale: 1)
            stamp(suffix, into: &px, x: (64 - sw) / 2, y: y + 19, rgb: ink, scale: 1)
        }
        return px
    }

    /// The words mode, wall-less: the same three movers the brain runs,
    /// keyed so a new text, style or ink starts the run over from its top.
    private func letteringFrame() -> [UInt8] {
        let ink: (UInt8, UInt8, UInt8) = {
            let hex = state.matchArt ? (artColors.first ?? state.color) : state.color
            if let c = rgb(hex) {
                return (UInt8(c.0 * 255), UInt8(c.1 * 255), UInt8(c.2 * 255))
            }
            return (244, 241, 234)
        }()
        let glyphInks: [(UInt8, UInt8, UInt8)] = state.tickerColors.compactMap {
            guard let c = rgb($0) else { return nil }
            return (UInt8(c.0 * 255), UInt8(c.1 * 255), UInt8(c.2 * 255))
        }
        let key = "\(state.tickerText)|\(state.tickerStyle)|\(state.tickerLoop)|\(ink.0).\(ink.1).\(ink.2)|\(state.tickerColors.joined())"
        if mover == nil || key != moverKey {
            mover = TextMover(
                text: state.tickerText,
                style: TextMover.Style(rawValue: state.tickerStyle) ?? .across,
                color: ink,
                loop: state.tickerLoop,
                colors: glyphInks
            )
            moverKey = key
            moverT0 = Date()
        }
        guard let mover else { return [UInt8](repeating: 0, count: 64 * 64 * 3) }
        let (px, done) = mover.frame(at: Date().timeIntervalSince(moverT0))
        if done {
            // same contract as the wall: a finished run hands back to art
            self.mover = nil
            state.mode = "art"
        }
        return px
    }

    /// The last nine sleeves this app has worn, from its own journal: real
    /// frames, reduced to tiles. Rebuilt only when the journal's head moves.
    private func nineGrid() -> [UInt8] {
        let entries = LocalJournal.entries()
        let newest = entries.first?.ts
        if newest == nineBuiltFor, let nineFrame { return nineFrame }

        var out = [UInt8](repeating: 0, count: 64 * 64 * 3)
        var seen = Set<String>()
        var slot = 0
        let tick: (UInt8, UInt8, UInt8) = (26, 24, 22)
        func corner(_ x: Int, _ y: Int) {
            for (cx, cy) in [(x, y), (x + 19, y), (x, y + 19), (x + 19, y + 19)] {
                let o = (cy * 64 + cx) * 3
                out[o] = tick.0; out[o + 1] = tick.1; out[o + 2] = tick.2
            }
        }
        for e in entries where slot < 9 {
            let key = "\(e.title)|\(e.artist)"
            guard !seen.contains(key), let full = LocalJournal.frame(e.ts) else { continue }
            seen.insert(key)
            let x0 = 1 + (slot % 3) * 21, y0 = 1 + (slot / 3) * 21
            // 64 -> 20 by 3x3 block means sampled on a 3.2 stride
            for ty in 0..<20 {
                for tx in 0..<20 {
                    var r = 0, g = 0, b = 0
                    let sx = Int(Double(tx) * 3.2), sy = Int(Double(ty) * 3.2)
                    for dy in 0..<3 {
                        for dx in 0..<3 {
                            let o = (min(63, sy + dy) * 64 + min(63, sx + dx)) * 3
                            r += Int(full[o]); g += Int(full[o + 1]); b += Int(full[o + 2])
                        }
                    }
                    let o = ((y0 + ty) * 64 + x0 + tx) * 3
                    out[o] = UInt8(r / 9); out[o + 1] = UInt8(g / 9); out[o + 2] = UInt8(b / 9)
                }
            }
            slot += 1
        }
        for empty in slot..<9 {
            corner(1 + (empty % 3) * 21, 1 + (empty / 3) * 21)
        }
        nineFrame = out
        nineBuiltFor = newest
        return out
    }

    /// The words over the sleeve, on this phone's own playhead, which is the
    /// best clock in the whole system: zero network between it and the song.
    private func lyricsFrame() -> [UInt8] {
        guard let art else { return [UInt8](repeating: 0, count: 64 * 64 * 3) }
        if let title = state.title {
            let item = MPMusicPlayerController.systemMusicPlayer.nowPlayingItem
            lyricsBook.ask(track: lastArtKey, artist: state.artist ?? "",
                           title: title, album: state.album ?? "",
                           duration: (item?.playbackDuration).flatMap { $0 > 0 ? $0 : nil })
        }
        guard let sheet = lyricsBook.sheet, lyricsBook.track == lastArtKey else {
            return art       // nothing to sing yet: the sleeve, undimmed
        }
        // A shade of lead so the line lands AS it is sung, plus the owner's
        // own nudge: LRC files in the wild are themselves shifted, and only
        // the person singing along can hear by how much.
        let nudge = UserDefaults.standard.double(forKey: "lyrics.nudge")
        let t = MPMusicPlayerController.systemMusicPlayer.currentPlaybackTime + 0.35 + nudge
        return LyricsBook.render(sheet: sheet, at: t, over: art,
                                 artKey: lastArtKey, ink: (244, 241, 234))
    }

    /// The finishes, phone-side, so choosing one changes the wall you are
    /// looking at and not just three thumbnails. Same math as the brain:
    /// poster is 3 bits a channel; dither is Floyd-Steinberg to the same
    /// levels, error carried right and down.
    private var finishCache: (key: String, px: [UInt8])? = nil
    private func finished(_ art: [UInt8]?) -> [UInt8]? {
        guard let art else { return nil }
        let f = state.finish
        guard f != "clean" else { return art }
        let key = "\(lastArtKey)|\(f)"
        if let c = finishCache, c.key == key { return c.px }
        var out = art
        func q(_ v: Double) -> Double {
            (Double(Int(max(0, min(255, v))) >> 5) * 255.0 / 7.0).rounded()
        }
        if f == "poster" {
            for i in out.indices { out[i] = UInt8(q(Double(art[i]))) }
        } else if f == "dither" {
            var work = art.map(Double.init)
            for y in 0..<64 {
                for x in 0..<64 {
                    for c in 0..<3 {
                        let o = (y * 64 + x) * 3 + c
                        let old = work[o]
                        let new = q(old)
                        work[o] = new
                        let err = old - new
                        if x + 1 < 64 { work[o + 3] += err * 7 / 16 }
                        if y + 1 < 64 {
                            if x > 0 { work[o + 64 * 3 - 3] += err * 3 / 16 }
                            work[o + 64 * 3] += err * 5 / 16
                            if x + 1 < 64 { work[o + 64 * 3 + 3] += err * 1 / 16 }
                        }
                    }
                }
            }
            for i in out.indices { out[i] = UInt8(max(0, min(255, work[i]))) }
        }
        finishCache = (key, out)
        return out
    }

    private func countdownFrame() -> [UInt8] {
        guard let tm = timer else {
            state.mode = "clock"
            return [UInt8](repeating: 0, count: 64 * 64 * 3)
        }
        let left = tm.end.timeIntervalSinceNow
        if left <= -60 {
            timer = nil
            state.timerRemaining = nil
            state.timerTotal = nil
            state.mode = tm.ret
            return frameForMode(t: Date().timeIntervalSince(started))
        }
        state.timerRemaining = max(0, Int(left))
        let a = rgb(state.color2) ?? (0.91, 0.69, 0.29)
        return PixelDraw.countdown(remaining: left, total: tm.total,
                                   ink: (234, 228, 216), accent: a)
    }

    /// One frame of whatever the mode says, for handing back mid-transition.
    private func frameForMode(t: Double) -> [UInt8] {
        switch state.mode {
        case "off": return [UInt8](repeating: 0, count: 64 * 64 * 3)
        case "cd": return disc(t)
        case "ambient": return ambient(t)
        default: return art ?? [UInt8](repeating: 0, count: 64 * 64 * 3)
        }
    }

    /// The sleeve as a record: circular crop, spindle hole, grooves catching a
    /// light that stays put while the disc turns. The wall's disc.py does this
    /// at higher quality; this is the same idea at phone cost.
    private func disc(_ t: Double) -> [UInt8] {
        guard let art else { return [UInt8](repeating: 0, count: 64 * 64 * 3) }
        var out = [UInt8](repeating: 0, count: 64 * 64 * 3)
        let angle = t * state.rpm / 60 * 2 * .pi
        let ca = cos(-angle), sa = sin(-angle)

        for y in 0..<64 {
            for x in 0..<64 {
                let dx = Double(x) - 31.5, dy = Double(y) - 31.5
                let rad = hypot(dx, dy) / 31.5
                let o = (y * 64 + x) * 3
                guard rad <= 1.0, rad > 0.055 else { continue }

                // sample the sleeve, rotated
                let sx = Int((dx * ca - dy * sa) + 31.5)
                let sy = Int((dx * sa + dy * ca) + 31.5)
                guard sx >= 0, sx < 64, sy >= 0, sy < 64 else { continue }
                let so = (sy * 64 + sx) * 3

                // grooves, and a light that does not turn with the record
                let groove = 0.5 + 0.5 * sin(rad * 31.5 / 2.2 * 2 * .pi)
                let play = min(1, max(0, (rad - 0.34) * 14)) * min(1, max(0, (0.90 - rad) * 14))
                var k = 1.0 - 0.17 * groove * play
                if rad < 0.34 { k *= 1.18 }                    // the paper label
                let ang = atan2(dy, dx)
                let sheen = pow(max(0, cos(ang - 0.9)), 12) * play * (0.55 + 0.45 * groove)

                for c in 0..<3 {
                    out[o + c] = UInt8(min(255, Double(art[so + c]) * k + sheen * 78))
                }
            }
        }
        return out
    }

    private func ambient(_ t: Double) -> [UInt8] {
        let (c1, c2) = colours()
        switch state.effect {
        case "plaid", "weave", "deco": return Patterns.frame(state.effect, t: t, c1: c1, c2: c2)
        case "snake": return snakeFrame(c1, c2)
        case "solid":    return fill(c1)
        case "breathe":  return fill(scale(c1, 0.25 + 0.75 * (0.5 + 0.5 * sin(t * 1.25))))
        case "pulse":    return fill(scale(c1, pow(0.5 + 0.5 * sin(t * 3.0), 3)))
        case "rainbow":  return sweep(t)
        default:         return gradient(t, c1, c2)
        }
    }

    /// The wall playing itself, in the album's thread. The engine advances
    /// on its own clock regardless of how often frames are asked for.
    private func snakeFrame(_ c1: (Double, Double, Double),
                            _ c2: (Double, Double, Double)) -> [UInt8] {
        if snakeGame == nil {
            let g = SnakeGame()
            g.deal(auto: true)
            snakeGame = g
            snakeTicked = Date()
        }
        guard let g = snakeGame else { return [UInt8](repeating: 0, count: 64 * 64 * 3) }
        g.ink = c1
        g.accent = c2
        while Date().timeIntervalSince(snakeTicked) >= g.interval {
            snakeTicked.addTimeInterval(g.interval)
            g.tick()
        }
        return g.px
    }

    private func colours() -> ((Double, Double, Double), (Double, Double, Double)) {
        if state.matchArt, artColors.count >= 2,
           let a = rgb(artColors[0]), let b = rgb(artColors[artColors.count - 1]) {
            return (a, b)
        }
        // Chosen colours, when not taking the album's.
        let a = rgb(state.color) ?? (0.91, 0.69, 0.29)
        let b = rgb(state.color2) ?? (0.88, 0.29, 0.12)
        return (a, b)
    }

    private func rgb(_ hex: String) -> (Double, Double, Double)? {
        var s = hex; guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255)
    }

    private func scale(_ c: (Double, Double, Double), _ k: Double) -> (Double, Double, Double) {
        (c.0 * k, c.1 * k, c.2 * k)
    }

    private func fill(_ c: (Double, Double, Double)) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 64 * 64 * 3)
        for i in stride(from: 0, to: px.count, by: 3) {
            px[i] = UInt8(min(255, c.0 * 255))
            px[i + 1] = UInt8(min(255, c.1 * 255))
            px[i + 2] = UInt8(min(255, c.2 * 255))
        }
        return px
    }

    private func sweep(_ t: Double) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 64 * 64 * 3)
        for y in 0..<64 {
            for x in 0..<64 {
                let h = (Double(x + y) / 128 + t * 0.12).truncatingRemainder(dividingBy: 1)
                let c = UIColor(hue: h, saturation: 0.85, brightness: 1, alpha: 1)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.getRed(&r, green: &g, blue: &b, alpha: &a)
                let o = (y * 64 + x) * 3
                px[o] = UInt8(r * 255); px[o + 1] = UInt8(g * 255); px[o + 2] = UInt8(b * 255)
            }
        }
        return px
    }

    private func gradient(_ t: Double, _ c1: (Double, Double, Double), _ c2: (Double, Double, Double)) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 64 * 64 * 3)
        let phase = 0.5 + 0.5 * sin(t * 0.5)
        for y in 0..<64 {
            for x in 0..<64 {
                let k = min(1, max(0, (Double(x + y) / 126 + phase - 0.5)))
                let o = (y * 64 + x) * 3
                px[o] = UInt8(min(255, (c1.0 * (1 - k) + c2.0 * k) * 255))
                px[o + 1] = UInt8(min(255, (c1.1 * (1 - k) + c2.1 * k) * 255))
                px[o + 2] = UInt8(min(255, (c1.2 * (1 - k) + c2.2 * k) * 255))
            }
        }
        return px
    }

    /// The two most chromatic colours in a frame, same rule the room uses.
    static func chroma(_ px: [UInt8]) -> [String] {
        var buckets: [Int: (n: Int, r: Int, g: Int, b: Int)] = [:]
        for i in 0..<(64 * 64) {
            let o = i * 3
            let r = Int(px[o]), g = Int(px[o + 1]), b = Int(px[o + 2])
            let mx = max(r, g, b), mn = min(r, g, b)
            guard mx > 60, Double(mx - mn) / Double(max(1, mx)) > 0.25 else { continue }
            let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
            var e = buckets[key] ?? (0, 0, 0, 0)
            e.n += 1; e.r += r; e.g += g; e.b += b
            buckets[key] = e
        }
        let top = buckets.values.sorted { $0.n > $1.n }.prefix(2)
        let out = top.map { e in
            String(format: "#%02x%02x%02x", e.r / e.n, e.g / e.n, e.b / e.n)
        }
        return out.isEmpty ? ["#e8b04b", "#8a5a2a"] : Array(out)
    }
}
