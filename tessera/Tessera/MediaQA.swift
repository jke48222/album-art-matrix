#if DEBUG
import UIKit

/// Authored, deterministic source for matched before/after crop checks.
/// Kept out of release builds and never substituted for a person's photo.
enum MediaQA {
    static func source() -> CGImage {
        let size = CGSize(width: 1200, height: 900)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            let colors = [UIColor(red: 0.07, green: 0.30, blue: 0.36, alpha: 1).cgColor,
                          UIColor(red: 0.20, green: 0.58, blue: 0.60, alpha: 1).cgColor,
                          UIColor(red: 0.73, green: 0.83, blue: 0.72, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.57, 1])!
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 1100, y: 850), options: [])
            let coast = UIBezierPath()
            coast.move(to: CGPoint(x: 980, y: -30))
            coast.addCurve(to: CGPoint(x: 790, y: 500), controlPoint1: CGPoint(x: 610, y: 150), controlPoint2: CGPoint(x: 1180, y: 230))
            coast.addCurve(to: CGPoint(x: 410, y: 940), controlPoint1: CGPoint(x: 440, y: 620), controlPoint2: CGPoint(x: 580, y: 710))
            coast.addLine(to: CGPoint(x: 1250, y: 940)); coast.addLine(to: CGPoint(x: 1250, y: -30)); coast.close()
            UIColor(red: 0.85, green: 0.72, blue: 0.52, alpha: 1).setFill(); coast.fill()
            for i in 0..<7 {
                context.saveGState()
                context.translateBy(x: CGFloat(-12 - i * 15), y: CGFloat(-i * 2))
                UIColor(red: 0.85, green: 0.92, blue: 0.81, alpha: 0.38 - Double(i) * 0.043).setStroke()
                coast.lineWidth = CGFloat(i == 0 ? 9 : 2); coast.stroke()
                context.restoreGState()
            }
            // A tiny boat gives the same crop an unmistakable point of reference.
            context.saveGState(); context.translateBy(x: 415, y: 310); context.rotate(by: -.pi / 7)
            UIColor(red: 0.05, green: 0.23, blue: 0.26, alpha: 0.3).setFill()
            UIBezierPath(ovalIn: CGRect(x: -15, y: -30, width: 35, height: 80)).fill()
            UIColor(red: 0.98, green: 0.94, blue: 0.81, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: -11, y: -28, width: 22, height: 59), cornerRadius: 10).fill()
            UIColor(red: 0.70, green: 0.25, blue: 0.14, alpha: 1).setFill()
            UIBezierPath(rect: CGRect(x: -7, y: -8, width: 14, height: 20)).fill()
            context.restoreGState()
            var seed: UInt64 = 91
            for _ in 0..<22000 {
                seed = seed &* 6364136223846793005 &+ 1
                let x = CGFloat((seed >> 18) % 1200)
                seed = seed &* 6364136223846793005 &+ 1
                let y = CGFloat((seed >> 18) % 900)
                context.setFillColor(UIColor(white: seed % 2 == 0 ? 1 : 0, alpha: 0.035).cgColor)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }.cgImage!
    }
}
#endif
