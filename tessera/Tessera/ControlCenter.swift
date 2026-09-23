// The controls: one board, five kinds of thing on it.
//
// Frosted glass over the room, and on it a bento of shapes that each say
// what they are by their shape. The light is a wide slab with a rail across
// it, because light is a quantity you slide. The wall's faces are capsules
// in a row you can flick, because they are names you choose between. What
// the current face needs sits in a taller board of its own, because it
// changes with the face. And the places you can go are three short pills.
// Glyphs do the work of words wherever a glyph can. The sleeve's colour is
// the only colour.

import MediaPlayer
import PhotosUI
import SwiftUI

/// The ink the glass is written in. Cream over the dark designs; near-black
/// over the white room, where cream would vanish.
struct GlassInk {
    var ink: Color = Ink.ink
    var dim: Color = Ink.dim
    var faint: Color = Ink.faint
    var fill: Color = Color.white.opacity(0.10)
    static let dark = GlassInk()
    static let light = GlassInk(ink: Color(hex: 0x1A1815), dim: Color(hex: 0x6B665C), faint: Color(hex: 0x9A948A), fill: Color.black.opacity(0.06))
}

// MARK: - The two buttons that open things

struct ControlCenterButtons: View {
    var ink: GlassInk = .dark
    var onControls: () -> Void
    var onSetup: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            FrostedKey(ink: ink, label: "Controls", action: onControls) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .medium)).foregroundStyle(ink.ink)
            }
            FrostedKey(ink: ink, label: "Settings", action: onSetup) {
                Image(systemName: "gearshape").font(.system(size: 18, weight: .medium)).foregroundStyle(ink.ink)
            }
        }
    }


}

/// A round key on glass.
struct FrostedKey<Content: View>: View {
    var size: CGFloat = 44
    var on: Bool = false
    var accent: Color = Ink.tile
    var ink: GlassInk = .dark
    let label: String
    var action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            ZStack {
                if on {
                    Circle().fill(accent)
                } else {
                    Circle().fill(.ultraThinMaterial)
                    Circle().strokeBorder(ink.ink.opacity(0.14), lineWidth: 1)
                }
                content()
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(PressStyle(scale: 0.9))
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// A frosted slab with a hairline: the board every control sits on.
struct Slab: View {
    var radius: CGFloat = 26
    var ink: GlassInk = .dark
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(ink.ink.opacity(0.10), lineWidth: 1))
    }
}

// MARK: - The board

/// How the panel is laid out: the whole thing over the room, or only the
/// wall's own controls, under the wall when the room is in close.
enum PanelLayout { case full, tuning }

struct ControlCenterPanel: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.scenePhase) private var scenePhase
    let light: Lighting
    var ink: GlassInk = .dark
    @Binding var dragLight: Double?
    var onStudio: () -> Void
    var onArchive: () -> Void
    var onSetup: () -> Void
    var onClose: () -> Void
    var layout: PanelLayout = .full
    /// The sleeve of the song that is on, for the now card; the wall's
    /// frame stands in when there is none.
    var sleeve: UIImage? = nil

    /// The Video face is chosen here, not on the wall: a video needs a link
    /// before there is anything for the wall to be in the middle of.
    @State private var videoFace = false
    /// The games live in their own sheet: a board wants the whole screen.
    @State private var showGames = false
    @State private var showWeather = false
    @State private var showArtwork = false
    @State private var artworkIsSpin = false
    @State private var showColour = false
    @State private var localPlayback = false
    @State private var controlsLocalTrack = false
    @State private var videoTask: Task<Void, Never>?
    @State private var videoRequest = UUID()
    @State private var videoLink = ""
    @AppStorage("video.sound") private var videoSound = true
    @State private var videoPick: PhotosPickerItem? = nil
    /// What is being done to a video of your own, and how far along.
    @State private var videoWork: (String, Double)? = nil
    @State private var videoProblem: String? = nil
    /// A rail being dragged: its key and where the thumb is now, so the
    /// number under a finger is the finger's, not the wall's last word.
    @State private var railDrag: (String, Double)? = nil
    /// What the wall will letter, as it is typed; sent on return or Send.
    @State private var wordsDraft = ""
    @AppStorage("lyrics.nudge") private var lyricsNudge: Double = 0
    /// The countdown being dialled up, before Start sends it.
    @State private var timerDraft: Double = 10
    // The minutes, typed: tap the number and it becomes a field. "12" is
    // twelve minutes, "1:30" a minute and a half, "45s" forty-five seconds.
    @State private var timerTyping = false
    @State private var timerTyped = ""
    @FocusState private var timerFocus: Bool
    // The alarm's time, typed the same way: "7:30", "19:45", "7:30 pm".
    @State private var alarmTyping = false
    @State private var alarmTyped = ""
    @FocusState private var alarmFocus: Bool
    private var accent: Color { light.steadyAccent }
    /// Ink that can be read on the record's own colour, whatever it is.
    private var onAccent: Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(accent).getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.55 ? Ink.ground : .white
    }
    private let gutter: CGFloat = 14

    var body: some View {
        Group {
            switch layout {
            case .full:
                ZStack(alignment: .top) {
                    Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                    GeometryReader { geo in
                        ScrollView(.vertical) {
                            VStack(spacing: gutter) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Your wall").font(.display(30)).foregroundStyle(ink.ink)
                                        Text(connectionLabel).font(.machine(9)).kerning(0.8).foregroundStyle(ink.ink.opacity(0.78))
                                    }
                                    Spacer()
                                    closeKey
                                }
                                .padding(.top, 4)
                                lightSlab
                                faces
                                context
                                nowCard
                                Spacer(minLength: 0)
                                places
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 58)
                            // clear of the page marks at the foot of the screen
                            .padding(.bottom, 60)
                            .frame(minHeight: geo.size.height)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .scrollIndicators(.hidden)
                        .defaultScrollAnchor(initialAnchor)
                    }
                    .transition(reducedMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            case .tuning:
                // Kept to a little over half the screen and scrolled past
                // that: a tall board (the words face, with its rail, its
                // finishes and its colours) used to push up over the wall
                // it was tuning.
                ScrollView(.vertical) {
                    VStack(spacing: gutter) {
                        // (the light is the wall itself up here: drag on it)
                        faces
                        context
                    }
                    .padding(.horizontal, 16)
                    // The rendered frame extends beyond the live pixel quad.
                    // Keep the first heading below its bezel, not on top of it.
                    .padding(.top, 28)
                    .padding(.bottom, 18)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                .frame(maxHeight: 452)
                .clipped()
                .background {
                    LinearGradient(colors: [.clear, .black.opacity(0.16), .black.opacity(0.28)],
                                   startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                }
            }
        }
        // the glass takes the room's own scheme: light over the white room,
        // dark over the dark designs, so it frosts instead of muddying
        .environment(\.colorScheme, ink.ink == Ink.ink ? .dark : .light)
        .sheet(isPresented: $showArtwork) { ArtworkPage(spin: artworkIsSpin, accent: accent).environment(wall) }
        .sheet(isPresented: $showGames) { GamesSheet(accent: accent).environment(wall) }
        .sheet(isPresented: $showWeather) {
            NavigationStack {
                WeatherPage(accent: accent).environment(wall)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showWeather = false } } }
            }.preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showColour) {
            ColourSheet(colour: Binding(get: { Color.wall(hex: wall.state.color) },
                                       set: { wall.send(["color": $0.wallHex]) }), title: "Primary colour")
        }
        .onAppear {
            refreshLocalPlayback()
            #if DEBUG
            if CommandLine.arguments.contains("-control-colour") { showColour = true }
            if CommandLine.arguments.contains("-artwork-page") || CommandLine.arguments.contains("-spin-page") {
                artworkIsSpin = CommandLine.arguments.contains("-spin-page"); showArtwork = true
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .MPMusicPlayerControllerPlaybackStateDidChange)) { _ in refreshLocalPlayback() }
        .onReceive(NotificationCenter.default.publisher(for: .MPMusicPlayerControllerNowPlayingItemDidChange)) { _ in refreshLocalPlayback() }
        .onChange(of: wall.state.title) { _, _ in refreshLocalPlayback() }
        .onChange(of: wall.host) { _, _ in
            videoTask?.cancel(); videoRequest = UUID(); videoWork = nil
        }
        .onDisappear {
            videoTask?.cancel(); videoRequest = UUID()
            dragLight = nil; railDrag = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshLocalPlayback() }
            else { dragLight = nil; railDrag = nil }
        }
        .accessibilityAction(.escape) { onClose() }
    }

    private var initialAnchor: UnitPoint {
        #if DEBUG
        if CommandLine.arguments.contains("-control-detail") { return .bottom }
        #endif
        return .top
    }
    private var connectionLabel: String {
        switch wall.link {
        case .live: "CONNECTED · \(faceName(wall.state.mode))"
        case .standIn: "PHONE PREVIEW"
        case .searching: "FINDING YOUR WALL"
        case .offline: "WALL OFFLINE · CHANGES WAIT FOR CONNECTION"
        }
    }

    /// A round key with a cross: the one sure way out.
    private var closeKey: some View {
        Button { onClose(); Taps.detent(intensity: 0.3) } label: {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                Circle().strokeBorder(ink.ink.opacity(0.14), lineWidth: 1)
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ink.ink).accessibilityHidden(true)
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(PressStyle(scale: 0.92))
        .accessibilityLabel("Close")
    }

    // MARK: Now: the record on, and where the needle is

    /// What is on, its sleeve, and how far the needle has got; one key to
    /// hold it or let it go.
    private var nowCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Group {
                    if let sleeve {
                        Image(uiImage: sleeve).resizable().interpolation(.high)
                    } else {
                        Rectangle().fill(ink.fill)
                            .overlay(Image(systemName: "music.note").font(.system(size: 24)).foregroundStyle(ink.dim))
                    }
                }
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
                NowPlayingIdentity(state: wall.state, link: wall.link, accent: accent,
                                   ink: ink.ink, secondary: ink.dim, compact: true, showsProgress: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if controlsLocalTrack {
                    Button {
                        let player = MPMusicPlayerController.systemMusicPlayer
                        if localPlayback { player.pause() } else { player.play() }
                        refreshLocalPlayback(); Taps.detent(intensity: 0.5)
                    } label: {
                        Image(systemName: localPlayback ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(onAccent).frame(width: 46, height: 46)
                            .background(accent, in: Circle())
                    }
                    .buttonStyle(PressStyle(scale: 0.94))
                    .accessibilityLabel(localPlayback ? "Pause Apple Music" : "Play Apple Music")
                }
            }
            PlaybackProgress(state: wall.state, link: wall.link, accent: accent, secondary: ink.dim, compact: true)
            if let owned = wall.state.owned, let url = URL(string: owned.url) {
                Link(destination: url) {
                    Label(owned.line, systemImage: "opticaldisc").font(.ui(12)).foregroundStyle(accent)
                }.frame(minHeight: 44, alignment: .leading)
            }
            if PlaybackIdentity(state: wall.state, link: wall.link).hasSong && !controlsLocalTrack {
                Text("Playback controls are in your music player.")
                    .font(.ui(11)).foregroundStyle(ink.dim)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(Slab(radius: 26, ink: ink))
    }

    private func refreshLocalPlayback() {
        guard MPMediaLibrary.authorizationStatus() == .authorized else {
            controlsLocalTrack = false; localPlayback = false; return
        }
        let player = MPMusicPlayerController.systemMusicPlayer
        localPlayback = player.playbackState == .playing
        guard let item = player.nowPlayingItem else { controlsLocalTrack = false; return }
        let title = (wall.state.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        controlsLocalTrack = !title.isEmpty && SleeveMatch.same(item.title ?? "", title)
            && SleeveMatch.same(item.artist ?? "", wall.state.artist ?? "")
    }

    // MARK: Light

    private var value: Double {
        let raw = dragLight ?? wall.state.brightness
        return raw.isFinite ? min(1, max(0.05, raw)) : 1
    }
    private var canSetLight: Bool { !light.isOff && (wall.link.isLive || wall.link.isStandIn) }

    private var lightSlab: some View {
        let heroLayout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 20))
        return VStack(alignment: .leading, spacing: 18) {
            heroLayout {
                VStack(alignment: .leading, spacing: 8) {
                    PanelCanvas(px: light.isOff ? nil : light.reading.px, duty: value)
                        .frame(width: 106, height: 106)
                        .overlay(Rectangle().strokeBorder(ink.ink.opacity(0.15), lineWidth: 0.5))
                        .accessibilityLabel(light.isOff ? "Wall is asleep" : "Current wall frame")
                    Text(wall.link.isLive ? "LIVE PIXELS" : wall.link.isStandIn ? "PHONE PREVIEW" : "LAST FRAME")
                        .font(.machine(7)).kerning(0.6).foregroundStyle(ink.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(light.isOff ? "ASLEEP" : "BRIGHTNESS").font(.machine(9)).kerning(1).foregroundStyle(ink.dim)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(light.isOff ? "—" : "\(Int((value * 100).rounded()))")
                            .font(.display(typeSize.isAccessibilitySize ? 40 : 58)).foregroundStyle(ink.ink).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.65)
                            .contentTransition(.numericText())
                        if !light.isOff { Text("%").font(.ui(17)).foregroundStyle(ink.dim) }
                    }
                    Text(light.isOff ? "Your next moment of light." : faceName(wall.state.mode))
                        .font(.ui(13)).foregroundStyle(ink.dim).fixedSize(horizontal: false, vertical: true)
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if light.isOff {
                Button { wall.send(["mode": "art"]); Taps.commit() } label: {
                    Label("Wake the wall", systemImage: "power")
                        .font(.ui(14, .semibold)).foregroundStyle(onAccent)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(accent, in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(PressStyle(scale: 0.97))
            } else {
                WallValueSlider(value: Binding(get: { value }, set: { dragLight = $0 }),
                                title: "Light level", accent: accent, ink: ink.ink, secondary: ink.dim,
                                onEditingChanged: { editing in if !editing { finishLightEditing() } },
                                onCancel: { dragLight = nil })
                    .disabled(!canSetLight)
                if !canSetLight {
                    Text("Reconnect your wall to adjust its light.").font(.ui(12)).foregroundStyle(ink.dim)
                }
            }
        }
        .padding(20).background(Slab(radius: 28, ink: ink))
    }

    private func finishLightEditing() {
        if let pending = dragLight, canSetLight {
            wall.send(["brightness": min(1, max(0.05, pending))]); Taps.commit()
        }
        dragLight = nil
    }

    // MARK: Faces: capsules you flick through

    /// The wall's faces: a grid of tiles, every one in view, the one that
    /// is on filled with the record's colour.
    private var faces: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Choose a face").font(.displayMid(23)).foregroundStyle(ink.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if typeSize.isAccessibilitySize {
                    Text("Current: \(faceName(wall.state.mode))")
                        .font(.ui(11, .medium)).foregroundStyle(ink.dim)
                }
            }
            faceGroup("MUSIC & CREATION") {
                tile(.art, "Art", mode: "art")
                tile(.spin, "Spin", mode: "cd")
                tile(.lyrics, "Lyrics", mode: "lyrics")
                tile(.nine, "Nine", mode: "nine")
                tile(.palette, "Design", mode: "frame") { onClose(); onStudio() }
                tile(.video, "Video", mode: "video") { videoFace = true }
            }
            faceGroup("IN YOUR ROOM") {
                tile(.lamp, "Lamp", mode: "ambient")
                tile(.clock, "Clock", mode: "clock")
                tile(.weather, "Weather", mode: "weather")
                tile(.games, "Games", mode: "game") { showGames = true }
                tile(.ticker, "Ticker", mode: "ticker")
                tile(.dark, "Off", mode: "off")
            }
        }
    }

    private func faceGroup<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.machine(8)).kerning(1.2).foregroundStyle(ink.dim)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: typeSize.isAccessibilitySize ? 2 : 3), spacing: 9) {
                content()
            }
        }
    }

    private func tile(_ g: Glyph, _ label: String, mode: String?, action: (() -> Void)? = nil) -> some View {
        let on = mode != nil && (wall.state.mode == mode || (mode == "clock" && wall.state.mode == "timer"))
        let draft = mode == "video" && videoFace && !on
        return Button {
            videoFace = mode == "video"
            if let action { action() }
            else if let mode { wall.send(["mode": mode == "off" && wall.state.mode == "off" ? "art" : mode]) }
            Taps.detent(intensity: 0.4)
        } label: {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 13).fill((on ? accent : ink.ink).opacity(on ? 0.16 : 0.045))
                        if let sleeve, mode == "art" || mode == "cd" {
                            Image(uiImage: sleeve).resizable().interpolation(.high)
                                .frame(width: 38, height: 38)
                                .clipShape(RoundedRectangle(cornerRadius: mode == "cd" ? 19 : 3))
                                .overlay {
                                    if mode == "cd" { Circle().fill(ink.ink).frame(width: 5, height: 5) }
                                }
                        } else if mode == "weather" {
                            Image(systemName: "cloud.sun").symbolRenderingMode(.monochrome)
                                .font(.system(size: 25)).foregroundStyle(on ? accent : ink.ink)
                        } else {
                            GlyphShape(glyph: g, lineWidth: 1.6).frame(width: 24, height: 24)
                                .foregroundStyle(on ? accent : ink.ink)
                        }
                    }.frame(width: 49, height: 49)
                    Spacer(minLength: 0)
                    if on {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 14))
                            .foregroundStyle(accent).accessibilityHidden(true)
                    } else if draft {
                        Image(systemName: "pencil.circle").font(.system(size: 14)).foregroundStyle(ink.dim)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(.ui(14, .semibold)).foregroundStyle(ink.ink)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(on ? (wall.link.isLive ? "On your wall" : "Selected") : draft ? "Choose a video" : faceDescription(mode))
                        .font(.ui(9)).foregroundStyle(ink.dim)
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1).minimumScaleFactor(0.8)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: typeSize.isAccessibilitySize ? 144 : 116)
            .background(Slab(radius: 20, ink: ink))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(on ? accent.opacity(0.85) : .clear, lineWidth: 1.5))
        }
        .buttonStyle(PressStyle(scale: 0.96))
        .accessibilityLabel(label)
        .accessibilityValue(on ? "Selected" : draft ? "Preparing a video" : faceDescription(mode))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func faceName(_ mode: String) -> String {
        ["art": "Album art", "cd": "Spin", "lyrics": "Lyrics", "nine": "Nine", "frame": "Design",
         "video": "Video", "ambient": "Lamp", "clock": "Clock", "timer": "Timer", "weather": "Weather",
         "game": "Games", "ticker": "Ticker", "off": "Off", "clip": "Clip", "imagine": "Imagine"][mode] ?? "Your wall"
    }
    private func faceDescription(_ mode: String?) -> String {
        switch mode {
        case "art": "The album sleeve"
        case "cd": "A record in motion"
        case "lyrics": "Follow the song"
        case "nine": "Nine sleeves"
        case "frame": "Open your studio"
        case "video": "A moving picture"
        case "ambient": "Colour & atmosphere"
        case "clock": "Time & timers"
        case "weather": "Your local sky"
        case "game": "Something to play"
        case "ticker": "Words in motion"
        case "off": "Let the wall rest"
        default: "Choose this face"
        }
    }

    // MARK: What this face needs

    @ViewBuilder private var context: some View {
        if videoFace || wall.state.mode == "video" {
            videoBoard
        } else {
            faceContext
        }
    }

    @ViewBuilder private var faceContext: some View {
        switch wall.state.mode {
        case "cd": speedBoard
        case "ambient": lampBoard
        case "clock", "timer": clockBoard
        case "lyrics": timingBoard
        case "ticker": wordsBoard
        case "off": sleepBoard
        case "frame", "clip": designBoard
        case "weather":
            board("Weather") {
                Label(wall.state.place.isEmpty ? "Choose a place to follow its sky." : wall.state.place, systemImage: "location")
                    .font(.ui(15)).foregroundStyle(ink.ink)
                Button { showWeather = true } label: {
                    Label("Forecast & place", systemImage: "arrow.up.right")
                        .font(.ui(14, .semibold)).foregroundStyle(accent)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.buttonStyle(PressStyle())
            }
        case "game":
            board("Games") {
                Text("Return to your game, or choose something new.").font(.ui(14)).foregroundStyle(ink.dim)
                Button { showGames = true } label: {
                    Label("Open games", systemImage: "gamecontroller")
                        .font(.ui(14, .semibold)).foregroundStyle(accent).frame(minHeight: 44)
                }.buttonStyle(PressStyle())
            }
        case "imagine":
            board("Imagine") {
                Text("Your generated artwork is on the wall.").font(.ui(14)).foregroundStyle(ink.dim)
            }
        case "art":
            VStack(spacing: 16) { artworkLink(spin: false); finishBoard }
        case "nine": finishBoard
        default: EmptyView()
        }
    }

    // MARK: Words: what the wall letters, and how it moves

    /// The Words face used to have no board here, so the wall lettered
    /// HELLO for as long as it was chosen. Typing is the whole point.
    private var wordsBoard: some View {
        let empty = wordsDraft.trimmingCharacters(in: .whitespaces).isEmpty
        return board("Words") {
            HStack(spacing: 10) {
                TextField("say something", text: $wordsDraft)
                    .font(.machine(14)).foregroundStyle(ink.ink)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: Round.card, style: .continuous).fill(ink.fill))
                    .onSubmit(sendWords)
                Button(action: sendWords) {
                    Text("Send").font(.ui(14, .semibold))
                        .foregroundStyle(empty ? ink.faint : Ink.ground)
                        .padding(.horizontal, 18).frame(height: 44)
                        .background(Capsule().fill(empty ? AnyShapeStyle(ink.fill) : AnyShapeStyle(accent)))
                }
                .buttonStyle(PressStyle(scale: 0.95))
                .disabled(empty)
            }
            HStack(spacing: 8) {
                choice("Across", "across", wall.state.tickerStyle, { wall.send(["ticker_style": $0]) })
                choice("Rising", "rising", wall.state.tickerStyle, { wall.send(["ticker_style": $0]) })
                choice("Tilt", "crawl", wall.state.tickerStyle, { wall.send(["ticker_style": $0]) })
            }
            HStack(spacing: 8) {
                choice("Loop", true, wall.state.tickerLoop, { wall.send(["ticker_loop": $0]) })
                choice("Once, then art", false, wall.state.tickerLoop, { wall.send(["ticker_loop": $0]) })
            }
            colours
        }
        .onAppear { if wordsDraft.isEmpty { wordsDraft = wall.state.tickerText } }
    }

    private func sendWords() {
        let text = wordsDraft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        wall.send(["ticker_text": text])
        Taps.commit()
    }

    private func board<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased()).font(.machine(9)).kerning(1.2).foregroundStyle(ink.dim)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Slab(radius: 26, ink: ink))
    }

    /// Choices inside a board: equal segments that share the row, the one
    /// that is on filled with the record's colour.
    private func choice<T: Equatable>(_ label: String, _ value: T, _ current: T, _ pick: @escaping (T) -> Void) -> some View {
        let on = value == current
        return Button { pick(value); Taps.detent(intensity: 0.4) } label: {
            Text(label).font(.ui(14, .medium))
                .foregroundStyle(on ? onAccent : ink.ink)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: Round.card, style: .continuous).fill(on ? AnyShapeStyle(accent) : AnyShapeStyle(ink.fill)))
        }
        .buttonStyle(PressStyle(scale: 0.96))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private func artworkLink(spin: Bool) -> some View {
        Button { artworkIsSpin = spin; showArtwork = true } label: {
            HStack(spacing: 12) {
                Image(systemName: spin ? "opticaldisc" : "photo.on.rectangle").font(.system(size: 22, weight: .medium))
                VStack(alignment: .leading, spacing: 4) {
                    Text(spin ? "The spinning record" : "A closer look").font(.ui(16, .semibold))
                    Text(spin ? "Live pixels, face & rotation" : "Original cover & live wall").font(.ui(12)).foregroundStyle(ink.dim)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
            }.foregroundStyle(ink.ink).padding(16).frame(maxWidth: .infinity, minHeight: 64)
                .background(ink.fill, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(PressStyle(scale: 0.98))
    }

    private var speedBoard: some View {
        let rpm = rail(key: "rpm") ?? wall.state.rpm
        return board("Spin") {
            artworkLink(spin: true)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.1f", rpm)).font(.display(28)).foregroundStyle(ink.ink).contentTransition(.numericText())
                Text("rpm").font(.ui(13)).foregroundStyle(ink.dim)
            }
            slider(key: "rpm", value: rpm, from: 0.5, to: 45, step: 0.5) {
                wall.send(["rpm": $0])
            }
            HStack(spacing: 8) {
                choice("7.5", 7.5, rpm, { wall.send(["rpm": $0]) })
                choice("33⅓", 33.333, rpm, { wall.send(["rpm": $0]) })
                choice("45", 45.0, rpm, { wall.send(["rpm": $0]) })
            }
            // what the wall turns: the record on the deck, or the sleeve
            HStack(spacing: 8) {
                choice("Pressing", "pressing", wall.state.spinFace, { wall.send(["spin_face": $0]) })
                choice("Album art", "art", wall.state.spinFace, { wall.send(["spin_face": $0]) })
            }
            finishes
        }
    }

    private var lampBoard: some View {
        board("Lamp") {
            let effects = [("plaid", "Plaid"), ("weave", "Weave"), ("deco", "Deco"), ("snake", "Snake"), ("solid", "Solid"),
                           ("breathe", "Breathe"), ("pulse", "Pulse"), ("rainbow", "Rainbow"), ("gradient", "Fade")]
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: typeSize.isAccessibilitySize ? 2 : 3), spacing: 8) {
                ForEach(effects, id: \.0) { e in
                    choice(e.1, e.0, wall.state.effect, { wall.send(["effect": $0]) })
                }
            }
            colours
        }
    }

    private var clockBoard: some View {
        board(wall.state.mode == "timer" ? "Timer" : "Clock") {
            if wall.state.mode == "timer", let left = wall.state.timerRemaining {
                HStack {
                    Text(String(format: "%02d:%02d", left / 60, left % 60)).font(.display(28)).foregroundStyle(ink.ink)
                        .contentTransition(.numericText(countsDown: true))
                    Spacer()
                    choice("Stop", true, false, { _ in wall.send(["timer_min": 0.0]) })
                }
            } else {
                let mins = rail(key: "timer_min") ?? timerDraft
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if timerTyping {
                        TextField("", text: $timerTyped)
                            .font(.display(28)).foregroundStyle(ink.ink)
                            .keyboardType(.numbersAndPunctuation)
                            .submitLabel(.done)
                            .focused($timerFocus)
                            .onSubmit { commitTypedTimer() }
                            .onChange(of: timerFocus) { _, on in if !on { commitTypedTimer() } }
                            .frame(maxWidth: 120)
                        Text("min").font(.ui(13)).foregroundStyle(ink.dim)
                    } else {
                        Text(timerLabel(mins)).font(.display(28)).foregroundStyle(ink.ink)
                            .contentTransition(.numericText())
                            .onTapGesture {
                                timerTyped = timerLabel(mins)
                                timerTyping = true
                                timerFocus = true
                                Taps.detent(intensity: 0.3)
                            }
                            .accessibilityHint("Tap to type a time")
                        Text(mins == mins.rounded(.down) ? "min" : "m:ss").font(.ui(13)).foregroundStyle(ink.dim)
                    }
                    Spacer()
                    Button {
                        if timerTyping { commitTypedTimer() }
                        wall.send(["timer_min": timerDraft]); Taps.commit()
                    } label: {
                        Text("Start").font(.ui(14, .semibold)).foregroundStyle(Ink.ground)
                            .padding(.horizontal, 20).frame(height: 40)
                            .background(Capsule().fill(accent))
                    }
                    .buttonStyle(PressStyle(scale: 0.95))
                }
                slider(key: "timer_min", value: mins, from: 1, to: 180, step: 1) { timerDraft = $0 }
                HStack(spacing: 8) {
                    ForEach([5.0, 10.0, 15.0, 30.0], id: \.self) { m in
                        choice("\(Int(m)) min", m, timerDraft, { timerDraft = $0 })
                    }
                }
                HStack(spacing: 8) {
                    choice("24 hour", true, wall.state.clock24h, { wall.send(["clock_24h": $0]) })
                    choice("12 hour", false, wall.state.clock24h, { wall.send(["clock_24h": $0]) })
                }
                alarmRow
                colours
            }
        }
    }

    /// A time of day the wall rings, with the timer's ending.
    private var alarmRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Alarm").font(.ui(14)).foregroundStyle(ink.ink)
            if alarmTyping {
                TextField("", text: $alarmTyped)
                    .font(.display(22)).foregroundStyle(ink.ink)
                    .keyboardType(.numbersAndPunctuation)
                    .submitLabel(.done)
                    .focused($alarmFocus)
                    .onSubmit { commitTypedAlarm() }
                    .onChange(of: alarmFocus) { _, on in if !on { commitTypedAlarm() } }
                    .frame(maxWidth: 130)
            } else {
                Text(alarmLabel(wall.state.alarmTime)).font(.display(22)).foregroundStyle(ink.ink)
                    .contentTransition(.numericText())
                    .onTapGesture {
                        alarmTyped = alarmLabel(wall.state.alarmTime)
                        alarmTyping = true
                        alarmFocus = true
                        Taps.detent(intensity: 0.3)
                    }
                    .accessibilityHint("Tap to type a time")
            }
            Spacer()
            Toggle("", isOn: Binding(get: { wall.state.alarmEnabled },
                                     set: { wall.send(["alarm_enabled": $0]); Taps.detent(intensity: 0.4) }))
                .labelsHidden()
                .tint(accent)
                .accessibilityLabel("Alarm on")
        }
    }

    /// "07:30" on the 24 hour clock, "7:30 AM" on the 12 hour one.
    private func alarmLabel(_ hhmm: String) -> String {
        let bits = hhmm.split(separator: ":")
        guard bits.count == 2, let h = Int(bits[0]), let m = Int(bits[1]) else { return hhmm }
        if wall.state.clock24h { return String(format: "%02d:%02d", h, m) }
        let h12 = h % 12 == 0 ? 12 : h % 12
        return String(format: "%d:%02d %@", h12, m, h < 12 ? "AM" : "PM")
    }

    /// What was typed, as HH:MM: "7:30", "07:30", "7:30 pm", "7pm", "1930".
    private func commitTypedAlarm() {
        guard alarmTyping else { return }
        alarmTyping = false; alarmFocus = false
        var t = alarmTyped.lowercased().replacingOccurrences(of: " ", with: "")
        var pm: Bool? = nil
        if t.hasSuffix("pm") { pm = true; t = String(t.dropLast(2)) }
        else if t.hasSuffix("am") { pm = false; t = String(t.dropLast(2)) }
        t = t.replacingOccurrences(of: ".", with: ":")
        var h = -1, m = 0
        if t.contains(":") {
            let p = t.split(separator: ":", omittingEmptySubsequences: false)
            if p.count == 2, let hh = Int(p[0]), let mm = Int(p[1]) { h = hh; m = mm }
        } else if let v = Int(t) {
            if t.count <= 2 { h = v } else { h = v / 100; m = v % 100 }
        }
        guard h >= 0, h < 24 || (pm != nil && h <= 12), m >= 0, m < 60 else { return }
        if let pm {
            h = h % 12 + (pm ? 12 : 0)
        }
        guard h < 24 else { return }
        wall.send(["alarm_time": String(format: "%02d:%02d", h, m)])
        Taps.detent(intensity: 0.3)
    }

    /// "12" for whole minutes, "1:30" otherwise.
    private func timerLabel(_ mins: Double) -> String {
        if mins == mins.rounded(.down) { return "\(Int(mins))" }
        let total = Int((mins * 60).rounded())
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    /// What was typed, as minutes: "12", "1:30", "90s", "0.5". Kept within
    /// what the wall accepts; nonsense leaves the draft alone.
    private func commitTypedTimer() {
        guard timerTyping else { return }
        timerTyping = false; timerFocus = false
        let t = timerTyped.trimmingCharacters(in: .whitespaces).lowercased()
        var mins: Double? = nil
        if t.contains(":") {
            let parts = t.split(separator: ":", omittingEmptySubsequences: false).map { Double($0) ?? 0 }
            if parts.count == 2 { mins = parts[0] + parts[1] / 60 }
            if parts.count == 3 { mins = parts[0] * 60 + parts[1] + parts[2] / 60 }
        } else if t.hasSuffix("s"), let v = Double(t.dropLast().trimmingCharacters(in: .whitespaces)) {
            mins = v / 60
        } else if t.hasSuffix("h"), let v = Double(t.dropLast().trimmingCharacters(in: .whitespaces)) {
            mins = v * 60
        } else if let v = Double(t.replacingOccurrences(of: "min", with: "").trimmingCharacters(in: .whitespaces)) {
            mins = v
        }
        guard let m = mins, m > 0 else { return }
        timerDraft = min(180, max(0.1, m))
        Taps.detent(intensity: 0.3)
    }

    private var timingBoard: some View {
        let ahead = rail(key: "lyric_offset") ?? wall.state.lyricOffset
        return board("Words") {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%+.2f", ahead)).font(.display(28)).foregroundStyle(ink.ink)
                    .contentTransition(.numericText())
                Text("s").font(.ui(13)).foregroundStyle(ink.dim)
            }
            slider(key: "lyric_offset", value: ahead, from: -2, to: 2, step: 0.05) { v in
                wall.send(["lyric_offset": v])
                lyricsNudge = v          // the phone's own words follow the wall's
            }
            HStack(spacing: 8) {
                choice("Sooner", -0.4, ahead, { wall.send(["lyric_offset": $0]); lyricsNudge = $0 })
                choice("On time", 0.2, ahead, { wall.send(["lyric_offset": $0]); lyricsNudge = $0 })
                choice("Later", 0.8, ahead, { wall.send(["lyric_offset": $0]); lyricsNudge = $0 })
            }
            finishes
        }
    }

    private var finishBoard: some View {
        board("Finish") { finishes }
    }

    /// A design or a clip: the studio itself, here, and the finish over it.
    /// Drawing is the point of this face, so it is not behind a door.
    // MARK: Video: a link, or something out of your own library

    private var videoBoard: some View {
        VStack(spacing: gutter) {
            if videoFace && wall.state.mode != "video" {
                HStack {
                    Label("Preparing a video", systemImage: "pencil.circle").font(.ui(12)).foregroundStyle(ink.dim)
                    Spacer()
                    Button("Cancel") { videoFace = false }.font(.ui(13, .semibold)).foregroundStyle(accent)
                        .frame(minHeight: 44)
                }
            }
            board("Video") {
                if let v = wall.state.video, v.live {
                    videoNow(v)
                } else {
                    videoEntry
                }
                if let work = videoWork { videoWorking(work) }
                if let why = videoProblem {
                    Text(why).font(.ui(13)).foregroundStyle(Ink.signal)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            board("Finish") { finishes }
        }
        .onChange(of: videoPick) { _, item in
            guard let item else { return }
            videoPick = nil
            videoTask?.cancel()
            videoTask = Task { await sendChosenVideo(item) }
        }
        .task { await takeHandedOverVideo() }
    }

    private var videoTyped: String {
        let raw = videoLink.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.lowercased().hasPrefix("http") { return raw }
        return raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            .first { $0.lowercased().hasPrefix("http") } ?? ""
    }

    /// Nothing on: a link, how it should sound, and your own library.
    private var videoEntry: some View {
        let empty = videoTyped.isEmpty
        let busy = videoWork != nil
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                TextField("youtube link", text: $videoLink)
                    .font(.machine(14)).foregroundStyle(ink.ink)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: Round.card, style: .continuous).fill(ink.fill))
                    .onSubmit(playVideoLink)
                Button(action: playVideoLink) {
                    Text("Play").font(.ui(14, .semibold))
                        .foregroundStyle(empty || busy ? ink.faint : Ink.ground)
                        .padding(.horizontal, 18).frame(height: 44)
                        .background(Capsule().fill(empty || busy ? AnyShapeStyle(ink.fill) : AnyShapeStyle(accent)))
                }
                .buttonStyle(PressStyle(scale: 0.95))
                .disabled(empty || busy)
            }
            HStack(spacing: 8) {
                choice("Sound here", true, videoSound, { videoSound = $0 })
                choice("Silent", false, videoSound, { videoSound = $0 })
            }
            PhotosPicker(selection: $videoPick, matching: .videos) {
                HStack(spacing: 8) {
                    GlyphShape(glyph: .photo, lineWidth: 1.5).frame(width: 17, height: 17)
                    Text("A video of your own").font(.ui(14, .medium))
                }
                .foregroundStyle(busy ? ink.faint : ink.ink)
                .frame(maxWidth: .infinity).frame(height: 44)
                .background(RoundedRectangle(cornerRadius: Round.card, style: .continuous).fill(ink.fill))
            }
            .buttonStyle(PressStyle(scale: 0.97))
            .disabled(busy)
        }
    }

    /// Something on: what it is, where it is, and the four things you can
    /// do to it.
    private func videoNow(_ v: WallVideo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(v.title ?? "Video")
                    .font(.ui(16, .medium)).foregroundStyle(ink.ink).lineLimit(2)
                Text(v.error ?? v.words)
                    .font(.ui(13)).foregroundStyle(v.error != nil ? Ink.signal : ink.dim)
            }
            if let of = v.duration, of > 1, ["playing", "paused"].contains(v.status) {
                videoRail(v, of)
            }
            HStack(spacing: 8) {
                if ["playing", "paused"].contains(v.status) {
                    videoKey(v.status == "playing" ? "Pause" : "Play", filled: true) {
                        if VideoSound.shared.started {
                            v.status == "playing" ? VideoSound.shared.pause() : VideoSound.shared.resume()
                        } else {
                            let h = wall.host
                            Task { await WallVideoLink.control(host: h, v.status == "playing" ? "pause" : "play") }
                        }
                        Taps.detent(intensity: 0.4)
                    }
                }
                if v.sound, !v.phoneClock, !VideoSound.shared.started,
                   ["playing", "paused"].contains(v.status) {
                    videoKey("Sound here") { VideoSound.shared.join(v, host: wall.host) }
                }
                videoKey("Stop") {
                    VideoSound.shared.stop()
                    let h = wall.host
                    Task { await WallVideoLink.stop(host: h) }
                    videoLink = ""
                    Taps.commit()
                }
            }
        }
    }

    private func videoKey(_ label: String, filled: Bool = false,
                          _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.ui(14, .medium))
                .foregroundStyle(filled ? Ink.ground : ink.ink)
                .lineLimit(1)
                .padding(.horizontal, 16).frame(height: 40)
                .background(Capsule().fill(filled ? AnyShapeStyle(accent) : AnyShapeStyle(ink.fill)))
        }
        .buttonStyle(PressStyle(scale: 0.95))
    }

    /// Where the video is, and a drag to put it somewhere else.
    private func videoRail(_ v: WallVideo, _ of: Double) -> some View {
        let at = rail(key: "video") ?? v.position
        return VStack(alignment: .leading, spacing: 6) {
            slider(key: "video", value: min(at, of), from: 0, to: of, step: 1) { t in
                if VideoSound.shared.started { VideoSound.shared.seek(to: t) }
                else {
                    let h = wall.host
                    Task { await WallVideoLink.control(host: h, "seek", t: t) }
                }
            }
            HStack {
                Text(WallVideo.clock(at)).font(.machine(11)).foregroundStyle(ink.dim)
                Spacer()
                Text(WallVideo.clock(of)).font(.machine(11)).foregroundStyle(ink.dim)
            }
        }
    }

    private func videoWorking(_ work: (String, Double)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(work.0).font(.ui(13)).foregroundStyle(ink.dim)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(ink.fill).frame(height: 6)
                    Capsule().fill(accent)
                        .frame(width: max(6, geo.size.width * max(0.06, work.1)), height: 6)
                }
            }
            .frame(height: 6)
        }
    }

    private func playVideoLink() {
        let url = videoTyped
        guard videoWork == nil, !url.isEmpty, wall.link.isLive else {
            if !wall.link.isLive { videoProblem = "Connect your wall before sending a video." }
            return
        }
        videoProblem = nil
        VideoSound.shared.stop()
        let h = wall.host, sound = videoSound
        videoTask?.cancel()
        let request = UUID(); videoRequest = request
        videoTask = Task {
            videoWork = ("Handing it to the wall", 0.15)
            let why = await WallVideoLink.start(host: h, url: url, sound: sound)
            guard !Task.isCancelled, videoRequest == request, wall.host == h else { return }
            videoWork = nil
            videoProblem = why
            if why == nil { videoLink = ""; Taps.landed() } else { Taps.error() }
        }
    }

    /// A video out of the library: the picture is made small here, sent up,
    /// and its sound stays on this phone.
    private func sendChosenVideo(_ item: PhotosPickerItem) async {
        guard wall.link.isLive else {
            videoProblem = "Connect your wall before sending a video."
            return
        }
        videoProblem = nil
        videoWork = ("Reading the video", 0)
        guard let movie = try? await item.loadTransferable(type: Movie.self) else {
            guard !Task.isCancelled else { return }
            videoWork = nil
            videoProblem = "That video could not be read."
            Taps.error()
            return
        }
        guard !Task.isCancelled else { return }
        await sendVideoFile(movie.url, title: "From your library")
    }

    private func sendVideoFile(_ file: URL, title: String) async {
        guard !Task.isCancelled, wall.link.isLive, !VideoHandoff.inProgress else {
            videoWork = nil
            videoProblem = VideoHandoff.inProgress ? "Another video is already being sent." : "Connect your wall before sending a video."
            return
        }
        let request = UUID(); videoRequest = request
        let host = wall.host
        VideoSound.shared.stop()
        VideoHandoff.inProgress = true
        defer { VideoHandoff.inProgress = false }
        do {
            _ = try await VideoHandoff.send(file: file, title: title, host: host) { words, fraction in
                Task { @MainActor in
                    guard videoRequest == request, wall.host == host else { return }
                    videoWork = (words, fraction)
                }
            }
            guard !Task.isCancelled, videoRequest == request, wall.host == host else { return }
            videoWork = nil
            Taps.landed()
        } catch {
            guard !Task.isCancelled, videoRequest == request else { return }
            videoWork = nil
            videoProblem = error.localizedDescription
            Taps.error()
        }
    }

    /// A video opened in Tessera from somewhere else lands here.
    private func takeHandedOverVideo() async {
        guard let p = VideoHandoff.arrived, p.kind == "file", let path = p.path else { return }
        VideoHandoff.arrived = nil
        await sendVideoFile(URL(fileURLWithPath: path), title: p.title ?? "Shared with the wall")
    }

    private var designBoard: some View {
        VStack(spacing: gutter) {
            board("Design") {
                Text(wall.state.mode == "clip" ? "A creation in motion." : "Your canvas, in light.")
                    .font(.ui(15)).foregroundStyle(ink.ink)
                Button { onClose(); onStudio() } label: {
                    Label("Open Studio", systemImage: "paintbrush.pointed")
                        .font(.ui(14, .semibold)).foregroundStyle(accent).frame(minHeight: 44)
                }.buttonStyle(PressStyle())
            }
            board("Finish") { finishes }
        }
    }

    /// The three finishes, each shown on what is on the wall right now.
    private var finishes: some View {
        LiveFinishRow(host: wall.host, mode: wall.state.mode, current: wall.state.finish,
                  accent: accent, ink: ink, sleeve: sleeve) { wall.send(["finish": $0]) }
    }

    /// The wall's own two colours, for every face that letters or lights
    /// something: pick them, or let the record choose.
    private var colours: some View {
        // With the album choosing, the bar shows the album's two colours and
        // takes no touches: the choice you could make would not be used.
        let album = wall.state.matchArt
        let art = wall.state.artColors
        let shown = album && art.count >= 2 ? art : [wall.state.color, wall.state.color2]
        return VStack(alignment: .leading, spacing: 10) {
            ColourBar(colours: [
                Binding(get: { Color.wall(hex: shown[0]) },
                        set: { if !album { wall.send(["color": $0.wallHex]) } }),
                Binding(get: { Color.wall(hex: shown[1]) },
                        set: { if !album { wall.send(["color2": $0.wallHex]) } }),
            ], height: 64, stroke: ink.ink.opacity(0.14), enabled: !album,
                       names: ["Primary", "Secondary"])
            Toggle(isOn: Binding(get: { wall.state.matchArt }, set: { wall.send(["match_art": $0]) })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Match album colours").font(.ui(14, .medium)).foregroundStyle(ink.ink)
                    Text(album ? "Colours follow the current sleeve." : "Choose a colour above.")
                        .font(.ui(11)).foregroundStyle(ink.dim)
                }
            }
            .tint(accent)
        }
    }

    // MARK: A rail

    /// Where a rail's thumb is while a finger is on it.
    private func rail(key: String) -> Double? {
        railDrag?.0 == key ? railDrag?.1 : nil
    }

    /// The same rail as the light's, for anything with a range.
    private func slider(key: String, value: Double, from lo: Double, to hi: Double,
                        step: Double, commit: @escaping (Double) -> Void) -> some View {
        let label = ["rpm": "Record speed", "timer_min": "Duration", "lyric_offset": "Timing offset", "video": "Position"][key] ?? "Value"
        return WallValueSlider(value: Binding(get: { rail(key: key) ?? value },
                                             set: { railDrag = (key, $0) }),
                               in: lo...max(lo, hi), step: step, title: label, accent: accent,
                               ink: ink.ink, secondary: ink.dim,
                               format: { number in
                                   switch key {
                                   case "rpm": String(format: "%.1f rpm", number)
                                   case "timer_min": timerLabel(number)
                                   case "lyric_offset": String(format: "%+.2f s", number)
                                   case "video": PlaybackIdentity.clock(number)
                                   default: String(format: "%.1f", number)
                                   }
                               }, onEditingChanged: { editing in
                                   if !editing, let pending = rail(key: key) {
                                       commit(pending); railDrag = nil; Taps.commit()
                                   }
                               }, onCancel: { railDrag = nil })
    }

    private var sleepBoard: some View {
        board("Asleep") {
            HStack(spacing: 8) {
                choice("Wake it", true, false, { _ in wall.send(["mode": "art"]) })
                choice("Leave it", false, true, { _ in onClose() })
            }
        }
    }

    // MARK: Places: three short pills

    private var places: some View {
        HStack(spacing: gutter) {
            place(.palette, "Studio") { onClose(); onStudio() }
            place(.crate, "Archive") { onClose(); onArchive() }
            place(.gear, "Settings") { onClose(); onSetup() }
        }
    }

    private func place(_ g: Glyph, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                GlyphShape(glyph: g, lineWidth: 1.5).frame(width: 16, height: 16).foregroundStyle(ink.ink)
                Text(label).font(.ui(13, .medium)).foregroundStyle(ink.ink)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Slab(radius: 28, ink: ink))
        }
        .buttonStyle(PressStyle(scale: 0.95))
        .accessibilityLabel(label)
    }
}

/// Items in rows that wrap, for the lamp's nine effects.
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}
