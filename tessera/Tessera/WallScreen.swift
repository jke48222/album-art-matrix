// The Wall. One glance answers: what is the wall doing right now.
// Hero preview, placard, mode strip, contextual row, light row.
// Chrome retreats when the wall is off.

import SwiftUI

struct WallScreen: View {
    @Environment(WallSession.self) private var wall

    // debounced brightness: local while dragging, sent on release
    @State private var light: Double = 1.0
    @State private var syncingLight = false

    private var reading: FrameReading { FrameReading.from(wall.frame) }

    /// The frame's own colour drives the accent; the brain's art_colors win
    /// when present (they were computed from the full-resolution art).
    private var accent: Color {
        if let hex = wall.state.artColors.first, let c = Color(wallHex: hex) { return c }
        return reading.glow
    }

    private var isOff: Bool { wall.state.mode == "off" }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                WallHero(
                    reading: isOff ? .dark : reading,
                    brightness: light,
                    link: wall.link,
                    trackKey: wall.state.title ?? wall.state.mode
                ) {
                    // Hold toggles: a dark wall wakes, a lit wall goes dark.
                    wall.send(["mode": isOff ? "art" : "off"])
                }
                Placard(state: wall.state, link: wall.link)
                controls
                Spacer(minLength: 8)
                footer
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .background(Ink.ground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            light = wall.state.brightness
            wall.start()
        }
        .onChange(of: wall.state.brightness) { _, new in
            if !syncingLight { light = new }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("TESSERA")
                .font(.display(17))
                .kerning(2.4)
                .foregroundStyle(Ink.ink)
            Spacer()
            LinkChip(link: wall.link)
        }
        .padding(.top, 6)
    }

    @ViewBuilder private var controls: some View {
        @Bindable var wallB = wall

        VStack(spacing: 18) {
            InkStrip(
                options: [
                    .init(id: "art", label: "Art"),
                    .init(id: "cd", label: "Spin"),
                    .init(id: "ambient", label: "Lamp"),
                    .init(id: "off", label: "Off"),
                ],
                selection: Binding(
                    get: { normalizedMode },
                    set: { wall.send(["mode": $0]) }
                )
            )

            if isOff {
                // Chrome retreats. One line of type, nothing else.
                Text("Hold the wall to wake it, or pick a mode.")
                    .font(.ui(13))
                    .foregroundStyle(Ink.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                contextRow
                LightRow(value: $light, accent: accent) { v in
                    syncingLight = true
                    wall.send(["brightness": v])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { syncingLight = false }
                }
            }
        }
        .animation(Motion.settle, value: isOff)
    }

    /// The wall may be in a mode the strip does not offer (ticker, clip...).
    /// Show it as Art rather than lying with an empty selection.
    private var normalizedMode: String {
        ["art", "cd", "ambient", "off"].contains(wall.state.mode) ? wall.state.mode : "art"
    }

    @ViewBuilder private var contextRow: some View {
        switch wall.state.mode {
        case "cd":
            labeledRow("speed") {
                InkStrip(
                    options: [
                        .init(id: 7.5, label: "7.5"),
                        .init(id: 33.33, label: "33⅓"),
                        .init(id: 45.0, label: "45"),
                    ],
                    selection: Binding(
                        get: { nearestRpm },
                        set: { wall.send(["rpm": $0]) }
                    ),
                    namespaceSeed: "rpm"
                )
            }
        case "ambient":
            VStack(spacing: 12) {
                labeledRow("effect") {
                    InkStrip(
                        options: [
                            .init(id: "solid", label: "Solid"),
                            .init(id: "breathe", label: "Breathe"),
                            .init(id: "pulse", label: "Pulse"),
                            .init(id: "rainbow", label: "Rainbow"),
                            .init(id: "gradient", label: "Fade"),
                        ],
                        selection: Binding(
                            get: { wall.state.effect },
                            set: { wall.send(["effect": $0]) }
                        ),
                        namespaceSeed: "effect"
                    )
                }
                Toggle(isOn: Binding(
                    get: { wall.state.matchArt },
                    set: { wall.send(["match_art": $0]) }
                )) {
                    Text("match the album").microlabel(Ink.ink)
                }
                .tint(accent)
            }
        default:
            labeledRow("finish") {
                InkStrip(
                    options: [
                        .init(id: "clean", label: "Clean"),
                        .init(id: "dither", label: "Dither"),
                        .init(id: "poster", label: "Poster"),
                    ],
                    selection: Binding(
                        get: { wall.state.finish },
                        set: { wall.send(["finish": $0]) }
                    ),
                    namespaceSeed: "finish"
                )
            }
        }
    }

    private var nearestRpm: Double {
        let presets = [7.5, 33.33, 45.0]
        return presets.min(by: { abs($0 - wall.state.rpm) < abs($1 - wall.state.rpm) }) ?? 7.5
    }

    private func labeledRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).microlabel()
            content()
        }
    }

    private var footer: some View {
        Text("Simulation of nothing: this preview is the wall's own frame.")
            .microlabel(Ink.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 12)
    }
}
