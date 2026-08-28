// The hero. Not a picture of the wall: the wall.
//
// 64x64 RGB888 from /frame.raw, drawn as 4,096 discrete emitters on black,
// each with its own halo. Brightness is a DUTY CYCLE multiplied into every
// emitter, never an alpha over the whole image, which is what makes the
// signature behaviour possible: above roughly 60% duty the halos overlap and
// merge into a continuous picture, and below roughly 30% they separate and
// four thousand individual tiles appear where the picture was. Dimming does
// not fade the wall. It dissolves the picture back into its tesserae.
//
// Rasterised once per (frame, duty step) and cached, so a full-travel drag
// costs at most 25 renders and every step is reused.

import SwiftUI
import UIKit

struct FrameReading {
    let panel: UIImage?
    let glow: Color
    let lit: Double          // 0...1 before duty; how much light the art has
    let key: String

    static let dark = FrameReading(panel: nil, glow: Ink.tile, lit: 0, key: "dark")
}

enum FrameRenderer {
    private static var cacheKey: String = ""
    private static var cached: FrameReading = .dark

    /// `duty` is the wall's brightness, 0.05...1.0. It changes the render,
    /// not the opacity of the render.
    static func read(_ data: Data?, duty: Double) -> FrameReading {
        guard let data, data.count == 64 * 64 * 3 else { return .dark }
        let bucket = Int((duty * 25).rounded())
        let key = "\(data.hashValue):\(bucket)"
        if key == cacheKey { return cached }

        var lum = [Float](repeating: 0, count: 64 * 64)
        var total: Float = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<(64 * 64) {
                let o = i * 3
                let l = 0.2126 * Float(p[o]) + 0.7152 * Float(p[o + 1]) + 0.0722 * Float(p[o + 2])
                lum[i] = l
                total += l
            }
        }
        let lit = min(1.0, pow(Double(total) / Double(64 * 64) / 255.0 * 3.2, 0.8))

        let reading = FrameReading(
            panel: render(data, lum: lum, duty: duty),
            glow: dominantChroma(data, lum: lum),
            lit: lit,
            key: "\(data.hashValue)"
        )
        cacheKey = key
        cached = reading
        return reading
    }

    /// What the room catches: the frame's dominant CHROMA. On a photographic
    /// sleeve the brightest average is the white highlights, and a wall of
    /// colour would light the room grey, so near-greys are excluded outright
    /// and population is weighted by saturation.
    private static func dominantChroma(_ data: Data, lum: [Float]) -> Color {
        var buckets: [Int: (n: Float, r: Float, g: Float, b: Float, sat: Float)] = [:]
        buckets.reserveCapacity(256)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<(64 * 64) where lum[i] >= 24 {
                let o = i * 3
                let r = Float(p[o]), g = Float(p[o + 1]), b = Float(p[o + 2])
                let mx = max(r, g, b), mn = min(r, g, b)
                let sat = mx > 0 ? (mx - mn) / mx : 0
                guard sat >= 0.28 else { continue }
                let key = (Int(r) >> 4) << 8 | (Int(g) >> 4) << 4 | (Int(b) >> 4)
                var e = buckets[key] ?? (0, 0, 0, 0, 0)
                e.n += 1; e.r += r; e.g += g; e.b += b; e.sat += sat
                buckets[key] = e
            }
        }
        var best: (score: Float, r: Float, g: Float, b: Float) = (0, 0, 0, 0)
        for e in buckets.values {
            let score = e.n * (0.2 + (e.sat / e.n) * 0.8)
            if score > best.score { best = (score, e.r / e.n, e.g / e.n, e.b / e.n) }
        }
        guard best.score > 0 else { return Ink.tile }
        let mx = max(best.r, best.g, best.b, 1)
        let k = (255 / mx) * 0.92
        return Color(red: Double(min(255, best.r * k) / 255),
                     green: Double(min(255, best.g * k) / 255),
                     blue: Double(min(255, best.b * k) / 255))
    }

    private static let cell: CGFloat = 9
    private static let side: CGFloat = 64 * 9

    private static func render(_ data: Data, lum: [Float], duty: Double) -> UIImage? {
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        fmt.opaque = true
        let d = CGFloat(max(0.05, min(1.0, duty)))
        // Dimming an LED goes warm, it does not go grey: pull green and blue
        // down harder than red as duty falls, toward roughly 2000K.
        let warm = 0.18 * (1 - d)
        let gK = 1 - warm * 0.34
        let bK = 1 - warm

        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt).image { rctx in
            let ctx = rctx.cgContext
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))

            let r = cell * 0.34
            // The unlit LED is still physically there, at every duty.
            let unlit = UIColor(white: 0.055, alpha: 1).cgColor

            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let p = raw.bindMemory(to: UInt8.self)

                ctx.setFillColor(unlit)
                for i in 0..<(64 * 64) where lum[i] < 8 {
                    let cx = CGFloat(i % 64) * cell + cell / 2
                    let cy = CGFloat(i / 64) * cell + cell / 2
                    ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                }

                ctx.setBlendMode(.plusLighter)
                for i in 0..<(64 * 64) where lum[i] >= 8 {
                    let o = i * 3
                    let cx = CGFloat(i % 64) * cell + cell / 2
                    let cy = CGFloat(i / 64) * cell + cell / 2
                    let n = CGFloat(lum[i] / 255)

                    let color = UIColor(
                        red: CGFloat(p[o]) / 255 * d,
                        green: CGFloat(p[o + 1]) / 255 * d * gK,
                        blue: CGFloat(p[o + 2]) / 255 * d * bK,
                        alpha: 1
                    )
                    // The halo is what merges neighbours into a picture. Shrink
                    // it with duty and the tiles separate.
                    let hr = r + cell * 0.55 * n * d
                    ctx.setFillColor(color.withAlphaComponent(0.20 * n * pow(d, 1.4)).cgColor)
                    ctx.fillEllipse(in: CGRect(x: cx - hr, y: cy - hr, width: hr * 2, height: hr * 2))
                    ctx.setFillColor(color.cgColor)
                    ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                }
                ctx.setBlendMode(.normal)
            }
        }
    }
}

// MARK: - The panel

/// The object in the room, and the only brightness control in the app.
///
/// Press anywhere on it and drag vertically: the picture dissolves into its
/// tiles as it dims. A rule across the panel marks the wall's last confirmed
/// brightness and is the entire reset affordance. Pressing and holding without
/// dragging puts the wall to sleep, or wakes it.
struct WallHero: View {
    let reading: FrameReading
    let confirmed: Double            // what the wall last told us
    @Binding var dragging: Double?   // non-nil while the finger is adjusting
    let link: LinkState
    var onCommit: (Double) -> Void
    var onHold: () -> Void

    @State private var startValue: Double? = nil
    @State private var lastDetent: Int = -1
    @State private var holdWork: DispatchWorkItem? = nil
    @State private var moved = false

    private var duty: Double { dragging ?? confirmed }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                Color.black
                if let panel = reading.panel {
                    Image(uiImage: panel)
                        .interpolation(.high)
                        .resizable()
                        .id(reading.key)
                        .transition(.opacity)
                }

                // The wall's last confirmed level, drawn on the object itself.
                // Always present, never labelled. This is the reset.
                Rectangle()
                    .fill(Ink.ink.opacity(dragging == nil ? 0.10 : 0.22))
                    .frame(height: 1)
                    .padding(.bottom, geo.size.height * ((confirmed - 0.05) / 0.95))
                    .allowsHitTesting(false)

                if dragging != nil {
                    Text("\(Int(duty * 100))%")
                        .font(.machine(11))
                        .foregroundStyle(Ink.ink)
                        .padding(14)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if startValue == nil {
                            startValue = confirmed
                            moved = false
                            scheduleHold()
                        }
                        if abs(g.translation.height) > 6 {
                            if !moved { moved = true; cancelHold() }
                        }
                        guard moved, let start = startValue else { return }
                        // Relative to touch-down, so grabbing never jumps the wall.
                        let delta = -g.translation.height / max(1, geo.size.height)
                        let stepped = ((start + delta * 0.95) / 0.04).rounded() * 0.04
                        let v = min(1.0, max(0.05, stepped))
                        if v != dragging {
                            dragging = v
                            let d = Int(v * 25)
                            if d != lastDetent {
                                // the control gets quieter as the room darkens
                                Taps.detent(intensity: 0.25 + 0.45 * v)
                                lastDetent = d
                            }
                        }
                    }
                    .onEnded { _ in
                        cancelHold()
                        if moved, let v = dragging {
                            onCommit(v)
                            Taps.commit()
                        }
                        startValue = nil
                        moved = false
                        dragging = nil
                    }
            )
            .animation(Motion.scene, value: reading.key)
            .overlay(alignment: .topTrailing) { staleStamp }
            .accessibilityElement()
            .accessibilityLabel("The wall")
            .accessibilityValue("Brightness \(Int(duty * 100)) percent")
            .accessibilityHint("Adjust to dim the wall. Press and hold to put it to sleep.")
            .accessibilityAdjustableAction { dir in
                onCommit(dir == .increment ? min(1.0, confirmed + 0.05) : max(0.05, confirmed - 0.05))
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func scheduleHold() {
        let work = DispatchWorkItem {
            guard !moved else { return }
            dragging = nil
            startValue = nil
            onHold()
        }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: work)
    }

    private func cancelHold() {
        holdWork?.cancel()
        holdWork = nil
    }

    @ViewBuilder private var staleStamp: some View {
        if case .offline(let since) = link {
            Text(since.formatted(date: .omitted, time: .shortened))
                .font(.machine(9))
                .foregroundStyle(Ink.faint)
                .padding(10)
        }
    }
}
