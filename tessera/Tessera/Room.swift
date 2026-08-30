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
    let light: Double        // 0...1, lit * duty
    /// Rises briefly when a new sleeve lands, then settles.
    let surge: Double

    var body: some View {
        ZStack {
            Ink.ground
            if light > 0.001, !palette.isEmpty {
                mesh
                    // Hard ceiling: the phone must stay the dimmest lit object
                    // in the room. This is a room catching light, not a lamp.
                    .opacity(min(0.40, light * 0.34 * (1 + surge)))
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
