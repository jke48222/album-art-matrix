// The label, styled by the sleeve.
//
// The mockup artists give each record a label that belongs to its sleeve:
// a neon sign on black for a club record, a gold coin for a glam one, a
// holographic disc for a gradient sleeve, plain paper with the art for
// most. The style is chosen from what the sleeve looks like, and every one
// carries the artist, the title and the side.

import UIKit

enum LabelStyle: Int { case paper, neon, coin, holo, mono
    var title: String {
        switch self { case .paper: "Paper"; case .neon: "Neon"; case .coin: "Coin"; case .holo: "Holo"; case .mono: "Mono" }
    }
}

extension RecordLabel {
    /// Which label a sleeve wants.
    static func style(for palette: [Pressing.RGB]) -> LabelStyle {
        guard let c0 = palette.first else { return .paper }
        let saturated = palette.filter { $0.sat > 0.3 && $0.luma > 0.08 }
        if saturated.isEmpty { return palette.allSatisfy({ $0.luma < 0.45 || $0.sat < 0.15 }) ? .mono : .paper }
        if c0.luma < 0.22 { return .neon }
        var hue: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        UIColor(red: CGFloat(c0.r), green: CGFloat(c0.g), blue: CGFloat(c0.b), alpha: 1).getHue(&hue, saturation: &s, brightness: &v, alpha: &a)
        if c0.sat > 0.5 && hue > 0.06 && hue < 0.17 { return .coin }
        if saturated.count >= 3 { return .holo }
        return .paper
    }

    /// The styled label, cached by song. Rendered on whichever task draws
    /// the pressing, so the cache is locked.
    private static var styledCache: (key: String, image: UIImage)? = nil
    private static let cacheLock = NSLock()

    static func styled(sleeve: UIImage?, title: String, artist: String, palette: [Pressing.RGB], key: String, forcedStyle: LabelStyle? = nil) -> UIImage {
        let st = forcedStyle ?? style(for: palette)
        if st == .paper { return label(sleeve: sleeve, title: title, artist: artist, tone: palette.first, key: key) }
        let k = key + "|\(st)|" + title + "|" + artist
        cacheLock.lock()
        let hit = styledCache.flatMap { $0.key == k ? $0.image : nil }
        cacheLock.unlock()
        if let hit { return hit }
        let d: CGFloat = 320
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1; fmt.opaque = false
        func ui(_ c: Pressing.RGB) -> UIColor { UIColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1) }
        let c0 = palette.first ?? .black
        let bright = palette.max { $0.luma * (0.5 + $0.sat) < $1.luma * (0.5 + $1.sat) } ?? c0
        let head = UIFont(name: "Technor-Bold", size: 34) ?? .systemFont(ofSize: 34, weight: .heavy)
        let sub = UIFont(name: "Switzer-Medium", size: 14) ?? .systemFont(ofSize: 14, weight: .medium)
        let small = UIFont(name: "Technor-Semibold", size: 11) ?? .systemFont(ofSize: 11, weight: .semibold)
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let img = UIGraphicsImageRenderer(size: CGSize(width: d, height: d), format: fmt).image { rc in
            let ctx = rc.cgContext
            let full = CGRect(x: 0, y: 0, width: d, height: d)
            func text(_ s: String, _ font: UIFont, _ y: CGFloat, _ colour: UIColor, kern: CGFloat = 0, glow: UIColor? = nil) {
                var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour, .paragraphStyle: para, .kern: kern]
                if let glow {
                    let sh = NSShadow(); sh.shadowColor = glow; sh.shadowBlurRadius = 14; sh.shadowOffset = .zero
                    a[.shadow] = sh
                }
                NSAttributedString(string: s, attributes: a).draw(in: CGRect(x: 20, y: y, width: d - 40, height: font.lineHeight + 6))
            }
            switch st {
            case .neon:
                // black label, the title as a neon tube in the sleeve's brightest colour
                ctx.setFillColor(UIColor(white: 0.07, alpha: 1).cgColor); ctx.fillEllipse(in: full)
                ctx.setStrokeColor(UIColor(white: 0.22, alpha: 1).cgColor); ctx.setLineWidth(1.5); ctx.strokeEllipse(in: full.insetBy(dx: 12, dy: 12))
                let tube = ui(bright.mix(.white, 0.35))
                let titleFont = UIFont(name: "Technor-Bold", size: title.count > 14 ? 26 : 34) ?? head
                text(title.uppercased(), titleFont, 92, tube, kern: 1.5, glow: ui(bright))
                text(title.uppercased(), titleFont, 92, UIColor.white.withAlphaComponent(0.85), kern: 1.5)
                text("SIDE A  ·  33 1/3 RPM", small, 176, UIColor(white: 0.75, alpha: 1), kern: 1.4)
                text(artist.uppercased(), sub, 204, UIColor(white: 0.9, alpha: 1), kern: 3)
            case .coin:
                // a struck medallion in the sleeve's gold, the title raised
                let gold = ui(c0)
                let colours = [gold.lighter(0.45).cgColor, gold.cgColor, gold.darker(0.45).cgColor, gold.lighter(0.2).cgColor] as CFArray
                if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours, locations: [0, 0.4, 0.75, 1]) {
                    ctx.saveGState(); ctx.addEllipse(in: full); ctx.clip()
                    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: d, y: d), options: [])
                    ctx.restoreGState()
                }
                ctx.setStrokeColor(gold.darker(0.5).cgColor); ctx.setLineWidth(3); ctx.strokeEllipse(in: full.insetBy(dx: 10, dy: 10))
                ctx.setStrokeColor(gold.lighter(0.5).cgColor); ctx.setLineWidth(1.5); ctx.strokeEllipse(in: full.insetBy(dx: 16, dy: 16))
                let titleFont = UIFont(name: "Technor-Bold", size: title.count > 14 ? 24 : 32) ?? head
                text(title.uppercased(), titleFont, 74, gold.darker(0.55), kern: 1.5)
                text(title.uppercased(), titleFont, 72, gold.lighter(0.55), kern: 1.5)
                if let sleeve {
                    let sq = CGRect(x: d / 2 - 52, y: 120, width: 104, height: 104)
                    ctx.saveGState(); ctx.addEllipse(in: sq); ctx.clip()
                    ctx.setAlpha(0.55); sleeve.draw(in: sq); ctx.restoreGState()
                    ctx.setStrokeColor(gold.darker(0.5).cgColor); ctx.setLineWidth(2); ctx.strokeEllipse(in: sq)
                }
                text(artist.uppercased(), small, 236, gold.darker(0.55), kern: 2.5)
                text("SIDE A", small, 254, gold.darker(0.55), kern: 1.5)
            case .holo:
                // a holographic disc, the sleeve's colours swept round it
                let cols = palette.prefix(3).map { ui($0.mix(.white, 0.45)).cgColor } + [ui(palette[0].mix(.white, 0.45)).cgColor]
                ctx.saveGState(); ctx.addEllipse(in: full); ctx.clip()
                if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols as CFArray, locations: nil) {
                    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 40), end: CGPoint(x: d, y: d - 40), options: [])
                }
                ctx.setBlendMode(.screen)
                for k in 0..<7 {
                    let a = CGFloat(k) * 0.9
                    ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.18).cgColor); ctx.setLineWidth(6)
                    ctx.move(to: CGPoint(x: d / 2 + cos(a) * 30, y: d / 2 + sin(a) * 30)); ctx.addLine(to: CGPoint(x: d / 2 + cos(a) * 170, y: d / 2 + sin(a) * 170)); ctx.strokePath()
                }
                ctx.restoreGState()
                text(artist.uppercased(), head, 88, .white, kern: 3)
                text(title.uppercased(), sub, 138, UIColor.white.withAlphaComponent(0.92), kern: 1.2)
                text("SIDE A", small, 236, UIColor.white.withAlphaComponent(0.8), kern: 1.5)
            case .mono:
                // black and white sleeve: a black label, small white type, a glyph ring
                ctx.setFillColor(UIColor(white: 0.08, alpha: 1).cgColor); ctx.fillEllipse(in: full)
                ctx.setStrokeColor(UIColor(white: 0.55, alpha: 1).cgColor); ctx.setLineWidth(1); ctx.strokeEllipse(in: full.insetBy(dx: 14, dy: 14))
                for k in 0..<16 {
                    let a = CGFloat(k) / 16 * 2 * .pi
                    ctx.setFillColor(UIColor(white: 0.85, alpha: 1).cgColor)
                    ctx.fillEllipse(in: CGRect(x: d / 2 + cos(a) * 138 - 2.5, y: d / 2 + sin(a) * 138 - 2.5, width: 5, height: 5))
                }
                let titleFont = UIFont(name: "Switzer-Medium", size: title.count > 14 ? 22 : 30) ?? head
                text(title.lowercased(), titleFont, 104, .white, kern: 0.5)
                text(artist.lowercased(), sub, 150, UIColor(white: 0.8, alpha: 1), kern: 1)
                text("side a", small, 224, UIColor(white: 0.6, alpha: 1), kern: 1.5)
            case .paper: break
            }
            // the spindle hole
            ctx.setFillColor(UIColor(white: 0.82, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: d / 2 - 9, y: d / 2 - 9, width: 18, height: 18))
            ctx.setStrokeColor(UIColor(white: 0.3, alpha: 1).cgColor); ctx.setLineWidth(1)
            ctx.strokeEllipse(in: CGRect(x: d / 2 - 9, y: d / 2 - 9, width: 18, height: 18))
        }
        cacheLock.lock()
        styledCache = (k, img)
        cacheLock.unlock()
        return img
    }
}

extension UIColor {
    func lighter(_ k: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r + (1 - r) * k, green: g + (1 - g) * k, blue: b + (1 - b) * k, alpha: a)
    }
}
