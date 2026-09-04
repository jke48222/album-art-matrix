// Hand-drawn icons. No SF Symbols anywhere in the control surface.
//
// Every glyph is the wall itself in a different state, so the icon set is one
// object rather than four unrelated pictures:
//   art    four tiles, the mosaic showing a picture
//   spin   the sleeve as a disc, with its spindle hole
//   lamp   one tile radiating, light with no picture in it
//   dark   the panel with nothing lit, a hairline outline
// They are drawn in a 24x24 space and scale with the button.

import SwiftUI

enum Glyph: String, CaseIterable, Hashable {
    case art, spin, lamp, dark
    // Utility glyphs. Deliberately not part of the mode row: that set is four
    // states of one object and it stays four.
    case make, erase, photo, letters, clock, snake, fill, pen, undo, redo
    case palette, crate, gear
    case play, pause, skip, back, nine, lyrics, rewind, forward
}

struct GlyphShape: View {
    let glyph: Glyph
    var lineWidth: CGFloat = 1.6

    var body: some View {
        // The drawing is a mask, and whatever foreground style the caller
        // sets shows through it. The Canvas draws in white so the mask is
        // solid where the glyph is. Before this, every glyph in the app was
        // white no matter what colour it was given: a Canvas paints its own
        // colours and ignores foregroundStyle entirely.
        Rectangle()
            .fill(.foreground)
            .mask { drawing }
            .accessibilityHidden(true)
    }

    private var drawing: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height)
            let u = s / 24.0                       // one unit of the 24pt grid
            let inset = 3.0 * u
            let box = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
            let lw = lineWidth * max(1, u)

            switch glyph {
            case .undo, .redo:
                // The undo arrow editors have drawn for thirty years: a solid
                // head pointing back, and a tail that runs out of its base
                // and hooks down and away. Redo is the same figure mirrored,
                // so the pair read as one motion in two directions.
                var g = ctx
                if glyph == .redo {
                    g.translateBy(x: size.width, y: 0)
                    g.scaleBy(x: -1, y: 1)
                }
                let hy = box.minY + 6.0 * u                 // the head's centre line
                var head = Path()
                head.move(to: CGPoint(x: box.minX, y: hy))
                head.addLine(to: CGPoint(x: box.minX + 7.0 * u, y: hy - 5.2 * u))
                head.addLine(to: CGPoint(x: box.minX + 7.0 * u, y: hy + 5.2 * u))
                head.closeSubpath()
                g.fill(head, with: .color(.white))
                // The tail: straight out of the head, then a quarter turn
                // down and a touch more, so it finishes heading down rather
                // than out. Points, not addArc, so the sweep is unambiguous.
                let cx = box.minX + 9.5 * u, rr = 7.0 * u
                var tail = Path()
                tail.move(to: CGPoint(x: box.minX + 6.2 * u, y: hy))
                tail.addLine(to: CGPoint(x: cx, y: hy))
                var deg = -90.0
                while deg < 15 {
                    deg += 5
                    let a = deg * .pi / 180
                    tail.addLine(to: CGPoint(x: cx + rr * cos(a), y: hy + rr + rr * sin(a)))
                }
                g.stroke(tail, with: .color(.white),
                         style: StrokeStyle(lineWidth: lw * 1.5, lineCap: .round, lineJoin: .round))

            case .palette:
                // The studio as a painter's palette: the board, its thumb
                // hole low on the right, three wells of paint along the top.
                let board = CGRect(x: box.minX, y: box.minY + 1.5 * u,
                                   width: box.width, height: box.height - 3.0 * u)
                ctx.stroke(Path(ellipseIn: board), with: .color(.white), lineWidth: lw)
                let hole = CGRect(x: board.maxX - 6.6 * u, y: board.midY + 0.2 * u,
                                  width: 3.2 * u, height: 3.2 * u)
                ctx.stroke(Path(ellipseIn: hole), with: .color(.white), lineWidth: lw)
                for (dx, dy) in [(4.2, 4.6), (7.6, 3.0), (11.4, 3.6)] {
                    let well = CGRect(x: board.minX + dx * u - 1.2 * u, y: board.minY + dy * u - 1.2 * u,
                                      width: 2.4 * u, height: 2.4 * u)
                    ctx.fill(Path(ellipseIn: well), with: .color(.white))
                }

            case .crate:
                // The archive as the box it lives in: a lid a shade wider
                // than the body, and the slot you lift it by.
                let lid = CGRect(x: box.minX, y: box.minY + 1.0 * u, width: box.width, height: 4.0 * u)
                ctx.stroke(Path(roundedRect: lid, cornerRadius: 1.0 * u), with: .color(.white), lineWidth: lw)
                let body = CGRect(x: box.minX + 1.4 * u, y: lid.maxY, width: box.width - 2.8 * u,
                                  height: box.maxY - lid.maxY - 0.5 * u)
                var walls = Path()
                walls.move(to: CGPoint(x: body.minX, y: body.minY))
                walls.addLine(to: CGPoint(x: body.minX, y: body.maxY - 1.5 * u))
                walls.addQuadCurve(to: CGPoint(x: body.minX + 1.5 * u, y: body.maxY),
                                   control: CGPoint(x: body.minX, y: body.maxY))
                walls.addLine(to: CGPoint(x: body.maxX - 1.5 * u, y: body.maxY))
                walls.addQuadCurve(to: CGPoint(x: body.maxX, y: body.maxY - 1.5 * u),
                                   control: CGPoint(x: body.maxX, y: body.maxY))
                walls.addLine(to: CGPoint(x: body.maxX, y: body.minY))
                ctx.stroke(walls, with: .color(.white), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                var slot = Path()
                slot.move(to: CGPoint(x: body.midX - 2.4 * u, y: body.minY + 3.4 * u))
                slot.addLine(to: CGPoint(x: body.midX + 2.4 * u, y: body.minY + 3.4 * u))
                ctx.stroke(slot, with: .color(.white), style: StrokeStyle(lineWidth: lw * 1.2, lineCap: .round))

            case .gear:
                // Settings as the gear everyone knows: a ring, eight teeth
                // out of it, the shaft hole in the middle.
                let c = CGPoint(x: box.midX, y: box.midY)
                let ring = 5.2 * u, tooth = 8.3 * u
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - ring, y: c.y - ring, width: ring * 2, height: ring * 2)),
                           with: .color(.white), lineWidth: lw * 1.1)
                var teeth = Path()
                for i in 0..<8 {
                    let a = Double(i) * .pi / 4
                    teeth.move(to: CGPoint(x: c.x + (ring - 0.3 * u) * cos(a), y: c.y + (ring - 0.3 * u) * sin(a)))
                    teeth.addLine(to: CGPoint(x: c.x + tooth * cos(a), y: c.y + tooth * sin(a)))
                }
                ctx.stroke(teeth, with: .color(.white), style: StrokeStyle(lineWidth: lw * 2.1, lineCap: .round))
                let hole = 2.0 * u
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - hole, y: c.y - hole, width: hole * 2, height: hole * 2)),
                           with: .color(.white), lineWidth: lw)

            case .pen:
                // a pencil, simply: body, collar, tip, lead
                let tip = CGPoint(x: box.minX + 2.2 * u, y: box.maxY - 2.2 * u)
                let ax = 0.7071, ay = -0.7071
                func at(_ d: CGFloat, _ side: CGFloat) -> CGPoint {
                    CGPoint(x: tip.x + d * ax - side * ay,
                            y: tip.y + d * ay + side * ax)
                }
                var point = Path()
                point.move(to: tip)
                point.addLine(to: at(4.2 * u, 2.0 * u))
                point.addLine(to: at(4.2 * u, -2.0 * u))
                point.closeSubpath()
                ctx.stroke(point, with: .color(.white),
                           style: StrokeStyle(lineWidth: lw * 0.9, lineJoin: .round))
                let lead = 1.3 * u
                ctx.fill(Path(ellipseIn: CGRect(x: tip.x - lead * 0.35,
                                                y: tip.y - lead * 0.65,
                                                width: lead, height: lead)),
                         with: .color(.white))
                var body = Path()
                body.move(to: at(5.2 * u, 0))
                body.addLine(to: at(12.0 * u, 0))
                ctx.stroke(body, with: .color(.white),
                           style: StrokeStyle(lineWidth: lw * 2.4, lineCap: .round))
                var collar = Path()
                collar.move(to: at(5.2 * u, 1.8 * u))
                collar.addLine(to: at(5.2 * u, -1.8 * u))
                ctx.stroke(collar, with: .color(.white),
                           style: StrokeStyle(lineWidth: lw * 0.8, lineCap: .round))

            case .fill:
                // a tile half-taken by its ink: what filling IS, on a wall
                // made of tiles. The diagonal is the pour line.
                let r = 2.2 * u
                let sq = box.insetBy(dx: 1.2 * u, dy: 1.2 * u)
                let outline = Path(roundedRect: sq, cornerRadius: r)
                var half = Path()
                half.move(to: CGPoint(x: sq.minX, y: sq.maxY - r))
                half.addLine(to: CGPoint(x: sq.maxX - r, y: sq.minY))
                half.addQuadCurve(to: CGPoint(x: sq.maxX, y: sq.minY + r),
                                  control: CGPoint(x: sq.maxX, y: sq.minY))
                half.addLine(to: CGPoint(x: sq.maxX, y: sq.maxY - r))
                half.addQuadCurve(to: CGPoint(x: sq.maxX - r, y: sq.maxY),
                                  control: CGPoint(x: sq.maxX, y: sq.maxY))
                half.addLine(to: CGPoint(x: sq.minX + r, y: sq.maxY))
                half.addQuadCurve(to: CGPoint(x: sq.minX, y: sq.maxY - r),
                                  control: CGPoint(x: sq.minX, y: sq.maxY))
                half.closeSubpath()
                ctx.fill(half, with: .color(.white))
                ctx.stroke(outline, with: .color(.white), lineWidth: lw * 0.9)

            case .nine:
                // the wall's memory: three by three, the newest lit
                let gap9 = 1.3 * u
                let cell9 = (box.width - gap9 * 2) / 3
                for i in 0..<9 {
                    let r9 = CGRect(
                        x: box.minX + CGFloat(i % 3) * (cell9 + gap9),
                        y: box.minY + CGFloat(i / 3) * (cell9 + gap9),
                        width: cell9, height: cell9)
                    let path9 = Path(roundedRect: r9, cornerRadius: 0.8 * u)
                    if i == 0 {
                        ctx.fill(path9, with: .color(.white))
                    } else {
                        ctx.stroke(path9, with: .color(.white), lineWidth: lw * 0.7)
                    }
                }

            case .lyrics:
                // Words being sung: a quaver, and three lines of text that
                // shorten as they go, the way a lyric sheet reads.
                let headR = 2.1 * u
                let headC = CGPoint(x: box.minX + 4.2 * u, y: box.maxY - 2.6 * u)
                var head = Path()
                head.addEllipse(in: CGRect(x: headC.x - headR * 1.15, y: headC.y - headR * 0.8,
                                           width: headR * 2.3, height: headR * 1.6))
                var h = ctx
                h.translateBy(x: headC.x, y: headC.y)
                h.rotate(by: .degrees(-22))
                h.translateBy(x: -headC.x, y: -headC.y)
                h.fill(head, with: .color(.white))
                let stemX = headC.x + headR * 1.0
                let stemTop = CGPoint(x: stemX, y: box.minY + 1.4 * u)
                var stem = Path()
                stem.move(to: CGPoint(x: stemX, y: headC.y - 0.4 * u))
                stem.addLine(to: stemTop)
                ctx.stroke(stem, with: .color(.white),
                           style: StrokeStyle(lineWidth: lw, lineCap: .round))
                var flag = Path()
                flag.move(to: stemTop)
                flag.addCurve(to: CGPoint(x: stemTop.x + 3.2 * u, y: stemTop.y + 5.2 * u),
                              control1: CGPoint(x: stemTop.x + 3.6 * u, y: stemTop.y + 0.6 * u),
                              control2: CGPoint(x: stemTop.x + 3.4 * u, y: stemTop.y + 3.0 * u))
                ctx.stroke(flag, with: .color(.white),
                           style: StrokeStyle(lineWidth: lw, lineCap: .round))
                for (i, w) in [(0, 6.0), (1, 4.6), (2, 5.4)] as [(Int, CGFloat)] {
                    var line = Path()
                    let ly = box.minY + 7.6 * u + CGFloat(i) * 3.4 * u
                    line.move(to: CGPoint(x: box.maxX - w * u, y: ly))
                    line.addLine(to: CGPoint(x: box.maxX - 0.6 * u, y: ly))
                    ctx.stroke(line, with: .color(.white),
                               style: StrokeStyle(lineWidth: lw * 0.95, lineCap: .round))
                }

            case .rewind, .forward:
                // two solid triangles, nose to tail: the double arrow of a
                // transport key. Forward is the same figure mirrored.
                var g = ctx
                if glyph == .rewind {
                    g.translateBy(x: size.width, y: 0)
                    g.scaleBy(x: -1, y: 1)
                }
                let h = box.height * 0.62
                let w = box.width * 0.46
                let y0 = box.midY - h / 2, y1 = box.midY + h / 2
                for x in [box.minX + 0.4 * u, box.minX + w - 0.6 * u] {
                    var tri = Path()
                    tri.move(to: CGPoint(x: x, y: y0))
                    tri.addLine(to: CGPoint(x: x + w, y: box.midY))
                    tri.addLine(to: CGPoint(x: x, y: y1))
                    tri.closeSubpath()
                    g.fill(tri, with: .color(.white))
                }

            case .play:
                var p = Path()
                p.move(to: CGPoint(x: box.minX + 2.4 * u, y: box.minY + 1.6 * u))
                p.addLine(to: CGPoint(x: box.maxX - 1.4 * u, y: box.midY))
                p.addLine(to: CGPoint(x: box.minX + 2.4 * u, y: box.maxY - 1.6 * u))
                p.closeSubpath()
                ctx.fill(p, with: .color(.white))

            case .pause:
                let bw2 = 2.6 * u
                for x in [box.minX + 3.2 * u, box.maxX - 3.2 * u - bw2] {
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: box.minY + 1.6 * u,
                                                      width: bw2,
                                                      height: box.height - 3.2 * u),
                                  cornerRadius: 1),
                             with: .color(.white))
                }

            case .skip:
                var p = Path()
                p.move(to: CGPoint(x: box.minX + 1.6 * u, y: box.minY + 2.4 * u))
                p.addLine(to: CGPoint(x: box.midX + 1.6 * u, y: box.midY))
                p.addLine(to: CGPoint(x: box.minX + 1.6 * u, y: box.maxY - 2.4 * u))
                p.closeSubpath()
                ctx.fill(p, with: .color(.white))
                ctx.fill(Path(roundedRect: CGRect(x: box.midX + 2.6 * u,
                                                  y: box.minY + 2.4 * u,
                                                  width: 1.7 * u,
                                                  height: box.height - 4.8 * u),
                              cornerRadius: 0.8),
                         with: .color(.white))

            case .back:
                var p = Path()
                p.move(to: CGPoint(x: box.maxX - 1.6 * u, y: box.minY + 2.4 * u))
                p.addLine(to: CGPoint(x: box.midX - 1.6 * u, y: box.midY))
                p.addLine(to: CGPoint(x: box.maxX - 1.6 * u, y: box.maxY - 2.4 * u))
                p.closeSubpath()
                ctx.fill(p, with: .color(.white))
                ctx.fill(Path(roundedRect: CGRect(x: box.midX - 4.3 * u,
                                                  y: box.minY + 2.4 * u,
                                                  width: 1.7 * u,
                                                  height: box.height - 4.8 * u),
                              cornerRadius: 0.8),
                         with: .color(.white))

            case .snake:
                // A serpentine chasing its meal: the body is three arcs of a
                // wave, the head is the fat end, the food sits where it is
                // headed. Round everywhere, because the game draws in round
                // emitters and the glyph should come from the same animal.
                let y0 = box.midY + box.height * 0.14
                let r = box.width / 5.6
                var path = Path()
                path.move(to: CGPoint(x: box.minX + 0.2 * u, y: y0))
                path.addArc(center: CGPoint(x: box.minX + 0.2 * u + r, y: y0),
                            radius: r, startAngle: .degrees(180), endAngle: .degrees(0),
                            clockwise: false)
                path.addArc(center: CGPoint(x: box.minX + 0.2 * u + 3 * r, y: y0),
                            radius: r, startAngle: .degrees(180), endAngle: .degrees(0),
                            clockwise: true)
                path.addArc(center: CGPoint(x: box.minX + 0.2 * u + 5 * r, y: y0),
                            radius: r, startAngle: .degrees(180), endAngle: .degrees(305),
                            clockwise: false)
                ctx.stroke(path, with: .color(.white),
                           style: StrokeStyle(lineWidth: lw, lineCap: .round))
                // the head, a filled tile at the raised end of the last arc
                let end = CGPoint(
                    x: box.minX + 0.2 * u + 5 * r + r * cos(.pi * 305 / 180),
                    y: y0 + r * sin(.pi * 305 / 180)
                )
                let hd = 3.0 * u
                ctx.fill(Path(roundedRect: CGRect(x: end.x - hd / 2, y: end.y - hd / 2,
                                                  width: hd, height: hd),
                              cornerRadius: hd * 0.32),
                         with: .color(.white))
                // the meal, small and square like the game draws it
                let fd = 1.7 * u
                ctx.fill(Path(roundedRect: CGRect(x: box.maxX - fd, y: box.minY + 0.6 * u,
                                                  width: fd, height: fd),
                              cornerRadius: fd * 0.3),
                         with: .color(.white))

            case .art:
                // four tiles, two lit
                let gap = 1.6 * u
                let cell = (box.width - gap) / 2
                let cells = [
                    CGRect(x: box.minX, y: box.minY, width: cell, height: cell),
                    CGRect(x: box.minX + cell + gap, y: box.minY, width: cell, height: cell),
                    CGRect(x: box.minX, y: box.minY + cell + gap, width: cell, height: cell),
                    CGRect(x: box.minX + cell + gap, y: box.minY + cell + gap, width: cell, height: cell),
                ]
                for (i, r) in cells.enumerated() {
                    let path = Path(roundedRect: r, cornerRadius: 1 * u)
                    if i == 0 || i == 3 {
                        ctx.fill(path, with: .color(.white))
                    } else {
                        ctx.stroke(path, with: .color(.white), lineWidth: lw)
                    }
                }

            case .spin:
                // a disc with a spindle hole, and one sheen wedge
                let c = CGPoint(x: box.midX, y: box.midY)
                let r = box.width / 2
                ctx.stroke(
                    Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                    with: .color(.white), lineWidth: lw
                )
                let hole = r * 0.26
                ctx.fill(
                    Path(ellipseIn: CGRect(x: c.x - hole, y: c.y - hole, width: hole * 2, height: hole * 2)),
                    with: .color(.white)
                )
                var sheen = Path()
                sheen.addArc(center: c, radius: r * 0.62,
                             startAngle: .degrees(-118), endAngle: .degrees(-42), clockwise: false)
                ctx.stroke(sheen, with: .color(.white), style: StrokeStyle(lineWidth: lw, lineCap: .round))

            case .lamp:
                // Light with no picture in it: one lit tile, and the glow it
                // throws as a ring of short rays all round. Eight rays, not
                // three: a lamp lights the whole room.
                let side = box.width * 0.40
                let r = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1.2 * u), with: .color(.white))
                for i in 0..<8 {
                    let a = (Double(i) * 45.0 - 90.0) * .pi / 180
                    let long = i % 2 == 0
                    let r0 = side * (long ? 0.80 : 0.86)
                    let r1 = box.width * (long ? 0.56 : 0.50)
                    var ray = Path()
                    ray.move(to: CGPoint(x: box.midX + cos(a) * r0, y: box.midY + sin(a) * r0))
                    ray.addLine(to: CGPoint(x: box.midX + cos(a) * r1, y: box.midY + sin(a) * r1))
                    ctx.stroke(ray, with: .color(.white),
                               style: StrokeStyle(lineWidth: lw * (long ? 1.0 : 0.8), lineCap: .round))
                }

            case .dark:
                // the panel, unlit
                ctx.stroke(Path(roundedRect: box, cornerRadius: 1.5 * u),
                           with: .color(.white), lineWidth: lw)

            case .make:
                // The studio: the panel with a stroke laid across it and the
                // brush still on the tile, mid-mark. The tile it just filled
                // is solid; the rest of the panel is the outline.
                ctx.stroke(Path(roundedRect: box, cornerRadius: 1.5 * u),
                           with: .color(.white), lineWidth: lw)
                let cell = box.width / 4
                let lit = CGRect(x: box.minX + cell * 0.55, y: box.maxY - cell * 1.55,
                                 width: cell, height: cell)
                ctx.fill(Path(roundedRect: lit, cornerRadius: 0.5 * u), with: .color(.white))
                var stroke = Path()
                stroke.move(to: CGPoint(x: lit.midX + 0.6 * u, y: lit.midY - 0.6 * u))
                stroke.addCurve(to: CGPoint(x: box.maxX - 2.6 * u, y: box.minY + 3.2 * u),
                                control1: CGPoint(x: box.midX + 1.0 * u, y: box.midY + 2.4 * u),
                                control2: CGPoint(x: box.midX + 2.0 * u, y: box.minY + 4.0 * u))
                ctx.stroke(stroke, with: .color(.white),
                           style: StrokeStyle(lineWidth: lw * 1.3, lineCap: .round))
                // the brush tip, a small solid wedge at the far end
                let tip = CGPoint(x: box.maxX - 2.6 * u, y: box.minY + 3.2 * u)
                var wedge = Path()
                wedge.move(to: CGPoint(x: tip.x + 1.4 * u, y: tip.y - 1.4 * u))
                wedge.addLine(to: CGPoint(x: tip.x - 0.4 * u, y: tip.y - 1.6 * u))
                wedge.addLine(to: CGPoint(x: tip.x + 1.6 * u, y: tip.y + 0.4 * u))
                wedge.closeSubpath()
                ctx.fill(wedge, with: .color(.white))

            case .erase:
                // the eraser itself, tilted mid-swipe, its two-tone seam,
                // and the clean streak it just left
                var e = ctx
                e.translateBy(x: box.midX, y: box.midY - 0.8 * u)
                e.rotate(by: .degrees(-38))
                let bw = 9.6 * u, bh = 5.4 * u
                let block = CGRect(x: -bw / 2, y: -bh / 2, width: bw, height: bh)
                e.stroke(Path(roundedRect: block, cornerRadius: 1.5 * u),
                         with: .color(.white),
                         style: StrokeStyle(lineWidth: lw * 0.95, lineJoin: .round))
                var seam = Path()
                seam.move(to: CGPoint(x: -bw / 2 + 3.1 * u, y: -bh / 2))
                seam.addLine(to: CGPoint(x: -bw / 2 + 3.1 * u, y: bh / 2))
                e.stroke(seam, with: .color(.white), lineWidth: lw * 0.8)
                var streak = Path()
                streak.move(to: CGPoint(x: box.minX + 1.4 * u, y: box.maxY - 1.8 * u))
                streak.addLine(to: CGPoint(x: box.minX + 8.0 * u, y: box.maxY - 1.8 * u))
                ctx.stroke(streak, with: .color(.white),
                           style: StrokeStyle(lineWidth: lw * 0.85, lineCap: .round))

            case .photo:
                // a frame with a horizon in it
                ctx.stroke(Path(roundedRect: box, cornerRadius: 1.5 * u),
                           with: .color(.white), lineWidth: lw)
                var hill = Path()
                hill.move(to: CGPoint(x: box.minX + 1.5 * u, y: box.maxY - 4 * u))
                hill.addLine(to: CGPoint(x: box.midX - 1 * u, y: box.midY))
                hill.addLine(to: CGPoint(x: box.maxX - 1.5 * u, y: box.maxY - 4 * u))
                ctx.stroke(hill, with: .color(.white),
                           style: StrokeStyle(lineWidth: lw, lineJoin: .round))
                let sun = 1.6 * u
                ctx.fill(Path(ellipseIn: CGRect(x: box.maxX - 5.5 * u, y: box.minY + 3 * u,
                                                width: sun * 2, height: sun * 2)),
                         with: .color(.white))

            case .clock:
                // a face and two hands
                let c = CGPoint(x: box.midX, y: box.midY)
                let rr = box.width / 2
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)),
                           with: .color(.white), lineWidth: lw)
                var hands = Path()
                hands.move(to: c); hands.addLine(to: CGPoint(x: c.x, y: c.y - rr * 0.55))
                hands.move(to: c); hands.addLine(to: CGPoint(x: c.x + rr * 0.42, y: c.y))
                ctx.stroke(hands, with: .color(.white),
                           style: StrokeStyle(lineWidth: lw, lineCap: .round))

            case .letters:
                // type, mid-thought: a set T and the cursor still blinking
                let stemX = box.minX + 5.4 * u
                var t = Path()
                t.move(to: CGPoint(x: box.minX + 0.8 * u, y: box.minY + 2.0 * u))
                t.addLine(to: CGPoint(x: box.minX + 10.0 * u, y: box.minY + 2.0 * u))
                ctx.stroke(t, with: .color(.white),
                           style: StrokeStyle(lineWidth: lw * 1.15, lineCap: .round))
                var down = Path()
                down.move(to: CGPoint(x: stemX, y: box.minY + 2.0 * u))
                down.addLine(to: CGPoint(x: stemX, y: box.maxY - 2.2 * u))
                ctx.stroke(down, with: .color(.white),
                           style: StrokeStyle(lineWidth: lw * 1.15, lineCap: .round))
                // serif feet: the tell that this is TYPE
                for x in [box.minX + 0.8 * u, box.minX + 10.0 * u] {
                    var serif = Path()
                    serif.move(to: CGPoint(x: x, y: box.minY + 2.0 * u))
                    serif.addLine(to: CGPoint(x: x, y: box.minY + 3.7 * u))
                    ctx.stroke(serif, with: .color(.white),
                               style: StrokeStyle(lineWidth: lw * 0.85, lineCap: .round))
                }
                // the caret as it actually looks: an I-beam, caps and all
                let cx2 = box.maxX - 1.8 * u
                var beam = Path()
                beam.move(to: CGPoint(x: cx2, y: box.midY - 0.2 * u))
                beam.addLine(to: CGPoint(x: cx2, y: box.maxY - 1.2 * u))
                ctx.stroke(beam, with: .color(.white),
                           style: StrokeStyle(lineWidth: lw * 0.9, lineCap: .round))
                for capY in [box.midY - 0.2 * u, box.maxY - 1.2 * u] {
                    var cap = Path()
                    cap.move(to: CGPoint(x: cx2 - 1.2 * u, y: capY))
                    cap.addLine(to: CGPoint(x: cx2 + 1.2 * u, y: capY))
                    ctx.stroke(cap, with: .color(.white),
                               style: StrokeStyle(lineWidth: lw * 0.8, lineCap: .round))
                }
            }
        }
    }
}

/// A circular control. The ring is the affordance, the glyph is the meaning,
/// and when it is the active one the disc fills with the wall's own light.
struct GlyphButton: View {
    let glyph: Glyph
    let label: String
    let active: Bool
    let accent: Color
    let lit: Double                  // 0...1, how much the wall is emitting
    var diameter: CGFloat = 62
    var action: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button {
            guard !active else { return }
            action()
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(active ? accent.opacity(0.16) : Ink.sunk)
                    Circle()
                        .strokeBorder(active ? accent : Ink.hairline, lineWidth: active ? 1.5 : 1)
                    GlyphShape(glyph: glyph, lineWidth: active ? 1.9 : 1.6)
                        .frame(width: diameter * 0.42, height: diameter * 0.42)
                        .foregroundStyle(active ? accent : Ink.dim)
                }
                .frame(width: diameter, height: diameter)
                // the active control catches the wall's light
                .shadow(color: active ? accent.opacity(0.5 * lit) : .clear,
                        radius: 14 * lit, y: 2)
                .animation(Motion.settle, value: active)

                Text(label)
                    .font(.machine(9))
                    .textCase(.uppercase)
                    .kerning(typeSize.isAccessibilitySize ? 0 : 0.7)
                    .foregroundStyle(active ? Ink.ink : Ink.faint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        // A ButtonStyle owns the press state. The previous version rode a
        // simultaneous DragGesture alongside the Button, which fought it for
        // the touch: the press animation fired inconsistently and could eat
        // the tap outright.
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

/// Press feedback done the way SwiftUI wants: the style is told when the
/// button is pressed, so it never competes with the button's own gesture.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.92
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.blink, value: configuration.isPressed)
            // The click, at finger-DOWN. Every button wearing this style is
            // felt the moment it is touched, so their actions must not add a
            // second buzz of their own.
            .onChange(of: configuration.isPressed) { _, down in
                if down { Taps.press() }
            }
    }
}

/// Small circular utility button (settings, sleep, poll). Same family, quieter.
struct MiniGlyphButton: View {
    let glyph: Glyph
    let label: String
    var action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            ZStack {
                Circle().strokeBorder(Ink.hairline, lineWidth: 1)
                GlyphShape(glyph: glyph, lineWidth: 1.5)
                    .frame(width: 16, height: 16)
                    .foregroundStyle(Ink.dim)
            }
            .frame(width: 36, height: 36)
        }
        .buttonStyle(PressStyle(scale: 0.9))
        .accessibilityLabel(label)
    }
}

/// The mark. One lit tessera in a dark lattice, the same object the icon is
/// and the same rules the panel is drawn by. It takes the wall's own colour,
/// so the logo is lit by the art like everything else.
struct TesseraMark: View {
    var accent: Color = Ink.tile
    var lit: Double = 1
    var side: CGFloat = 18

    var body: some View {
        Canvas { ctx, size in
            let grid = 3
            let cell = size.width / CGFloat(grid)
            let r = cell * 0.30
            for gy in 0..<grid {
                for gx in 0..<grid {
                    let cx = CGFloat(gx) * cell + cell / 2
                    let cy = CGFloat(gy) * cell + cell / 2
                    let dot = Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                    if gx == 1 && gy == 1 {
                        ctx.fill(dot, with: .color(accent))
                    } else {
                        // neighbours catch a little of the lit tile
                        ctx.fill(dot, with: .color(accent.opacity(0.14 + 0.16 * lit)))
                    }
                }
            }
        }
        .frame(width: side, height: side)
        .shadow(color: accent.opacity(0.55 * lit), radius: 6)
        .accessibilityHidden(true)
    }
}
