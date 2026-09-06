import UIKit

enum RecordLabel {
    /// A label the way a pressing plant prints one: paper, the artist above,
    /// the sleeve in a square in the middle with the spindle hole through
    /// it, the title and the side below, a thin ring in the sleeve's colour.
    static func label(sleeve: UIImage?, title: String, artist: String, tone: Pressing.RGB?, key: String) -> UIImage {
        let d: CGFloat = 320
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1; fmt.opaque = false
        let ink = tone.map { UIColor(red: CGFloat($0.r), green: CGFloat($0.g), blue: CGFloat($0.b), alpha: 1) } ?? UIColor(white: 0.15, alpha: 1)
        let dark: UIColor
        if let tone, tone.luma > 0.62 {
            dark = UIColor(red: CGFloat(tone.r * 0.45), green: CGFloat(tone.g * 0.45), blue: CGFloat(tone.b * 0.45), alpha: 1)
        } else { dark = ink }
        let img = UIGraphicsImageRenderer(size: CGSize(width: d, height: d), format: fmt).image { rc in
            let ctx = rc.cgContext
            ctx.setFillColor(UIColor(red: 0.97, green: 0.965, blue: 0.95, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: d, height: d))
            ctx.setStrokeColor(dark.withAlphaComponent(0.85).cgColor); ctx.setLineWidth(2.2)
            ctx.strokeEllipse(in: CGRect(x: 0, y: 0, width: d, height: d).insetBy(dx: 14, dy: 14))
            let para = NSMutableParagraphStyle(); para.alignment = .center
            func text(_ s: String, _ font: UIFont, _ y: CGFloat, _ colour: UIColor, kern: CGFloat = 0) {
                let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour, .paragraphStyle: para, .kern: kern]
                NSAttributedString(string: s, attributes: a).draw(in: CGRect(x: 24, y: y, width: d - 48, height: font.lineHeight + 4))
            }
            let head = UIFont(name: "Technor-Bold", size: 30) ?? .systemFont(ofSize: 30, weight: .heavy)
            let sub = UIFont(name: "Switzer-Medium", size: 13) ?? .systemFont(ofSize: 13, weight: .medium)
            let side = UIFont(name: "Technor-Semibold", size: 12) ?? .systemFont(ofSize: 12, weight: .semibold)
            text(artist.uppercased(), head, 42, dark, kern: 2.5)
            let sq = CGRect(x: d / 2 - 66, y: 86, width: 132, height: 132)
            if let sleeve {
                ctx.saveGState(); ctx.addRect(sq); ctx.clip()
                sleeve.draw(in: sq)
                ctx.restoreGState()
            } else {
                ctx.setFillColor(dark.withAlphaComponent(0.12).cgColor); ctx.fill(sq)
            }
            ctx.setStrokeColor(dark.cgColor); ctx.setLineWidth(1.4); ctx.stroke(sq)
            text(title, sub, 228, dark)
            text("SIDE A", side, 252, dark, kern: 1.5)
            ctx.setStrokeColor(dark.withAlphaComponent(0.7).cgColor); ctx.setLineWidth(2)
            for x in [CGFloat(30), d - 58] { ctx.move(to: CGPoint(x: x, y: d / 2)); ctx.addLine(to: CGPoint(x: x + 28, y: d / 2)) }
            ctx.strokePath()
            // the spindle hole, through the middle of it all
            ctx.setFillColor(UIColor(white: 0.82, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: d / 2 - 9, y: d / 2 - 9, width: 18, height: 18))
            ctx.setStrokeColor(UIColor(white: 0.35, alpha: 1).cgColor); ctx.setLineWidth(1)
            ctx.strokeEllipse(in: CGRect(x: d / 2 - 9, y: d / 2 - 9, width: 18, height: 18))
        }
        return img
    }

}
