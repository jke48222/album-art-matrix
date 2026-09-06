// The colours you can set, as one bar.
//
// Round wells in a row read as decoration and waste the width. This is a
// single rounded rectangle divided into as many parts as there are colours,
// filling whatever space it is given, each part showing its colour and
// opening a picker when touched.
//
// The picker is presented, not overlaid. A system colour well cannot be
// restyled, so the first version laid an almost invisible one over each part
// and scaled it up to cover it; a scaled view keeps its enlarged touch area
// whatever is clipped around it, so the bar quietly swallowed taps meant for
// the buttons above it.

import SwiftUI
import UIKit

struct ColourBar: View {
    /// Each colour, and what to do when it changes.
    let colours: [Binding<Color>]
    var height: CGFloat = 46
    var radius: CGFloat = 15
    var stroke: Color = .white.opacity(0.14)
    /// Which one is in use, when the bar is a choice as well as a set.
    var selected: Int? = nil
    /// Touching a part when there is a selection picks it; touching the one
    /// already picked opens the picker.
    var onPick: ((Int) -> Void)? = nil
    /// Off when the colours are being chosen elsewhere (the album's): the
    /// bar still shows them, and nothing happens when it is touched.
    var enabled: Bool = true

    @State private var editing: Int? = nil

    var body: some View {
        HStack(spacing: 1) {
            ForEach(colours.indices, id: \.self) { i in
                Rectangle()
                    .fill(colours[i].wrappedValue)
                    .overlay {
                        if selected == i {
                            Rectangle().strokeBorder(.white, lineWidth: 3)
                                .blendMode(.difference)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard enabled else { return }
                        Taps.detent(intensity: 0.35)
                        if let onPick, selected != i { onPick(i) } else { editing = i }
                    }
                    .accessibilityLabel("Colour \(i + 1)")
                    .accessibilityAddTraits(selected == i ? [.isButton, .isSelected] : .isButton)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(stroke, lineWidth: 1))
        .opacity(enabled ? 1 : 0.55)
        .allowsHitTesting(enabled)
        .accessibilityHint(enabled ? "" : "Set by the album")
        .animation(.easeOut(duration: 0.2), value: enabled)
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let i = editing, i < colours.count {
                ColourSheet(colour: colours[i])
                    .presentationDetents([.height(360)])
                    .presentationBackground(Ink.ground)
            }
        }
    }
}

/// The system picker, given a page of its own.
private struct ColourSheet: View {
    @Binding var colour: Color
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("COLOUR").font(.machine(10)).kerning(1.6).foregroundStyle(Ink.dim)
                Spacer()
                Button("Done") { dismiss() }.font(.ui(15, .semibold)).foregroundStyle(Ink.ink)
            }
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(colour)
                .frame(height: 96)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1))
            ColorPicker("Pick", selection: $colour, supportsOpacity: false)
                .font(.ui(15)).foregroundStyle(Ink.ink)
            Spacer(minLength: 0)
        }
        .padding(22)
        .preferredColorScheme(.dark)
    }
}

extension Color {
    /// "#rrggbb" as a colour.
    static func wall(hex: String) -> Color {
        let t = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let v = UInt32(t, radix: 16) ?? 0
        return Color(red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }

    /// The same, back again.
    var wallHex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
