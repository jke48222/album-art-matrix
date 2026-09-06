// The pressing.
//
// Every song gets its own record, the kind of exclusive pressing a shop
// puts out for one release, and the way the mockup artists draw them: the
// colours are the sleeve's own, never invented, and the sleeve itself often
// ends up in the disc. The kinds: a marble, smoke in clear vinyl, a
// splatter, a galaxy, half and half, a starburst of wedges, a colour inside
// a colour, a translucent colour with its depth showing, a picture disc,
// and a filled disc with the sleeve's picture floating small in clear
// vinyl. A hash of the song picks the kind (weighted by what the sleeve
// looks like) and seeds the pattern, so the same song always gets the same
// record.
//
// The pressing is rendered flat once, at full resolution, and a shader
// puts it on the platter in true perspective and turns it (RecordWarp.metal).

import CoreGraphics
import UIKit

struct Pressing: Equatable {
    enum Kind: Int, CaseIterable {
        case marble, smoke, splatter, galaxy, half, starburst, ring, translucent, picture, filled
        /// Clear vinyl with the sleeve's dark colour as ink, its bright one
        /// as glowing filaments, and a spray of sparks.
        case electric
        /// The kinds that borrow the sleeve's own shapes, the way the mockup
        /// artists do: its photo as a picture centre in a clear ring; glitter
        /// in clear vinyl with the photo in the middle; concentric bands of its
        /// colours; its line-art etched round the disc; and its most detailed
        /// patches ringed round the edge like swatches.
        case centre, glitter, rings, etched, swatches
    }
    struct RGB: Equatable {
        var r: Float, g: Float, b: Float
        static let white = RGB(r: 0.965, g: 0.965, b: 0.965)
        static let black = RGB(r: 0.06, g: 0.06, b: 0.06)
        static let clear = RGB(r: 0.84, g: 0.87, b: 0.90)
        var luma: Float { 0.2126 * r + 0.7152 * g + 0.0722 * b }
        var sat: Float { let mx = max(r, max(g, b)), mn = min(r, min(g, b)); return mx <= 0.001 ? 0 : (mx - mn) / mx }
        func mix(_ o: RGB, _ t: Float) -> RGB {
            let k = max(0, min(1, t)); return RGB(r: r + (o.r - r) * k, g: g + (o.g - g) * k, b: b + (o.b - b) * k)
        }
        var tint: RGB { mix(.white, 0.42) }
        var shade: RGB { mix(.black, 0.38) }
    }
    let key: String
    let kind: Kind
    /// c0 the sleeve's main colour, c1 its second, c2 a third; where the
    /// sleeve has fewer, tints and shades of its own, never another hue.
    let colours: [RGB]
    let seed: UInt64

    static func make(key: String, palette: [RGB], hasPicture: Bool, title: String = "", artist: String = "", forced: Int? = nil) -> Pressing {
        var h: UInt64 = 0xcbf29ce484222325
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        var rng = SplitMix(h)
        // the kinds, weighted by the sleeve: a mostly monochrome sleeve
        // wants its one colour in smoke or marble, a picture wants to be in
        // the disc, two strong colours want to be set against each other
        let saturated = palette.filter { $0.sat > 0.28 && $0.luma > 0.08 }.count
        var weights: [(Kind, Int)] = [(.marble, 3), (.smoke, 3), (.splatter, 3), (.galaxy, 2), (.half, 1),
                                      (.starburst, 1), (.ring, 2), (.translucent, 1), (.electric, 1)]
        if hasPicture { weights += [(.picture, 1), (.centre, 3), (.glitter, 3), (.etched, 3), (.swatches, 2)] }
        if saturated >= 2 { weights += [(.rings, 3)] }
        if saturated < 2 { weights = weights.map { ($0.0, [.marble, .smoke, .splatter, .translucent].contains($0.0) ? $0.1 + 3 : $0.1) } }
        if saturated >= 2 { weights = weights.map { ($0.0, [.half, .ring, .galaxy].contains($0.0) ? $0.1 + 2 : $0.1) } }
        let total = weights.reduce(0) { $0 + $1.1 }
        var pick = Int(rng.next() % UInt64(total))
        var kind = Kind.marble
        for (k, w) in weights { if pick < w { kind = k; break }; pick -= w }
        // An art-directed interpretation of the user's CHAT mockup, not a
        // claim that this colourway is a commercially released pressing.
        let chat = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "girlset"
            && title.lowercased().split(whereSeparator: { !$0.isLetter }).first == "chat"
        var cols = palette
        if chat {
            kind = .electric
            cols = [RGB(r: 0.025, g: 0.065, b: 0.82), .white, RGB(r: 0.025, g: 0.70, b: 0.91)]
        }
        if let forced, let k = Kind(rawValue: forced) { kind = k }
        if cols.isEmpty { cols = [.black, .white] }
        if cols.count < 2 { cols.append(cols[0].luma > 0.6 ? cols[0].shade : cols[0].tint) }
        if cols.count < 3 { cols.append(cols[0].luma > 0.45 ? RGB.white : RGB.black) }
        return Pressing(key: key, kind: kind, colours: Array(cols.prefix(3)), seed: h)
    }

    /// Area-weighted sleeve colours, including its neutrals. Keep the sampled
    /// RGB values intact; no hue substitutions or saturation boosts.
    static func palette(of image: UIImage?) -> [RGB] {
        guard let cg = image?.cgImage else { return [] }
        let n = 32
        var buf = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &buf, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        // buckets by hue for colour, by lightness for the neutrals
        var buckets: [Int: (w: Float, r: Float, g: Float, b: Float)] = [:]
        for i in 0..<(n * n) {
            let c = RGB(r: Float(buf[i * 4]) / 255, g: Float(buf[i * 4 + 1]) / 255, b: Float(buf[i * 4 + 2]) / 255)
            let k: Int
            if c.sat < 0.18 || c.luma < 0.06 {
                k = 100 + Int(c.luma * 3.99)                       // black, dark grey, light grey, white
            } else {
                var hue: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
                UIColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1).getHue(&hue, saturation: &s, brightness: &v, alpha: &a)
                k = Int(hue * 12) % 12
            }
            let w: Float = Float(buf[i * 4 + 3]) / 255
            guard w > 0.1 else { continue }
            let e = buckets[k] ?? (0, 0, 0, 0)
            buckets[k] = (e.w + w, e.r + c.r * w, e.g + c.g * w, e.b + c.b * w)
        }
        let top = buckets.sorted { $0.value.w == $1.value.w ? $0.key < $1.key : $0.value.w > $1.value.w }.prefix(3)
        return top.map { e in
            let c = e.value
            return RGB(r: c.r / c.w, g: c.g / c.w, b: c.b / c.w)
        }
    }
}

/// A small deterministic generator, so a song's splatter is its splatter.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
}

/// Value noise and its fractal sum, the grain every pattern is made of.
struct Noise {
    let seed: UInt32
    @inline(__always) func hash(_ x: Int32, _ y: Int32) -> Float {
        var h = UInt32(bitPattern: x) &* 374761393 &+ UInt32(bitPattern: y) &* 668265263 &+ seed &* 2246822519
        h = (h ^ (h >> 13)) &* 1274126177
        h ^= h >> 16
        return Float(h & 0xffffff) / Float(0x1000000)
    }
    @inline(__always) func value(_ x: Float, _ y: Float) -> Float {
        let fx = floor(x), fy = floor(y)
        let ix = Int32(fx), iy = Int32(fy)
        var tx = x - fx, ty = y - fy
        tx = tx * tx * (3 - 2 * tx); ty = ty * ty * (3 - 2 * ty)
        let a = hash(ix, iy), b = hash(ix + 1, iy), c = hash(ix, iy + 1), d = hash(ix + 1, iy + 1)
        let top = a + (b - a) * tx, bottom = c + (d - c) * tx
        return top + (bottom - top) * ty
    }
    func fbm(_ x: Float, _ y: Float, octaves: Int = 4) -> Float {
        var sum: Float = 0, amp: Float = 0.5, fx = x, fy = y, norm: Float = 0
        for _ in 0..<octaves {
            sum += value(fx, fy) * amp; norm += amp
            fx = fx * 2.03 + 17.1; fy = fy * 1.97 + 9.3; amp *= 0.5
        }
        return sum / norm
    }
}

/// The pressing as a picture: the disc on a clear square, at full
/// resolution, rendered once per song.
enum RecordDesign {
    static let side = 512
    static let label: Float = 0.337          // the label's radius over the record's

    @inline(__always) static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t)
    }

    static func render(_ p: Pressing, sleeve: UIImage?, printed: UIImage? = nil) -> UIImage? {
        let n = side
        var out = [UInt8](repeating: 0, count: n * n * 4)
        let c0 = p.colours[0], c1 = p.colours[1], c2 = p.colours[2]
        var rng = SplitMix(p.seed ^ 0x77)
        let noise = Noise(seed: UInt32(truncatingIfNeeded: p.seed))
        let noise2 = Noise(seed: UInt32(truncatingIfNeeded: p.seed >> 32) ^ 0x9e37)
        let phase = rng.unit() * 6.2832
        let whiteBase = rng.unit() < 0.5
        // drops for the splatter, wisps for the smoke
        var drops: [(x: Float, y: Float, r: Float, c: Int)] = []
        for _ in 0..<(70 + Int(rng.unit() * 90)) {
            let a = rng.unit() * 6.2832, d = 0.36 + rng.unit() * 0.63
            let r = 0.008 + rng.unit() * rng.unit() * rng.unit() * 0.09
            drops.append((cos(a) * d, sin(a) * d, r, rng.unit() < 0.7 ? 1 : 2))
        }
        var wisps: [(x: Float, y: Float, r: Float)] = []
        for _ in 0..<(3 + Int(rng.unit() * 4)) {
            let a = rng.unit() * 6.2832, d = 0.4 + rng.unit() * 0.55
            wisps.append((cos(a) * d, sin(a) * d, 0.16 + rng.unit() * 0.3))
        }
        let wedges = 6 + Int(rng.unit() * 4) * 2
        let seam = rng.unit() * 6.2832
        // sparks: two bursts of radial streaks, bright at the head, rasterised
        // once into their own layer; filaments are ridged noise, per pixel
        var sparks = [Float](repeating: 0, count: n * n)
        let sparkly = [.electric, .splatter, .half, .starburst].contains(p.kind)
        if sparkly {
            let burstAngle = rng.unit() * 6.2832
            let bursts = [(burstAngle, Float(0.7)), (burstAngle + 2.7, Float(0.5))]
            for (centre, spread) in bursts {
                for _ in 0..<(120 + Int(rng.unit() * 160)) {
                    let a = centre + (rng.unit() - 0.5) * spread * 2
                    let r0 = 0.36 + rng.unit() * 0.6
                    let len = 0.006 + rng.unit() * rng.unit() * 0.075
                    let bright = 0.5 + rng.unit() * 0.5
                    let ca = cos(a), sa = sin(a)
                    var s: Float = 0
                    while s < len {
                        let rr = r0 + s
                        if rr > 0.99 { break }
                        let fx = (rr * ca + 1) * 0.5 * Float(n), fy = (1 - rr * sa) * 0.5 * Float(n)
                        let taper = 1 - s / len
                        let ix = Int(fx), iy = Int(fy)
                        for dy in -1...1 { for dx in -1...1 {
                            let x = ix + dx, y = iy + dy
                            guard x >= 0, y >= 0, x < n, y < n else { continue }
                            let w: Float = (dx == 0 && dy == 0) ? 1 : 0.35
                            sparks[y * n + x] = min(1.6, sparks[y * n + x] + bright * (0.35 + 0.65 * taper) * w)
                        } }
                        s += 1.6 / Float(n)
                    }
                }
            }
        }
        let glowTone = c0.sat > 0.25 ? c0 : (c1.sat > 0.25 ? c1 : c0)
        let inkTone = glowTone.mix(.black, 0.68)
        let sparkTone = p.kind == .electric ? Pressing.RGB.white : (whiteBase ? c0 : c1)
        // the sleeve, for every kind that puts it in the disc
        var pic: [UInt8] = []; let pn = 256
        if [.picture, .filled, .centre, .glitter, .etched, .swatches].contains(p.kind), let cg = sleeve?.cgImage {
            pic = [UInt8](repeating: 0, count: pn * pn * 4)
            let ok: Bool = pic.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: pn, height: pn, bitsPerComponent: 8, bytesPerRow: pn * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: pn, height: pn))
                return true
            }
            if !ok { pic = [] }
        }
        func sample(_ u: Float, _ v: Float) -> Pressing.RGB {
            guard !pic.isEmpty else { return c0 }
            let x = max(0, min(pn - 1, Int(u * Float(pn)))), y = max(0, min(pn - 1, Int(v * Float(pn))))
            let o = (y * pn + x) * 4
            return .init(r: Float(pic[o]) / 255, g: Float(pic[o + 1]) / 255, b: Float(pic[o + 2]) / 255)
        }
        // the sleeve's lines, for the etched disc: a Sobel edge map of it
        var edges: [Float] = []
        if p.kind == .etched, !pic.isEmpty {
            var grey = [Float](repeating: 0, count: pn * pn)
            for i in 0..<(pn * pn) { grey[i] = (0.299 * Float(pic[i * 4]) + 0.587 * Float(pic[i * 4 + 1]) + 0.114 * Float(pic[i * 4 + 2])) / 255 }
            edges = [Float](repeating: 0, count: pn * pn)
            for y in 1..<(pn - 1) {
                for x in 1..<(pn - 1) {
                    let gx = grey[(y - 1) * pn + x + 1] + 2 * grey[y * pn + x + 1] + grey[(y + 1) * pn + x + 1]
                           - grey[(y - 1) * pn + x - 1] - 2 * grey[y * pn + x - 1] - grey[(y + 1) * pn + x - 1]
                    let gy = grey[(y + 1) * pn + x - 1] + 2 * grey[(y + 1) * pn + x] + grey[(y + 1) * pn + x + 1]
                           - grey[(y - 1) * pn + x - 1] - 2 * grey[(y - 1) * pn + x] - grey[(y - 1) * pn + x + 1]
                    edges[y * pn + x] = min(1, (gx * gx + gy * gy).squareRoot() * 2.4)
                }
            }
        }
        func edge(_ u: Float, _ v: Float) -> Float {
            guard !edges.isEmpty else { return 0 }
            let x = max(0, min(pn - 1, Int(u * Float(pn)))), y = max(0, min(pn - 1, Int(v * Float(pn))))
            return edges[y * pn + x]
        }
        // the sleeve's most detailed patches, for the swatch ring: eight
        // cells of a six by six grid, by variance
        var patches: [(u: Float, v: Float)] = []
        if p.kind == .swatches, !pic.isEmpty {
            var scored: [(Float, Float, Float)] = []
            let cell = pn / 6
            for gy in 0..<6 { for gx in 0..<6 {
                var sum: Float = 0, sq: Float = 0, cnt: Float = 0
                for y in stride(from: gy * cell, to: gy * cell + cell, by: 3) { for x in stride(from: gx * cell, to: gx * cell + cell, by: 3) {
                    let o = (y * pn + x) * 4
                    let l = (0.299 * Float(pic[o]) + 0.587 * Float(pic[o + 1]) + 0.114 * Float(pic[o + 2])) / 255
                    sum += l; sq += l * l; cnt += 1
                } }
                let mean = sum / cnt
                scored.append((sq / cnt - mean * mean, Float(gx) / 6, Float(gy) / 6))
            } }
            scored.sort { $0.0 > $1.0 }
            patches = scored.prefix(8).map { ($0.1, $0.2) }
            var g = SplitMix(p.seed ^ 0x51)
            patches.shuffle(using: &g)
        }
        // glitter: flecks in clear vinyl, rasterised once, a few of them lit
        var glitter = [Float](repeating: 0, count: n * n)
        var glitterHue = [UInt8](repeating: 0, count: n * n)
        if p.kind == .glitter || p.kind == .swatches {
            let count = p.kind == .glitter ? 2600 : 700
            let rMin: Float = p.kind == .glitter ? (pic.isEmpty ? 0.35 : 0.64) : 0.35
            let rMax: Float = p.kind == .glitter ? 0.985 : 0.64
            for _ in 0..<count {
                let a = rng.unit() * 6.2832, d = rMin + (rMax - rMin) * rng.unit().squareRoot()
                let fx = (cos(a) * d + 1) * 0.5 * Float(n), fy = (1 - sin(a) * d) * 0.5 * Float(n)
                let size = rng.unit() < 0.2 ? 2 : 1
                let lit: Float = rng.unit() < 0.18 ? 1.6 : 1.0
                let hue: UInt8 = rng.unit() < 0.7 ? 0 : 1
                for dy in -size...size { for dx in -size...size {
                    let x = Int(fx) + dx, y = Int(fy) + dy
                    guard x >= 0, y >= 0, x < n, y < n, dx * dx + dy * dy <= size * size + 1 else { continue }
                    glitter[y * n + x] = max(glitter[y * n + x], lit)
                    glitterHue[y * n + x] = hue
                } }
            }
        }
        let clearTint = Pressing.RGB.clear.mix(c0, 0.10)

        let inv = 2 / Float(n)
        for py in 0..<n {
            if Task.isCancelled { return nil }
            let y = 1 - (Float(py) + 0.5) * inv
            for px in 0..<n {
                let x = (Float(px) + 0.5) * inv - 1
                let r = (x * x + y * y).squareRoot()
                let o = (py * n + px) * 4
                if r > 1.0 { continue }
                let theta = atan2(y, x)
                var c: Pressing.RGB
                var transmission: Float = 1
                if r < label {
                    // the paper under the label; the sleeve is laid over it live
                    c = Pressing.RGB(r: 0.93, g: 0.91, b: 0.86)
                    if r < 0.025 { c = Pressing.RGB(r: 0.75, g: 0.73, b: 0.70) }
                } else {
                    // domain warp: the flow every marble and smoke has
                    let wx = x * 2.2 + 1.6 * noise.fbm(x * 1.7 + phase, y * 1.7, octaves: 3)
                    let wy = y * 2.2 + 1.6 * noise.fbm(x * 1.7, y * 1.7 - phase, octaves: 3)
                    let f1 = noise.fbm(wx, wy)
                    let f2 = noise2.fbm(wx * 1.3 + 4.2, wy * 1.3 - 2.1)
                    switch p.kind {
                    case .marble:
                        let flow = x * 1.8 + y * 0.65 + (f1 - 0.5) * 4.2
                        let folds = sin(flow * 12 + sin(wy * 2.6) * 3)
                        c = c0.mix(c1, smooth(-0.7, 0.75, folds))
                        let thread = abs(sin(flow * 30 + f2 * 7))
                        c = c.mix(c2, smooth(0.97, 1, thread) * 0.38)
                    case .smoke:
                        var dens: Float = 0
                        for w in wisps {
                            let d2 = (x - w.x) * (x - w.x) + (y - w.y) * (y - w.y)
                            dens += exp(-d2 / (w.r * w.r * 0.55))
                        }
                        let t = min(1, dens * (0.55 + 0.9 * f1) + smooth(0.62, 0.9, f2) * 0.7)
                        let ink = c0.luma > 0.75 ? c1 : c0
                        let ribbon = pow(abs(sin(wx * 8 + wy * 3 + f2 * 5)), 12)
                        let density = min(1, t * 0.8 + ribbon * 0.65)
                        c = Pressing.RGB.clear.mix(ink, density)
                        transmission = 0.65 + 0.35 * density
                    case .splatter:
                        let base = whiteBase ? Pressing.RGB.white : c0
                        c = base
                        var best: Float = 0; var which = 0
                        for d in drops {
                            let dx = x - d.x, dy = y - d.y
                            let distance = max(0.001, hypot(d.x, d.y))
                            let along = (dx * d.x + dy * d.y) / distance
                            let across = (-dx * d.y + dy * d.x) / distance
                            let rr = d.r * (0.85 + 0.3 * f2)
                            let s = rr * rr / max(0.00001, along * along * 0.12 + across * across * 2.5)
                            if s > best { best = s; which = d.c }
                        }
                        if best > 1 { c = which == 1 ? (whiteBase ? c0 : c1) : c2 }
                    case .galaxy:
                        let t1 = smooth(0.3, 0.7, f1)
                        c = c0.mix(c1, t1).mix(c2, smooth(0.58, 0.85, f2))
                        let swirl = abs(sin((x + f1 * 2.4) * 16 + y * 5))
                        c = c.mix(c1, smooth(0.96, 1, swirl) * 0.42)
                    case .half:
                        let xs = x * cos(seam) - y * sin(seam) + (f1 - 0.5) * 0.16
                        c = c0.mix(c1, smooth(-0.012, 0.012, xs))
                    case .starburst:
                        let a = (theta + seam) / 6.2832
                        let w = (a - floor(a)) * Float(wedges)
                        let k = Int(w) & 1
                        let frac = w - floor(w)
                        let edge = min(frac, 1 - frac)
                        let soft = smooth(0.0, 0.03, edge)
                        c = (k == 0 ? c0 : c1).mix(k == 0 ? c1 : c0, 0.5 * (1 - soft))
                        c = c.mix(c.tint, (f2 - 0.5) * 0.25)
                    case .ring:
                        let inner = c1.mix(c1.tint, smooth(0.35, 0.7, f1) * 0.5)
                        c = inner.mix(c0, smooth(0.66, 0.69, r + (f2 - 0.5) * 0.13))
                    case .translucent:
                        let depth = (r - label) / (1 - label)
                        c = c0.mix(.white, 0.05 + 0.17 * depth + (f1 - 0.5) * 0.12)
                        transmission = 0.72 + 0.22 * (1 - depth)
                    case .picture:
                        c = sample((x + 1) / 2, (1 - y) / 2).mix(c0, 0.12)
                    case .filled:
                        // Small picture medallions suspended around a clear disc.
                        c = Pressing.RGB.clear.mix(c0, 0.08); transmission = 0.65
                        for index in 0..<10 {
                            let a = Float(index) * 6.2832 / 10 + phase
                            let dx = x - cos(a) * 0.72, dy = y - sin(a) * 0.72
                            let d = hypot(dx, dy)
                            if d < 0.145 {
                                c = d > 0.133 ? c0 : sample(dx / 0.29 + 0.5, 0.5 - dy / 0.29)
                                transmission = 0.97
                            }
                        }
                    case .centre:
                        // the photo as the middle of the disc, out to well past the
                        // label, in a clear ring tinted with the sleeve's colour
                        if r < 0.64 {
                            c = sample((x / 0.64 + 1) / 2, (1 - y / 0.64) / 2)
                            if r > 0.625 { c = c.mix(.white, smooth(0.625, 0.64, r) * 0.5) }
                        } else {
                            c = clearTint; transmission = 0.62
                            let g = noise2.fbm(x * 9, y * 9, octaves: 2)
                            if g > 0.78 { c = c.mix(c0.tint, (g - 0.78) * 3) }
                        }
                    case .glitter:
                        if !pic.isEmpty, r < 0.64 {
                            c = sample((x / 0.64 + 1) / 2, (1 - y / 0.64) / 2)
                            if r > 0.62 { c = c.mix(clearTint, smooth(0.62, 0.64, r)) }
                        } else {
                            c = Pressing.RGB.clear.mix(c0, 0.04); transmission = 0.6
                        }
                        let gl = glitter[py * n + px]
                        if gl > 0 {
                            let fleck = glitterHue[py * n + px] == 0 ? c0 : (c1.sat > 0.2 ? c1 : c0.shade)
                            c = c.mix(fleck, 0.9); transmission = max(transmission, 0.9)
                            if gl > 1.2 { c = c.mix(.white, 0.7) }
                        }
                    case .rings:
                        // the sleeve's colours as nested bands, the way a sleeve
                        // built from nested shapes reads, with hairline geometry
                        let bands: Float = 7
                        let t = (r - label) / (1 - label)
                        let band = floor(t * bands) / (bands - 1)
                        let soft = smooth(0.0, 0.02, (t * bands) - floor(t * bands)) * 0.06
                        let seq = band < 0.5 ? c2.mix(c1, band * 2) : c1.mix(c0, (band - 0.5) * 2)
                        c = seq.mix(.white, soft + 0.04 * sin(r * 300))
                        let lines = abs(sin(theta * 8)) < 0.008 || abs(sin(theta * 8 + 0.39)) < 0.008
                        if lines { c = c.mix(.white, 0.28) }
                    case .etched:
                        // the sleeve's own lines, wrapped twice round the disc in
                        // clear vinyl, drawn as etched silver, with dark specks
                        c = clearTint; transmission = 0.6
                        let band = (r - 0.40) / 0.58
                        if band >= 0 && band <= 1 {
                            let around = (theta / 6.2832 + 1.0).truncatingRemainder(dividingBy: 0.5) * 2
                            let e = edge(around, 1 - band)
                            let silver = Pressing.RGB(r: 0.88, g: 0.90, b: 0.94)
                            c = c.mix(silver, smooth(0.18, 0.6, e) * 0.9).mix(c0.shade, smooth(0.6, 1.0, e) * 0.75)
                            transmission = min(1, 0.6 + e * 0.4)
                        }
                        var best: Float = 0
                        for d in drops.prefix(60) {
                            let dx = x - d.x, dy = y - d.y
                            let rr = d.r * 0.45
                            best = max(best, rr * rr / max(0.00001, dx * dx + dy * dy))
                        }
                        if best > 1 { c = Pressing.RGB.black.mix(c0.shade, 0.3); transmission = 1 }
                    case .swatches:
                        // eight patches of the sleeve set round the edge, clear
                        // between them, silver inside with glitter of the accent
                        c = Pressing.RGB(r: 0.78, g: 0.79, b: 0.81); transmission = 0.75
                        if r > 0.66 {
                            let sectors: Float = 8
                            let a = ((theta + seam) / 6.2832 + 1).truncatingRemainder(dividingBy: 1) * sectors
                            let idx = Int(a) % 8, frac = a - floor(a)
                            if frac > 0.06 && frac < 0.94, idx < patches.count {
                                let pt = patches[idx]
                                let u = pt.u + (frac - 0.06) / 0.88 / 6, v = pt.v + (0.98 - r) / 0.32 / 6
                                c = sample(u, v); transmission = 1
                            } else { c = clearTint; transmission = 0.6 }
                        } else {
                            let gl = glitter[py * n + px]
                            if gl > 0 { c = c.mix(c0.sat > 0.2 ? c0 : c1, 0.9); if gl > 1.2 { c = c.mix(.white, 0.6) }; transmission = 1 }
                        }
                    case .electric:
                        // Layered smoke, with only a few thin bright folds. The
                        // body stays tonal instead of becoming contour-map stripes.
                        let plume = smooth(0.25, 0.68, f1)
                        let fold = sin(wx * 6 + wy * 2 + f2 * 8)
                        let fine = pow(abs(fold), 14)
                        let density = min(1, plume * 0.90 + fine * 0.22)
                        c = Pressing.RGB.clear.mix(inkTone, density)
                        transmission = 0.74 + 0.26 * density
                        let ridge = exp(-pow((f2 - 0.52) * 80, 2))
                        let window = smooth(0.35, 0.58, f1) * (1 - smooth(0.63, 0.8, f1))
                        let cyan = c2.sat > 0.2 ? c2 : glowTone.tint
                        c = c.mix(cyan, ridge * window * 0.95)
                    }
                    let sp = sparks[py * n + px]
                    if sp > 0 { c = c.mix(sparkTone, min(1, sp)).mix(.white, min(1, sp * sp * 0.5)) }
                    // the grooves, and the run-out's darker band
                    let groove: Float = 1 - 0.045 * (0.5 + 0.5 * sin(r * 620))
                    let deadwax: Float = r < label + 0.035 ? 0.9 : 1
                    let k = groove * deadwax
                    c = Pressing.RGB(r: c.r * k, g: c.g * k, b: c.b * k)
                }
                // Rim catches light; directional reflections are added in screen
                // space by RecordView so they do not spin with the pigment.
                if r > 0.985 { c = c.mix(.white, 0.20) }
                let alpha = smooth(1.0, 0.994, r) * transmission
                out[o] = UInt8(max(0, min(255, c.r * 255 * alpha)))
                out[o + 1] = UInt8(max(0, min(255, c.g * 255 * alpha)))
                out[o + 2] = UInt8(max(0, min(255, c.b * 255 * alpha)))
                out[o + 3] = UInt8(max(0, min(255, alpha * 255)))
            }
        }
        // the printed label, in the middle, so it turns with the record and
        // sits in the same perspective; a picture centre carries no label,
        // only a small spindle plate
        if p.kind == .centre || (p.kind == .glitter && !pic.isEmpty) {
            out.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                let cx = CGFloat(n) / 2, plate: CGFloat = 0.075 * CGFloat(n) / 2
                let colours = [UIColor(white: 0.92, alpha: 1).cgColor, UIColor(white: 0.55, alpha: 1).cgColor, UIColor(white: 0.80, alpha: 1).cgColor] as CFArray
                ctx.saveGState()
                ctx.addEllipse(in: CGRect(x: cx - plate, y: cx - plate, width: plate * 2, height: plate * 2)); ctx.clip()
                if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours, locations: [0, 0.6, 1]) {
                    ctx.drawLinearGradient(g, start: CGPoint(x: cx - plate, y: cx - plate), end: CGPoint(x: cx + plate, y: cx + plate), options: [])
                }
                ctx.restoreGState()
                ctx.setFillColor(UIColor(white: 0.12, alpha: 1).cgColor)
                ctx.fillEllipse(in: CGRect(x: cx - 6, y: cx - 6, width: 12, height: 12))
            }
        } else if let printed, let lcg = printed.cgImage {
            out.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                let rad = CGFloat(Self.label) * CGFloat(n) / 2
                let box = CGRect(x: CGFloat(n) / 2 - rad, y: CGFloat(n) / 2 - rad, width: rad * 2, height: rad * 2)
                ctx.addEllipse(in: box); ctx.clip()
                ctx.interpolationQuality = .high
                ctx.draw(lcg, in: box)
            }
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let cg = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

