// The Wall.
//
// The panel owns the screen and the primary parameter lives on the panel:
// drag it to dim, and the picture dissolves into its tiles. There is no
// brightness row, because the object is the control. Everything else on
// screen is lit by what the panel is showing.

import SwiftUI

struct WallScreen: View {
    @Environment(WallSession.self) private var wall

    /// The room's light, computed once by RootView and shared with Archive.
    let light: Lighting
    /// Non-nil only while a finger is on the panel adjusting the light.
    @Binding var dragLight: Double?
    var onSetup: () -> Void

    private var duty: Double { light.duty }
    private var isOff: Bool { light.isOff }
    private var reading: FrameReading { light.reading }
    private var accent: Color { light.accent }
    private var roomLight: Double { light.room }
    private var litInk: Color { light.litInk }
    private var litDim: Color { light.litDim }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)

                // The panel bleeds past the gutter: it is the object, not a card.
                WallHero(
                    reading: reading,
                    confirmed: isOff ? 0.05 : wall.state.brightness,
                    dragging: $dragLight,
                    link: wall.link,
                    onCommit: { wall.send(["brightness": $0]) },
                    onHold: { wall.send(["mode": isOff ? "art" : "off"]) }
                )
                .padding(.horizontal, -4)
                .padding(.bottom, 26)

                Placard(state: wall.state, link: wall.link, litInk: litInk, litDim: litDim)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 26)

                modeRow
                    .padding(.horizontal, 12)
                    .padding(.bottom, isOff ? 8 : 24)

                if !isOff {
                    contextRow
                        .padding(.horizontal, 20)
                        .transition(.opacity)
                }

                Spacer(minLength: 40)
            }
            .padding(.top, 6)
            .animation(Motion.settle, value: isOff)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            TesseraMark(accent: accent, lit: roomLight, side: 17)
            Text("TESSERA")
                .font(.display(18))
                .kerning(3.0)
                .foregroundStyle(litInk)
            Spacer()
            Button {
                Taps.detent()
                onSetup()
            } label: {
                LinkChip(link: wall.link)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Setup. Link is \(wall.link.isLive ? "live" : "not answering").")
        }
        .padding(.top, 4)
    }

    private var modeRow: some View {
        HStack(spacing: 0) {
            glyph(.art, "art", mode: "art")
            glyph(.spin, "spin", mode: "cd")
            glyph(.lamp, "lamp", mode: "ambient")
            glyph(.dark, "off", mode: "off")
        }
    }

    private func glyph(_ g: Glyph, _ label: String, mode: String) -> some View {
        GlyphButton(
            glyph: g,
            label: label,
            active: normalizedMode == mode,
            accent: accent,
            lit: roomLight
        ) {
            wall.send(["mode": mode])
        }
        .frame(maxWidth: .infinity)
    }

    /// The wall may be in a mode this row does not offer (ticker, clip, frame).
    /// Show Art rather than lying with nothing selected.
    private var normalizedMode: String {
        ["art", "cd", "ambient", "off"].contains(wall.state.mode) ? wall.state.mode : "art"
    }

    @ViewBuilder private var contextRow: some View {
        switch wall.state.mode {
        case "cd":
            SpeedTicker(rpm: nearestRpm, accent: accent) { wall.send(["rpm": $0]) }

        case "ambient":
            VStack(alignment: .leading, spacing: 18) {
                PillRow(
                    label: "light",
                    options: [("solid", "solid"), ("breathe", "breathe"), ("pulse", "pulse"),
                              ("rainbow", "rainbow"), ("fade", "gradient")],
                    selected: wall.state.effect,
                    accent: accent
                ) { wall.send(["effect": $0]) }

                Toggle(isOn: Binding(
                    get: { wall.state.matchArt },
                    set: { wall.send(["match_art": $0]) }
                )) {
                    Text("Take the album's colours")
                        .font(.ui(15))
                        .foregroundStyle(litInk)
                }
                .tint(accent)
            }

        default:
            FinishRow(
                frame: wall.frame,
                duty: duty,
                selected: wall.state.finish,
                accent: accent
            ) { wall.send(["finish": $0]) }
        }
    }

    private var nearestRpm: Double {
        [7.5, 33.33, 45.0].min(by: { abs($0 - wall.state.rpm) < abs($1 - wall.state.rpm) }) ?? 7.5
    }
}
