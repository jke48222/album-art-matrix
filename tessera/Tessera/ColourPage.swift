import SwiftUI

struct ColourPage: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dynamicTypeSize) private var typeSize
    let accent: Color
    @Binding var showCalibrate: Bool
    @State private var confirmingReset = false
    @State private var busy = false
    @State private var problem: String?
    @State private var notice: String?
    private let pearl = Color(hex: 0xDFE8DC)
    private var gains: CalibrationMeasurement.Gains { .init(r: wall.state.wbR, g: wall.state.wbG, b: wall.state.wbB) }
    private var corrected: Bool { gains.values.contains { abs($0 - 1) > 0.005 } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 20) {
                    if typeSize.isAccessibilitySize {
                        Text("Colour balance").font(.ui(12, .semibold)).foregroundStyle(pearl)
                    } else {
                        Label("COLOUR BALANCE", systemImage: "camera.filters").font(.machine(10)).tracking(1).foregroundStyle(pearl)
                        Text("Measure your\nwall’s white.").font(.display(43)).tracking(-0.8).foregroundStyle(Ink.ink)
                        CalibrationSpectrum().frame(height: 100).accessibilityHidden(true)
                    }
                    Text(!wall.link.isLive ? "Last known channel balance" : corrected ? "Colour correction is on." : "Colour correction is off.").font(.ui(typeSize.isAccessibilitySize ? 10 : 15, .medium)).foregroundStyle(pearl)
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: 0x1B2420), in: RoundedRectangle(cornerRadius: 26))
                    .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(pearl.opacity(0.16), lineWidth: 1))
                if !wall.link.isLive {
                    Label("Connect to your wall to measure or reset its colour.", systemImage: "wifi.slash").font(.ui(14)).foregroundStyle(Ink.dim).accessibilityIdentifier("colour.offline")
                }
                // The page's one action sits right under the hero at every
                // text size, so it is on the first screen.
                measureAction
                VStack(alignment: .leading, spacing: 17) {
                    HStack { Text("Channel balance").font(.ui(typeSize.isAccessibilitySize ? 12 : 21, .semibold)); Spacer(); Text(corrected ? "CORRECTED" : "ORIGINAL").font(.machine(typeSize.isAccessibilitySize ? 7 : 9)).foregroundStyle(pearl) }
                    CalibrationGainRows(before: nil, after: gains, accent: pearl)
                    Text("Relative light output. 1.00 means unchanged.").font(.ui(typeSize.isAccessibilitySize ? 9 : 12)).foregroundStyle(Ink.dim)
                }.foregroundStyle(Ink.ink)
                VStack(alignment: .leading, spacing: 13) {
                    Text("How measuring works").font(.ui(typeSize.isAccessibilitySize ? 13 : 22, .semibold)).foregroundStyle(Ink.ink)
                    Text("The wall shows a neutral card. Photograph it, frame the panel and compare the proposed correction on the actual LEDs before keeping it.").font(.ui(typeSize.isAccessibilitySize ? 10 : 15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label("A visual adjustment", systemImage: "eye").font(.ui(15, .semibold)).foregroundStyle(Ink.ink)
                    Text("A phone camera can help reduce a colour cast. It cannot certify white point or colour accuracy. Room reflections and the camera’s processing influence the reading. Use a colour meter when accuracy is critical.").font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }.padding(18).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 18))
                if let problem { Label(problem, systemImage: "exclamationmark.circle").font(.ui(14)).foregroundStyle(Ink.ink).accessibilityIdentifier("colour.problem") }
                if let notice { Text(notice).font(.ui(14)).foregroundStyle(pearl).accessibilityIdentifier("colour.notice") }
                if corrected {
                    // Explicit colours with a plain press style, so a turned-off
                    // reset stays readable (4.5:1) instead of the system grey.
                    let off = busy || !wall.link.isLive
                    VStack(alignment: .leading, spacing: 8) {
                        if confirmingReset {
                            Text("Return all three colour gains to 1.00? Your display brightness stays the same.").font(.ui(14)).foregroundStyle(Ink.dim)
                            Button(busy ? "Resetting…" : "Reset correction", role: .destructive) { reset() }.foregroundStyle(off ? Ink.faint : Ink.signal).frame(minHeight: 44).buttonStyle(CalibrationLinkStyle()).disabled(off).accessibilityIdentifier("colour.confirmReset")
                            Button("Keep my correction") { confirmingReset = false }.foregroundStyle(busy ? Ink.faint : pearl).frame(minHeight: 44).buttonStyle(CalibrationLinkStyle()).disabled(busy)
                        } else {
                            Button("Reset colour correction") { confirmingReset = true }.foregroundStyle(off ? Ink.faint : pearl).frame(minHeight: 44).buttonStyle(CalibrationLinkStyle()).disabled(off).accessibilityIdentifier("colour.reset")
                        }
                    }
                }
            }.padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 38)
        }.scrollIndicators(.hidden).background(Ink.ground).tint(pearl).navigationTitle("True colour").navigationBarTitleDisplayMode(.inline)
    }
    /// Turned off, it takes a quiet fill with a readable label (4.5:1)
    /// instead of a fade, which also faded the label into its own fill.
    private var measureAction: some View {
        let off = !wall.link.isLive || busy
        return Button { showCalibrate = true } label: {
            Label(corrected ? "Measure again" : "Measure the wall", systemImage: "camera").font(.ui(typeSize.isAccessibilitySize ? 12 : 16, .semibold)).frame(maxWidth: .infinity, minHeight: 54).padding(.vertical, typeSize.isAccessibilitySize ? 8 : 0)
                .foregroundStyle(off ? Ink.faint : Color(hex: 0x132018))
                .background(off ? Ink.plaster : pearl, in: RoundedRectangle(cornerRadius: 15))
                .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(off ? Ink.hairline : .clear, lineWidth: 1) }
                .contentShape(RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(PressStyle()).disabled(off).accessibilityIdentifier("colour.measure")
    }
    private func reset() {
        guard !busy, wall.link.isLive else { return }
        busy = true; problem = nil; notice = nil
        Task {
            let ok = await wall.updateRoutine(["wb_r": 1.0, "wb_g": 1.0, "wb_b": 1.0])
            busy = false
            guard ok, gains.values.allSatisfy({ abs($0 - 1) < 0.001 }) else { problem = "The wall did not confirm the reset. Reconnect and try again."; return }
            confirmingReset = false; notice = "Original channel balance restored."; Taps.commit()
        }
    }
}

/// Press feedback only, for text buttons and the comparison pair. Unlike the
/// default style it adds no fade of its own when the button is turned off,
/// so each control sets a disabled colour that stays readable.
struct CalibrationLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle()).opacity(configuration.isPressed ? 0.6 : 1)
    }
}

struct CalibrationSpectrum: View {
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                HStack(spacing: 1) {
                    ForEach(0..<24, id: \.self) { index in
                        let fraction = Double(index) / 23
                        Rectangle().fill(Color(white: 0.18 + fraction * 0.72)).frame(height: geo.size.height * (0.48 + fraction * 0.52))
                    }
                }
                HStack(spacing: 0) { Color(hex: 0xD99587); Color(hex: 0xA3C5A3); Color(hex: 0x9FBBDC) }.frame(height: 5)
            }
        }
    }
}

struct CalibrationGainRows: View {
    let before: CalibrationMeasurement.Gains?
    let after: CalibrationMeasurement.Gains
    let accent: Color
    @Environment(\.dynamicTypeSize) private var typeSize
    private let names = ["Red", "Green", "Blue"]
    private let colors = [Color(hex: 0xD99587), Color(hex: 0xA3C5A3), Color(hex: 0x9FBBDC)]
    var body: some View {
        VStack(spacing: 17) {
            ForEach(0..<3, id: \.self) { index in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(names[index]).font(.ui(typeSize.isAccessibilitySize ? 10 : 14, .medium)).foregroundStyle(Ink.ink)
                        Spacer(minLength: 8)
                        if let before { Text(String(format: "%.2f to", before.values[index])).font(.machine(typeSize.isAccessibilitySize ? 9 : 12)).foregroundStyle(Ink.dim) }
                        Text(String(format: "%.2f", after.values[index])).font(.machine(typeSize.isAccessibilitySize ? 10 : 15)).foregroundStyle(accent)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Ink.ink.opacity(0.09))
                            Capsule().fill(colors[index]).frame(width: geo.size.width * min(1, max(0, after.values[index])))
                        }
                    }.frame(height: 4).accessibilityHidden(true)
                }.accessibilityElement(children: .ignore).accessibilityLabel(names[index]).accessibilityValue(before.map { "\(String(format: "%.2f", $0.values[index])) before, \(String(format: "%.2f", after.values[index])) after" } ?? String(format: "%.2f", after.values[index]))
            }
        }
    }
}
