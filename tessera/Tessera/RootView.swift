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

    /// How much light is actually in the room. Everything visual scales by
    /// this, so the phone dims as the wall dims and goes dark when it does.
    var room: Double { isOff ? 0 : reading.lit * duty }
    var litInk: Color { Ink.ink.lit(by: accent, 0.20 * room) }
    var litDim: Color { Ink.dim.lit(by: accent, 0.16 * room) }
}

struct RootView: View {
    @Environment(WallSession.self) private var wall

    @State private var page = 0
    @State private var dragLight: Double? = nil
    @State private var arrival: Double = 0
    @State private var lastTitle = ""
    @State private var showSetup = false
    @State private var showStudio = false

    private var duty: Double { dragLight ?? wall.state.brightness }
    private var isOff: Bool { wall.state.mode == "off" }

    private var lighting: Lighting {
        let reading = FrameRenderer.read(wall.frame, duty: isOff ? 0.05 : duty)
        let accent: Color = {
            if let hex = wall.state.artColors.first, let c = Color(wallHex: hex) { return c }
            return reading.glow
        }()
        return Lighting(reading: reading, accent: accent, duty: duty, isOff: isOff)
    }

    var body: some View {
        let light = lighting

        ZStack(alignment: .bottom) {
            Room(
                palette: light.isOff ? [] : light.reading.palette,
                light: light.room,
                surge: arrival
            )

            TabView(selection: $page) {
                WallScreen(
                    light: light,
                    dragLight: $dragLight,
                    onSetup: { showSetup = true },
                    onStudio: { showStudio = true }
                )
                .tag(0)
                ArchiveScreen(accent: light.accent)
                    .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            PageTesserae(page: page, accent: light.accent, lit: light.room)
                .padding(.bottom, 8)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSetup) {
            SettingsSheet(accent: light.accent).environment(wall)
        }
        // The studio is a place you go into and come back from, not a third
        // page: drawing needs the whole surface, and a horizontal stroke must
        // not turn into a page swipe.
        .fullScreenCover(isPresented: $showStudio) {
            StudioScreen(roomPalette: light.reading.palette, accent: light.accent)
                .environment(wall)
        }
        .onAppear { wall.start() }
        .onChange(of: wall.state.title ?? "") { _, new in
            // A new sleeve landing on 4,096 LEDs is an event, not a fade.
            guard !lastTitle.isEmpty, new != lastTitle, !isOff, !new.isEmpty else {
                lastTitle = new
                return
            }
            lastTitle = new
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
