// Ticker — type a message, it scrolls across the wall. The preview is the
// same 5x7 font at the same 64 pixels, live, so what you see is what
// scrolls. "<3" becomes a heart.
import SwiftUI
import UIKit

struct TickerView: View {
    @Environment(\.theme) private var t
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var wall: WallAPI

    @State private var text = ""
    @State private var color = Color(hex: "#f4f1ea")
    @State private var speed = 1.0
    @State private var loop = true
    @State private var sent = false
    @FocusState private var typing: Bool

    private let swatches = ["#f4f1ea", "#e8631a", "#d9a028", "#4c6b4f", "#5e8dd6"]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .light))
                            .foregroundStyle(t.ink)
                    }
                    .buttonStyle(Pressable())
                    .padding(.trailing, 8)
                    Text("Ticker")
                        .font(.displayWide(28)).foregroundStyle(t.ink)
                    Spacer()
                }
                .padding(.top, 8)

                // live preview — the honest 64px scroll
                WallPanel(captionLeft: "PREVIEW",
                          captionRight: display.isEmpty ? "TYPE SOMETHING" : "64x64 LIVE") {
                    if display.isEmpty {
                        Color.clear
                    } else {
                        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { tl in
                            let t0 = tl.date.timeIntervalSinceReferenceDate
                            let travel = Double(PixelFont.width(display, scale: 2) + 64 + 4)
                            let offset = Int((t0 * 18.0 * speed)
                                .truncatingRemainder(dividingBy: travel))
                            if let img = PixelFont.tickerFrame(
                                text: display, offset: offset, rgb: rgbTuple) {
                                PixelImage(image: img, alreadyTiny: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)

                TextField("Say something", text: $text)
                    .font(.display(17, .semibold))
                    .foregroundStyle(t.ink)
                    .focused($typing)
                    .autocorrectionDisabled()
                    .padding(14)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(typing ? t.ink : t.hairline, lineWidth: 1))
                    .onChange(of: text) { _, _ in sent = false }

                HStack(spacing: 11) {
                    MicroLabel(text: "COLOR").frame(width: 56, alignment: .leading)
                    ForEach(swatches, id: \.self) { hex in
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 26, height: 26)
                            .overlay(Circle().stroke(
                                color.hexString == hex ? t.ink : t.hairline,
                                lineWidth: color.hexString == hex ? 2 : 1))
                            .onTapGesture {
                                UISelectionFeedbackGenerator().selectionChanged()
                                color = Color(hex: hex)
                            }
                    }
                    Spacer(minLength: 0)
                    ColorPicker("", selection: $color, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 32)
                }

                SliderRow(label: "SPEED",
                          valueText: String(format: "%.1fx", speed),
                          value: $speed, range: 0.3...3.0) { _ in }

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Loop").font(.display(15, .semibold))
                            .foregroundStyle(t.ink)
                        Text(loop ? "Scrolls until you change modes"
                                  : "Scrolls once, then back to the music")
                            .font(.display(12, .medium)).foregroundStyle(t.ink45)
                    }
                    Spacer()
                    MechanicalToggle(isOn: $loop)
                }

                PrimaryButton(label: sent ? "On the wall" : "Send to the wall",
                              enabled: wall.reachable && !display.isEmpty && !sent) {
                    typing = false
                    wall.send(["mode": "ticker",
                               "ticker_text": display,
                               "ticker_loop": loop,
                               "color": color.hexString,
                               "speed": speed])
                    withAnimation { sent = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        dismiss()
                    }
                }
                if !wall.reachable {
                    HStack { Spacer(); MonoTag("NO LINK"); Spacer() }
                }
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 30)
        }
        .background(t.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private var display: String { PixelFont.normalize(text) }

    private var rgbTuple: (UInt8, UInt8, UInt8) { color.rgb888 }
}
