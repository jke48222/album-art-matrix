// The Wall.
//
// The panel owns the screen and the primary parameter lives on the panel:
// drag it to dim, and the picture dissolves into its tiles. There is no
// brightness row, because the object is the control. Everything else on
// screen is lit by what the panel is showing.

import SwiftUI

struct WallScreen: View {
    @Environment(WallSession.self) private var wall

    /// Non-nil only while a finger is on the panel adjusting the light.
    @State private var dragLight: Double? = nil
    @State private var lastTrackKey: String = ""

    private var duty: Double { dragLight ?? wall.state.brightness }
    private var isOff: Bool { wall.state.mode == "off" }

    private var reading: FrameReading {
        FrameRenderer.read(wall.frame, duty: isOff ? 0.05 : duty)
    }

    /// The room's colour: the brain's own dominant chroma when it has one,
    /// otherwise the frame's.
    private var accent: Color {
        if let hex = wall.state.artColors.first, let c = Color(wallHex: hex) { return c }
        return reading.glow
    }

    /// How much light is actually in the room right now. Everything visual
    /// is scaled by this, so the phone dims as the wall dims.
    private var roomLight: Double { isOff ? 0 : reading.lit * duty }

    private var litInk: Color { Ink.ink.lit(by: accent, 0.20 * roomLight) }
    private var litDim: Color { Ink.dim.lit(by: accent, 0.16 * roomLight) }

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
        .background {
            // The room. Lit only by the wall, and dark when the wall is dark.
            ZStack(alignment: .top) {
                Ink.ground
                RadialGradient(
                    colors: [accent.opacity(0.20 * roomLight), .clear],
                    center: .init(x: 0.5, y: 0.26),
                    startRadius: 0,
                    endRadius: 520
                )
            }
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 1.2), value: roomLight)
            .animation(.easeInOut(duration: 1.2), value: reading.key)
        }
        .preferredColorScheme(.dark)
        .onAppear { wall.start() }
        .onChange(of: reading.key) { _, new in
            // A new sleeve arriving on 4,096 LEDs is an event, not a fade.
            guard !lastTrackKey.isEmpty, new != lastTrackKey, !isOff else {
                lastTrackKey = new
                return
            }
            lastTrackKey = new
            Taps.landed()
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .center) {
            Text("TESSERA")
                .font(.display(18))
                .kerning(3.0)
                .foregroundStyle(litInk)
            Spacer()
            LinkChip(link: wall.link)
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
