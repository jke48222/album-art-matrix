// The hero. The wall's actual frame, never a mockup of it: 64x64 RGB888 from
// /frame.raw, nearest-neighbour, on true black. The room's glow is computed
// from the same bytes, so the app is lit by what the wall is lit by.

import SwiftUI
import UIKit

/// Everything the frame tells the room: image, glow colour, how lit it is.
struct FrameReading {
    let image: UIImage?
    let glow: Color
    let lit: Double        // 0...1, gates every ambient effect

    static let dark = FrameReading(image: nil, glow: Ink.tile, lit: 0)

    static func from(_ data: Data?) -> FrameReading {
        guard let data, data.count == 64 * 64 * 3 else { return .dark }

        // luminance + bright-quartile average colour, single pass budget
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
        let mean = Double(total) / Double(64 * 64) / 255.0
        let lit = min(1.0, pow(mean * 3.2, 0.8))

        let cut = lum.sorted()[Int(Double(lum.count) * 0.75)]
        var r: Float = 0, g: Float = 0, b: Float = 0, n: Float = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<(64 * 64) where lum[i] >= cut {
                let o = i * 3
                r += Float(p[o]); g += Float(p[o + 1]); b += Float(p[o + 2]); n += 1
            }
        }
        var glow = Ink.tile
        if n > 0 {
            let mx = max(r / n, g / n, b / n, 1)
            glow = Color(
                red: Double(r / n / mx),
                green: Double(g / n / mx),
                blue: Double(b / n / mx)
            )
        }

        return FrameReading(image: makeImage(data), glow: glow, lit: lit)
    }

    private static func makeImage(_ data: Data) -> UIImage? {
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(
                width: 64, height: 64,
                bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: 64 * 3,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// The panel on the wall. Square, hairline inset, floor glow beneath,
/// stale stamp when the link is not live. Long-press = hold to off.
struct WallHero: View {
    let reading: FrameReading
    let brightness: Double     // display dim follows the wall's own brightness
    let link: LinkState
    let trackKey: String
    var onHoldOff: () -> Void

    @State private var holding = false
    @GestureState private var pressed = false

    var body: some View {
        ZStack {
            Color.black
            if let img = reading.image {
                Image(uiImage: img)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .opacity(0.15 + 0.85 * brightness)
                    .id(trackKey)
                    .transition(.opacity)
                    .animation(Motion.scene, value: trackKey)
            }
            if holding {
                // tiles extinguishing: a dim rising from the press
                Color.black.opacity(0.55)
                    .transition(.opacity)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(
            Rectangle().strokeBorder(Ink.hairline, lineWidth: 1)
        )
        .overlay(alignment: .bottomTrailing) {
            if case .offline(let since) = link {
                Text("as of \(since.formatted(date: .omitted, time: .shortened))")
                    .microlabel(Ink.faint)
                    .padding(6)
                    .background(Color.black.opacity(0.7))
                    .padding(8)
            }
        }
        .background(alignment: .bottom) {
            // the floor catching the glow
            Ellipse()
                .fill(reading.glow)
                .frame(height: 70)
                .blur(radius: 46)
                .opacity(reading.lit * brightness * 0.5)
                .offset(y: 58)
                .allowsHitTesting(false)
        }
        .scaleEffect(holding ? 0.985 : 1)
        .animation(Motion.settle, value: holding)
        .onLongPressGesture(minimumDuration: 0.9) {
            holding = false
            onHoldOff()
        } onPressingChanged: { pressing in
            withAnimation(Motion.settle) { holding = pressing }
        }
        .accessibilityElement()
        .accessibilityLabel(a11yLabel)
        .accessibilityHint("Hold to turn the wall off.")
    }

    private var a11yLabel: String {
        let liveness = link.isLive ? "live" : "showing the last known frame"
        return "Wall, \(liveness), brightness \(Int(brightness * 100)) percent."
    }
}
