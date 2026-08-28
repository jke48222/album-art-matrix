// Tessera's instruments. Standard bones, custom skin: system gestures and
// accessibility underneath, the tile language on top.

import SwiftUI

// MARK: - The strip

/// Sliding-ink segmented control. Hairline sunk strip; the active cell is
/// inverted and the ink block slides between cells.
struct InkStrip<T: Hashable>: View {
    struct Option { let id: T; let label: String }
    let options: [Option]
    @Binding var selection: T
    var namespaceSeed: String = "strip"

    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.id) { opt in
                let active = opt.id == selection
                Button {
                    guard !active else { return }
                    Taps.commit()
                    withAnimation(Motion.settle) { selection = opt.id }
                } label: {
                    Text(opt.label)
                        .font(.machine(10))
                        .textCase(.uppercase)
                        .kerning(0.8)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(active ? Ink.ground : Ink.dim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background {
                            if active {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Ink.ink)
                                    .matchedGeometryEffect(id: namespaceSeed, in: ns)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Ink.sunk)
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Ink.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - The light row

/// Brightness as a gesture, not a widget: drag anywhere on the row, detents
/// every 5%, mono readout, immediate response. At accessibility type sizes it
/// becomes a labeled slider with the same range.
struct LightRow: View {
    @Binding var value: Double        // 0.05...1.0
    var accent: Color
    var onCommit: (Double) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var dragStart: Double? = nil
    @State private var lastDetent: Int = -1

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                Text("light · \(Int(value * 100))%").microlabel()
                Slider(value: $value, in: 0.05...1.0, step: 0.05) { editing in
                    if !editing { onCommit(value) }
                }
                .tint(accent)
            }
        } else {
            VStack(spacing: 7) {
                HStack {
                    Text("light").microlabel()
                    Spacer()
                    Text("\(Int(value * 100))%")
                        .font(.machine(11))
                        .foregroundStyle(Ink.ink)
                        .contentTransition(.numericText())
                        .animation(Motion.blink, value: Int(value * 100))
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Ink.hairline).frame(height: 1)
                        // ticks every 20%
                        HStack(spacing: 0) {
                            ForEach(0..<6) { i in
                                Rectangle().fill(Ink.faint)
                                    .frame(width: 1, height: 5)
                                if i < 5 { Spacer() }
                            }
                        }
                        Rectangle()
                            .fill(accent)
                            .frame(width: max(0, geo.size.width * norm), height: 3)
                        Rectangle()
                            .fill(Ink.ink)
                            .frame(width: 4, height: 16)
                            .offset(x: max(0, geo.size.width * norm - 2))
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                if dragStart == nil { dragStart = value }
                                let v = 0.05 + (g.location.x / geo.size.width) * 0.95
                                let stepped = (v / 0.05).rounded() * 0.05
                                let clamped = min(1.0, max(0.05, stepped))
                                if clamped != value {
                                    value = clamped
                                    let detent = Int(clamped * 20)
                                    if detent != lastDetent {
                                        Taps.detent()
                                        lastDetent = detent
                                    }
                                }
                            }
                            .onEnded { _ in
                                dragStart = nil
                                onCommit(value)
                            }
                    )
                }
                .frame(height: 28)
            }
            .accessibilityElement()
            .accessibilityLabel("Light")
            .accessibilityValue("\(Int(value * 100)) percent")
            .accessibilityAdjustableAction { direction in
                let step = 0.05
                switch direction {
                case .increment: value = min(1.0, value + step)
                case .decrement: value = max(0.05, value - step)
                @unknown default: break
                }
                onCommit(value)
            }
        }
    }

    private var norm: Double { (value - 0.05) / 0.95 }
}

// MARK: - Link chip

struct LinkChip: View {
    let link: LinkState
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 5, height: 5)
            Text(label).microlabel(text)
        }
        .accessibilityElement(children: .combine)
    }

    private var dot: Color {
        switch link {
        case .live: Ink.moss
        case .searching: Ink.tile
        case .offline: Ink.faint
        }
    }
    private var text: Color {
        switch link {
        case .live: Ink.moss
        case .searching: Ink.dim
        case .offline: Ink.faint
        }
    }
    private var label: String {
        switch link {
        case .live: "live · lan"
        case .searching: "finding the wall"
        case .offline: "offline"
        }
    }
}

// MARK: - Placard

/// What the wall is wearing: display serif title, mono artist line. This is
/// the wall's own truth (now_showing), so there is no progress bar here until
/// the phone's push service owns that number honestly.
struct Placard: View {
    let state: WallState
    let link: LinkState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow).microlabel()
            if let title = state.title, !title.isEmpty {
                Text(title)
                    .font(.display(28))
                    .foregroundStyle(Ink.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                Text(artistLine)
                    .font(.machine(10, medium: false))
                    .foregroundStyle(Ink.dim)
                    .lineLimit(1)
            } else {
                Text(silenceTitle)
                    .font(.display(26))
                    .foregroundStyle(Ink.ink)
                Text(silenceNote)
                    .font(.ui(13))
                    .foregroundStyle(Ink.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.settle, value: state.title)
    }

    private var eyebrow: String {
        switch state.mode {
        case "off": "the wall is off"
        case "ambient": "lamp"
        case "cd": "spinning"
        default: "on the wall"
        }
    }
    private var artistLine: String {
        let a = state.artist ?? ""
        let al = state.album ?? ""
        return al.isEmpty || al == a ? a : "\(a) — \(al)"
    }
    private var silenceTitle: String {
        link.isLive ? "Nothing is playing." : "The wall is away."
    }
    private var silenceNote: String {
        switch link {
        case .live: "The wall is listening."
        case .searching: "Looking for it on this network."
        case .offline: "Showing the last thing it told us."
        }
    }
}
