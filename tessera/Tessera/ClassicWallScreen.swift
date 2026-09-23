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
    @Environment(\.dynamicTypeSize) private var typeSize

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
                header.padding(.horizontal, 24).padding(.bottom, 12)
                panelCaption.padding(.horizontal, 24).padding(.bottom, 8)
                panel.padding(.horizontal, 32)
                panelFootnote.padding(.horizontal, 24).padding(.top, 4)

                Placard(state: wall.state, link: wall.link, litInk: Ink.ink, litDim: Ink.dim)
                    .padding(.horizontal, 24).padding(.top, 8)

                MusicBar(accent: accent, litInk: Ink.ink)
                    .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 28)

                if wall.state.mode == "timer", let left = wall.state.timerRemaining {
                    HStack(spacing: 12) {
                        Text(String(format: "%02d:%02d", left / 60, left % 60))
                            .font(.machine(22)).monospacedDigit().foregroundStyle(Ink.ink)
                            .contentTransition(.numericText(countsDown: true))
                        Text("Remaining").font(.ui(14)).foregroundStyle(Ink.dim)
                        Spacer()
                        Button("Stop") { wall.send(["timer_min": 0.0]) }
                            .buttonStyle(PressStyle(scale: 0.95))
                            .font(.ui(15, .semibold)).foregroundStyle(Ink.signal)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .padding(.horizontal, 24).padding(.bottom, 20)
                }

                Rectangle().fill(Ink.hairline).frame(height: 0.5)
                    .padding(.horizontal, 24)
                HStack {
                    Text("On the wall").font(.displayMid(21)).foregroundStyle(Ink.ink)
                    Spacer()
                    if !typeSize.isAccessibilitySize {
                        Text(faceName).font(.ui(12)).foregroundStyle(Ink.dim)
                    }
                }
                .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)
                modeRow.padding(.horizontal, 14).padding(.bottom, 24)
                if !isOff {
                    contextRow.padding(.horizontal, 24).transition(.opacity)
                }
                Spacer(minLength: 64)
            }
            .padding(.top, 4)
            .animation(Motion.settle, value: isOff)
        }
        .scrollIndicators(.hidden)
        .clipped()
        .padding(.bottom, 8)
        .background {
            ZStack(alignment: .top) {
                Ink.ground
                LinearGradient(colors: [accent.opacity(0.10), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(height: 620)
            }.ignoresSafeArea()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RecordMark(accent: accent, lit: 0.9, side: 22)
            Text("Tessera").font(.custom(Face.displayMid, fixedSize: 27)).tracking(-0.5).foregroundStyle(Ink.ink)
                .lineLimit(1).minimumScaleFactor(0.65)
            Spacer(minLength: 12)
            Button(action: onStudio) {
                Image(systemName: "square.and.pencil").font(.system(size: 19, weight: .regular))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(PressStyle(scale: 0.94))
            .accessibilityLabel("Open Studio")
            Button(action: onSetup) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 19, weight: .regular))
                    .frame(width: 44, height: 44)
                    .background(Ink.plaster, in: Circle())
            }
            .buttonStyle(PressStyle(scale: 0.94))
            .accessibilityLabel("Settings")
        }
        .foregroundStyle(Ink.ink)
    }

    private var panelCaption: some View {
        HStack(spacing: 7) {
            Circle().fill(wall.link.isLive ? accent : Ink.dim).frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(connectionTitle).font(.ui(13, .medium)).foregroundStyle(Ink.dim)
            Spacer()
            if !typeSize.isAccessibilitySize, let count = reading.px?.count, let side = Panel.square(count) {
                Text("\(side) × \(side)").font(.machine(10)).foregroundStyle(Ink.dim)
                    .accessibilityLabel("\(side) by \(side) lights")
            }
        }
    }

    private var panel: some View {
        ZStack {
            WallHero(reading: reading,
                     confirmed: isOff ? 0.05 : wall.state.brightness,
                     dragging: $dragLight, link: wall.link, arrivalKey: wall.arrivalKey,
                     touching: $onPanel,
                     onCommit: { wall.send(["brightness": $0]) },
                     onHold: { wall.send(["mode": isOff ? "art" : "off"]) },
                     onFlickPrev: { skipMusic(previous: true) },
                     onFlickNext: { skipMusic(previous: false) })
                .accessibilityIdentifier("home.panel")
            if reading.px == nil || isOff {
                VStack(spacing: 10) {
                    Image(systemName: isOff ? "moon" : "square.grid.3x3")
                        .font(.system(size: 28, weight: .ultraLight)).foregroundStyle(accent)
                    Text(isOff ? "A little quiet." : wall.link.isLive ? "Waiting for the first frame" : "Your wall, right here.")
                        .font(.displayMid(24)).foregroundStyle(Ink.ink)
                    Text(isOff ? "Hold the panel to wake it" : wall.link.isLive ? "Play a song or make something in Studio" : "Finding the wall on your network")
                        .font(.ui(13)).foregroundStyle(Ink.dim)
                        .multilineTextAlignment(.center)
                }
                .padding(28).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .padding(7)
        .background(Color(hex: 0x171C1B))
        .overlay(Rectangle().strokeBorder(LinearGradient(colors: [Ink.ink.opacity(0.18), Ink.ink.opacity(0.025)],
                                                        startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
        .shadow(color: .black.opacity(0.24), radius: 20, y: 12)
    }

    private var panelFootnote: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { panelHint; Spacer(minLength: 4); powerControl }
            VStack(alignment: .leading, spacing: 8) { panelHint; powerControl }
        }
    }

    @ViewBuilder private var panelHint: some View {
        switch wall.link {
        case .offline:
            Button { Task { await wall.poll() } } label: {
                Label("Reconnect to the wall", systemImage: "arrow.clockwise")
                    .font(.ui(13, .medium)).foregroundStyle(accent.toned(forDark: true)).frame(minHeight: 44)
            }.buttonStyle(PressStyle())
        case .searching:
            Text("Looking for your wall…").font(.ui(12)).foregroundStyle(Ink.dim)
        case .standIn:
            Text("Preview on this phone").font(.ui(12)).foregroundStyle(Ink.dim)
        case .live:
            Text(dragLight == nil ? "Drag the artwork to dim" : "Release to set the light")
                .font(.ui(12)).foregroundStyle(Ink.dim)
        }
    }

    private var powerControl: some View {
        Button {
            wall.send(["mode": isOff ? "art" : "off"])
            Taps.detent()
        } label: {
            HStack(spacing: 7) {
                Text(isOff ? "Wake wall" : "\(Int((dragLight ?? duty) * 100))%")
                    .font(.machine(11)).monospacedDigit().contentTransition(.numericText())
                Image(systemName: "power").font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(isOff ? accent : Ink.dim).frame(minHeight: 44)
            .padding(.leading, 8)
        }
        .buttonStyle(PressStyle(scale: 0.96))
        .accessibilityLabel(isOff ? "Turn wall on" : "Turn wall off")
        .accessibilityValue("Brightness \(Int((dragLight ?? duty) * 100)) percent")
    }

    private var connectionTitle: String {
        switch wall.link {
        case .live: isOff ? "Wall is resting" : "Live from the wall"
        case .offline: "Last frame from the wall"
        case .standIn: "Your personal preview"
        case .searching: "Connecting"
        }
    }

    private var faceName: String {
        ["art": "Album art", "cd": "Spin", "ambient": "Lamp", "clock": "Clock",
         "timer": "Timer", "off": "Off", "weather": "Weather", "lyrics": "Lyrics",
         "nine": "Nine", "frame": "Your creation", "clip": "Clip", "ticker": "Words",
         "game": "Game", "imagine": "Imagine", "video": "Video"][wall.state.mode] ?? "Wall"
    }

    private func skipMusic(previous: Bool) {
        guard MPMediaLibrary.authorizationStatus() == .authorized,
              MPMusicPlayerController.systemMusicPlayer.nowPlayingItem != nil else {
            Taps.error(); return
        }
        if previous { MPMusicPlayerController.systemMusicPlayer.skipToPreviousItem() }
        else { MPMusicPlayerController.systemMusicPlayer.skipToNextItem() }
    }

    /// Seven faces. Words left this row at the owner's request (text is made
    /// in the Studio); nine and lyrics joined it because both are things the
    /// wall IS for a while, not things you do to it.
    private var modeRow: some View {
        VStack(spacing: 10) {
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

    private var normalizedMode: String {
        wall.state.mode == "timer" ? "clock" : wall.state.mode
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

        case "clock", "timer":
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
                ) { lyricsNudge = $0; wall.send(["lyric_offset": $0]) }
                Text("Words come from LRCLIB; a track it has never heard shows the sleeve alone.")
                    .font(.ui(12))
                    .foregroundStyle(litDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case "weather":
            Text("Current conditions from your saved location. Open Weather in Settings to explore the forecast.")
                .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        case "art", "frame", "clip", "video":
            FinishRow(
                frame: wall.frame,
                duty: duty,
                selected: wall.state.finish,
                accent: accent
            ) { wall.send(["finish": $0]) }
        default:
            EmptyView()
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
    @State private var playing = false
    @State private var authorized = false
    @State private var hasTrack = false
    @Environment(\.scenePhase) private var scenePhase
    private var music: MPMusicPlayerController { .systemMusicPlayer }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 32) {
                key("backward.end.fill", title: "Previous track", primary: false) { music.skipToPreviousItem() }
                key(playing ? "pause.fill" : "play.fill", title: playing ? "Pause Apple Music" : "Play Apple Music", primary: true) {
                    if playing { music.pause() } else { music.play() }
                    refresh()
                }
                key("forward.end.fill", title: "Next track", primary: false) { music.skipToNextItem() }
            }
            .frame(maxWidth: .infinity)
            if !authorized || !hasTrack {
                Text(!authorized ? "Connect Apple Music in Settings for playback controls" : "Choose a song in Apple Music to play here")
                    .font(.ui(12)).foregroundStyle(Ink.dim).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Apple Music on this iPhone").font(.ui(11)).foregroundStyle(Ink.dim)
            }
        }
        .onAppear { music.beginGeneratingPlaybackNotifications(); refresh() }
        .onDisappear { music.endGeneratingPlaybackNotifications() }
        .onReceive(NotificationCenter.default.publisher(for: .MPMusicPlayerControllerPlaybackStateDidChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .MPMusicPlayerControllerNowPlayingItemDidChange)) { _ in refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
    }

    private func refresh() {
        authorized = MPMediaLibrary.authorizationStatus() == .authorized
        hasTrack = authorized && music.nowPlayingItem != nil
        playing = authorized && music.playbackState == .playing
    }

    private func key(_ symbol: String, title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button {
            guard authorized && hasTrack else { return }
            action()
            Taps.detent(intensity: 0.4)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: primary ? 24 : 20, weight: .medium))
                .foregroundStyle(primary ? Ink.ground : litInk)
                .frame(width: primary ? 64 : 52, height: primary ? 64 : 52)
                .background(primary ? accent.toned(forDark: true) : Ink.plaster, in: Circle())
                .opacity(authorized && hasTrack ? 1 : 0.38)
        }
        .disabled(!authorized || !hasTrack)
        .buttonStyle(PressStyle(scale: 0.92))
        .accessibilityLabel(title)
    }
}
