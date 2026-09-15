// The mark. A record, tessellated: nine by nine cells, the spindle hole the
// centre cell, each lit tile sized by how much of the disc sits under it.
// The same geometry as tessera/Tools/logos.py draws for the logo files. It
// takes the wall's own colour, so the logo is lit by the art like
// everything else on the phone.

import SwiftUI

struct RecordMark: View {
    var accent: Color = Ink.ink
    var lit: Double = 1
    var side: CGFloat = 18

    struct Cell { let x: Double; let y: Double; let s: Double; let lit: Bool }

    /// Computed once: the lattice, then the disc's tiles over it.
    static let cells: [Cell] = {
        let n = 9, ss = 12
        let R = 0.485, hole = 0.105
        let cell = 1.0 / Double(n), mx = cell * 0.86
        var lattice: [Cell] = [], disc: [Cell] = []
        for gy in 0..<n {
            for gx in 0..<n {
                let cx = Double(gx) * cell + cell / 2, cy = Double(gy) * cell + cell / 2
                lattice.append(Cell(x: cx, y: cy, s: mx, lit: false))
                var cov = 0
                for j in 0..<ss {
                    for i in 0..<ss {
                        let px = Double(gx) * cell + (Double(i) + 0.5) * cell / Double(ss) - 0.5
                        let py = Double(gy) * cell + (Double(j) + 0.5) * cell / Double(ss) - 0.5
                        let d = (px * px + py * py).squareRoot()
                        if d >= hole && d <= R { cov += 1 }
                    }
                }
                let s = mx * (Double(cov) / Double(ss * ss)).squareRoot()
                if s >= 0.008 { disc.append(Cell(x: cx, y: cy, s: s, lit: true)) }
            }
        }
        return lattice + disc
    }()

    var body: some View {
        Canvas { ctx, size in
            let k = size.width
            for c in Self.cells {
                let r = CGRect(x: (c.x - c.s / 2) * k, y: (c.y - c.s / 2) * k, width: c.s * k, height: c.s * k)
                let p = Path(roundedRect: r, cornerRadius: max(0.4, c.s * k * 0.12))
                ctx.fill(p, with: .color(c.lit ? accent : accent.opacity(0.10 + 0.10 * lit)))
            }
        }
        .frame(width: side, height: side)
        .shadow(color: accent.opacity(0.45 * lit), radius: 5)
        .accessibilityHidden(true)
    }
}
