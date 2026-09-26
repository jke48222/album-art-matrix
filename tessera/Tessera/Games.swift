import SwiftUI

/// A small drawing for each game, in its colour: the board's own shape as
/// a badge, drawn in the panel's spirit (blocks, not lines).
struct GameMotif: View {
    let name: String

    static func colour(_ name: String) -> Color {
        switch name {
        case "wordle": return Color(red: 83 / 255, green: 141 / 255, blue: 78 / 255)
        case "connections": return Color(red: 150 / 255, green: 100 / 255, blue: 190 / 255)
        case "sudoku": return Color(red: 120 / 255, green: 180 / 255, blue: 250 / 255)
        case "spellingbee": return Color(red: 232 / 255, green: 178 / 255, blue: 44 / 255)
        case "letterboxed": return Color(red: 196 / 255, green: 166 / 255, blue: 56 / 255)
        case "strands": return Color(red: 70 / 255, green: 122 / 255, blue: 210 / 255)
        case "crossword": return Color(red: 196 / 255, green: 166 / 255, blue: 56 / 255)
        case "contexto": return Color(red: 78 / 255, green: 150 / 255, blue: 84 / 255)
        case "heardle": return Color(red: 196 / 255, green: 166 / 255, blue: 56 / 255)
        case "sliding", "reveal", "pictionary": return Color(red: 226 / 255, green: 140 / 255, blue: 46 / 255)
        case "twentyq", "quiz": return Color(red: 232 / 255, green: 178 / 255, blue: 44 / 255)
        case "whistlebird": return Color(red: 78 / 255, green: 150 / 255, blue: 84 / 255)
        case "reaction": return Color(red: 78 / 255, green: 150 / 255, blue: 84 / 255)
        case "pong", "snake", "tetris": return Color(red: 74 / 255, green: 196 / 255, blue: 214 / 255)
        default: return Ink.dim
        }
    }

    var body: some View {
        Canvas { ctx, size in
            let c = Self.colour(name)
            let dim = Ink.faint
            func block(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ col: Color, r: Double = 3) {
                ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r), with: .color(col))
            }
            let W = size.width, H = size.height
            let cx = W / 2, cy = H / 2
            switch name {
            case "wordle":
                let marks: [[Int]] = [[0, 0, 2, 0, 2], [0, 1, 1, 1, 1], [2, 2, 2, 2, 2]]
                for (r, row) in marks.enumerated() {
                    for (k, m) in row.enumerated() {
                        block(cx - 52 + Double(k) * 21, cy - 30 + Double(r) * 21, 17, 17, m == 2 ? c : m == 1 ? Color(red: 196 / 255, green: 166 / 255, blue: 56 / 255) : Ink.sunk)
                    }
                }
            case "connections":
                let cols: [Color] = [Color(red: 196 / 255, green: 166 / 255, blue: 56 / 255), Color(red: 83 / 255, green: 141 / 255, blue: 78 / 255),
                                     Color(red: 70 / 255, green: 122 / 255, blue: 210 / 255), c]
                for (r, col) in cols.enumerated() { block(cx - 48, cy - 30 + Double(r) * 15, 96, 12, col, r: 4) }
            case "sudoku":
                for r in 0..<3 { for k in 0..<3 { block(cx - 30 + Double(k) * 21, cy - 30 + Double(r) * 21, 18, 18, (r + k) % 2 == 0 ? c.opacity(0.9) : Ink.sunk, r: 3) } }
            case "spellingbee":
                for k in 0..<6 {
                    let a = Double(k) * .pi / 3
                    ctx.fill(Path(ellipseIn: CGRect(x: cx + cos(a) * 24 - 9, y: cy + sin(a) * 24 - 9, width: 18, height: 18)), with: .color(Ink.sunk))
                }
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 11, y: cy - 11, width: 22, height: 22)), with: .color(c))
            case "letterboxed":
                ctx.stroke(Path(CGRect(x: cx - 26, y: cy - 26, width: 52, height: 52)), with: .color(dim), lineWidth: 2)
                var p = Path(); p.move(to: CGPoint(x: cx - 26, y: cy - 8)); p.addLine(to: CGPoint(x: cx + 8, y: cy + 26)); p.addLine(to: CGPoint(x: cx + 26, y: cy - 12)); p.addLine(to: CGPoint(x: cx - 10, y: cy - 26))
                ctx.stroke(p, with: .color(c), lineWidth: 3)
            case "strands":
                for r in 0..<3 { for k in 0..<5 { ctx.fill(Path(ellipseIn: CGRect(x: cx - 46 + Double(k) * 21, y: cy - 28 + Double(r) * 21, width: 14, height: 14)), with: .color((r == 1 && k >= 1 && k <= 3) || (r == 0 && k == 4) ? c : Ink.sunk)) } }
            case "crossword":
                for r in 0..<3 { for k in 0..<3 { block(cx - 30 + Double(k) * 21, cy - 30 + Double(r) * 21, 18, 18, (r == 0 && k == 0) || (r == 2 && k == 2) ? Ink.ground : Ink.sunk, r: 3) } }
                block(cx - 9, cy - 30, 18, 18, c, r: 3)
            case "contexto":
                for (k, w) in [70.0, 46.0, 28.0, 12.0].enumerated() { block(cx - 40, cy - 28 + Double(k) * 15, w, 10, k == 3 ? c : Ink.sunk, r: 5) }
            case "heardle":
                for (k, w) in [6.0, 10.0, 16.0, 24.0, 34.0].enumerated() { block(cx - 50 + Double(k) * 21, cy - 8, w, 16, k < 2 ? c : Ink.sunk, r: 5) }
            case "sliding":
                for r in 0..<3 { for k in 0..<3 { if !(r == 2 && k == 2) { block(cx - 30 + Double(k) * 21, cy - 30 + Double(r) * 21, 18, 18, c.opacity(0.4 + 0.2 * Double((r * 3 + k) % 3)), r: 3) } } }
            case "reveal":
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 26, y: cy - 26, width: 52, height: 52)), with: .color(c.opacity(0.25)))
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 16, y: cy - 16, width: 32, height: 32)), with: .color(c.opacity(0.5)))
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 6, y: cy - 6, width: 12, height: 12)), with: .color(c))
            case "twentyq":
                ctx.draw(Text("?").font(.system(size: 44, weight: .black, design: .rounded)).foregroundStyle(c), at: CGPoint(x: cx, y: cy))
            case "pictionary":
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 28, y: cy - 16, width: 40, height: 32)), with: .color(c))
                block(cx + 8, cy - 4, 14, 24, c, r: 4)
            case "quiz":
                ctx.stroke(Path(ellipseIn: CGRect(x: cx - 24, y: cy - 24, width: 48, height: 48)), with: .color(Ink.sunk), lineWidth: 5)
                var p = Path(); p.addArc(center: CGPoint(x: cx, y: cy), radius: 24, startAngle: .degrees(-90), endAngle: .degrees(150), clockwise: false)
                ctx.stroke(p, with: .color(c), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            case "whistlebird":
                block(cx - 40, cy - 30, 10, 26, c, r: 2); block(cx - 40, cy + 12, 10, 18, c, r: 2)
                block(cx + 26, cy - 30, 10, 16, c, r: 2); block(cx + 26, cy + 2, 10, 28, c, r: 2)
                block(cx - 8, cy - 4, 14, 9, Color(red: 196 / 255, green: 166 / 255, blue: 56 / 255), r: 3)
            case "reaction":
                block(cx - 44, cy - 22, 40, 44, Color(red: 0.62, green: 0.14, blue: 0.14), r: 8)
                block(cx + 4, cy - 22, 40, 44, c, r: 8)
            case "pong":
                block(cx - 44, cy - 14, 5, 28, Ink.ink, r: 2); block(cx + 39, cy - 4, 5, 28, Ink.ink, r: 2)
                block(cx - 2, cy - 2, 6, 6, c, r: 1)
                for k in 0..<5 { block(cx - 1, cy - 30 + Double(k) * 13, 2, 6, dim, r: 1) }
            case "snake":
                for k in 0..<6 { block(cx - 40 + Double(k) * 12, cy - 6, 10, 10, c.opacity(0.4 + 0.1 * Double(k)), r: 2) }
                block(cx + 30, cy - 6, 10, 10, c, r: 3)
                ctx.fill(Path(ellipseIn: CGRect(x: cx + 8, y: cy - 26, width: 10, height: 10)), with: .color(Color(red: 200 / 255, green: 66 / 255, blue: 56 / 255)))
            case "tetris":
                let cells = [(0, 2), (1, 2), (2, 2), (1, 1), (4, 2), (4, 1), (5, 2), (5, 1), (3, 0), (3, 1), (3, 2)]
                for (k, cell) in cells.enumerated() { block(cx - 42 + Double(cell.0) * 14, cy - 20 + Double(cell.1) * 14, 12, 12, k < 4 ? c : k < 8 ? Color(red: 196 / 255, green: 166 / 255, blue: 56 / 255) : Ink.sunk, r: 2) }
            default:
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 12, y: cy - 12, width: 24, height: 24)), with: .color(c))
            }
        }
    }
}

/// The wall as it is right now, small, over the phone's own board, so the
/// two are seen to agree.
struct WallStrip: View {
    @Environment(WallSession.self) private var wall
    let colour: Color
    let message: String
    var body: some View {
        HStack(spacing: 12) {
            PanelCanvas(px: wall.frame.map { [UInt8]($0) }, duty: 1.0)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: Round.control, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("On the wall").font(.ui(11, .semibold)).foregroundStyle(colour)
                Text(message).font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Round.card, style: .continuous).fill(Ink.plaster.opacity(0.7)))
    }
}

/// The wall's own frame, for a game with no native board on the phone yet.
struct WallBoard: View {
    @Environment(WallSession.self) private var wall
    var body: some View {
        PanelCanvas(px: wall.frame.map { [UInt8]($0) }, duty: 1.0)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Round.card, style: .continuous))
    }
}
