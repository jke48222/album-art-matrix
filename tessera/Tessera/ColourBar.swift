import SwiftUI
import UIKit

/// Canonical wire colour conversion shared by the picker and its swatches.
/// Invalid input never silently becomes a colour in the editor.
enum WallColourValue {
    struct RGB: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        var hex: String { String(format: "#%02x%02x%02x", red, green, blue) }
        var usesDarkInk: Bool {
            func linear(_ byte: UInt8) -> Double {
                let channel = Double(byte) / 255
                return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
            return luminance > 0.179
        }
    }

    static func parse(_ text: String) -> RGB? {
        var digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard [3, 6].contains(digits.count), digits.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { return nil }
        if digits.count == 3 { digits = digits.map { String(repeating: String($0), count: 2) }.joined() }
        guard let value = UInt32(digits, radix: 16) else { return nil }
        return RGB(red: UInt8((value >> 16) & 255), green: UInt8((value >> 8) & 255), blue: UInt8(value & 255))
    }

    static func byte(_ value: Double) -> UInt8 {
        guard value.isFinite else { return 0 }
        return UInt8((min(1, max(0, value)) * 255).rounded())
    }
}

/// Each segment is a real button: choose an ink once, edit it on the next tap.
struct ColourBar: View {
    let colours: [Binding<Color>]
    var height: CGFloat = 46
    var radius: CGFloat = 15
    var stroke: Color = .white.opacity(0.14)
    var selected: Int? = nil
    var onPick: ((Int) -> Void)? = nil
    var enabled: Bool = true
    var names: [String] = []

    @State private var editing: Int?
    @State private var editingColour: Color = .white
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize && !names.isEmpty {
                VStack(spacing: 6) { swatches }
            } else {
                HStack(spacing: 1) { swatches }
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(stroke, lineWidth: 1))
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let index = editing, colours.indices.contains(index) {
                // Studio appends custom ink instead of overwriting its album
                // swatch. Keep the editor's own value stable while forwarding
                // changes, so its picker cannot snap back to the old swatch.
                ColourSheet(colour: Binding(get: { editingColour }, set: { value in
                    editingColour = value
                    if colours.indices.contains(index) { colours[index].wrappedValue = value }
                }), title: name(index))
            }
        }
        .onChange(of: colours.count) { _, count in
            if let editing, editing >= count { self.editing = nil }
        }
        .onChange(of: enabled) { _, enabled in if !enabled { editing = nil } }
    }

    @ViewBuilder private var swatches: some View {
        ForEach(colours.indices, id: \.self) { index in
            let colour = colours[index].wrappedValue
            let ink = colour.wallUsesDarkInk ? Color.black : Color.white
            Button {
                if let onPick, selected != index { onPick(index) }
                else { editingColour = colour; editing = index }
                Taps.detent(intensity: 0.35)
            } label: {
                ZStack(alignment: .topTrailing) {
                    Rectangle().fill(colour)
                    if names.indices.contains(index) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name(index)).font(.ui(12, .semibold))
                            Text(colour.wallHex.uppercased()).font(.machine(9, medium: false))
                        }
                        .foregroundStyle(ink)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                    }
                    if selected == index {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(ink).padding(8)
                    } else if onPick == nil && names.indices.contains(index) {
                        Image(systemName: enabled ? "slider.horizontal.3" : "lock.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(ink.opacity(0.8)).padding(8)
                    }
                }
                .frame(minWidth: 44, maxWidth: .infinity)
                .frame(height: max(44, height, names.isEmpty ? 44 : (typeSize.isAccessibilitySize ? 100 : 62)))
                .overlay {
                    if selected == index {
                        Rectangle().strokeBorder(ink.opacity(0.85), lineWidth: 2)
                            .padding(3)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .accessibilityLabel(name(index))
            .accessibilityValue(colour.wallHex.uppercased())
            .accessibilityHint(!enabled ? "Set by the album" : onPick != nil && selected != index ? "Select this ink" : "Edit this colour")
            .accessibilityAddTraits(selected == index ? .isSelected : [])
        }
    }

    private func name(_ index: Int) -> String {
        names.indices.contains(index) ? names[index] : "Colour \(index + 1)"
    }
}

/// A scrollable native picker, shared by Studio, lamp colours and the iPod.
/// https://mobbin.com/screens/fef54acd-4816-44d7-b987-141018058119
/// https://developer.apple.com/documentation/swiftui/colorpicker
struct ColourSheet: View {
    @Binding var colour: Color
    var title = "Colour"
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var editingHex: Bool
    @State private var hex = ""
    @State private var problem: String?

    private let presets: [(name: String, hex: String)] = [
        ("Warm", "#FFE2B7"), ("Amber", "#E8B04B"), ("Rose", "#DD718B"),
        ("Lilac", "#B9A7E5"), ("Ocean", "#729FC8"), ("Mint", "#83BFA0")
    ]
    private var validHex: WallColourValue.RGB? { WallColourValue.parse(hex) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(colour)
                        .frame(height: typeSize.isAccessibilitySize ? 190 : 148)
                        .overlay(alignment: .bottomLeading) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("CURRENT COLOUR").font(.machine(9)).tracking(1)
                                Text(colour.wallHex.uppercased()).font(.displayMid(32))
                                    .lineLimit(1).minimumScaleFactor(0.35)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(colour.wallUsesDarkInk ? .black : .white)
                            .padding(20)
                        }
                        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Ink.hairline, lineWidth: 1))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Current colour")
                        .accessibilityValue(colour.wallHex.uppercased())

                    VStack(alignment: .leading, spacing: 12) {
                        Text("A few favourites").font(.ui(15, .medium)).foregroundStyle(Ink.ink)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 100 : 74), spacing: 10)], spacing: 12) {
                            ForEach(presets, id: \.hex) { preset in
                                Button { choose(preset.hex) } label: {
                                    VStack(spacing: 7) {
                                        RoundedRectangle(cornerRadius: 13)
                                            .fill(Color.wall(hex: preset.hex))
                                            .frame(height: 46)
                                            .overlay {
                                                if colour.wallHex.caseInsensitiveCompare(preset.hex) == .orderedSame {
                                                    Image(systemName: "checkmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(.black)
                                                }
                                            }
                                        Text(preset.name).font(.ui(12)).foregroundStyle(Ink.dim)
                                    }
                                    .frame(minWidth: 44, minHeight: 44)
                                }
                                .buttonStyle(PressStyle(scale: 0.96))
                                .accessibilityLabel(preset.name)
                                .accessibilityValue(preset.hex)
                                .accessibilityAddTraits(colour.wallHex.caseInsensitiveCompare(preset.hex) == .orderedSame ? .isSelected : [])
                            }
                        }
                    }
                    ColorPicker(selection: $colour, supportsOpacity: false) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Full spectrum").font(.ui(16, .medium)).foregroundStyle(Ink.ink)
                            Text("Choose any colour").font(.ui(12)).foregroundStyle(Ink.dim)
                        }
                    }
                    .frame(minHeight: 44)
                    .padding(16)
                    .background(Ink.plaster, in: RoundedRectangle(cornerRadius: 16))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Hex colour").font(.ui(14, .medium)).foregroundStyle(Ink.ink)
                        let fieldLayout = typeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                            : AnyLayout(HStackLayout(spacing: 12))
                        fieldLayout { hexInput; applyButton }
                        if let problem {
                            Label(problem, systemImage: "exclamationmark.circle")
                                .font(.ui(12)).foregroundStyle(Ink.signal)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(22)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Ink.ground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.font(.ui(15, .semibold)).frame(minWidth: 44, minHeight: 44)
                }
            }
        }
        .tint(Ink.ink)
        .preferredColorScheme(.dark)
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Ink.ground)
        .onAppear { hex = colour.wallHex.uppercased() }
        .onChange(of: colour.wallHex) { _, value in
            if !editingHex { hex = value.uppercased(); problem = nil }
        }
    }

    private var hexInput: some View {
        TextField("#RRGGBB", text: $hex)
            .font(.machine(16)).foregroundStyle(Ink.ink)
            .textInputAutocapitalization(.characters).autocorrectionDisabled()
            .keyboardType(.asciiCapable).submitLabel(.done)
            .focused($editingHex)
            .padding(.horizontal, 14).frame(minWidth: 140, minHeight: 48)
            .background(Ink.plaster, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(problem == nil ? Ink.hairline : Ink.signal, lineWidth: 1))
            .accessibilityLabel("Hex colour")
            .onSubmit { applyHex() }
    }

    private var applyButton: some View {
        Button("Apply") { applyHex() }
            .font(.ui(14, .semibold)).foregroundStyle(Ink.ink)
            .padding(.horizontal, 20).frame(minHeight: 48)
            .background(Ink.plaster, in: Capsule())
            .disabled(validHex == nil)
            .opacity(validHex == nil ? 0.45 : 1)
            .buttonStyle(PressStyle(scale: 0.96))
            .accessibilityLabel("Apply hex colour")
    }

    private func applyHex() {
        guard let value = validHex else {
            problem = "Enter three or six hexadecimal digits."
            Taps.error()
            return
        }
        choose(value.hex)
    }

    private func choose(_ value: String) {
        editingHex = false
        colour = .wall(hex: value)
        hex = colour.wallHex.uppercased()
        problem = nil
    }
}

extension Color {
    static func wall(hex: String) -> Color {
        guard let value = WallColourValue.parse(hex) else { return .black }
        return Color(.sRGB, red: Double(value.red) / 255, green: Double(value.green) / 255,
                     blue: Double(value.blue) / 255, opacity: 1)
    }

    private var wallRGB: WallColourValue.RGB {
        let resolved = UIColor(self).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        if !resolved.getRed(&r, green: &g, blue: &b, alpha: &a) {
            var white: CGFloat = 0
            if resolved.getWhite(&white, alpha: &a) { r = white; g = white; b = white }
        }
        return WallColourValue.RGB(red: WallColourValue.byte(Double(r)),
                                   green: WallColourValue.byte(Double(g)),
                                   blue: WallColourValue.byte(Double(b)))
    }

    var wallHex: String { wallRGB.hex }
    var wallUsesDarkInk: Bool { wallRGB.usesDarkInk }
}
