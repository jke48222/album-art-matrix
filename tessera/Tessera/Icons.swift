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
    case make, erase, photo, letters, clock, snake, fill, pen, undo
    case play, pause, skip, back, nine, lyrics
}

struct GlyphShape: View {
    let glyph: Glyph
    var lineWidth: CGFloat = 1.6

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height)
            let u = s / 24.0                       // one unit of the 24pt grid
            let inset = 3.0 * u
            let box = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
            let lw = lineWidth * max(1, u)

            switch glyph {
            case .undo:
                // back the way it came: an arc returning, arrowhead first
                let c = CGPoint(x: box.midX, y: box.midY + 0.8 * u)
                let r = box.width * 0.34
                var arc = Path()
                arc.addArc(center: c, radius: r,
                           startAngle: .degrees(10), endAngle: .degrees(215),
                           clockwise: false)
                ctx.stroke(arc, with: .color(.white),
                           style: StrokeStyle(lineWidth: lw, lineCap: .round))
                let tip = CGPoint(x: c.x + r * cos(.pi * 215 / 180),
                                  y: c.y + r * sin(.pi * 215 / 180))
                var head = Path()
                head.move(to: CGPoint(x: tip.x - 2.0 * u, y: tip.y - 0.4 * u))
                head.addLine(to: tip)
                head.addLine(to: CGPoint(x: tip.x + 0.5 * u, y: tip.y - 2.4 * u))
                ctx.stroke(head, with: .color(.white),
                           style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))

            case .pen:
                // a nib mid-stroke: shaft to the corner, tip filled, and the
                // mark it just made
                let tip = CGPoint(x: box.minX + 3.0 * u, y: box.maxY - 4.6 * u)
                var shaft = Path()
                shaft.move(to: CGPoint(x: tip.x + 2.0 * u, y: tip.y - 2.0 * u))
                shaft.addLine(to: CGPoint(x: box.maxX - 1.2 * u, y: box.minY + 2.6 * u))
                ctx.stroke(shaft, with: .color(.white),
                           style: StrokeStyle(lineWidth: lw, lineCap: .round))
                var nib = Path()
                nib.move(to: tip)
                nib.addLine(to: CGPoint(x: tip.x + 2.6 * u, y: tip.y - 0.6 * u))
                nib.addLine(to: CGPoint(x: tip.x + 0.6 * u, y: tip.y - 2.6 * u))
                nib.closeSubpath()
                ctx.fill(nib, with: .color(.white))
                var mark = Path()
                mark.move(to: CGPoint(x: tip.x - 1.6 * u, y: tip.y + 1.8 * u))
                mark.addLine(to: CGPoint(x: tip.x + 3.4 * u, y: tip.y + 1.8 * u))
                ctx.stroke(mark, with: .color(.white),
                           style: StrokeStyle(lineWidth: lw * 0.8, lineCap: .round))

            case .fill:
                // a paint bucket mid-pour: the tin tipped, the handle above,
                // one drop already loose
                var tilted = ctx
                tilted.translateBy(x: box.midX, y: box.midY)
                tilted.rotate(by: .degrees(-24))
                tilted.translateBy(x: -box.midX, y: -box.midY)
                let bw = box.width * 0.52, bh = box.height * 0.44
                let bx = box.midX - bw / 2, by = box.midY - bh * 0.28
                var tin = Path()
                tin.move(to: CGPoint(x: bx, y: by))
                tin.addLine(to: CGPoint(x: bx + bw, y: by))
                tin.addLine(to: CGPoint(x: bx + bw - 1.4 * u, y: by + bh))
                tin.addLine(to: CGPoint(x: bx + 1.4 * u, y: by + bh))
                tin.closeSubpath()
                tilted.stroke(tin, with: .color(.white),
                              style: StrokeStyle(lineWidth: lw, lineJoin: .round))
                var handle = Path()
                handle.addArc(center: CGPoint(x: box.midX, y: by),
                              radius: bw * 0.42,
                              startAngle: .degrees(200), endAngle: .degrees(340),
                              clockwise: false)
                tilted.stroke(handle, with: .color(.white),
                              style: StrokeStyle(lineWidth: lw * 0.85, lineCap: .round))
                let dd = 1.9 * u
                ctx.fill(Path(ellipseIn: CGRect(x: box.minX + 1.2 * u,
                                                y: box.maxY - dd - 0.4 * u,
                                                width: dd, height: dd)),
                         with: .color(.white))

            case .nine:
                // the wall's memory: three by three, the newest lit
                let gap = 1.3 * u
                let cell = (box.width - gap * 2) / 3
                for i in 0..<9 {
                    let r = CGRect(
                        x: box.minX + CGFloat(i % 3) * (cell + gap),
                        y: box.minY + CGFloat(i / 3) * (cell + gap),
                        width: cell, height: cell)
                    let path = Path(roundedRect: r, cornerRadius: 0.8 * u)
                    if i == 0 {
                        ctx.fill(path, with: .color(.white))
                    } else {
                        ctx.stroke(path, with: .color(.white), lineWidth: lw * 0.7)
                    }
                }

            case .lyrics:
                // an eighth note, and the two lines it is singing
                let headR = 2.0 * u
                let headC = CGPoint(x: box.minX + 3.6 * u, y: box.maxY - 3.0 * u)
                ctx.fill(Path(ellipseIn: CGRect(x: headC.x - headR, y: headC.y - headR * 0.8,
                                                width: headR * 2, height: headR * 1.6)),
                         with: .color(.white))
                var stem = Path()
                let stemTop = CGPoint(x: headC.x + headR - lw * 0.4, y: box.minY + 2.2 * u)
                stem.move(to: CGPoint(x: headC.x + headR - lw * 0.4, y: headC.y))
                stem.addLine(to: stemTop)
                ctx.stroke(stem, with: .color(.white),
                           style: StrokeStyle(lineWidth: lw * 0.9, lineCap: .round))
                var flag = Path()
                flag.move(to: stemTop)
                flag.addQuadCurve(
                    to: CGPoint(x: stemTop.x + 3.6 * u, y: stemTop.y + 4.6 * u),
                    control: CGPoint(x: stemTop.x + 3.8 * u, y: stemTop.y + 0.8 * u))
                ctx.stroke(flag, with: .color(.white),
                           style: StrokeStyle(lineWidth: lw * 0.9, lineCap: .round))
                for (i, w) in [(0, 5.4), (1, 3.6)] as [(Int, CGFloat)] {
                    var line = Path()
                    let ly = box.midY + CGFloat(i) * 3.0 * u + 0.4 * u
                    line.move(to: CGPoint(x: box.maxX - w * u, y: ly))
                    line.addLine(to: CGPoint(x: box.maxX - 1.0 * u, y: ly))
                    ctx.stroke(line, with: .color(.white),
                               style: StrokeStyle(lineWidth: lw * 0.9, lineCap: .round))
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
                // one lit tile throwing light: a filled square and three rays
                let side = box.width * 0.46
                let r = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1 * u), with: .color(.white))
                for angle in stride(from: -90.0, through: 150.0, by: 120.0) {
                    let a = angle * .pi / 180
                    var ray = Path()
                    ray.move(to: CGPoint(x: box.midX + cos(a) * side * 0.86,
                                         y: box.midY + sin(a) * side * 0.86))
                    ray.addLine(to: CGPoint(x: box.midX + cos(a) * box.width * 0.56,
                                            y: box.midY + sin(a) * box.width * 0.56))
                    ctx.stroke(ray, with: .color(.white), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                }

            case .dark:
                // the panel, unlit
                ctx.stroke(Path(roundedRect: box, cornerRadius: 1.5 * u),
                           with: .color(.white), lineWidth: lw)

            case .make:
                // the panel, with a stroke being drawn across it
                ctx.stroke(Path(roundedRect: box, cornerRadius: 1.5 * u),
                           with: .color(.white), lineWidth: lw)
                var nib = Path()
                nib.move(to: CGPoint(x: box.minX + box.width * 0.24, y: box.maxY - box.height * 0.24))
                nib.addLine(to: CGPoint(x: box.maxX - box.width * 0.20, y: box.minY + box.height * 0.20))
                ctx.stroke(nib, with: .color(.white),
                           style: StrokeStyle(lineWidth: lw * 1.5, lineCap: .round))

            case .erase:
                // a tile going dark: outline plus a slash
                ctx.stroke(Path(roundedRect: box, cornerRadius: 1.5 * u),
                           with: .color(.white), lineWidth: lw)
                var slash = Path()
                slash.move(to: CGPoint(x: box.minX + 2 * u, y: box.maxY - 2 * u))
                slash.addLine(to: CGPoint(x: box.maxX - 2 * u, y: box.minY + 2 * u))
                ctx.stroke(slash, with: .color(.white),
                           style: StrokeStyle(lineWidth: lw, lineCap: .round))

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
                // three stacked bars: a line of type at 64 pixels
                for (i, w) in [0.86, 0.62, 0.74].enumerated() {
                    let y = box.minY + box.height * (0.24 + Double(i) * 0.26)
                    var bar = Path()
                    bar.move(to: CGPoint(x: box.minX, y: y))
                    bar.addLine(to: CGPoint(x: box.minX + box.width * w, y: y))
                    ctx.stroke(bar, with: .color(.white),
                               style: StrokeStyle(lineWidth: lw * 1.3, lineCap: .round))
                }
            }
        }
        .accessibilityHidden(true)
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
