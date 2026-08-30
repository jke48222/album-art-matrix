// The three pattern modes, in Swift, for the stand-in wall.
//
// These mirror brain/art/effects.py: plaid is a mirrored tartan sett crossed
// by a 2/2 twill, weave is a bordered geometric field, deco is mid-century
// flat shapes on a grid that flip one cell at a time. The wall's own versions
// are the truth; these exist so the modes can be seen and tested with no wall
// in the room. Keep them in step by eye, not by contract: nothing depends on
// them matching pixel for pixel.

import Foundation

enum Patterns {
    static func frame(_ kind: String, t: Double,
                      c1: (Double, Double, Double), c2: (Double, Double, Double)) -> [UInt8] {
        let pal = palette(c1, c2)
        switch kind {
        case "weave": return weave(t, pal)
        case "deco":  return deco(t, pal)
        default:      return plaid(t, pal)
        }
    }

    /// The album's two colours, a mid tint, a light tint, and a dark ground
    /// last so borders can always reach for it.
    private static func palette(_ c1: (Double, Double, Double),
                                _ c2: (Double, Double, Double)) -> [(Double, Double, Double)] {
        let mid = ((c1.0 + c2.0) / 2, (c1.1 + c2.1) / 2, (c1.2 + c2.2) / 2)
        let light = (min(1, max(c1.0, c2.0) * 1.2 + 0.16),
                     min(1, max(c1.1, c2.1) * 1.2 + 0.16),
                     min(1, max(c1.2, c2.2) * 1.2 + 0.16))
        let deep = (min(c1.0, c2.0) * 0.22, min(c1.1, c2.1) * 0.22, min(c1.2, c2.2) * 0.22)
        return [c1, c2, mid, light, deep]
    }

    private static func put(_ px: inout [UInt8], _ i: Int, _ c: (Double, Double, Double), _ k: Double = 1) {
        px[i] = UInt8(min(255, max(0, c.0 * 255 * k)))
        px[i + 1] = UInt8(min(255, max(0, c.1 * 255 * k)))
        px[i + 2] = UInt8(min(255, max(0, c.2 * 255 * k)))
    }

    /// A small deterministic generator, so a draft is stable while it is held.
    private struct Seeded {
        var s: UInt64
        init(_ seed: UInt64) { s = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func next() -> UInt64 {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            return s
        }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
    }

    // MARK: plaid

    private static func plaid(_ t: Double, _ pal: [(Double, Double, Double)]) -> [UInt8] {
        let draftLen = 26.0, blend = 3.0
        let draft = Int(max(0, t) / draftLen)
        let into = max(0, t) - Double(draft) * draftLen
        let mix = into < draftLen - blend ? 0 : (into - (draftLen - blend)) / blend

        var px = [UInt8](repeating: 0, count: 64 * 64 * 3)
        let a = sett(draft, pal.count), b = sett(draft + 1, pal.count)
        let offset = Int(t * 1.5)

        for y in 0..<64 {
            for x in 0..<64 {
                let o = (y * 64 + x) * 3
                let ca = cloth(x, y, a, pal, offset)
                let c = mix > 0 ? lerp(ca, cloth(x, y, b, pal, offset), mix) : ca
                put(&px, o, c)
            }
        }
        return px
    }

    private static func cloth(_ x: Int, _ y: Int, _ sett: [Int],
                              _ pal: [(Double, Double, Double)], _ offset: Int) -> (Double, Double, Double) {
        let wi = sett[x], fi = sett[y]
        let over = (x + y + offset) % 4 < 2
        let base = pal[over ? wi : fi]
        guard wi != fi else { return base }
        // where two threads cross the eye reads a blend
        let m = ((pal[wi].0 + pal[fi].0) / 2, (pal[wi].1 + pal[fi].1) / 2, (pal[wi].2 + pal[fi].2) / 2)
        return (base.0 * 0.55 + m.0 * 0.45, base.1 * 0.55 + m.1 * 0.45, base.2 * 0.55 + m.2 * 0.45)
    }

    /// A reflective sett: stripe widths mirrored, then tiled. Mirroring is
    /// what separates tartan from wallpaper.
    private static func sett(_ draft: Int, _ ncolors: Int) -> [Int] {
        var rng = Seeded(UInt64(bitPattern: Int64(draft &* 104729 &+ 7)))
        let widths = [1, 1, 2, 2, 3, 4, 6, 8]
        var half: [Int] = []
        let target = 15 + rng.int(8)
        while half.count < target {
            let w = min(widths[rng.int(widths.count)], target - half.count)
            let c = rng.int(ncolors)
            half.append(contentsOf: Array(repeating: c, count: w))
        }
        let full = half + half.reversed()
        var line: [Int] = []
        while line.count < 64 { line.append(contentsOf: full) }
        return Array(line.prefix(64))
    }

    // MARK: weave

    private static func weave(_ t: Double, _ pal: [(Double, Double, Double)]) -> [UInt8] {
        let draftLen = 24.0
        let draft = Int(max(0, t) / draftLen)
        var rng = Seeded(UInt64(bitPattern: Int64(draft &* 7919 &+ 3)))
        let motif = rng.int(4), s1 = 4 + rng.int(4)
        let s2 = 3 + rng.int(3), bmotif = rng.int(3)
        let ba = rng.int(pal.count), bb = rng.int(pal.count)
        let shift = Int(t * 0.6)
        let border = 2, band = 6
        let deep = pal.count - 1

        var px = [UInt8](repeating: 0, count: 64 * 64 * 3)
        for y in 0..<64 {
            for x in 0..<64 {
                let o = (y * 64 + x) * 3
                let xm = min(x, 63 - x), ym = min(y, 63 - y)
                var idx: Int
                if x < border || x >= 64 - border || y < border || y >= 64 - border {
                    idx = deep
                } else if y < border + band || y >= 64 - border - band {
                    let bi: Int
                    switch bmotif {
                    case 0: bi = (xm / s2) % 2
                    case 1: bi = ((xm + ym) / s2) % 2
                    default: bi = ((xm / s2) + (ym / s2)) % 2
                    }
                    idx = bi == 1 ? ba : bb
                } else {
                    switch motif {
                    case 0: idx = ((xm + ym) / s1) % pal.count
                    case 1: idx = (max(xm, ym) / s1) % pal.count
                    case 2: idx = ((abs(xm - ym) / s1) + (min(xm, ym) / s1)) % pal.count
                    default: idx = ((min(xm, ym) / s1) * 2 + (xm + ym) / (s1 * 2)) % pal.count
                    }
                }
                put(&px, o, pal[(idx + shift) % pal.count])
            }
        }
        return px
    }

    // MARK: deco

    private static func deco(_ t: Double, _ pal: [(Double, Double, Double)]) -> [UInt8] {
        let cells = 4, c = 64 / cells
        var px = [UInt8](repeating: 0, count: 64 * 64 * 3)
        let flips = Int(max(0, t) / 0.55)

        for k in 0..<(cells * cells) {
            let cy = k / cells, cx = k % cells
            let slot = (k &* 7) % (cells * cells)          // a scattered order
            let seen = max(0, (flips - slot) / (cells * cells)) + 1
            var rng = Seeded(UInt64(bitPattern: Int64(k &* 131 &+ seen &* 17)))
            let motif = rng.int(7)
            let fg = pal[rng.int(pal.count - 1)]
            let bg = rng.int(100) < 55 ? pal[pal.count - 1] : pal[rng.int(pal.count - 1)]

            // the flip: the cell squashes and comes back
            let since = t - Double(slot + (seen - 1) * cells * cells) * 0.55
            var squash = 1.0
            if since >= 0, since < 0.35 { squash = abs(since / 0.35 - 0.5) * 2 }

            for yy in 0..<c {
                for xx in 0..<c {
                    let o = ((cy * c + yy) * 64 + cx * c + xx) * 3
                    if squash < 1 {
                        let h = max(1, Int(Double(c) * squash))
                        let pad = (c - h) / 2
                        guard yy >= pad, yy < pad + h else { continue }
                    }
                    let fx = Double(xx), fy = Double(yy), r = Double(c) / 2
                    let d = hypot(fx - r + 0.5, fy - r + 0.5)
                    let on: Bool
                    switch motif {
                    case 0: on = d < r * 0.72
                    case 1: on = d < r * 0.92 && fy >= r
                    case 2: let h2 = hypot(fx, fy); on = h2 < Double(c) * 0.85 && h2 > Double(c) * 0.45
                    case 3: on = fy >= Double(c) - 1 - 2 * abs(fx - r + 0.5)
                    case 4: on = abs(fx - r + 0.5) < Double(c) * 0.16 || abs(fy - r + 0.5) < Double(c) * 0.16
                    case 5: on = cos(atan2(fy - r + 0.5, fx - r + 0.5) * 8) > 0.25 && d < r * 0.95
                    default: on = (Int(fy + abs(fx - r + 0.5)) / max(1, c / 4)) % 2 == 0
                    }
                    put(&px, o, on ? fg : bg)
                }
            }
        }
        return px
    }

    private static func lerp(_ a: (Double, Double, Double), _ b: (Double, Double, Double),
                             _ k: Double) -> (Double, Double, Double) {
        (a.0 * (1 - k) + b.0 * k, a.1 * (1 - k) + b.1 * k, a.2 * (1 - k) + b.2 * k)
    }
}


/// Drawing the wall's own letters into a raw frame, phone-side. The bit
/// layout mirrors brain/art/pixelfont.py exactly; gen_pixelfont.py keeps the
/// glyphs from drifting, this keeps the drawing from drifting.
enum PixelDraw {
    static func text(_ px: inout [UInt8], _ text: String, x: Int, y: Int,
                     rgb: (UInt8, UInt8, UInt8), scale: Int = 1,
                     width: Int = 64, height: Int = 64) {
        var cx = x
        for ch in text {
            // both scripts: ASCII 5 wide, Hangul 7 wide, unknown = the box
            let (rows, gw, adv, gdy) = PixelFont.cell(ch) ?? (PixelFont.box, 5, 6, 0)
            for (ry, mask) in rows.enumerated() {
                for rx in 0..<gw where mask & (1 << (gw - 1 - rx)) != 0 {
                    for sy in 0..<scale {
                        for sx in 0..<scale {
                            let xx = cx + rx * scale + sx
                            let yy = y + (ry + gdy) * scale + sy
                            guard xx >= 0, xx < width, yy >= 0, yy < height else { continue }
                            let o = (yy * width + xx) * 3
                            px[o] = rgb.0; px[o + 1] = rgb.1; px[o + 2] = rgb.2
                        }
                    }
                }
            }
            cx += adv * scale
        }
    }

    /// The countdown face, matching the brain's Countdown: digits centered,
    /// the border draining clockwise from 12 o'clock, a breathing pulse at
    /// zero. Same idea at phone cost, for the wall that does not exist yet.
    static func countdown(remaining: Double, total: Double,
                          ink: (UInt8, UInt8, UInt8),
                          accent: (Double, Double, Double)) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 64 * 64 * 3)

        if remaining <= 0 {
            let k = 0.35 + 0.65 * (0.5 + 0.5 * sin(Date().timeIntervalSince1970 * 5))
            for i in stride(from: 0, to: px.count, by: 3) {
                px[i] = UInt8(min(255, accent.0 * 255 * k * 0.55))
                px[i + 1] = UInt8(min(255, accent.1 * 255 * k * 0.55))
                px[i + 2] = UInt8(min(255, accent.2 * 255 * k * 0.55))
            }
            digits(&px, 0, ink)
            return px
        }

        let ring = ringPath()
        let lit = Int(Double(ring.count) * max(0, min(1, remaining / max(1, total))))
        for (i, p) in ring.enumerated() {
            let o = (p.1 * 64 + p.0) * 3
            let k = i < lit ? 1.0 : 0.25
            px[o] = UInt8(min(255, accent.0 * 255 * k))
            px[o + 1] = UInt8(min(255, accent.1 * 255 * k))
            px[o + 2] = UInt8(min(255, accent.2 * 255 * k))
        }
        digits(&px, Int(remaining), ink)
        return px
    }

    private static func digits(_ px: inout [UInt8], _ seconds: Int,
                               _ ink: (UInt8, UInt8, UInt8)) {
        let m = seconds / 60, s = seconds % 60
        let text = String(format: "%02d:%02d", m, s)
        let w = PixelFont.textWidth(text, scale: 2)
        PixelDraw.text(&px, text, x: (64 - w) / 2, y: (64 - 14) / 2, rgb: ink, scale: 2)
    }

    /// Clockwise from the top middle, one lap of the border.
    private static func ringPath() -> [(Int, Int)] {
        var p: [(Int, Int)] = []
        for x in 32..<64 { p.append((x, 0)) }
        for y in 1..<64 { p.append((63, y)) }
        for x in stride(from: 62, through: 0, by: -1) { p.append((x, 63)) }
        for y in stride(from: 62, through: 1, by: -1) { p.append((0, y)) }
        for x in 1..<32 { p.append((x, 0)) }
        return p
    }
}


/// The three ways words move, phone-side, mirroring brain/art/text_modes.py
/// the way Patterns mirrors effects.py: same shapes, phone cost, so the
/// words mode works before any wall exists. The wall's own renders stay the
/// truth once it does.
final class TextMover {
    enum Style: String { case across, up, tilt }

    private let style: Style
    private let text: String
    private let color: (UInt8, UInt8, UInt8)
    /// Per-glyph inks, consumed by visible glyphs in order; spaces take
    /// nothing, so the array means the same thing in every style and
    /// survives wrapping. Glyphs past the end wear the base ink.
    private let colors: [(UInt8, UInt8, UInt8)]
    private let loop: Bool
    private let pxPerS: Double

    // across
    private var lineWidth = 0
    // up/tilt: the tall mask and the per-row resampling tables
    private var mask: [Float] = []
    private var maskH = 0
    private var offset = [Double](repeating: 0, count: 64)
    private var span: Double = 0
    private var xi = [[Int]](repeating: [], count: 64)
    private var xok = [[Bool]](repeating: [], count: 64)
    private var fade = [Double](repeating: 1, count: 64)

    init(text raw: String, style: Style, color: (UInt8, UInt8, UInt8),
         loop: Bool, speed: Double = 1.0,
         colors: [(UInt8, UInt8, UInt8)] = []) {
        self.style = style
        self.color = color
        self.colors = colors
        self.loop = loop
        let clean = PixelFont.normalize(raw)
        self.text = clean.isEmpty ? "?" : clean

        switch style {
        case .across:
            pxPerS = 18.0 * max(0.1, speed)
            lineWidth = PixelFont.textWidth(text, scale: 2)
        case .up, .tilt:
            pxPerS = 5.5 * max(0.1, speed)
            buildMask()
            buildRows()
        }
    }

    private func buildMask() {
        let lines = PixelFont.wrap(text, maxWidth: 60, scale: 1)
        let lineH = 9
        maskH = lines.count * lineH + 1
        var rgb = [UInt8](repeating: 0, count: maskH * 64 * 3)
        // Inks are baked into the plane; the resampler then only moves and
        // fades what is already the right colour. The glyph counter runs
        // across lines so a wrapped word keeps its inks.
        var gi = 0
        for (i, ln) in lines.enumerated() {
            var x = (64 - PixelFont.textWidth(ln, scale: 1)) / 2
            for ch in ln {
                if ch != " " {
                    let ink = gi < colors.count ? colors[gi] : color
                    PixelDraw.text(&rgb, String(ch), x: x, y: i * lineH,
                                   rgb: ink, scale: 1,
                                   width: 64, height: maskH)
                    gi += 1
                }
                x += PixelFont.advance
            }
        }
        mask = rgb.map { Float($0) / 255.0 }
    }

    private func buildRows() {
        var scale = [Double](repeating: 1, count: 64)
        for y in 0..<64 {
            let d = Double(y) / 63.0
            if style == .tilt {
                scale[y] = 0.28 + 0.87 * pow(d, 1.35)
                fade[y] = pow(min(1, max(0, (d - 0.05) / 0.30)), 1.2)
            } else {
                fade[y] = min(1, min(d / 0.08, (1 - d) / 0.08))
            }
        }
        var acc = 0.0
        for y in stride(from: 63, through: 0, by: -1) {
            offset[y] = acc
            acc += 1.0 / scale[y]
        }
        span = offset[0]
        let c = 31.5
        for y in 0..<64 {
            var idx = [Int](); idx.reserveCapacity(64)
            var ok = [Bool](); ok.reserveCapacity(64)
            for x in 0..<64 {
                let src = (Double(x) - c) / scale[y] + c
                let i = Int(src.rounded())
                ok.append(i >= 0 && i < 64)
                idx.append(min(63, max(0, i)))
            }
            xi[y] = idx
            xok[y] = ok
        }
    }

    /// One frame at time t, and whether a non-looping run has finished.
    func frame(at t: Double) -> (px: [UInt8], done: Bool) {
        style == .across ? slide(t) : crawl(t)
    }

    private func slide(_ t: Double) -> ([UInt8], Bool) {
        var px = [UInt8](repeating: 0, count: 64 * 64 * 3)
        let travel = Double(lineWidth + 64 + 4)
        let dist = t * pxPerS
        let off = loop ? dist.truncatingRemainder(dividingBy: travel) : min(dist, travel)
        if colors.isEmpty {
            PixelDraw.text(&px, text, x: 64 - Int(off), y: (64 - 14) / 2,
                           rgb: color, scale: 2)
        } else {
            var x = 64 - Int(off)
            var gi = 0
            for ch in text {
                if ch != " " {
                    let ink = gi < colors.count ? colors[gi] : color
                    PixelDraw.text(&px, String(ch), x: x, y: (64 - 14) / 2,
                                   rgb: ink, scale: 2)
                    gi += 1
                }
                x += PixelFont.advance * 2
            }
        }
        return (px, !loop && dist > travel)
    }

    private func crawl(_ t: Double) -> ([UInt8], Bool) {
        var px = [UInt8](repeating: 0, count: 64 * 64 * 3)
        let travel = Double(maskH) + span + 8
        let dist = t * pxPerS
        let p = loop ? dist.truncatingRemainder(dividingBy: travel) : dist
        for y in 0..<64 {
            let src = p - offset[y]
            let lo = Int(src.rounded(.down))
            let frac = Float(src - Double(lo))
            guard lo >= -1, lo < maskH else { continue }
            let f = Float(fade[y])
            guard f > 0.001 else { continue }
            for x in 0..<64 where xok[y][x] {
                let sx = xi[y][x]
                var r: Float = 0, g: Float = 0, b: Float = 0
                if lo >= 0, lo < maskH {
                    let o = (lo * 64 + sx) * 3
                    r += mask[o] * (1 - frac); g += mask[o + 1] * (1 - frac); b += mask[o + 2] * (1 - frac)
                }
                if lo + 1 >= 0, lo + 1 < maskH {
                    let o = ((lo + 1) * 64 + sx) * 3
                    r += mask[o] * frac; g += mask[o + 1] * frac; b += mask[o + 2] * frac
                }
                guard r + g + b > 0.01 else { continue }
                let o = (y * 64 + x) * 3
                px[o] = UInt8(min(255, r * f * 255))
                px[o + 1] = UInt8(min(255, g * f * 255))
                px[o + 2] = UInt8(min(255, b * f * 255))
            }
        }
        return (px, !loop && dist > travel)
    }
}
