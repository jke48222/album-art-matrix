// The Wall.
//
// The panel owns the screen and the primary parameter lives on the panel:
// drag it to dim, and the picture dissolves into its tiles. There is no
// brightness row, because the object is the control. Everything else on
// screen is lit by what the panel is showing.

import MediaPlayer
import SwiftUI

struct WallScreen: View {
    @Environment(WallSession.self) private var wall
    @Environment(ArchiveStore.self) private var worn

    /// The room's light, computed once by RootView and shared with Archive.
    let light: Lighting
    /// Non-nil only while a finger is on the panel adjusting the light.
    @Binding var dragLight: Double?
    /// Passed up so the pager can step aside; see RootView.
    @Binding var onPanel: Bool
    var onSetup: () -> Void
    var onStudio: () -> Void

    private var duty: Double { light.duty }
    private var isOff: Bool { light.isOff }
    private var reading: FrameReading { light.reading }
    private var accent: Color { light.steadyAccent }
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
                    arrivalKey: wall.arrivalKey,
                    history: worn.runs,
                    tile: { worn.tile($0) },
                    touching: $onPanel,
                    onCommit: { wall.send(["brightness": $0]) },
                    onHold: { wall.send(["mode": isOff ? "art" : "off"]) },
                    onWear: { wall.replay(ts: $0.ts) }
                )
                .padding(.horizontal, -4)
                .padding(.bottom, 26)

                Placard(state: wall.state, link: wall.link, litInk: litInk, litDim: litDim)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)

                MusicBar(accent: accent, litInk: litInk)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)

                if wall.state.mode == "timer", let left = wall.state.timerRemaining {
                    // The running countdown is never more than one glance and
                    // one tap away, whatever else is selected.
                    HStack(spacing: 12) {
                        Text(String(format: "%02d:%02d", left / 60, left % 60))
                            .font(.machine(18))
                            .foregroundStyle(accent)
                            .contentTransition(.numericText(countsDown: true))
                        Text("counting down")
                            .font(.ui(13))
                            .foregroundStyle(litDim)
                        Spacer()
                        Button("stop") { wall.send(["timer_min": 0.0]) }
                            .buttonStyle(PressStyle(scale: 0.95))
                            .font(.ui(14, .semibold))
                            .foregroundStyle(Ink.signal)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
                }

                modeRow
                    .padding(.horizontal, 12)
                    .padding(.bottom, isOff ? 8 : 24)

                if !isOff {
                    contextRow
                        .padding(.horizontal, 20)
                        .transition(.opacity)
                }

                Spacer(minLength: 56)
            }
            .padding(.top, 6)
            .animation(Motion.settle, value: isOff)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            TesseraMark(accent: accent, lit: roomLight, side: 17)
            Text("TESSERA")
                .font(.display(18))
                .kerning(3.0)
                .foregroundStyle(litInk)
            Spacer()
            MiniGlyphButton(glyph: .make,
                            label: "Make something for the wall") { onStudio() }

            Button {
                onSetup()
            } label: {
                LinkChip(link: wall.link)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Setup. Link is \(wall.link.isLive ? "live" : "not answering").")
        }
        .padding(.top, 4)
    }

    /// Seven faces. Words left this row at the owner's request (text is made
    /// in the Studio); nine and lyrics joined it because both are things the
    /// wall IS for a while, not things you do to it.
    private var modeRow: some View {
        VStack(spacing: 16) {
            HStack(spacing: 0) {
                glyph(.art, "art", mode: "art")
                glyph(.spin, "spin", mode: "cd")
                glyph(.lamp, "lamp", mode: "ambient")
                glyph(.nine, "nine", mode: "nine")
            }
            HStack(spacing: 0) {
                Spacer().frame(maxWidth: .infinity)
                glyph(.lyrics, "lyrics", mode: "lyrics")
                glyph(.clock, "clock", mode: "clock")
                glyph(.dark, "off", mode: "off")
                Spacer().frame(maxWidth: .infinity)
            }
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
        let m = wall.state.mode
        if m == "timer" { return "clock" }   // a countdown is the clock, busy
        return ["art", "cd", "ambient", "off", "ticker", "clock", "nine", "lyrics"].contains(m)
            ? m : "art"
    }

    @ViewBuilder private var contextRow: some View {
        switch wall.state.mode {
        case "cd":
            SpeedTicker(rpm: nearestRpm, accent: accent) { wall.send(["rpm": $0]) }

        case "ambient":
            VStack(alignment: .leading, spacing: 18) {
                PillRow(
                    label: "light",
                    options: [("plaid", "plaid"), ("weave", "weave"), ("deco", "deco"),
                              ("snake", "snake"), ("solid", "solid"), ("breathe", "breathe"),
                              ("pulse", "pulse"), ("rainbow", "rainbow"), ("fade", "gradient")],
                    selected: wall.state.effect,
                    accent: accent
                ) { wall.send(["effect": $0]) }

                LampInks(
                    color: wall.state.color,
                    color2: wall.state.color2,
                    matchArt: wall.state.matchArt,
                    effect: wall.state.effect,
                    accent: accent
                ) { key, hex in
                    wall.send([key: hex])
                }

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

        case "ticker":
            TickerRow(
                text: wall.state.tickerText,
                loop: wall.state.tickerLoop,
                style: wall.state.tickerStyle,
                colors: wall.state.tickerColors,
                accent: accent
            ) { key, value in wall.send([key: value]) }

        case "clock":
            VStack(alignment: .leading, spacing: 18) {
                WallTimerRow(
                    remaining: wall.state.mode == "timer" ? (wall.state.timerRemaining ?? 0) : nil,
                    total: wall.state.timerTotal,
                    accent: accent
                ) { wall.send(["timer_min": $0]) }
                if wall.state.mode != "timer" {
                    PillRow(
                        label: "clock",
                        options: [("24 hour", true), ("12 hour", false)],
                        selected: wall.state.clock24h,
                        accent: accent
                    ) { wall.send(["clock_24h": $0]) }
                }
            }

        case "nine":
            Text("The last nine sleeves the wall has worn, newest first.")
                .font(.ui(13))
                .foregroundStyle(litDim)
                .fixedSize(horizontal: false, vertical: true)

        case "lyrics":
            Text("The words, over the sleeve, in time with the song. They come from LRCLIB, so a track it has never heard shows the sleeve alone.")
                .font(.ui(13))
                .foregroundStyle(litDim)
                .fixedSize(horizontal: false, vertical: true)

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


// MARK: - Music

/// The music this phone is playing, steered from the same screen that shows
/// what it lands on. Three keys and nothing else: the queue, the library and
/// the rest of it belong to the music app, but play, skip and back are wall
/// gestures now, because the wall is where the song is showing.
private struct MusicBar: View {
    let accent: Color
    let litInk: Color

    @State private var playing =
        MPMusicPlayerController.systemMusicPlayer.playbackState == .playing

    private var music: MPMusicPlayerController { .systemMusicPlayer }

    var body: some View {
        HStack(spacing: 0) {
            key(.back, small: true) { music.skipToPreviousItem() }
                .frame(maxWidth: .infinity)
            key(playing ? .pause : .play, small: false) {
                if playing { music.pause() } else {
                    StandIn.requestMusicAccess { music.play() }
                }
                playing.toggle()
            }
            .frame(maxWidth: .infinity)
            key(.skip, small: true) { music.skipToNextItem() }
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 44)
        .onAppear { music.beginGeneratingPlaybackNotifications() }
        .onReceive(NotificationCenter.default.publisher(
            for: .MPMusicPlayerControllerPlaybackStateDidChange)) { _ in
            playing = music.playbackState == .playing
        }
    }

    private func key(_ glyph: Glyph, small: Bool,
                     _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(small ? Ink.hairline : accent.opacity(0.7),
                                      lineWidth: small ? 1 : 1.5)
                GlyphShape(glyph: glyph, lineWidth: 1.6)
                    .frame(width: small ? 15 : 20, height: small ? 15 : 20)
                    .foregroundStyle(small ? Ink.dim : litInk)
            }
            .frame(width: small ? 44 : 56, height: small ? 44 : 56)
        }
        .buttonStyle(PressStyle(scale: 0.9))
        .accessibilityLabel(glyph == .back ? "Previous track"
                            : glyph == .skip ? "Next track"
                            : playing ? "Pause" : "Play")
    }
}