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
