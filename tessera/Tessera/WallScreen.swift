// The Wall, second design: the iPod.
//
// Everything lives in the iPod body; the room's light sits behind it.

import MediaPlayer
import SwiftUI

struct IPodWallScreen: View {
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
    var onArchive: () -> Void = {}

    private var duty: Double { light.duty }
    private var isOff: Bool { light.isOff }
    private var reading: FrameReading { light.reading }
    private var accent: Color { light.steadyAccent }
    private var roomLight: Double { light.room }
    private var litInk: Color { light.litInk }
    private var litDim: Color { light.litDim }

    @State private var zoomed = false
    /// The opening film plays once per launch, over the spot the iPod
    /// lands on. `-nointro` on the launch line skips it.
    @State private var introDone = !IntroFlip.available || CommandLine.arguments.contains("-nointro")
    @AppStorage("intro.replay") private var replay = false

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                Spacer(minLength: 8)
                ZStack {
                    IPodView(
                        light: light,
                        dragLight: $dragLight,
                        touching: $onPanel,
                        onSetup: onSetup,
                        onStudio: onStudio,
                        onArchive: onArchive,
                        onZoom: { zoomed = true }
                    )
                    .opacity(introDone ? 1 : 0)
                    if !introDone {
                        IntroFlip { withAnimation(.easeOut(duration: 0.25)) { introDone = true } }
                            .frame(width: IPodMetrics.bodyW, height: IPodMetrics.bodyH)
                            .shadow(color: .black.opacity(0.55), radius: 30, y: 18)
                            .allowsHitTesting(false)
                    }
                }
                // A body wider than the phone would clip; on the narrowest
                // phones it scales down and keeps its proportions.
                .scaleEffect(min(1, (geo.size.width - 24) / IPodMetrics.bodyW), anchor: .top)
                .frame(height: IPodMetrics.bodyH * min(1, (geo.size.width - 24) / IPodMetrics.bodyW))
                if wall.state.mode == "timer", let left = wall.state.timerRemaining {
                    HStack(spacing: 12) {
                        Text(String(format: "%02d:%02d", left / 60, left % 60))
                            .font(.machine(16))
                            .foregroundStyle(chrome)
                            .contentTransition(.numericText(countsDown: true))
                        Text("counting down").font(.ui(13)).foregroundStyle(chromeDim)
                        Spacer()
                        Button("stop") { wall.send(["timer_min": 0.0]) }
                            .buttonStyle(PressStyle(scale: 0.95))
                            .font(.ui(14, .semibold))
                            .foregroundStyle(Ink.signal)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                }
                Spacer(minLength: 40)
            }
            .frame(width: geo.size.width)
        }
        .onChange(of: replay) { _, on in
            if on, IntroFlip.available { replay = false; introDone = false }
        }
        .fullScreenCover(isPresented: $zoomed) {
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                VStack(spacing: 24) {
                    Spacer()
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
                    .aspectRatio(1, contentMode: .fit)
                    Placard(state: wall.state, link: wall.link, litInk: Ink.ink, litDim: Ink.dim)
                        .padding(.horizontal, 24)
                    Spacer()
                }
                Button { zoomed = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Ink.ink)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Ink.plaster))
                }
                .buttonStyle(PressStyle(scale: 0.94))
                .padding(20)
                .accessibilityLabel("Close")
            }
            .preferredColorScheme(.dark)
        }
    }

    /// Ink for anything that sits on the room rather than on the iPod. The
    /// room is lit by the sleeve, and a pale sleeve makes a pale room, on
    /// which pale ink vanishes. So the ink flips.
    private var chrome: Color { light.chrome }
    private var chromeDim: Color { light.chromeDim }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            TesseraMark(accent: accent, lit: roomLight, side: 17)
            Text("TESSERA")
                .font(.display(18))
                .kerning(3.0)
                .foregroundStyle(chrome)
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


// MARK: - Which design

/// Three designs of the same room, one at a time: the panel (2D), the iPod,
/// and the room itself in 3D. Chosen in Settings; nothing else changes.
enum Design: String, CaseIterable {
    case classic, ipod, room
    var name: String {
        switch self {
        case .classic: "Panel"
        case .ipod: "iPod"
        case .room: "Room"
        }
    }
}

struct WallScreen: View {
    @AppStorage("design") private var design = Design.ipod.rawValue
    let light: Lighting
    @Binding var dragLight: Double?
    @Binding var onPanel: Bool
    var onSetup: () -> Void
    var onStudio: () -> Void
    var onArchive: () -> Void = {}

    var body: some View {
        switch Design(rawValue: design) ?? .ipod {
        case .classic:
            ClassicWallScreen(light: light, dragLight: $dragLight, onPanel: $onPanel,
                              onSetup: onSetup, onStudio: onStudio)
        case .room:
            RoomWallScreen(light: light, dragLight: $dragLight, onPanel: $onPanel,
                           onSetup: onSetup, onStudio: onStudio, onArchive: onArchive)
        case .ipod:
            IPodWallScreen(light: light, dragLight: $dragLight, onPanel: $onPanel,
                           onSetup: onSetup, onStudio: onStudio, onArchive: onArchive)
        }
    }
}
