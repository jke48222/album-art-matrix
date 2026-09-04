// The Wall, the first design: the panel owns the screen.
//
// The panel owns the screen and the primary parameter lives on the panel:
// drag it to dim, and the picture dissolves into its tiles. There is no
// brightness row, because the object is the control. Everything else on
// screen is lit by what the panel is showing.

import MediaPlayer
import SwiftUI

struct ClassicWallScreen: View {
    @Environment(WallSession.self) private var wall
    @Environment(ArchiveStore.self) private var worn

    /// The room's light, computed once by RootView and shared with Archive.
    let light: Lighting
    /// Non-nil only while a finger is on the panel adjusting the light.
    @Binding var dragLight: Double?
    /// Passed up so the pager can step aside; see RootView.
    @Binding var onPanel: Bool
    @AppStorage("lyrics.nudge") private var lyricsNudge: Double = 0
    @AppStorage("spin.beat") private var beatOn = false
    @State private var beats = BeatBook()
    @Environment(\.scenePhase) private var scenePhase
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

                // Full bleed, exactly to the screen's edges and no further:
                // an earlier negative padding pushed the square wider than
                // the glass and cropped the outer emitter columns.
                WallHero(
                    reading: reading,
                    confirmed: isOff ? 0.05 : wall.state.brightness,
                    dragging: $dragLight,
                    link: wall.link,
                    arrivalKey: wall.arrivalKey,
                    touching: $onPanel,
                    onCommit: { wall.send(["brightness": $0]) },
                    onHold: { wall.send(["mode": isOff ? "art" : "off"]) },
                    onFlickPrev: { MPMusicPlayerController.systemMusicPlayer.skipToPreviousItem() },
                    onFlickNext: { MPMusicPlayerController.systemMusicPlayer.skipToNextItem() }
                )
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
            // Grouped by what they are: the song's faces on the top row,
            // the room's faces below.
            HStack(spacing: 0) {
                glyph(.art, "art", mode: "art")
                glyph(.spin, "spin", mode: "cd")
                glyph(.lyrics, "lyrics", mode: "lyrics")
                glyph(.nine, "nine", mode: "nine")
            }
            HStack(spacing: 0) {
                Spacer().frame(maxWidth: .infinity)
                glyph(.lamp, "lamp", mode: "ambient")
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
            VStack(alignment: .leading, spacing: 16) {
                // The rail shows the true rate, not the nearest preset: a
                // free or beat-locked value must not read as 33 1/3.
                SpeedTicker(rpm: wall.state.rpm, accent: accent) {
                    beatOn = false          // a hand on the rail outranks the meter
                    wall.send(["rpm": $0])
                }
                beatRow
            }

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
            VStack(alignment: .leading, spacing: 14) {
                // The one knob syncing genuinely needs: the words files in
                // the wild are themselves early or late, and only the person
                // singing along can hear by how much.
                PillRow(
                    label: "timing",
                    options: [("sooner", -0.4), ("on time", 0.0), ("later", 0.4)],
                    selected: lyricsNudge,
                    accent: accent
                ) { lyricsNudge = $0 }
                Text("Words come from LRCLIB; a track it has never heard shows the sleeve alone.")
                    .font(.ui(12))
                    .foregroundStyle(litDim)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// The record turning at the song's own rate: one revolution per bar.
    /// The chip owns nothing but the choice; the measured value still lands
    /// in state.rpm like any other, so the wall and the rail agree.
    private var beatRow: some View {
        HStack(spacing: 10) {
            Button {
                if beatOn {
                    beatOn = false
                } else {
                    beatOn = true
                    Taps.detent()
                    beats.measure(title: wall.state.title, artist: wall.state.artist)
                }
            } label: {
                Text("BEAT")
                    .font(.ui(12, .medium))
                    .foregroundStyle(beatOn ? Ink.ground : Ink.dim)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 18)
                    .background { Capsule().fill(beatOn ? accent : Color.clear) }
                    .overlay { Capsule().strokeBorder(beatOn ? .clear : Ink.hairline, lineWidth: 1) }
            }
            .buttonStyle(PressStyle(scale: 0.95))
            .accessibilityLabel("Spin on the song's beat")

            Group {
                switch beats.phase {
                case .listening:
                    Text("listening...")
                        .foregroundStyle(Ink.dim)
                case .locked(let r) where beatOn:
                    Text("\(Int(r.bpm.rounded())) bpm")
                        .foregroundStyle(accent)
                        .contentTransition(.numericText())
                case .missed where beatOn:
                    Text("couldn't hear it")
                        .foregroundStyle(Ink.faint)
                default:
                    Text("spin to the song")
                        .foregroundStyle(Ink.faint)
                }
            }
            .font(.machine(11))
            Spacer()
        }
        .animation(Motion.settle, value: beats.phase)
        .animation(Motion.settle, value: beatOn)
        .onAppear {
            // Track changes that happened while this row was off screen.
            beats.retune(title: wall.state.title, artist: wall.state.artist)
            if case .locked(let r) = beats.phase, beatOn { wall.send(["rpm": r.rpm]) }
        }
        .onChange(of: beats.phase) {
            // Every road to a reading converges here: chip tap, cache hit on
            // a track change, or a listen finishing. One sender, no races.
            if case .locked(let r) = beats.phase, beatOn, wall.state.mode == "cd" {
                wall.send(["rpm": r.rpm])
            }
        }
        .onChange(of: wall.state.title) {
            beats.retune(title: wall.state.title, artist: wall.state.artist)
            guard beatOn, wall.state.mode == "cd", scenePhase == .active else { return }
            if case .locked = beats.phase { return }
            Task {
                // Let the intro actually start before listening to it.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard beatOn, wall.state.mode == "cd", scenePhase == .active else { return }
                beats.measure(title: wall.state.title, artist: wall.state.artist)
            }
        }
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
            key(.rewind, small: true) { music.skipToPreviousItem() }
                .frame(maxWidth: .infinity)
            key(playing ? .pause : .play, small: false) {
                if playing { music.pause() } else {
                    StandIn.requestMusicAccess { music.play() }
                }
                playing.toggle()
            }
            .frame(maxWidth: .infinity)
            key(.forward, small: true) { music.skipToNextItem() }
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
        .accessibilityLabel(glyph == .rewind ? "Previous track"
                            : glyph == .forward ? "Next track"
                            : playing ? "Pause" : "Play")
    }
}