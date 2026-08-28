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
    case make, erase, photo, letters
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
    @State private var pressed = false

    var body: some View {
        Button {
            guard !active else { return }
            Taps.commit()
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
                .scaleEffect(pressed ? 0.93 : 1)
                .animation(Motion.settle, value: pressed)
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
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

/// Small circular utility button (settings, sleep, poll). Same family, quieter.
struct MiniGlyphButton: View {
    let glyph: Glyph
    let label: String
    var action: () -> Void

    var body: some View {
        Button {
            Taps.detent()
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
        .buttonStyle(.plain)
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
