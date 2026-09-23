// The iPod.
//
// The whole of the main screen lives in one object: a body the size of an
// iPod classic, a 4:3 screen at the top with what the wall is showing, and
// a click wheel below it. The room's light sits behind the body and never
// touches what is on the screen, so type and glyphs always sit on black or
// on the body's own dark metal, whatever the sleeve is doing.
//
// Proportions come from the classic: the body is 61.8 by 103.5 mm, which at
// this phone's density is 352 by 590 points; the screen is 4:3 and starts
// 30 points down; the wheel is 232 across with an 84 point button in it.
//
// The wheel does what an iPod wheel does. Turning it scrubs the one live
// parameter (light, or speed when the record is spinning), with a detent
// every fifteen degrees. MENU opens the menu and backs out of it. The
// centre button selects, and in Now Playing it changes what the wheel
// scrubs. The bottom key plays and pauses the music, and held for a moment
// it puts the wall to sleep, which is exactly what holding play did.

import MediaPlayer
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

// MARK: - Geometry

enum IPodMetrics {
    static let bodyW: CGFloat = 352
    static let bodyH: CGFloat = 590
    static let bodyRadius: CGFloat = 42
    static let bezel = CGRect(x: 26, y: 28, width: 300, height: 228)
    static let screen = CGRect(x: 31, y: 33, width: 290, height: 218)
    static let wheelCenter = CGPoint(x: 176, y: 420)
    static let wheelR: CGFloat = 116
    static let buttonR: CGFloat = 42
}

// MARK: - The menu

struct IPodItem: Identifiable {
    enum Kind { case action(() -> Void), submenu(IPodPage), toggle(Bool, (Bool) -> Void), pick(Bool, () -> Void) }
    let id: String
    let title: String
    var value: String? = nil
    let kind: Kind
}

enum IPodPage: Equatable {
    case root, speed, effect, colours, finish, timing
    var title: String {
        switch self {
        case .root: "Tessera"
        case .speed: "Speed"
        case .effect: "Lamp"
        case .colours: "Colours"
        case .finish: "Finish"
        case .timing: "Timing"
        }
    }
}

// MARK: - The object

struct IPodView: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    let light: Lighting
    @Binding var dragLight: Double?
    @Binding var touching: Bool
    var onSetup: () -> Void
    var onStudio: () -> Void
    var onCreation: (String) -> Void = { _ in }
    var onArchive: () -> Void
    var onZoom: () -> Void
    var onHintChange: (String) -> Void = { _ in }

    @State private var pages: [IPodPage] = []            // empty = Now Playing
    @State private var selected: [IPodPage: Int] = [:]
    @State private var scrub: Scrub = .light
    @State private var scrubbing: Double? = nil
    @State private var scrubVisible = false
    @State private var scrubHideTask: Task<Void, Never>?
    @State private var editingColour: ColourTarget?
    @State private var showingTime = false
    @State private var beats = BeatBook()
    // Read on appear, never here: this view is made on every evaluation of
    // the screen above it, and a system player read is an XPC call.
    @State private var playing = false
    @AppStorage("lyrics.nudge") private var lyricsNudge: Double = 0
    @AppStorage("spin.beat") private var beatOn = false

    private enum Scrub { case light, speed }
    private enum ColourTarget: String, Identifiable {
        case first, second
        var id: String { rawValue }
        var title: String { self == .first ? "Lamp colour" : "Second colour" }
    }
    private var page: IPodPage? { pages.last }
    private var accent: Color { light.steadyAccent }

    var body: some View {
        ZStack(alignment: .topLeading) {
            IPodBody()
            screen
                .frame(width: IPodMetrics.screen.width, height: IPodMetrics.screen.height)
                .clipShape(RoundedRectangle(cornerRadius: Round.chip, style: .continuous))
                .offset(x: IPodMetrics.screen.minX, y: IPodMetrics.screen.minY)
            HStack(spacing: 6) {
                Circle().fill(accent.toned(forDark: true)).frame(width: 3, height: 3)
                Text("TESSERA").font(.custom(Face.displayMid, fixedSize: 9)).tracking(2.6)
                    .foregroundStyle(Ink.ink.opacity(0.65))
            }
            .frame(width: IPodMetrics.bodyW, height: 28)
            .offset(y: 264)
            .accessibilityHidden(true)
            ClickWheel(
                accent: accent,
                accessibilityValue: wheelDescription,
                onTurn: { turn($0) },
                onMenu: { menu() },
                onSelect: { select() },
                onPrev: { skip(previous: true) },
                onNext: { skip(previous: false) },
                onPlay: { togglePlay() },
                onHoldPlay: { wall.send(["mode": wall.state.mode == "off" ? "art" : "off"]); Taps.found() },
                onTouch: { active, cancelled in
                    touching = active
                    if active { scrubHideTask?.cancel() }
                    else { finishScrub(commit: !cancelled) }
                }
            )
            .frame(width: IPodMetrics.wheelR * 2, height: IPodMetrics.wheelR * 2)
            .offset(x: IPodMetrics.wheelCenter.x - IPodMetrics.wheelR,
                    y: IPodMetrics.wheelCenter.y - IPodMetrics.wheelR)
        }
        .frame(width: IPodMetrics.bodyW, height: IPodMetrics.bodyH)
        .onReceive(NotificationCenter.default.publisher(for: .MPMusicPlayerControllerPlaybackStateDidChange)) { _ in
            playing = MPMusicPlayerController.systemMusicPlayer.playbackState == .playing
        }
        .onAppear {
            MPMusicPlayerController.systemMusicPlayer.beginGeneratingPlaybackNotifications()
            playing = MPMusicPlayerController.systemMusicPlayer.playbackState == .playing
            beats.retune(title: wall.state.title, artist: wall.state.artist)
            #if DEBUG
            if CommandLine.arguments.contains("-ipod-menu") { pages = [.root] }
            if CommandLine.arguments.contains("-ipod-colour") { editingColour = .first }
            #endif
        }
        .onDisappear {
            MPMusicPlayerController.systemMusicPlayer.endGeneratingPlaybackNotifications()
            finishScrub(commit: false)
            scrubHideTask?.cancel()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { finishScrub(commit: false) }
        }
        .onChange(of: wall.state.mode) { _, mode in
            if mode != "cd" { scrub = .light }
            finishScrub(commit: false)
        }
        .onChange(of: wall.state.title) {
            beats.retune(title: wall.state.title, artist: wall.state.artist)
        }
        .onChange(of: wheelHint, initial: true) { _, hint in onHintChange(hint) }
        .onChange(of: beats.phase) {
            guard beatOn, wall.state.mode == "cd", scenePhase == .active else { return }
            if case .locked(let reading) = beats.phase { wall.send(["rpm": reading.rpm]) }
        }
        .sheet(isPresented: $showingTime) { TimePage(accent: accent).environment(wall) }
        .sheet(item: $editingColour) { target in
            ColourSheet(colour: colourBinding(target), title: target.title)
        }
    }

    // MARK: - Screen

    @ViewBuilder private var screen: some View {
        ZStack {
            IPodLCD.paper
            if let page {
                IPodMenuView(
                    title: page.title,
                    items: items(for: page),
                    selected: selected[page] ?? 0,
                    accent: accent,
                    onTap: { i in selected[page] = i; select() }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                NowPlayingScreen(
                    state: wall.state,
                    reading: light.reading,
                    duty: dragLight ?? wall.state.brightness,
                    playing: playing,
                    link: wall.link,
                    scrub: scrubLabel,
                    scrubValue: scrubValue,
                    showScrub: scrubbing != nil || scrubVisible,
                    accent: accent,
                    onTapWall: onZoom
                )
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .dynamicTypeSize(.large)
        .overlay {
            RoundedRectangle(cornerRadius: Round.chip, style: .continuous)
                .strokeBorder(Color.black.opacity(0.24), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .animation(reducedMotion ? nil : Motion.settle, value: pages)
    }

    private var scrubLabel: String {
        switch scrub {
        case .light: "LIGHT"
        case .speed: "SPEED"
        }
    }

    private var scrubValue: (Double, String) {
        switch scrub {
        case .light:
            let v = dragLight ?? wall.state.brightness
            return ((v - 0.05) / 0.95, "\(Int(v * 100))%")
        case .speed:
            let v = scrubbing ?? wall.state.rpm
            return (min(1, (v - 0.5) / 44.5), String(format: "%.1f rpm", v))
        }
    }

    // MARK: - Wheel

    private func turn(_ step: Int) {
        if let page {
            let n = items(for: page).count
            guard n > 0 else { return }
            let cur = selected[page] ?? 0
            let next = min(n - 1, max(0, cur + step))
            if next != cur {
                selected[page] = next
                Taps.detent(intensity: 0.45)
            }
            return
        }
        // Now Playing: the wheel scrubs the live parameter, in detents.
        switch scrub {
        case .light:
            let cur = scrubbing ?? wall.state.brightness
            let v = min(1.0, max(0.05, ((cur + Double(step) * 0.05) / 0.05).rounded() * 0.05))
            guard v != cur else { return }
            scrubbing = v
            dragLight = v
            Taps.detent(intensity: 0.25 + 0.45 * v)
        case .speed:
            let cur = scrubbing ?? wall.state.rpm
            let v = min(45.0, max(0.5, cur + Double(step) * 0.5))
            guard v != cur else { return }
            scrubbing = v
            beatOn = false
            Taps.detent(intensity: 0.5)
        }
        showScrubBriefly()
    }

    private func menu() {
        Taps.press()
        if pages.isEmpty {
            pages = [.root]
            if selected[.root] == nil { selected[.root] = 0 }
        } else {
            pages.removeLast()
        }
    }

    private func select() {
        guard let page else {
            // In Now Playing the centre button changes what the wheel does,
            // the way it walked the scrub bar on the classic.
            if wall.state.mode == "cd" {
                scrub = scrub == .light ? .speed : .light
                showScrubBriefly()
                Taps.detent(intensity: 0.5)
            } else {
                pages = [.root]
            }
            return
        }
        let list = items(for: page)
        guard !list.isEmpty else { return }
        let item = list[min(list.count - 1, selected[page] ?? 0)]
        switch item.kind {
        case .action(let run):
            run()
        case .submenu(let sub):
            pages.append(sub)
            if selected[sub] == nil { selected[sub] = 0 }
        case .toggle(let on, let set):
            set(!on)
        case .pick(_, let run):
            run()
            pages.removeLast()
        }
        Taps.commit()
    }

    private func togglePlay() {
        let m = MPMusicPlayerController.systemMusicPlayer
        if playing { m.pause() } else {
            StandIn.requestMusicAccess {
                guard MPMediaLibrary.authorizationStatus() == .authorized,
                      m.nowPlayingItem != nil else { return }
                m.play()
            }
        }
    }

    private var wheelDescription: String {
        if let page {
            let entries = items(for: page)
            let index = min(max(0, selected[page] ?? 0), max(0, entries.count - 1))
            return entries.isEmpty ? page.title : "\(page.title). \(entries[index].title). \(index + 1) of \(entries.count)."
        }
        return "\(scrub == .light ? "Brightness" : "Speed"), \(scrubValue.1)"
    }

    private var wheelHint: String {
        if page != nil { return "Turn to browse · press centre to choose" }
        if wall.state.mode == "off" { return "Hold play to wake the wall" }
        return scrub == .speed ? "Turn the wheel to change the speed" : "Turn the wheel to change the light"
    }

    private var beatDescription: String {
        guard beatOn else { return "off" }
        switch beats.phase {
        case .listening: return "listening"
        case .locked(let reading): return "\(Int(reading.bpm.rounded())) bpm"
        case .missed: return "try again"
        case .idle: return "ready"
        }
    }

    private func skip(previous: Bool) {
        guard MPMediaLibrary.authorizationStatus() == .authorized else { return }
        let player = MPMusicPlayerController.systemMusicPlayer
        if previous { player.skipToPreviousItem() } else { player.skipToNextItem() }
        Taps.commit()
    }

    private func showScrubBriefly() {
        scrubVisible = true
        scrubHideTask?.cancel()
        scrubHideTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(1.6)) } catch { return }
            guard !Task.isCancelled else { return }
            scrubVisible = false
        }
    }

    private func finishScrub(commit: Bool) {
        if commit, let value = scrubbing {
            wall.send(scrub == .light ? ["brightness": value] : ["rpm": value])
            Taps.commit()
            showScrubBriefly()
        } else if !commit {
            scrubHideTask?.cancel()
            scrubVisible = false
        }
        touching = false
        dragLight = nil
        scrubbing = nil
    }

    private func colourBinding(_ target: ColourTarget) -> Binding<Color> {
        Binding(get: {
            Color(wallHex: target == .first ? wall.state.color : wall.state.color2) ?? Ink.tile
        }, set: { colour in
            var change: [String: Any] = [target == .first ? "color" : "color2": colour.wallHex,
                                          "match_art": false]
            if wall.state.effect == "rainbow" { change["effect"] = "solid" }
            wall.send(change)
        })
    }

    // MARK: - Items

    private func mode(_ id: String, _ title: String) -> IPodItem {
        IPodItem(id: id, title: title, value: wall.state.mode == id ? "on" : nil,
                 kind: .action { wall.send(["mode": id]); pages = [] })
    }

    private func items(for page: IPodPage) -> [IPodItem] {
        let s = wall.state
        switch page {
        case .root:
            var out: [IPodItem] = [
                IPodItem(id: "now", title: "Now Playing", kind: .action { pages = [] }),
                mode("art", "Art"), mode("cd", "Spin"), mode("lyrics", "Lyrics"), mode("nine", "Nine"),
                mode("ambient", "Lamp"),
                IPodItem(id: "time", title: "Time & alarms", value: s.mode == "clock" || s.mode == "timer" ? "on" : nil, kind: .action { showingTime = true }),
                mode("off", "Off"),
            ]
            switch s.mode {
            case "cd":
                out.append(IPodItem(id: "speed", title: "Speed", value: String(format: "%.1f", s.rpm), kind: .submenu(.speed)))
            case "ambient":
                out.append(IPodItem(id: "effect", title: "Lamp", value: s.effect, kind: .submenu(.effect)))
                out.append(IPodItem(id: "colours", title: "Colours", kind: .submenu(.colours)))
                out.append(IPodItem(id: "match", title: "Album colours", value: s.matchArt ? "on" : "off",
                                    kind: .toggle(s.matchArt) { wall.send(["match_art": $0]) }))
            case "art":
                out.append(IPodItem(id: "finish", title: "Finish", value: s.finish, kind: .submenu(.finish)))
            case "lyrics":
                out.append(IPodItem(id: "timing", title: "Timing", value: wall.state.lyricOffset == 0.2 ? "on time" : wall.state.lyricOffset < 0.2 ? "later" : "sooner", kind: .submenu(.timing)))
            default: break
            }
            out.append(IPodItem(id: "ticker", title: "Ticker", kind: .action { onCreation("ticker") }))
            out.append(IPodItem(id: "video", title: "Video", kind: .action { onCreation("video") }))
            out.append(IPodItem(id: "studio", title: "Studio", kind: .action { onStudio() }))
            out.append(IPodItem(id: "archive", title: "Archive", kind: .action { onArchive() }))
            out.append(IPodItem(id: "settings", title: "Settings", kind: .action { onSetup() }))
            return out
        case .speed:
            return [("33⅓ rpm", 33.333), ("45 rpm", 45.0), ("Slow · 7½ rpm", 7.5)].enumerated().map { i, option in
                IPodItem(id: "sp\(i)", title: option.0,
                         kind: .pick(!beatOn && abs(s.rpm - option.1) < 0.2) {
                    beatOn = false
                    wall.send(["rpm": option.1])
                })
            } + [IPodItem(id: "free", title: "Adjust with wheel", kind: .action {
                pages = []
                scrub = .speed
                showScrubBriefly()
            }), IPodItem(id: "beat", title: "Spin on the beat", value: beatDescription,
                        kind: .toggle(beatOn) { enabled in
                beatOn = enabled
                if enabled { beats.measure(title: s.title, artist: s.artist) }
            })]
        case .effect:
            return ["plaid", "weave", "deco", "snake", "solid", "breathe", "pulse", "rainbow", "gradient"].map { e in
                IPodItem(id: e, title: e == "gradient" ? "Fade" : e.capitalized, value: s.effect == e ? "on" : nil,
                         kind: .pick(s.effect == e) { wall.send(["effect": e]) })
            }
        case .colours:
            return [IPodItem(id: "c1", title: "Colour", value: s.color, kind: .action { editingColour = .first }),
                    IPodItem(id: "c2", title: "Second colour", value: s.color2, kind: .action { editingColour = .second }),
                    IPodItem(id: "match", title: "Album colours", kind: .toggle(s.matchArt) { wall.send(["match_art": $0]) })]
        case .finish:
            return [("clean", "Clean"), ("dither", "Dither"), ("poster", "Poster")].map { f in
                IPodItem(id: f.0, title: f.1, value: s.finish == f.0 ? "on" : nil,
                         kind: .pick(s.finish == f.0) { wall.send(["finish": f.0]) })
            }
        case .timing:
            return [("Later", -0.4), ("On time", 0.2), ("Sooner", 0.8)].map { o in
                IPodItem(id: o.0, title: o.0, value: wall.state.lyricOffset == o.1 ? "on" : nil,
                         kind: .pick(wall.state.lyricOffset == o.1) { lyricsNudge = o.1; wall.send(["lyric_offset": o.1]) })
            }
        }
    }
}

// MARK: - Body

/// The metal. Matte, near-black, one soft vertical gradient so it reads as a
/// surface and not a fill, a hairline rim, and the screen's black bezel.
struct IPodBody: View {
    /// The Blender render of the front, when the bundle has it. Points map
    /// to pixels one to one at 2x, so the screen and wheel land where the
    /// live overlays expect them.
    static let rendered: UIImage? = UIImage(named: "IPodFront")

    var body: some View {
        if let img = Self.rendered {
            Image(uiImage: img)
                .resizable()
                .interpolation(.high)
                .frame(width: IPodMetrics.bodyW, height: IPodMetrics.bodyH)
                .shadow(color: .black.opacity(0.55), radius: 30, y: 18)
        } else {
            drawn
        }
    }

    private var drawn: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: IPodMetrics.bodyRadius, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x1C1A17), Color(hex: 0x121110), Color(hex: 0x0F0E0C)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: IPodMetrics.bodyRadius, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.04), Color.white.opacity(0.08)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1)
            // the bezel: a black plate the screen sits in, with a lip
            RoundedRectangle(cornerRadius: Round.control, style: .continuous)
                .fill(Color.black)
                .frame(width: IPodMetrics.bezel.width, height: IPodMetrics.bezel.height)
                .overlay {
                    RoundedRectangle(cornerRadius: Round.control, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.6), radius: 1, y: 1)
                .offset(x: IPodMetrics.bezel.minX, y: IPodMetrics.bezel.minY)
        }
        .frame(width: IPodMetrics.bodyW, height: IPodMetrics.bodyH)
        .shadow(color: .black.opacity(0.55), radius: 30, y: 18)
    }
}

// MARK: - Click wheel

struct ClickWheel: View {
    let accent: Color
    var drawn: Bool = IPodBody.rendered == nil
    var accessibilityValue: String
    var onTurn: (Int) -> Void
    var onMenu: () -> Void
    var onSelect: () -> Void
    var onPrev: () -> Void
    var onNext: () -> Void
    var onPlay: () -> Void
    var onHoldPlay: () -> Void
    var onTouch: (Bool, Bool) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var interaction = IPodWheelInteraction()
    @State private var holdTask: Task<Void, Never>?
    @State private var pressed: IPodWheelInteraction.Sector?
    @FocusState private var focused: Bool

    private let r = IPodMetrics.wheelR
    private let br = IPodMetrics.buttonR
    private var highlight: Color { accent.toned(forDark: true) }

    var body: some View {
        ZStack {
            if drawn {
                Circle().fill(RadialGradient(colors: [Color(hex: 0x1A1816), Color(hex: 0x292623)],
                                              center: .center, startRadius: br, endRadius: r))
                Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }
            Circle().strokeBorder(highlight.opacity(focused ? 0.85 : 0), lineWidth: 2)
                .padding(3)
            Text("MENU")
                .font(.custom(Face.displayMid, fixedSize: 11)).tracking(1.3)
                .foregroundStyle(pressed == .top ? highlight : Ink.ink.opacity(0.85))
                .offset(y: -(r - 25))
            wheelSymbol("backward.end.fill", sector: .left).offset(x: -(r - 25))
            wheelSymbol("forward.end.fill", sector: .right).offset(x: r - 25)
            Image(systemName: "playpause.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(pressed == .bottom ? highlight : Ink.ink.opacity(0.85))
                .offset(y: r - 25)
            centerButton
        }
        .frame(width: r * 2, height: r * 2)
        .contentShape(Circle())
        .overlay {
            WheelTouches(radius: r,
                         onDown: { began(at: $0) },
                         onMove: { moved(to: $0) },
                         onUp: { point, cancelled in ended(at: point, cancelled: cancelled) })
                .accessibilityHidden(true)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { accessibleTurn(-1); return .handled }
        .onKeyPress(.downArrow) { accessibleTurn(1); return .handled }
        .onKeyPress(.leftArrow) { onMenu(); return .handled }
        .onKeyPress(.rightArrow) { onSelect(); return .handled }
        .onKeyPress(.return) { onSelect(); return .handled }
        .onKeyPress(.space) { onPlay(); return .handled }
        .onKeyPress(.escape) { onMenu(); return .handled }
        .animation(reducedMotion ? nil : Motion.blink, value: pressed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Click wheel")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Adjust to turn the wheel. Activate to select. More actions include Menu and playback controls.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: accessibleTurn(1)
            case .decrement: accessibleTurn(-1)
            @unknown default: break
            }
        }
        .accessibilityAction { onSelect() }
        .accessibilityAction(named: "Menu or back") { onMenu() }
        .accessibilityAction(named: "Select") { onSelect() }
        .accessibilityAction(named: "Previous track") { onPrev() }
        .accessibilityAction(named: "Next track") { onNext() }
        .accessibilityAction(named: "Play or pause") { onPlay() }
        .accessibilityAction(named: "Sleep or wake the wall") { onHoldPlay() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancel() }
        }
        .onDisappear { cancel() }
    }

    private var centerButton: some View {
        Circle()
            .fill(drawn ? Color(hex: 0x181613) : Color.white.opacity(pressed == .center ? 0.09 : 0.015))
            .frame(width: br * 2, height: br * 2)
            .overlay { Circle().strokeBorder(Color.white.opacity(pressed == .center ? 0.3 : 0.09), lineWidth: 1) }
            .overlay {
                Circle().fill(highlight.opacity(pressed == .center ? 0.95 : 0.38))
                    .frame(width: 5, height: 5)
            }
            .scaleEffect(reducedMotion ? 1 : pressed == .center ? 0.97 : 1)
    }

    private func wheelSymbol(_ name: String, sector: IPodWheelInteraction.Sector) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(pressed == sector ? highlight : Ink.ink.opacity(0.85))
    }

    private func accessibleTurn(_ step: Int) {
        onTouch(true, false)
        onTurn(step)
        onTouch(false, false)
    }

    private func began(at point: CGPoint) {
        guard interaction.begin(x: point.x - r, y: point.y - r) else { return }
        onTouch(true, false)
        Taps.warm()
        pressed = interaction.startSector
        holdTask?.cancel()
        if interaction.canHold {
            holdTask = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
                guard !Task.isCancelled, scenePhase == .active, interaction.hold() else { return }
                onHoldPlay()
            }
        }
    }

    private func moved(to point: CGPoint) {
        let steps = interaction.move(x: point.x - r, y: point.y - r)
        if !interaction.canHold { holdTask?.cancel() }
        if interaction.moved >= 8 { pressed = nil }
        if steps != 0 { onTurn(steps) }
    }

    private func ended(at point: CGPoint, cancelled: Bool) {
        guard interaction.isActive else { return }
        holdTask?.cancel()
        let sector = interaction.end(x: point.x - r, y: point.y - r, cancelled: cancelled)
        pressed = nil
        // A cancelled touch drops the preview; it never writes to the wall.
        onTouch(false, cancelled)
        switch sector {
        case .center: onSelect()
        case .top: onMenu()
        case .left: onPrev()
        case .right: onNext()
        case .bottom: onPlay()
        case nil: break
        }
    }

    private func cancel() {
        holdTask?.cancel()
        holdTask = nil
        let wasActive = interaction.isActive
        interaction.cancel()
        pressed = nil
        if wasActive { onTouch(false, true) }
    }
}

// MARK: - Touches for the wheel

struct WheelTouches: UIViewRepresentable {
    let radius: CGFloat
    var onDown: (CGPoint) -> Void
    var onMove: (CGPoint) -> Void
    var onUp: (CGPoint, Bool) -> Void

    func makeUIView(context: Context) -> WheelTouchView {
        let view = WheelTouchView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = false
        return view
    }

    func updateUIView(_ view: WheelTouchView, context: Context) {
        view.radius = radius
        view.onDown = onDown
        view.onMove = onMove
        view.onUp = onUp
    }

    static func dismantleUIView(_ view: WheelTouchView, coordinator: ()) {
        view.cancelTrackingWheel()
        view.onDown = nil
        view.onMove = nil
        view.onUp = nil
    }
}

final class WheelTouchView: UIControl {
    var radius: CGFloat = 0
    var onDown: ((CGPoint) -> Void)?
    var onMove: ((CGPoint) -> Void)?
    var onUp: ((CGPoint, Bool) -> Void)?
    private let touch = ImmediateTouch()
    private var suspendedPans: [(recognizer: UIPanGestureRecognizer, enabled: Bool)] = []
    private var trackingWheel = false
    private var lastPoint = CGPoint.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        touch.cancelsTouchesInView = false
        touch.addTarget(self, action: #selector(handle(_:)))
        addGestureRecognizer(touch)
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        hypot(point.x - bounds.midX, point.y - bounds.midY) <= radius
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelTrackingWheel() }
    }

    func cancelTrackingWheel() {
        restoreScrolling()
        guard trackingWheel else { return }
        trackingWheel = false
        onUp?(lastPoint, true)
        touch.isEnabled = false
        touch.isEnabled = true
    }

    private func suspendScrolling() {
        restoreScrolling()
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView {
                let pan = scroll.panGestureRecognizer
                suspendedPans.append((pan, pan.isEnabled))
                pan.isEnabled = false
            }
            ancestor = view.superview
        }
    }

    private func restoreScrolling() {
        let pans = suspendedPans
        suspendedPans.removeAll()
        for pan in pans { pan.recognizer.isEnabled = pan.enabled }
    }

    @objc private func handle(_ gesture: UIGestureRecognizer) {
        let point = gesture.location(in: self)
        lastPoint = point
        switch gesture.state {
        case .began:
            trackingWheel = true
            suspendScrolling()
            onDown?(point)
        case .changed:
            guard trackingWheel else { return }
            onMove?(point)
        case .ended, .cancelled, .failed:
            restoreScrolling()
            guard trackingWheel else { return }
            trackingWheel = false
            onUp?(point, gesture.state != .ended)
        default: break
        }
    }
}

final class ImmediateTouch: UIGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if state == .possible { state = .began }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        if state == .began || state == .changed { state = .changed }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        state = .cancelled
    }
}

// MARK: - Now Playing

private enum IPodLCD {
    static let paper = Color(hex: 0xEAE6D9)
    static let ink = Color(hex: 0x242B2A)
    static let secondary = Color(hex: 0x59625D)
    static let rule = Color(hex: 0xB9BDB0)
    static let header = Color(hex: 0xD7DCCC)
}

struct NowPlayingScreen: View {
    let state: WallState
    let reading: FrameReading
    let duty: Double
    let playing: Bool
    let link: LinkState
    let scrub: String
    let scrubValue: (Double, String)
    let showScrub: Bool
    let accent: Color
    var onTapWall: () -> Void

    private var song: PlaybackIdentity { PlaybackIdentity(state: state, link: link) }

    var body: some View {
        VStack(spacing: 0) {
            StatusStrip(title: song.statusLabel, symbol: song.statusSymbol, link: link)
            HStack(alignment: .top, spacing: 11) {
                Button(action: onTapWall) {
                    PanelCanvas(px: reading.px, duty: duty)
                        .frame(width: 130, height: 130)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(.black.opacity(0.15), lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("The wall. Opens large.")
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title)
                        .font(.custom(Face.displayMid, fixedSize: 17))
                        .tracking(-0.3)
                        .foregroundStyle(IPodLCD.ink)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if song.hasSong, !song.artist.isEmpty {
                        Text(song.artist)
                            .font(.custom(Face.uiMedium, fixedSize: 12))
                            .foregroundStyle(IPodLCD.ink)
                            .lineLimit(2)
                    }
                    if song.hasSong, !song.album.isEmpty {
                        Text(song.album)
                            .font(.custom(Face.ui, fixedSize: 10))
                            .foregroundStyle(IPodLCD.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    HStack(spacing: 4) {
                        Image(systemName: state.mode == "off" ? "moon.zzz.fill" : "square.grid.3x3.fill")
                            .font(.system(size: 7, weight: .semibold))
                        Text(modeWord.uppercased())
                            .font(.custom(Face.mono, fixedSize: 8)).tracking(0.5)
                    }
                    .foregroundStyle(IPodLCD.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 130)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(song.accessibilitySummary + ". Wall mode: " + modeWord)
            }
            .padding(.horizontal, 11)
            .padding(.top, 10)
            Spacer(minLength: 4)
            bar.padding(.horizontal, 11).padding(.bottom, 10)
        }
        .background(IPodLCD.paper)
    }

    private var modeWord: String {
        switch state.mode {
        case "cd": "spinning"
        case "ambient": "lamp"
        case "lyrics": "lyrics"
        case "nine": "nine"
        case "clock": "clock"
        case "timer": "timer"
        case "off": "asleep"
        case "weather": "weather"
        case "frame": "drawing"
        case "clip": "clip"
        case "video": "video"
        case "game": "game"
        case "imagine": "imagine"
        case "ticker": "lettering"
        default: "art"
        }
    }

    @ViewBuilder private var bar: some View {
        if showScrub {
            VStack(spacing: 5) {
                HStack {
                    Text(scrub).tracking(1)
                    Spacer()
                    Text(scrubValue.1).monospacedDigit()
                }
                .font(.custom(Face.mono, fixedSize: 9))
                .foregroundStyle(IPodLCD.ink)
                ScreenRule(fraction: scrubValue.0, tint: IPodLCD.ink)
            }
            .accessibilityElement(children: .combine)
        } else if song.hasSong {
            PlaybackProgress(state: state, link: link, accent: IPodLCD.ink,
                             secondary: IPodLCD.secondary, compact: true)
        } else {
            Text(song.context)
                .font(.custom(Face.ui, fixedSize: 11))
                .foregroundStyle(IPodLCD.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct StatusStrip: View {
    let title: String
    var symbol: String? = nil
    var link: LinkState? = nil
    var count: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            }
            Text(title).font(.custom(Face.uiSemibold, fixedSize: 11)).lineLimit(1)
            Spacer(minLength: 4)
            if let count {
                Text(count).font(.custom(Face.mono, fixedSize: 9)).monospacedDigit()
                    .foregroundStyle(IPodLCD.secondary)
            }
            if let link {
                Image(systemName: link.isLive ? "wifi" : link.isStandIn ? "iphone" : "wifi.slash")
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityLabel(link.isLive ? "Wall connected" : link.isStandIn ? "Phone preview" : "Wall disconnected")
            }
        }
        .foregroundStyle(IPodLCD.ink)
        .padding(.horizontal, 11)
        .frame(height: 28)
        .background(IPodLCD.header.gradient)
        .overlay(alignment: .bottom) { Rectangle().fill(IPodLCD.rule).frame(height: 1) }
    }
}

struct ScreenRule: View {
    let fraction: Double
    let tint: Color
    var body: some View {
        GeometryReader { geometry in
            let count = 36
            let cell = geometry.size.width / CGFloat(count)
            let valid = fraction.isFinite ? max(0, min(1, fraction)) : 0
            let filled = Int((valid * Double(count)).rounded())
            HStack(spacing: cell * 0.35) {
                ForEach(0..<count, id: \.self) { index in
                    Rectangle().fill(index < filled ? tint : tint.opacity(0.17))
                        .frame(width: cell * 0.65)
                }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

// MARK: - Menu

struct IPodMenuView: View {
    let title: String
    let items: [IPodItem]
    let selected: Int
    let accent: Color
    var onTap: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    var body: some View {
        VStack(spacing: 0) {
            StatusStrip(title: title, symbol: title == "Tessera" ? "square.grid.3x3.fill" : "chevron.left",
                        count: "\(min(selected + 1, items.count))/\(items.count)")
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            row(item, selected: index == selected) { onTap(index) }.id(index)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onAppear { proxy.scrollTo(selected, anchor: .center) }
                .onChange(of: selected) { _, next in
                    withAnimation(reducedMotion ? nil : Motion.blink) { proxy.scrollTo(next, anchor: .center) }
                }
            }
        }
        .background(IPodLCD.paper)
    }

    private func row(_ item: IPodItem, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(item.title)
                    .font(.custom(selected ? Face.uiSemibold : Face.ui, fixedSize: 14))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let value = item.value, value != "on", value != "off" {
                    Text(value)
                        .font(.custom(Face.ui, fixedSize: 10))
                        .lineLimit(1)
                        .foregroundStyle(selected ? IPodLCD.paper.opacity(0.82) : IPodLCD.secondary)
                }
                trailing(item, selected: selected)
            }
            .foregroundStyle(selected ? IPodLCD.paper : IPodLCD.ink)
            .padding(.horizontal, 11)
            .frame(height: 44)
            .background(selected ? IPodLCD.ink : .clear)
            .overlay(alignment: .leading) {
                if selected { Rectangle().fill(accent.toned(forDark: true)).frame(width: 3) }
            }
            .overlay(alignment: .bottom) {
                if !selected { Rectangle().fill(IPodLCD.rule.opacity(0.35)).frame(height: 0.5).padding(.leading, 11) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(accessibilityValue(item))
    }

    @ViewBuilder private func trailing(_ item: IPodItem, selected: Bool) -> some View {
        switch item.kind {
        case .submenu:
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
        case .toggle(let on, _):
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14, weight: .medium))
        case .pick(let on, _):
            Image(systemName: on ? "checkmark" : "circle")
                .font(.system(size: on ? 12 : 5, weight: .semibold))
                .opacity(on ? 1 : 0.35)
        case .action:
            if item.value == "on" {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
            } else {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).opacity(0.6)
            }
        }
    }

    private func accessibilityValue(_ item: IPodItem) -> String {
        switch item.kind {
        case .toggle(let on, _): return on ? "On" : "Off"
        case .pick(let on, _): return on ? "Current setting" : ""
        default: return item.value ?? ""
        }
    }
}
