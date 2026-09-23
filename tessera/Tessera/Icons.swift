// A single native symbol family for every control surface. Symbols preserve
// optical alignment, foreground tint and readable weight at small sizes.
import SwiftUI

enum Glyph: String, CaseIterable, Hashable {
    case art, spin, lamp, dark
    case make, erase, photo, letters, clock, snake, fill, pen, undo, redo
    case palette, crate, gear
    case play, pause, skip, back, nine, lyrics, rewind, forward
    case video, games, weather, ticker

    var symbol: String {
        switch self {
        case .art: "photo.on.rectangle"
        case .spin: "opticaldisc"
        case .lamp: "lightbulb"
        case .dark: "power"
        case .make: "square.and.pencil"
        case .erase: "eraser"
        case .photo: "photo"
        case .letters: "textformat"
        case .clock: "clock"
        case .snake: "point.topleft.down.to.point.bottomright.curvepath"
        case .fill: "drop.halffull"
        case .pen: "pencil.tip"
        case .undo: "arrow.uturn.backward"
        case .redo: "arrow.uturn.forward"
        case .palette: "paintpalette"
        case .crate: "square.stack"
        case .gear: "gearshape"
        case .play: "play.fill"
        case .pause: "pause.fill"
        case .skip: "forward.end.fill"
        case .back: "backward.end.fill"
        case .nine: "square.grid.3x3"
        case .lyrics: "quote.bubble"
        case .rewind: "backward.fill"
        case .forward: "forward.fill"
        case .video: "play.rectangle"
        case .games: "gamecontroller"
        case .weather: "cloud.sun"
        case .ticker: "text.alignleft"
        }
    }
}

struct GlyphShape: View {
    let glyph: Glyph
    var lineWidth: CGFloat = 1.6

    var body: some View {
        GeometryReader { geometry in
            Image(systemName: glyph.symbol)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: min(geometry.size.width, geometry.size.height) * 0.86,
                              weight: lineWidth >= 1.9 ? .semibold : .medium))
                .frame(width: geometry.size.width, height: geometry.size.height)
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
            .frame(width: 44, height: 44)
        }
        .buttonStyle(PressStyle(scale: 0.9))
        .accessibilityLabel(label)
    }
}

