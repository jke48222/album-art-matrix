// The wall's emitters, rastered by hand into a byte buffer.
//
// Moved out of EmitterTile (Archive.swift) so the widget draws emitters by
// exactly the rules the app's archive, WallThumb and finish swatches use: a
// supersampled circle of radius 0.35 cell, lit when any channel reaches 8,
// the unlit lattice at 12.75, and duty dimming lit emitters only. The widget
// used to stretch a 384 pixel bitmap drawn by different rules, so the same
// wall looked softer and greyer on the Home Screen than in the app.
//
// CoreGraphics only: the app wraps the CGImage in a UIImage and caches it,
// the widget hands it to SwiftUI, and the Mac-side tests read the bytes.

import CoreGraphics
import Foundation

enum EmitterRaster {
    static let litFloor: UInt8 = 8
    static let unlit = 12.75
    /// The largest raster worth making: a tile in a dense grid is the same
    /// size on screen whether it holds 4,096 emitters or 36,864.
    static let maxSide = 768

    /// The cell that reaches a target pixel size without upscaling, capped so
    /// the raster stays at or under maxSide. A 170 pt panel at 3x is 510 px:
    /// 64 emitters at cell 8 (512 px), 192 at cell 3 (576 px).
    static func cell(forPixels target: CGFloat, side n: Int) -> Int {
        guard n > 0, target.isFinite, target > 0 else { return 1 }
        return max(1, min(Int((target / CGFloat(n)).rounded(.up)), maxSide / n))
    }

    /// FNV-1a over the whole buffer, for caches. A prefix hash would call
    /// two frames with the same dark top the same frame.
    static func digest(_ bytes: [UInt8]) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in bytes { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    /// Circle coverage across one cell, supersampled once per cell size and
    /// shared by every emitter of every raster at that size.
    private static var masks: [Int: [Double]] = [:]
    /// The shelf rasters off the main thread while the archive rasters on it.
    private static let maskLock = NSLock()

    static func mask(_ cell: Int) -> [Double] {
        maskLock.lock(); defer { maskLock.unlock() }
        if let m = masks[cell] { return m }
        let r = Double(cell) * 0.35
        let mid = Double(cell) / 2
        let ss = 4
        var m = [Double](repeating: 0, count: cell * cell)
        for y in 0..<cell {
            for x in 0..<cell {
                var hit = 0
                for sy in 0..<ss {
                    for sx in 0..<ss {
                        let dx = Double(x) + (Double(sx) + 0.5) / Double(ss) - mid
                        let dy = Double(y) + (Double(sy) + 0.5) / Double(ss) - mid
                        if dx * dx + dy * dy <= r * r { hit += 1 }
                    }
                }
                m[y * cell + x] = Double(hit) / Double(ss * ss)
            }
        }
        masks[cell] = m
        return m
    }

    /// RGBX bytes (the fourth byte 255) of a square RGB888 frame, `cell`
    /// pixels an emitter. Nil when the frame is not a square.
    static func raster(_ px: [UInt8], cell: Int, duty: Double = 1) -> (side: Int, rgba: [UInt8])? {
        guard let n = Panel.square(px.count) else { return nil }
        let c = max(1, min(cell, maxSide / n))
        let d = max(0.05, min(1.0, duty))
        let side = n * c
        let m = mask(c)
        var buf = [UInt8](repeating: 0, count: side * side * 4)
        buf.withUnsafeMutableBufferPointer { out in
            px.withUnsafeBufferPointer { pin in
                for i in 0..<(n * n) {
                    let o = i * 3
                    let lit = pin[o] >= litFloor || pin[o + 1] >= litFloor || pin[o + 2] >= litFloor
                    let er = lit ? Double(pin[o]) * d : unlit
                    let eg = lit ? Double(pin[o + 1]) * d : unlit
                    let eb = lit ? Double(pin[o + 2]) * d : unlit
                    let x0 = (i % n) * c
                    let y0 = (i / n) * c
                    for yy in 0..<c {
                        var at = ((y0 + yy) * side + x0) * 4
                        let row = yy * c
                        for xx in 0..<c {
                            let cov = m[row + xx]
                            out[at] = UInt8(min(255, er * cov))
                            out[at + 1] = UInt8(min(255, eg * cov))
                            out[at + 2] = UInt8(min(255, eb * cov))
                            out[at + 3] = 255
                            at += 4
                        }
                    }
                }
            }
        }
        return (side, buf)
    }

    static func render(_ px: [UInt8], cell: Int, duty: Double = 1) -> CGImage? {
        guard let (side, rgba) = raster(px, cell: cell, duty: duty) else { return nil }
        return image(side: side, rgba: rgba)
    }

    /// Whether a panel of `n` emitters shown `target` pixels wide is better
    /// rastered at that exact size. A dense wall does not divide the
    /// widget's pixels: 192 emitters in 510 px would be drawn at cell 3
    /// (576 px) and scaled by 0.885, and that resampling beats against the
    /// lattice into a plaid, some rows of emitters brighter than others.
    static func wantsExact(pixels target: CGFloat, side n: Int) -> Bool {
        guard n > 0, target.isFinite, target >= 1 else { return false }
        let pitch = target / CGFloat(n)
        return pitch < 4 && abs(pitch - pitch.rounded()) > 0.01
    }

    /// The same emitters rastered at exactly `pixels` a side, centres at a
    /// fractional pitch ((i + 0.5) x pixels / n), each pixel supersampled
    /// 4 x 4 against the circles it touches. By the same rules as
    /// raster(_:cell:duty:), and byte for byte the same when the pitch is
    /// a whole number.
    static func raster(_ px: [UInt8], pixels target: Int, duty: Double = 1) -> (side: Int, rgba: [UInt8])? {
        guard let n = Panel.square(px.count), target > 0 else { return nil }
        let side = min(target, maxSide)
        let d = max(0.05, min(1.0, duty))
        let pitch = Double(side) / Double(n)
        let r = pitch * 0.35
        let ss = 4
        // Along either axis, every subsample's emitter and its offset from
        // that emitter's centre.
        var index = [Int](repeating: 0, count: side * ss)
        var offset = [Double](repeating: 0, count: side * ss)
        for u in 0..<(side * ss) {
            let at = Double(u / ss) + (Double(u % ss) + 0.5) / Double(ss)
            let i = min(n - 1, Int(at / pitch))
            index[u] = i
            offset[u] = at - (Double(i) + 0.5) * pitch
        }
        var emit = [Double](repeating: 0, count: n * n * 3)
        for i in 0..<(n * n) {
            let o = i * 3
            let lit = px[o] >= litFloor || px[o + 1] >= litFloor || px[o + 2] >= litFloor
            emit[o] = lit ? Double(px[o]) * d : unlit
            emit[o + 1] = lit ? Double(px[o + 1]) * d : unlit
            emit[o + 2] = lit ? Double(px[o + 2]) * d : unlit
        }
        let whole = Double(ss * ss)
        var buf = [UInt8](repeating: 0, count: side * side * 4)
        buf.withUnsafeMutableBufferPointer { out in
            for y in 0..<side {
                for x in 0..<side {
                    // Hits per emitter touched. A pixel is narrower than a
                    // pitch, so it touches at most two emitters on each axis.
                    var ids = (-1, -1, -1, -1)
                    var hits = (0, 0, 0, 0)
                    for sy in 0..<ss {
                        let v = y * ss + sy
                        let dy = offset[v]
                        let row = index[v] * n
                        for sx in 0..<ss {
                            let u = x * ss + sx
                            let dx = offset[u]
                            guard dx * dx + dy * dy <= r * r else { continue }
                            let e = row + index[u]
                            if ids.0 == e || ids.0 < 0 { ids.0 = e; hits.0 += 1 }
                            else if ids.1 == e || ids.1 < 0 { ids.1 = e; hits.1 += 1 }
                            else if ids.2 == e || ids.2 < 0 { ids.2 = e; hits.2 += 1 }
                            else { ids.3 = e; hits.3 += 1 }
                        }
                    }
                    var cr = 0.0, cg = 0.0, cb = 0.0
                    func add(_ e: Int, _ h: Int) {
                        guard e >= 0 else { return }
                        let cov = Double(h) / whole
                        cr += emit[e * 3] * cov
                        cg += emit[e * 3 + 1] * cov
                        cb += emit[e * 3 + 2] * cov
                    }
                    add(ids.0, hits.0); add(ids.1, hits.1); add(ids.2, hits.2); add(ids.3, hits.3)
                    let at = (y * side + x) * 4
                    out[at] = UInt8(min(255, cr))
                    out[at + 1] = UInt8(min(255, cg))
                    out[at + 2] = UInt8(min(255, cb))
                    out[at + 3] = 255
                }
            }
        }
        return (side, buf)
    }

    static func render(_ px: [UInt8], pixels: Int, duty: Double = 1) -> CGImage? {
        guard let (side, rgba) = raster(px, pixels: pixels, duty: duty) else { return nil }
        return image(side: side, rgba: rgba)
    }

    /// One pixel of a colour. The widget's label ground is drawn as an image
    /// so the Tinted and Clear Home Screens keep it dark under the words.
    static func solid(r: UInt8, g: UInt8, b: UInt8) -> CGImage? {
        image(side: 1, rgba: [r, g, b, 255])
    }

    static func image(side: Int, rgba: [UInt8]) -> CGImage? {
        guard side > 0, rgba.count == side * side * 4,
              let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: side, height: side,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: side * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
}
