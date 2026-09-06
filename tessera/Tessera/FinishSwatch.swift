// What a finish would do, on what is on the wall.
//
// The three finishes used to be three words, and a word is a poor way to
// choose a look. Each one is drawn here on the picture the wall is showing
// (or on the sleeve, when a wall has not answered yet), so the choice is
// made by eye.
//
// The wall's own dither is Floyd-Steinberg into sixteen colours chosen from
// the picture, so that is what runs here as well: the same median cut and
// the same error diffusion, on the sleeve rather than on whatever the wall
// happens to be lighting, since a clock face is not art to put a finish on.

import SwiftUI
import UIKit

struct FinishSwatch: View {
    /// The wall's live frame: the fallback when there is no art.
    let px: [UInt8]?
    /// The sleeve. What a finish is actually for.
    var sleeve: UIImage? = nil
    let finish: String

    var body: some View {
        Group {
            if let image = Self.render(px: px, sleeve: sleeve, finish: finish) {
                Image(uiImage: image).resizable().interpolation(.none).aspectRatio(1, contentMode: .fill)
            } else {
                Rectangle().fill(Color.white.opacity(0.06))
            }
        }
    }

    // MARK: The picture

    private static var cache: [String: UIImage] = [:]

    static func render(px: [UInt8]?, sleeve: UIImage?, finish: String) -> UIImage? {
        guard var rgb = source(px: px, sleeve: sleeve) else { return nil }
        let key = "\(finish)|\(rgb.count)|\(rgb.prefix(96).reduce(0) { $0 &+ Int($1) })"
        if let c = cache[key] { return c }
        switch finish {
        case "poster": posterize(&rgb)
        case "dither": dither(&rgb)
        default: break
        }
        guard let image = bitmap(rgb) else { return nil }
        if cache.count > 24 { cache.removeAll(keepingCapacity: true) }
        cache[key] = image
        return image
    }

    /// One wall of RGB. The SLEEVE first: the wall's own frame already carries
    /// whichever finish is on, and in a face like the clock it is not art at
    /// all, so previewing from it showed three versions of a countdown.
    private static func source(px: [UInt8]?, sleeve: UIImage?) -> [UInt8]? {
        guard let cg = sleeve?.cgImage else {
            if let px, Panel.square(px.count) != nil { return px }
            return nil
        }
        let n = Panel.side
        var raw = [UInt8](repeating: 0, count: n * n * 4)
        let ok: Bool = raw.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n,
                                      bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard ok else { return nil }
        var out = [UInt8](repeating: 0, count: n * n * 3)
        for i in 0..<(n * n) {
            out[i * 3] = raw[i * 4]; out[i * 3 + 1] = raw[i * 4 + 1]; out[i * 3 + 2] = raw[i * 4 + 2]
        }
        return out
    }

    /// Three bits a channel: flat fields, like a cheap print.
    private static func posterize(_ rgb: inout [UInt8]) {
        for i in rgb.indices { rgb[i] = rgb[i] & 0xE0 }
    }

    /// The wall's own dither: sixteen colours chosen from the picture, and
    /// Floyd-Steinberg error diffusion into them. An ordered dither to a
    /// fixed ramp was close enough to look like grain and wrong enough to
    /// show colours the wall would never pick.
    private static func dither(_ rgb: inout [UInt8]) {
        let palette = medianCut(rgb, wanted: 16)
        guard !palette.isEmpty else { return }
        var work = rgb.map { Double($0) }
        func nearest(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
            var best = palette[0], bestD = Double.greatestFiniteMagnitude
            for c in palette {
                let d = (c.0 - r) * (c.0 - r) + (c.1 - g) * (c.1 - g) + (c.2 - b) * (c.2 - b)
                if d < bestD { bestD = d; best = c }
            }
            return best
        }
        let n = Panel.square(rgb.count) ?? 64
        for y in 0..<n {
            for x in 0..<n {
                let i = (y * n + x) * 3
                let old = (work[i], work[i + 1], work[i + 2])
                let new = nearest(old.0, old.1, old.2)
                work[i] = new.0; work[i + 1] = new.1; work[i + 2] = new.2
                let err = (old.0 - new.0, old.1 - new.1, old.2 - new.2)
                func spread(_ dx: Int, _ dy: Int, _ w: Double) {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < n, ny < n else { return }
                    let j = (ny * n + nx) * 3
                    work[j] += err.0 * w; work[j + 1] += err.1 * w; work[j + 2] += err.2 * w
                }
                spread(1, 0, 7.0 / 16); spread(-1, 1, 3.0 / 16)
                spread(0, 1, 5.0 / 16); spread(1, 1, 1.0 / 16)
            }
        }
        for i in rgb.indices { rgb[i] = UInt8(max(0, min(255, work[i].rounded()))) }
    }

    /// Sixteen colours out of the picture, the way a quantiser picks them:
    /// split the box of colours along its longest side at the median, again
    /// and again, and take each box's average.
    private static func medianCut(_ rgb: [UInt8], wanted: Int) -> [(Double, Double, Double)] {
        var boxes: [[Int]] = [Array(stride(from: 0, to: rgb.count, by: 3))]
        while boxes.count < wanted {
            guard let (bi, _) = boxes.enumerated()
                .filter({ $0.element.count > 1 })
                .max(by: { spread(rgb, $0.element) < spread(rgb, $1.element) }) else { break }
            let box = boxes.remove(at: bi)
            let c = widest(rgb, box)
            let sorted = box.sorted { rgb[$0 + c] < rgb[$1 + c] }
            let half = sorted.count / 2
            boxes.append(Array(sorted[..<half])); boxes.append(Array(sorted[half...]))
        }
        return boxes.filter { !$0.isEmpty }.map { box in
            var r = 0.0, g = 0.0, b = 0.0
            for i in box { r += Double(rgb[i]); g += Double(rgb[i + 1]); b += Double(rgb[i + 2]) }
            let n = Double(box.count)
            return (r / n, g / n, b / n)
        }
    }

    private static func widest(_ rgb: [UInt8], _ box: [Int]) -> Int {
        var lo = [255, 255, 255], hi = [0, 0, 0]
        for i in box {
            for c in 0..<3 {
                let v = Int(rgb[i + c]); lo[c] = min(lo[c], v); hi[c] = max(hi[c], v)
            }
        }
        let ranges = (0..<3).map { hi[$0] - lo[$0] }
        return ranges.firstIndex(of: ranges.max() ?? 0) ?? 0
    }

    private static func spread(_ rgb: [UInt8], _ box: [Int]) -> Int {
        var lo = [255, 255, 255], hi = [0, 0, 0]
        for i in box {
            for c in 0..<3 {
                let v = Int(rgb[i + c]); lo[c] = min(lo[c], v); hi[c] = max(hi[c], v)
            }
        }
        return (0..<3).map { hi[$0] - lo[$0] }.max() ?? 0
    }

    static func bitmap(_ rgb: [UInt8]) -> UIImage? {
        guard let n = Panel.square(rgb.count) else { return nil }
        var raw = [UInt8](repeating: 255, count: n * n * 4)
        for i in 0..<(n * n) {
            raw[i * 4] = rgb[i * 3]; raw[i * 4 + 1] = rgb[i * 3 + 1]; raw[i * 4 + 2] = rgb[i * 3 + 2]
        }
        return raw.withUnsafeMutableBytes { buf -> UIImage? in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n,
                                      bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let cg = ctx.makeImage() else { return nil }
            return UIImage(cgImage: cg)
        }
    }
}
