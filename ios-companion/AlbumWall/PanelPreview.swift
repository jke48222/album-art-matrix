// What the wall is showing, rendered honestly on the phone: the same
// sleeve at the same 64x64, the disc actually spinning at the set rpm,
// ambient effects approximated live. No network round-trip — art mode
// uses the artwork this phone pushed in the first place.
import SwiftUI
import UIKit

enum PanelSource {
    case art(UIImage?)               // sleeve (nil -> placeholder)
    case spin(UIImage?, rpm: Double)
    case ambient(effect: String, c1: Color, c2: Color, speed: Double)
    case frame(UIImage?)             // last doodle/photo/clip frame
    case clock(rgb: (UInt8, UInt8, UInt8), twentyFour: Bool)
    case dark                        // off / no link
}

struct PanelContent: View {
    let source: PanelSource

    var body: some View {
        switch source {
        case .art(let img):
            PixelImage(image: img ?? Self.placeholder)
        case .frame(let img):
            if let img { PixelImage(image: img, alreadyTiny: true) }
        case .clock(let rgb, let twentyFour):
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if let img = PixelFont.clockFrame(twentyFour: twentyFour,
                                                  rgb: rgb) {
                    PixelImage(image: img, alreadyTiny: true)
                }
            }
        case .spin(let img, let rpm):
            SpinningDisc(image: img ?? Self.placeholder, rpm: rpm)
        case .ambient(let effect, let c1, let c2, let speed):
            AmbientPreview(effect: effect, c1: c1, c2: c2, speed: speed)
        case .dark:
            Color.clear
        }
    }

    static let placeholder = UIImage(named: "sleeve64") ?? UIImage()
}

// Downscale to the wall's true 64x64 once, then scale up with no smoothing.
struct PixelImage: View {
    let image: UIImage
    var alreadyTiny = false

    var body: some View {
        Image(uiImage: alreadyTiny ? image : image.led64())
            .resizable()
            .interpolation(.none)
            .aspectRatio(contentMode: .fill)
    }
}

// Mirrors brain/art/disc.py: full-bleed disc, 5.5% punched hole, darkened
// hub ring, fixed sheen the art turns beneath — re-rendered at a true
// 64x64 every frame so it crawls exactly like the LEDs will.
struct SpinningDisc: View {
    let image: UIImage
    let rpm: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let angle = (t * rpm / 60.0 * 360.0)
                .truncatingRemainder(dividingBy: 360)
            Image(uiImage: Self.frame(art: image, angle: angle))
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fill)
        }
    }

    static func frame(art: UIImage, angle: Double) -> UIImage {
        let n: CGFloat = 256                       // supersample, then 64
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let big = UIGraphicsImageRenderer(
            size: CGSize(width: n, height: n), format: fmt).image { ctx in
            let c = ctx.cgContext
            UIColor.black.setFill()
            c.fill(CGRect(x: 0, y: 0, width: n, height: n))
            // disc = full circle, art rotating beneath
            c.saveGState()
            c.addEllipse(in: CGRect(x: 1, y: 1, width: n - 2, height: n - 2))
            c.clip()
            c.translateBy(x: n / 2, y: n / 2)
            c.rotate(by: angle * .pi / 180)
            art.led64().draw(in: CGRect(x: -n / 2, y: -n / 2, width: n, height: n))
            c.restoreGState()
            // hub ring (darkened label area), like disc.py's composite
            let ring = n * 0.16
            UIColor.black.withAlphaComponent(0.35).setFill()
            c.fillEllipse(in: CGRect(x: n / 2 - ring, y: n / 2 - ring,
                                     width: ring * 2, height: ring * 2))
            // punched center hole
            let hole = n * 0.055
            UIColor.black.setFill()
            c.fillEllipse(in: CGRect(x: n / 2 - hole, y: n / 2 - hole,
                                     width: hole * 2, height: hole * 2))
            // fixed specular sheen — light stays put, disc turns
            c.saveGState()
            c.addEllipse(in: CGRect(x: 1, y: 1, width: n - 2, height: n - 2))
            c.clip()
            UIColor.white.withAlphaComponent(0.13).setFill()
            c.translateBy(x: n / 2, y: n / 2)
            c.rotate(by: -0.7)
            c.fill(CGRect(x: -n * 0.06, y: -n / 2, width: n * 0.12, height: n))
            c.rotate(by: 2.9)
            UIColor.white.withAlphaComponent(0.08).setFill()
            c.fill(CGRect(x: -n * 0.05, y: -n / 2, width: n * 0.1, height: n))
            c.restoreGState()
        }
        return UIGraphicsImageRenderer(
            size: CGSize(width: 64, height: 64), format: fmt).image { _ in
            big.draw(in: CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }
}

struct AmbientPreview: View {
    let effect: String
    let c1: Color
    let c2: Color
    let speed: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate * speed
            switch effect {
            case "solid":
                c1
            case "breathe":
                c1.opacity(0.625 + 0.375 * sin(t * 2 * .pi / 5))
            case "pulse":
                c1.opacity(0.2 + 0.8 * exp(-4 * t.truncatingRemainder(dividingBy: 1)))
            case "rainbow":
                LinearGradient(
                    colors: (0...6).map {
                        Color(hue: (Double($0) / 6 + t / 12)
                                .truncatingRemainder(dividingBy: 1),
                              saturation: 0.9, brightness: 1)
                    },
                    startPoint: .leading, endPoint: .trailing)
            default:  // gradient — axis slowly rotating, like the brain's
                LinearGradient(
                    colors: [c1, c2],
                    startPoint: rotate(.init(x: 0.1, y: 0.1), t / 40),
                    endPoint: rotate(.init(x: 0.9, y: 0.9), t / 40))
            }
        }
    }

    private func rotate(_ p: UnitPoint, _ turns: Double) -> UnitPoint {
        let a = turns * 2 * .pi
        let dx = p.x - 0.5, dy = p.y - 0.5
        return UnitPoint(x: 0.5 + dx * cos(a) - dy * sin(a),
                         y: 0.5 + dx * sin(a) + dy * cos(a))
    }
}

extension UIImage {
    /// Center-crop square, resample to 64x64 — the wall's whole world.
    func led64() -> UIImage {
        let side = min(size.width, size.height)
        let crop = CGRect(x: (size.width - side) / 2,
                          y: (size.height - side) / 2,
                          width: side, height: side)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64),
                                       format: fmt).image { _ in
            let source = cgImage.flatMap { $0.cropping(to: crop) }
                .map { UIImage(cgImage: $0) } ?? self
            source.draw(in: CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }

    /// Build a 64x64 UIImage from raw RGB bytes (the wall's native format).
    static func fromRGB64(_ rgb: Data) -> UIImage? {
        guard rgb.count == 64 * 64 * 3 else { return nil }
        var rgba = [UInt8](repeating: 255, count: 64 * 64 * 4)
        for i in 0..<(64 * 64) {
            rgba[i * 4] = rgb[i * 3]
            rgba[i * 4 + 1] = rgb[i * 3 + 1]
            rgba[i * 4 + 2] = rgb[i * 3 + 2]
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(width: 64, height: 64, bitsPerComponent: 8,
                               bitsPerPixel: 32, bytesPerRow: 64 * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(
                                   rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Raw RGB bytes (64*64*3) of the 64x64 render — the /frame payload.
    func rgbBytes64() -> Data? {
        guard let cg = led64().cgImage else { return nil }
        var rgba = [UInt8](repeating: 0, count: 64 * 64 * 4)
        guard let ctx = CGContext(
            data: &rgba, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        var rgb = Data(capacity: 64 * 64 * 3)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            rgb.append(contentsOf: rgba[i...(i + 2)])
        }
        return rgb
    }
}
