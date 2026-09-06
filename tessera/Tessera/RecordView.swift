import SwiftUI
import UIKit

/// The record in the room: the pressing put on the platter by the shader
/// and turned with it, over the render's own vinyl so the room's light
/// still catches it.
struct RecordView: View {
    let image: UIImage
    let quad: [CGPoint]
    let angle: Double
    /// Over the render's shaded record, multiply; through a hole, plain.
    var blend: BlendMode = .normal

    var body: some View {
        if let h = Homography.unitSquare(to: quad), let inv = Homography.inverse(h) {
            let box = Path(RecordLattice.ring(h: h, radius: 1)).boundingRect
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: box.width, height: box.height)
                .distortionEffect(ShaderLibrary.recordWarp(
                    .float2(box.width, box.height), .float2(box.minX, box.minY),
                    .float3(inv[0], inv[1], inv[2]), .float3(inv[3], inv[4], inv[5]), .float3(inv[6], inv[7], inv[8]),
                    .float(Float(angle))), maxSampleOffset: CGSize(width: box.width, height: box.height))
                .colorEffect(ShaderLibrary.recordSheen(
                    .float2(box.minX, box.minY),
                    .float3(inv[0], inv[1], inv[2]), .float3(inv[3], inv[4], inv[5]), .float3(inv[6], inv[7], inv[8])))
                .blendMode(blend)
                .position(x: box.midX, y: box.midY)
                .allowsHitTesting(false)
        }
    }
}

/// The rim of the disc, projected; the box it sits in is the record's.
enum RecordLattice {
    static func ring(h: [Double], radius: Double, steps: Int = 96) -> CGMutablePath {
        let p = CGMutablePath()
        for k in 0...steps {
            let t = 2 * Double.pi * Double(k) / Double(steps)
            let q = Homography.map(h, (radius * cos(t) + 1) / 2, (1 - radius * sin(t)) / 2)
            if k == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        p.closeSubpath()
        return p
    }
}
