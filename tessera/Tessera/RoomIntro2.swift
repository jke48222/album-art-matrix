// The second opening: the mark on the wall.
//
// Nothing is filmed. On the app's own background, where the wall will be,
// nine tiles fly in and build the mark in the wall's colour. Then the mark
// grows into the wall itself: the nine tiles become the panel's nine coarse
// cells, and the picture refines from those cells down to the panel's own
// emitters while the frame, the table and the record player arrive from
// coarse pixels into the room. Everything drawn is the room's own picture,
// so the end is the room exactly.

import SwiftUI
import UIKit

struct RoomIntro2: View {
    let light: Lighting
    let duty: Double
    let fit: CGRect
    let face: CGRect
    /// The room's picture, to pixelate in.
    let picture: AnyView
    var onDone: () -> Void

    @State private var began = Date()
    @State private var finished = false

    // the timing, in seconds from the start
    private let flyEnd = 1.15
    private let holdEnd = 1.55
    private let growEnd = 2.55
    private let roomStart = 1.7
    private let roomEnd = 3.1

    var body: some View {
        TimelineView(.animation(paused: finished)) { tl in
            let t = tl.date.timeIntervalSince(began)
            let accent = light.steadyAccent
            ZStack(alignment: .topLeading) {
                // the room arriving from coarse cells
                let ra = smooth((t - roomStart) / (roomEnd - roomStart))
                if ra > 0 {
                    let coarse: Float = Float((1 - ra) * (1 - ra) * 56) + (ra < 1 ? 1.5 : 0)
                    let originX: Float = Float(fit.minX), originY: Float = Float(fit.minY)
                    let fade: Double = min(1, ra * 1.6)
                    picture
                        .layerEffect(ShaderLibrary.pixelate(.float(coarse), .float2(originX, originY)),
                                     maxSampleOffset: CGSize(width: 60, height: 60), isEnabled: ra < 1)
                        .opacity(fade)
                }
                // the mark: nine tiles flying in to the lattice, then growing into the panel's cells
                if t < growEnd {
                    let fly = smooth(t / flyEnd)
                    let grow = smooth((t - holdEnd) / (growEnd - holdEnd))
                    let letGo: Double = t < growEnd - 0.25 ? 1 : smooth((growEnd - t) / 0.25)
                    MarkTiles(face: face, fly: fly, grow: grow, accent: accent, seed: 7)
                        .opacity(letGo)
                }
                // the panel refining from nine cells to its emitters, under the tiles as they let go
                if t > holdEnd {
                    let g = smooth((t - holdEnd) / (growEnd - holdEnd))
                    let cells: Float = Float(max(0, 1 - g) * face.width / 3) + (g < 1 ? 1.5 : 0)
                    let reveal: Double = min(1, g * 2.2)
                    let third = face.width / 3
                    RoomPanel(px: light.reading.px, duty: duty)
                        .frame(width: face.width, height: face.height)
                        .layerEffect(ShaderLibrary.pixelate(.float(cells), .float2(0, 0)),
                                     maxSampleOffset: CGSize(width: third, height: third), isEnabled: g < 1)
                        .opacity(reveal)
                        .position(x: face.midX, y: face.midY)
                }
            }
            .onChange(of: t >= roomEnd) { _, over in
                if over, !finished { finished = true; onDone() }
            }
        }
        .allowsHitTesting(false)
        .onAppear { began = Date() }
    }

    private func smooth(_ x: Double) -> Double {
        let k = max(0, min(1, x)); return k * k * (3 - 2 * k)
    }
}

/// The nine tiles of the mark, flying in from around the wall, holding, then
/// each growing to the third of the panel it stands for.
private struct MarkTiles: View {
    let face: CGRect
    let fly: Double
    let grow: Double
    let accent: Color
    let seed: UInt64

    var body: some View {
        Canvas { ctx, _ in
            var rng = SplitMix(seed)
            let side = face.width * 0.16                      // a tile at rest
            let pitch = face.width * 0.22
            for i in 0..<9 {
                let gx = Double(i % 3 - 1), gy = Double(i / 3 - 1)
                // where it rests, in the lattice; where it comes from; where it grows to
                let rest = CGPoint(x: face.midX + gx * pitch, y: face.midY + gy * pitch)
                let a = Double(rng.unit()) * 2 * .pi, d = 180 + Double(rng.unit()) * 260
                let from = CGPoint(x: rest.x + cos(a) * d, y: rest.y + sin(a) * d)
                let cellW = face.width / 3, cellH = face.height / 3
                let grown = CGPoint(x: face.minX + (gx + 1) * cellW + cellW / 2, y: face.minY + (gy + 1) * cellH + cellH / 2)
                // each tile lands a beat after the last
                let own = max(0, min(1, (fly * 1.25) - Double(i) * 0.03))
                let e = own * own * (3 - 2 * own)
                var c = CGPoint(x: from.x + (rest.x - from.x) * e, y: from.y + (rest.y - from.y) * e)
                var w = side * (0.15 + 0.85 * e), h = w
                if grow > 0 {
                    c = CGPoint(x: rest.x + (grown.x - rest.x) * grow, y: rest.y + (grown.y - rest.y) * grow)
                    w = side + (cellW - side) * grow; h = side + (cellH - side) * grow
                }
                let spin = (1 - e) * (Double(rng.unit()) - 0.5) * 3.0
                let radius = w * (0.22 * (1 - grow) + 0.02)
                var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: spin)
                let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
                let path = Path(roundedRect: rect, cornerRadius: radius).applying(t)
                let lit = i == 4
                let alpha = (lit ? 1.0 : 0.62) * (0.25 + 0.75 * e)
                if lit {
                    ctx.drawLayer { l in
                        l.addFilter(.blur(radius: 10 + 10 * e))
                        l.fill(path, with: .color(accent.opacity(0.7 * e)))
                    }
                }
                ctx.fill(path, with: .color(accent.opacity(alpha)))
                t = .identity
            }
        }
        .allowsHitTesting(false)
    }
}
