// The room.
//
// Not a themed background: a computed readout of the light the wall is
// throwing. The colours are the art's own, the intensity is the art's
// luminance times the wall's duty, and the falloff is vertical because the
// panel is above and light falls off with distance. When the wall is dark
// the room is Ink.ground and nothing else.

import SwiftUI
import UIKit

/// Fine monochrome grain, generated once and tiled. The room's gradient is
/// smooth by construction, and smooth gradients on OLED read as plastic;
/// a breath of noise gives the light something to land on, the way paint
/// does. Static on purpose: animated grain is film, static grain is a wall.
private enum Grain {
    static let tile: UIImage = {
        let side = 160
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt8 {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return UInt8(truncatingIfNeeded: seed)
        }
        let count = side * side * 4
        var buf = [UInt8](repeating: 0, count: count)
        for i in stride(from: 0, to: count, by: 4) {
            let v = next()
            buf[i] = v; buf[i + 1] = v; buf[i + 2] = v
            buf[i + 3] = 255
        }
        let cg = buf.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }
        return cg.map { UIImage(cgImage: $0) } ?? UIImage()
    }()
}

struct Room: View {
    let palette: [Color]
    /// The frame itself: the room is lit by the actual picture, not only by
    /// its extracted colours.
    var px: [UInt8]? = nil
    let light: Double        // 0...1, lit * duty
    /// Rises briefly when a new sleeve lands, then settles.
    let surge: Double

    var body: some View {
        ZStack {
            Ink.ground
            // The cover's own colours, arranged the way the cover arranges
            // them. Twelve regions of the frame are sampled where the mesh's
            // control points sit, pushed toward their saturated selves, and
            // poured through the gradient: the room agrees with the artwork
            // spatially, not just statistically, and a red-left blue-right
            // sleeve makes a red-left blue-right room. Stretching the actual
            // image here read as a smear; this reads as light.
            if light > 0.001, let tones = Room.tones(px) {
                MeshGradient(
                    width: 3,
                    height: 4,
                    points: [
                        .init(0, 0),    .init(0.5, 0),    .init(1, 0),
                        .init(0, 0.34), .init(0.5, 0.30), .init(1, 0.34),
                        .init(0, 0.68), .init(0.5, 0.72), .init(1, 0.68),
                        .init(0, 1),    .init(0.5, 1),    .init(1, 1),
                    ],
                    colors: tones
                )
                .opacity(min(0.75, 0.22 + light * 0.60 * (1 + surge)))
                .blur(radius: 24)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            } else if light > 0.001, !palette.isEmpty {
                mesh
                    .opacity(min(0.40, light * 0.30 * (1 + surge)))
                    .blur(radius: 44)
                    .ignoresSafeArea()
            }
            // The tooth of the wall, over the light so the light lands on
            // it. Overlay blend rides the colour underneath rather than
            // sitting on it as a grey film.
            Image(uiImage: Grain.tile)
                .resizable(resizingMode: .tile)
                .opacity(0.07)
                .blendMode(.overlay)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 1.1), value: light)
        .animation(.easeOut(duration: 0.9), value: surge)
    }

    /// Twelve tones, one per mesh point, sampled from the frame region under
    /// each point and pushed toward the cover's saturated self. Cached per
    /// frame: twelve averages and hue conversions, done once, not per eval.
    private static var cachedKey: Int = 0
    private static var cachedTones: [Color]? = nil
    static func tones(_ px: [UInt8]?) -> [Color]? {
        guard let px, px.count == 64 * 64 * 3 else { return nil }
        var h = 0
        for i in stride(from: 0, to: px.count, by: 97) { h = h &* 31 &+ Int(px[i]) }
        if h == cachedKey, let cachedTones { return cachedTones }

        func region(_ cx: Double, _ cy: Double) -> (Double, Double, Double) {
            let x0 = max(0, Int(cx * 63) - 10), x1 = min(64, Int(cx * 63) + 11)
            let y0 = max(0, Int(cy * 63) - 8), y1 = min(64, Int(cy * 63) + 9)
            var r = 0.0, g = 0.0, b = 0.0, n = 0.0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let o = (y * 64 + x) * 3
                    r += Double(px[o]); g += Double(px[o + 1]); b += Double(px[o + 2])
                    n += 1
                }
            }
            return (r / n / 255, g / n / 255, b / n / 255)
        }

        /// The pop: hold the hue, raise the chroma, lift the floor. A dim
        /// region keeps its identity instead of averaging into brown.
        func voiced(_ c: (Double, Double, Double), floorLift: Double) -> Color {
            let ui = UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, a: CGFloat = 0
            ui.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &a)
            return Color(hue: hue,
                         saturation: min(1, sat * 1.6 + 0.06),
                         brightness: min(1, bri * 1.15 + floorLift))
        }

        // Sample where the mesh points sit; the bottom row goes to ground so
        // the floor of the screen stays a floor.
        let spots: [(Double, Double)] = [
            (0.08, 0.10), (0.50, 0.08), (0.92, 0.10),
            (0.08, 0.42), (0.50, 0.38), (0.92, 0.42),
            (0.08, 0.75), (0.50, 0.80), (0.92, 0.75),
        ]
        var out = spots.enumerated().map { (i, s) in
            voiced(region(s.0, s.1), floorLift: i < 3 ? 0.10 : 0.05)
        }
        out.append(contentsOf: [Ink.ground, Ink.ground, Ink.ground])

        cachedKey = h
        cachedTones = out
        return out
    }

    private var a: Color { palette.first ?? Ink.tile }
    private var b: Color { palette.count > 1 ? palette[1] : a }
    private var c: Color { palette.count > 2 ? palette[2] : b }

    /// Light pools at the top where the panel is, and dies toward the floor.
    private var mesh: some View {
        MeshGradient(
            width: 3,
            height: 4,
            points: [
                .init(0, 0),    .init(0.5, 0),    .init(1, 0),
                .init(0, 0.32), .init(0.5, 0.28), .init(1, 0.32),
                .init(0, 0.66), .init(0.5, 0.70), .init(1, 0.66),
                .init(0, 1),    .init(0.5, 1),    .init(1, 1),
            ],
            colors: [
                b.opacity(0.45), a.opacity(0.80), c.opacity(0.45),
                a.opacity(0.62), a.opacity(0.95), b.opacity(0.62),
                c.opacity(0.20), b.opacity(0.26), a.opacity(0.20),
                .clear,          .clear,          .clear,
            ]
        )
    }
}
