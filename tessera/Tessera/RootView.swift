// The app is one room with two things in it: the wall, and what the wall has
// worn. Both pages remain available through the labeled navigation dock or a
// horizontal swipe, while panel gestures keep ownership of their touches.
//
// The room is computed here rather than inside a screen, because the light is
// a property of the app, not of a page. Both screens sit in it.

import SwiftUI

/// Everything derived from the frame currently on the wall. Computed once and
/// handed down, so the two screens are lit by exactly the same light.
struct Lighting {
    let reading: FrameReading
    let accent: Color
    let duty: Double
    let isOff: Bool
    /// Held steady rather than read per frame; see RootView.
    let palette: [Color]

    /// How much light is actually in the room. Everything visual scales by
    /// this, so the phone dims as the wall dims and goes dark when it does.
    var room: Double { isOff ? 0 : reading.lit * duty }
    /// The accent, also held steady, so nothing tinted by it can strobe.
    var steadyAccent: Color { palette.first ?? accent }
    /// How bright the room reads: the lead colour's luminance times how much
    /// light is in the room. Past a threshold, ink on the room goes dark.
    var roomBright: Bool {
        guard room > 0.45, let c = UIColor(steadyAccent).cgColor.components, c.count >= 3 else { return false }
        let lum = 0.2126 * Double(c[0]) + 0.7152 * Double(c[1]) + 0.0722 * Double(c[2])
        return lum * room > 0.42
    }
    var chrome: Color { roomBright ? Ink.ground : litInk }
    var chromeDim: Color { roomBright ? Ink.ground.opacity(0.62) : litDim }
    var litInk: Color { Ink.ink.lit(by: accent, 0.20 * room) }
    var litDim: Color { Ink.dim.lit(by: accent, 0.16 * room) }
}

struct RootView: View {
    @Environment(WallSession.self) private var wall

    @State private var page: Int? = 0
    /// One list of what the wall has worn, shared: the Archive shows it as a
    /// grid, and the panel scrubs through it. Two fetches of the same journal
    /// would be two slightly different pasts.
    @State private var worn = ArchiveStore()
    @State private var dragLight: Double? = nil
    /// A finger is on the panel. The pager stops listening while that is
    /// true, because a sideways pull on the wall is aimed at the wall.
    @State private var onPanel = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var arrival: Double = 0
    @State private var lastTitle = ""
    @State private var router = HomeRouter()
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage("onboarding.again") private var onboardingAgain = false
    @AppStorage("intro.replay") private var replay = false
    /// The room's colours, held steady. Reading them straight from the frame
    /// meant rainbow and the pattern modes strobed the whole interface: the
    /// swatches, the glyph rings and the background all chased the hue. The
    /// room updates its colour a few times a minute, like a room.
    @State private var stablePalette: [Color] = []
    @State private var paletteAt: Date = .distantPast
    /// A screen has something over the whole of itself (a board, an
    /// opening): the page marks step out of the way rather than sit on it.
    @State private var marksHidden = false
    /// The Record sting as the opening, laid over everything until it is
    /// done; see StingOpening.swift. Off unless Settings chose it.
    @AppStorage("intro.style") private var introStyle = "sting"
    @State private var sting: StingPhase = {
        // once, for phones that had the film or the mark saved: this build's
        // opening is the sting; Settings still offers the others
        let d = UserDefaults.standard
        if !d.bool(forKey: "intro.sting.migrated") {
            d.set(true, forKey: "intro.sting.migrated")
            if !StingFilm.styles.contains(d.string(forKey: "intro.style") ?? "") { d.set("sting", forKey: "intro.style") }
        }
        return StingFilm.plays(d.string(forKey: "intro.style") ?? "sting") ? .film : .done
    }()
    @State private var stingKey = 0
    /// The glitch-in's progress; 1 whenever no opening is running.
    @State private var glitch: Double = 1

    private var duty: Double { dragLight ?? wall.state.brightness }
    private var isOff: Bool { wall.state.mode == "off" }

    private var lighting: Lighting {
        let reading = FrameRenderer.read(wall.frame)
        // the room's own colours, from the same reading its light is poured
        // from, before the brain's colour or the histogram: what the
        // background looks like is what everything is tinted with
        let room = Room.palette(reading.px)
        let accent: Color = {
            if let c = room?.first { return c }
            if let hex = wall.state.artColors.first, let c = Color(wallHex: hex) { return c }
            // the sleeve's own palette before the app's amber: a grey sleeve
            // lends grey, and only a dark wall lends nothing
            return reading.palette.first ?? reading.glow
        }()
        return Lighting(reading: reading, accent: accent, duty: duty, isOff: isOff,
                        palette: stablePalette.isEmpty ? (room ?? reading.palette) : stablePalette)
    }

    var body: some View {
        let light = lighting
        @Bindable var routes = router

        ZStack(alignment: .bottom) {
            Room(
                palette: light.isOff ? [] : light.palette,
                px: light.isOff ? nil : light.reading.px,
                light: light.room,
                surge: arrival
            )

            // A paging scroll view rather than TabView(.page): the panel has
            // its own sideways gesture now, and this is the only pager that
            // can be told to stand down while a finger is on it.
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    WallScreen(
                        light: light,
                        dragLight: $dragLight,
                        onPanel: $onPanel,
                        onSetup: { router.present(.settings) },
                        onStudio: { router.present(.studio) },
                        onArchive: { selectPage(1) }
                    )
                    .containerRelativeFrame(.horizontal)
                    .id(0)
                    ArchiveScreen(accent: light.steadyAccent)
                        .containerRelativeFrame(.horizontal)
                        .id(1)
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $page)
            .scrollIndicators(.hidden)
            .scrollDisabled(onPanel)
            .ignoresSafeArea(edges: .horizontal)
            // after the sting in the room, the room's picture glitches in; the
            // pages themselves are never wrapped in the effect (see GlitchIn)
            .environment(\.glitchIn, glitch)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if sting == .done, page == 1 || !marksHidden {
                    HomeNavigation(page: page ?? 0, accent: light.steadyAccent,
                                   select: selectPage)
                        .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 4)
                }
            }
            .onPreferenceChange(PageMarksHidden.self) { marksHidden = $0 }

            if sting != .done {
                StingOpening(style: introStyle, light: light, surge: arrival, phase: $sting)
                    .id(stingKey)
                    .zIndex(3)
            }
        }
        .environment(worn)
        .preferredColorScheme(.dark)
        .task { await worn.load(host: wall.host) }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: wall.live.appSleeps(canStayAwake: wall.push.keepAlive)
            case .active: wall.live.appWakes()
            default: break
            }
        }
        .sheet(item: $routes.sheet, onDismiss: router.didDismiss) { _ in
            SettingsSheet(accent: light.steadyAccent).environment(wall)
                .onAppear { router.didPresent(.settings) }
        }
        // The studio is a place you go into and come back from, not a third
        // page: drawing needs the whole surface, and a horizontal stroke must
        // not turn into a page swipe.
        .fullScreenCover(item: $routes.cover, onDismiss: router.didDismiss) { destination in
            switch destination {
            case .onboarding:
                OnboardingFlow().environment(wall)
                    .onAppear { router.didPresent(.onboarding) }
            case .studio:
                StudioScreen(roomPalette: light.palette, accent: light.steadyAccent)
                    .environment(wall)
                    .onAppear { router.didPresent(.studio) }
            }
        }
        .onChange(of: onboardingAgain) { _, again in
            // asked for from inside Settings: the sheet has to go first, or
            // the cover waits behind it until the sheet is closed by hand
            guard again else { return }
            onboardingAgain = false
            router.present(.onboarding)
        }
        .onChange(of: sting) { _, phase in
            guard case .glitch = phase else { return }
            guard !reducedMotion, scenePhase == .active else { glitch = 1; return }
            glitch = 0
            DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.9)) { glitch = 1 } }
        }
        .onChange(of: replay) { _, on in
            // the opening plays on the wall screen, so Settings steps aside
            if on { router.dismiss() }
            // the sting is the root's to replay; the screens' own openings
            // put the switch back themselves
            guard on, StingFilm.plays(introStyle) else { return }
            replay = false
            stingKey += 1
            sting = .film
        }
        .onAppear {
            wall.start()
            if reducedMotion { sting = .done; glitch = 1 }
            if !onboarded && !CommandLine.arguments.contains("-nointro") { router.present(.onboarding) }
            #if DEBUG
            // `-settings` on the launch line opens Setup straight away, so a
            // simulator run can be looked at without a tap nobody can make.
            if CommandLine.arguments.contains("-settings") { router.present(.settings) }
            if CommandLine.arguments.contains("-archive") { page = 1 }
            if CommandLine.arguments.contains("-studio") { router.present(.studio) }
            #endif
        }
        // The lock screen's three keys land here. Only modes: anything that
        // needs a choice made about it needs the app open to make it in.
        .onOpenURL { url in
            // a video opened in Tessera: it goes up to the wall as it is,
            // small picture made here, and the wall plays it
            if VideoHandoff.accept(url), let p = VideoHandoff.arrived,
               let path = p.path {
                VideoHandoff.arrived = nil
                let host = wall.host
                Task {
                    _ = try? await VideoHandoff.send(
                        file: URL(fileURLWithPath: path),
                        title: p.title, host: host) { _, _ in }
                }
                router.dismiss()
                page = 0
                return
            }
            guard url.scheme == "tessera" else { return }
            if url.host == "mode", let mode = url.pathComponents.last,
               ["art", "cd", "ambient", "off", "ticker", "clock"].contains(mode) {
                wall.send(["mode": mode])
                Taps.commit()
            }
            page = 0
        }
        .onChange(of: lighting.reading.key) { _, _ in
            guard Date().timeIntervalSince(paletteAt) > 1.2 else { return }
            paletteAt = Date()
            withAnimation(reducedMotion ? nil : .easeInOut(duration: 1.0)) {
                stablePalette = Room.palette(lighting.reading.px) ?? lighting.reading.palette
            }
        }
        .onChange(of: wall.arrivalKey) { _, new in
            // A new sleeve is a new row in the Archive and a new step in the
            // panel's backwards drag, so the list catches up on every
            // arrival, the first one included: with nothing playing at
            // launch the first key is empty, and the surge guard below used
            // to swallow the reload along with the surge.
            Task { await worn.load(host: wall.host) }
            // A new sleeve landing on 4,096 LEDs is an event, not a fade.
            // Keyed on the wall's own shown_seq (title as the old-brain
            // fallback), so same-title tracks surge too and mode taps never
            // false-fire it.
            guard !lastTitle.isEmpty, new != lastTitle, !isOff, !new.isEmpty else {
                lastTitle = new
                return
            }
            lastTitle = new
            guard !reducedMotion, scenePhase == .active else { arrival = 0; return }
            Taps.landed()
            withAnimation(.easeOut(duration: 0.25)) { arrival = 0.30 }
            withAnimation(.easeInOut(duration: 0.9).delay(0.25)) { arrival = 0 }
        }
        .onChange(of: reducedMotion) { _, reduced in
            if reduced { sting = .done; glitch = 1; arrival = 0 }
        }
    }

    private func selectPage(_ destination: Int) {
        guard !onPanel, page != destination else { return }
        withAnimation(reducedMotion ? nil : Motion.scene) { page = destination }
        Taps.detent(intensity: 0.35)
    }
}

/// Set by a page that has covered itself with something (the room's boards,
/// its opening), so the page marks are not drawn over it.
struct PageMarksHidden: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// Labeled, reachable destinations retain the two-page room gesture.
private struct HomeNavigation: View {
    let page: Int
    let accent: Color
    var select: (Int) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<2, id: \.self) { i in
                Button { select(i) } label: {
                    Group {
                        if typeSize.isAccessibilitySize {
                            VStack(spacing: 4) { symbol(i); title(i) }
                        } else {
                            HStack(spacing: 9) { symbol(i); title(i) }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.vertical, typeSize.isAccessibilitySize ? 8 : 0)
                    .background(i == page ? Ink.ink.opacity(0.09) : .clear,
                                in: RoundedRectangle(cornerRadius: 20))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.96))
                .accessibilityLabel(i == 0 ? "Wall" : "Archive")
                .accessibilityAddTraits(i == page ? [.isSelected] : [])
                .accessibilityIdentifier(i == 0 ? "navigation.wall" : "navigation.archive")
            }
        }
        .padding(5)
        .frame(maxWidth: typeSize.isAccessibilitySize ? 480 : 300)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(Ink.ink.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .frame(maxWidth: .infinity)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation")
    }

    private func symbol(_ index: Int) -> some View {
        Image(systemName: index == 0 ? "square.grid.3x3.fill" : "square.stack.3d.up.fill")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(index == page ? accent.toned(forDark: true) : Ink.dim)
            .accessibilityHidden(true)
    }

    private func title(_ index: Int) -> some View {
        Text(index == 0 ? "Wall" : "Archive")
            .font(.ui(13, index == page ? .semibold : .medium))
            .foregroundStyle(index == page ? Ink.ink : Ink.dim)
            .lineLimit(1).minimumScaleFactor(0.8)
    }
}
