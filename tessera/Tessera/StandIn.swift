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

import Foundation
import SwiftUI
import UIKit
import MediaPlayer

@MainActor
final class StandIn {
    private(set) var state = WallState()
    private var started = Date()
    private var art: [UInt8]?          // 64x64x3 of whatever is playing
    private var artColors: [String] = []
    private var lastArtKey = ""

    init() {
        state.mode = "art"
        state.brightness = 1.0
        state.effect = "plaid"
        state.matchArt = true
    }

    func apply(_ patch: [String: Any]) {
        if let v = patch["mode"] as? String { state.mode = v }
        if let v = patch["brightness"] as? Double { state.brightness = v }
        if let v = patch["rpm"] as? Double { state.rpm = v }
        if let v = patch["effect"] as? String { state.effect = v }
        if let v = patch["finish"] as? String { state.finish = v }
        if let v = patch["match_art"] as? Bool { state.matchArt = v }
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

        if let image = item.artwork?.image(at: CGSize(width: 256, height: 256)),
           let cg = image.cgImage, let px = Clip.square64(cg) {
            art = px
            artColors = Self.chroma(px)
            state.artColors = artColors
        } else {
            makeFallbackArt()
        }
    }

    static func requestMusicAccess() {
        MPMediaLibrary.requestAuthorization { _ in }
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
        default:       px = art ?? [UInt8](repeating: 0, count: 64 * 64 * 3)
        }
        return Data(px)
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
        case "solid":    return fill(c1)
        case "breathe":  return fill(scale(c1, 0.25 + 0.75 * (0.5 + 0.5 * sin(t * 1.25))))
        case "pulse":    return fill(scale(c1, pow(0.5 + 0.5 * sin(t * 3.0), 3)))
        case "rainbow":  return sweep(t)
        default:         return gradient(t, c1, c2)
        }
    }

    private func colours() -> ((Double, Double, Double), (Double, Double, Double)) {
        if state.matchArt, artColors.count >= 2,
           let a = rgb(artColors[0]), let b = rgb(artColors[artColors.count - 1]) {
            return (a, b)
        }
        return ((0.25, 0.38, 1.0), (1.0, 0.13, 0.5))
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
