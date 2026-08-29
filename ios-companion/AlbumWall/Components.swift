// The three custom controls the whole app is built from, plus the wall
// panel. One vocabulary, reused everywhere — that's the design system.
import SwiftUI
import UIKit

// ---- strip control ------------------------------------------------------
// A hairline-bordered strip of cells; the active cell inverts to solid ink.
// Used for modes, effects, finishes, presets, sleep timer — everything.
struct StripControl<ID: Hashable>: View {
    @Environment(\.theme) private var t
    let options: [(id: ID, label: String)]
    @Binding var selection: ID
    var enabled: Bool = true
    var height: CGFloat = 46
    var fontSize: CGFloat = 12
    var kern: CGFloat = 1.5
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element.id) { i, opt in
                cell(opt.label, active: opt.id == selection, divided: i > 0)
                    .onTapGesture {
                        guard enabled, selection != opt.id else { return }
                        UISelectionFeedbackGenerator().selectionChanged()
                        selection = opt.id
                    }
            }
        }
        .frame(height: height)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(strokeColor, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .opacity(enabled ? 1 : 0.35)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: selection)
    }

    private func cell(_ label: String, active: Bool, divided: Bool) -> some View {
        Text(label)
            .font(.display(fontSize, .bold))
            .kerning(kern)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if active {                     // the ink block slides
                    Rectangle().fill(t.ink)
                        .matchedGeometryEffect(id: "active-cell", in: ns)
                }
            }
            .foregroundStyle(active ? t.ground : t.ink70)
            .overlay(alignment: .leading) {
                if divided { Rectangle().fill(strokeColor).frame(width: 1) }
            }
            .contentShape(Rectangle())
    }

    private var strokeColor: Color { enabled ? t.ink : t.hairline }
}

// ---- tick slider --------------------------------------------------------
// A ruler: fine ticks, a 2pt rail, a flat round knob. Continuous drag,
// commit callback on release (so the wall isn't flooded mid-drag).
struct TickSlider: View {
    @Environment(\.theme) private var t
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onLive: (Double) -> Void = { _ in }   // streams during drag
    var onCommit: (Double) -> Void = { _ in }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let frac = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                Canvas { ctx, size in
                    for i in 0...24 {
                        let x = size.width * CGFloat(i) / 24
                        let tall: CGFloat = i % 6 == 0 ? 12 : 8
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: tall))
                        ctx.stroke(p, with: .color(t.ink.opacity(0.25)), lineWidth: 1)
                    }
                }
                .frame(height: 12)
                .offset(y: -8)

                Rectangle().fill(t.hairline).frame(height: 2)
                Rectangle().fill(t.ink)
                    .frame(width: max(0, w * frac), height: 2)
                Circle().fill(t.ink)
                    .frame(width: 20, height: 20)
                    .offset(x: max(0, min(w - 20, w * frac - 10)))
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let f = max(0, min(1, g.location.x / w))
                        value = range.lowerBound + f * (range.upperBound - range.lowerBound)
                        onLive(value)
                    }
                    .onEnded { _ in
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onCommit(value)
                    }
            )
        }
        .frame(height: 36)
    }
}

// A labeled slider row: micro label left, live value right, ruler under.
struct SliderRow: View {
    @Environment(\.theme) private var t
    let label: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onLive: (Double) -> Void = { _ in }
    var onCommit: (Double) -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                MicroLabel(text: label)
                Spacer()
                Text(valueText)
                    .font(.display(15, .bold))
                    .monospacedDigit()
                    .foregroundStyle(t.ink)
            }
            TickSlider(value: $value, range: range,
                       onLive: onLive, onCommit: onCommit)
        }
    }
}

// ---- the wall panel -----------------------------------------------------
// The product photo: a black square in a hairline frame, LED grid on top,
// mono caption underneath. Content is whatever the wall currently shows.
struct WallPanel<Content: View>: View {
    @Environment(\.theme) private var t
    let captionLeft: String
    let captionRight: String
    var captionRightColor: Color? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Theme.panel
                content
                PixelGrid(cells: 64)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipped()
            .padding(6)
            .overlay(Rectangle().stroke(t.hairline, lineWidth: 1))

            HStack {
                MonoTag(captionLeft)
                Spacer()
                MonoTag(captionRight, color: captionRightColor)
            }
        }
    }
}

struct PixelGrid: View {
    let cells: Int
    var body: some View {
        Canvas { ctx, size in
            let step = size.width / CGFloat(cells)
            guard step > 1.5 else { return }
            var p = Path()
            for i in 1..<cells {
                let x = CGFloat(i) * step
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: size.height))
                p.move(to: CGPoint(x: 0, y: x))
                p.addLine(to: CGPoint(x: size.width, y: x))
            }
            ctx.stroke(p, with: .color(.black.opacity(0.45)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

// ---- buttons ------------------------------------------------------------
/// Every tappable thing squeezes a little. Cheap, physical, everywhere.
struct Pressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7),
                       value: configuration.isPressed)
    }
}

struct PrimaryButton: View {
    @Environment(\.theme) private var t
    let label: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            Text(label)
                .font(.display(16, .bold))
                .foregroundStyle(Color(hex: 0xF4F1EA))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Theme.signal)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(Pressable())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

struct GhostButton: View {
    @Environment(\.theme) private var t
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.display(14, .semibold))
                .foregroundStyle(t.ink70)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(t.ink.opacity(0.3)).frame(height: 1.5)
                        .offset(y: 3)
                }
        }
        .buttonStyle(Pressable())
    }
}

struct SettingsSection<Content: View>: View {
    @Environment(\.theme) private var t
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(t.hairline).frame(height: 1)
            MicroLabel(text: title)
                .padding(.top, 2)
            content
        }
        .padding(.bottom, 10)
    }
}

// ---- tab bar ------------------------------------------------------------
// Four labeled cells, hand-drawn icons, active cell inverted — the strip
// control grown into the app's chassis.
enum WallTab: String, CaseIterable {
    case record, lamp, create, wall

    var label: String {
        switch self {
        case .record: "MUSIC"
        case .lamp: "LAMP"
        case .create: "CREATE"
        case .wall: "WALL"
        }
    }
}

struct TabIcon: View {
    let tab: WallTab
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let s = size.width
            let line = StrokeStyle(lineWidth: 1.6, lineCap: .round,
                                   lineJoin: .round)
            var p = Path()
            switch tab {
            case .record:
                p.addEllipse(in: CGRect(x: 2, y: 2, width: s - 4, height: s - 4))
                p.addEllipse(in: CGRect(x: s / 2 - 2, y: s / 2 - 2,
                                        width: 4, height: 4))
            case .lamp:
                for row in 0..<2 {
                    let y = s * 0.36 + CGFloat(row) * s * 0.3
                    p.move(to: CGPoint(x: 2, y: y))
                    p.addCurve(to: CGPoint(x: s / 2, y: y),
                               control1: CGPoint(x: s * 0.17, y: y - s * 0.22),
                               control2: CGPoint(x: s * 0.33, y: y + s * 0.22))
                    p.addCurve(to: CGPoint(x: s - 2, y: y),
                               control1: CGPoint(x: s * 0.67, y: y - s * 0.22),
                               control2: CGPoint(x: s * 0.83, y: y + s * 0.22))
                }
            case .create:
                p.move(to: CGPoint(x: 3, y: s - 3))
                p.addLine(to: CGPoint(x: 3, y: s - 7.5))
                p.addLine(to: CGPoint(x: s - 7.5, y: 3))
                p.addLine(to: CGPoint(x: s - 3, y: 7.5))
                p.addLine(to: CGPoint(x: 7.5, y: s - 3))
                p.closeSubpath()
                p.move(to: CGPoint(x: s - 10, y: 5.5))
                p.addLine(to: CGPoint(x: s - 5.5, y: 10))
            case .wall:
                let cell = (s - 4 - 4) / 3
                for r in 0..<3 {
                    for c in 0..<3 {
                        p.addRect(CGRect(x: 2 + CGFloat(c) * (cell + 2),
                                         y: 2 + CGFloat(r) * (cell + 2),
                                         width: cell, height: cell))
                    }
                }
            }
            ctx.stroke(p, with: .color(color), style: line)
        }
        .frame(width: 22, height: 22)
    }
}

struct PaperTabBar: View {
    @Environment(\.theme) private var t
    @Binding var selection: WallTab

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(t.hairline).frame(height: 1)
            HStack(spacing: 0) {
                ForEach(WallTab.allCases, id: \.self) { tab in
                    let active = tab == selection
                    VStack(spacing: 5) {
                        TabIcon(tab: tab, color: active ? t.ground : t.ink70)
                            .scaleEffect(active ? 1.12 : 1)
                            .animation(.spring(response: 0.3, dampingFraction: 0.6),
                                       value: selection)
                        Text(tab.label)
                            .font(.display(9, .bold))
                            .kerning(1.2)
                            .foregroundStyle(active ? t.ground : t.ink55)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(active ? t.ink : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard selection != tab else { return }
                        UISelectionFeedbackGenerator().selectionChanged()
                        selection = tab
                    }
                    .overlay(alignment: .leading) {
                        if tab != .record {
                            Rectangle().fill(t.hairlineSoft).frame(width: 1)
                        }
                    }
                }
            }
        }
        .background(t.ground)
    }
}

// ---- compact wall status (top of Lamp / Create / Wall pages) ------------
struct CompactStatus: View {
    @Environment(\.theme) private var t
    @EnvironmentObject var wall: WallAPI

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Theme.panel
                if let f = wall.wallFrame {
                    Image(uiImage: f).resizable().interpolation(.none)
                }
            }
            .frame(width: 26, height: 26)
            .overlay(Rectangle().stroke(t.hairline, lineWidth: 1))
            MonoTag("ON THE WALL, \(modeName)")
            Spacer()
            Circle()
                .fill(wall.reachable ? t.ink : Theme.signal)
                .frame(width: 6, height: 6)
            MonoTag(wall.reachable ? "OK" : "NO LINK",
                    color: wall.reachable ? nil : Theme.signal)
        }
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(t.hairline).frame(height: 1)
        }
    }

    private var modeName: String {
        switch wall.state.mode {
        case "cd": "SPIN"
        case "ambient": "LAMP"
        case "off": "ASLEEP"
        case "frame": "YOURS"
        case "ticker": "TICKER"
        case "clock": "CLOCK"
        case "clip": "VIDEO"
        default: "ART"
        }
    }
}

struct MechanicalToggle: View {
    @Environment(\.theme) private var t
    @Binding var isOn: Bool
    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(isOn ? t.ink : .clear)
                RoundedRectangle(cornerRadius: 7)
                    .stroke(t.ink.opacity(isOn ? 1 : 0.4), lineWidth: 1)
                RoundedRectangle(cornerRadius: 5)
                    .fill(isOn ? t.ground : t.ink.opacity(0.7))
                    .frame(width: 24, height: 24)
                    .padding(3)
            }
            .frame(width: 52, height: 30)
        }
        .buttonStyle(.plain)
    }
}
