// The app is one room with two things in it: the wall, and what the wall has
// worn. You move between them by swiping, not by pressing a tab bar, and the
// only navigation chrome is two tesserae, one of them lit.
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
    @State private var arrival: Double = 0
    @State private var lastTitle = ""
    @State private var showSetup = false
    @State private var showStudio = false
    /// The room's colours, held steady. Reading them straight from the frame
    /// meant rainbow and the pattern modes strobed the whole interface: the
    /// swatches, the glyph rings and the background all chased the hue. The
    /// room updates its colour a few times a minute, like a room.
    @State private var stablePalette: [Color] = []
    @State private var paletteAt: Date = .distantPast

    private var duty: Double { dragLight ?? wall.state.brightness }
    private var isOff: Bool { wall.state.mode == "off" }

    private var lighting: Lighting {
        let reading = FrameRenderer.read(wall.frame)
        let accent: Color = {
            if let hex = wall.state.artColors.first, let c = Color(wallHex: hex) { return c }
            return reading.glow
        }()
        return Lighting(reading: reading, accent: accent, duty: duty, isOff: isOff,
                        palette: stablePalette.isEmpty ? reading.palette : stablePalette)
    }

    var body: some View {
        let light = lighting

        ZStack(alignment: .bottom) {
            Room(
                palette: light.isOff ? [] : light.palette,
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
                        onSetup: { showSetup = true },
                        onStudio: { showStudio = true }
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

            PageTesserae(page: page ?? 0, accent: light.steadyAccent, lit: light.room)
                .padding(.bottom, 8)
        }
        .environment(worn)
        .preferredColorScheme(.dark)
        .task { await worn.load(host: wall.host) }
        .sheet(isPresented: $showSetup) {
            SettingsSheet(accent: light.steadyAccent).environment(wall)
        }
        // The studio is a place you go into and come back from, not a third
        // page: drawing needs the whole surface, and a horizontal stroke must
        // not turn into a page swipe.
        .fullScreenCover(isPresented: $showStudio) {
            StudioScreen(roomPalette: light.palette, accent: light.steadyAccent)
                .environment(wall)
        }
        .onAppear { wall.start() }
        // The lock screen's three keys land here. Only modes: anything that
        // needs a choice made about it needs the app open to make it in.
        .onOpenURL { url in
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
            withAnimation(.easeInOut(duration: 1.0)) {
                stablePalette = lighting.reading.palette
            }
        }
        .onChange(of: wall.arrivalKey) { _, new in
            // A new sleeve landing on 4,096 LEDs is an event, not a fade.
            // Keyed on the wall's own shown_seq (title as the old-brain
            // fallback), so same-title tracks surge too and mode taps never
            // false-fire it.
            guard !lastTitle.isEmpty, new != lastTitle, !isOff, !new.isEmpty else {
                lastTitle = new
                return
            }
            lastTitle = new
            // A new sleeve is a new row in the Archive and a new step in the
            // panel's backwards drag, so the list catches up here rather than
            // only when someone pulls it down.
            Task { await worn.load(host: wall.host) }
            Taps.landed()
            withAnimation(.easeOut(duration: 0.25)) { arrival = 0.30 }
            withAnimation(.easeInOut(duration: 0.9).delay(0.25)) { arrival = 0 }
        }
    }
}

/// The page indicator is the mark: two tiles, the one you are on is lit.
private struct PageTesserae: View {
    let page: Int
    let accent: Color
    let lit: Double

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<2, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i == page ? accent : Ink.faint.opacity(0.5))
                    .frame(width: 7, height: 7)
                    .shadow(color: i == page ? accent.opacity(0.6 * lit) : .clear, radius: 5)
            }
        }
        .animation(Motion.settle, value: page)
        .accessibilityHidden(true)
    }
}
