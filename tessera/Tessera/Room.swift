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
            // The picture, thrown soft across the whole room. The softness
            // is baked in (the frame is box-reduced to ten pixels and
            // bilinear upscaling melts it), and the image is given the
            // room's exact size: a resizable fill-mode image with no frame
            // proposes its own enormous one and detonates the layout around
            // it, which is a lesson this file has now learned twice.
            if light > 0.001, let cg = Room.bitmap(px) {
                GeometryReader { geo in
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                .opacity(min(0.60, 0.16 + light * 0.55 * (1 + surge)))
                .ignoresSafeArea()
                LinearGradient(
                    colors: [.clear, Ink.ground.opacity(0.55), Ink.ground.opacity(0.9)],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
            if light > 0.001, !palette.isEmpty {
                mesh
                    .opacity(min(0.30, light * 0.22 * (1 + surge)))
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

    /// The frame box-reduced to 10x10: the mean of each block IS the blur,
    /// computed once per new frame instead of per composited screen.
    private static var cachedKey: Int = 0
    private static var cachedImage: CGImage? = nil
    static func bitmap(_ px: [UInt8]?) -> CGImage? {
        guard let px, px.count == 64 * 64 * 3 else { return nil }
        var h = 0
        for i in stride(from: 0, to: px.count, by: 97) { h = h &* 31 &+ Int(px[i]) }
        if h == cachedKey, let cachedImage { return cachedImage }
        let side = 10
        var rgba = [UInt8](repeating: 255, count: side * side * 4)
        let block = 64 / side
        for ty in 0..<side {
            for tx in 0..<side {
                var r = 0, g = 0, b = 0, n = 0
                let x1 = tx == side - 1 ? 64 : (tx + 1) * block
                let y1 = ty == side - 1 ? 64 : (ty + 1) * block
                for y in (ty * block)..<y1 {
                    for x in (tx * block)..<x1 {
                        let o = (y * 64 + x) * 3
                        r += Int(px[o]); g += Int(px[o + 1]); b += Int(px[o + 2]); n += 1
                    }
                }
                let o = (ty * side + tx) * 4
                rgba[o] = UInt8(r / max(1, n))
                rgba[o + 1] = UInt8(g / max(1, n))
                rgba[o + 2] = UInt8(b / max(1, n))
            }
        }
        let cg = rgba.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }
        cachedKey = h
        cachedImage = cg
        return cg
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
