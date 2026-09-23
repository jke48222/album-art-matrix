// The iPod home keeps its physical scale while the surrounding controls can
// scroll and grow with Dynamic Type. The LCD always shows the actual wall frame.

import MediaPlayer
import SwiftUI

struct IPodWallScreen: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    let light: Lighting
    @Binding var dragLight: Double?
    @Binding var onPanel: Bool
    var onSetup: () -> Void
    var onStudio: () -> Void
    var onArchive: () -> Void = {}

    @State private var zoomed = false
    @State private var wheelHint = "Turn the wheel to change the light"
    @State private var headerHeight: CGFloat = 70
    @State private var statusHeight: CGFloat = 44
    @State private var introDone = !IntroFlip.available || CommandLine.arguments.contains("-nointro")
        || StingFilm.plays(UserDefaults.standard.string(forKey: "intro.style") ?? "film")
    @AppStorage("intro.replay") private var replay = false

    private var accent: Color { light.steadyAccent.toned(forDark: true) }
    private var isOff: Bool { light.isOff }

    var body: some View {
        GeometryReader { geometry in
            let widthScale = max(0.6, min(1, (geometry.size.width - 28) / IPodMetrics.bodyW))
            // Keep the complete object and its instruction in the initial
            // viewport. Smaller phones and accessibility sizes scroll instead
            // of shrinking the physical controls beyond this modest adjustment.
            let availableHeight = geometry.size.height - headerHeight - statusHeight - 44
            let heightScale = max(0.9, min(1, availableHeight / IPodMetrics.bodyH))
            let scale = typeSize.isAccessibilitySize ? widthScale : min(widthScale, heightScale)
            VStack(spacing: 0) {
                header.padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 10)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                ScrollView(.vertical) {
                    VStack(spacing: 16) {
                        ZStack {
                            IPodView(light: light, dragLight: $dragLight, touching: $onPanel,
                                     onSetup: onSetup, onStudio: onStudio, onArchive: onArchive,
                                     onZoom: { zoomed = true }, onHintChange: { wheelHint = $0 })
                                .opacity(introDone || reducedMotion ? 1 : 0)
                                .allowsHitTesting(introDone || reducedMotion)
                            if !introDone && !reducedMotion {
                                IntroFlip {
                                    withAnimation(.easeOut(duration: 0.25)) { introDone = true }
                                }
                                .frame(width: IPodMetrics.bodyW, height: IPodMetrics.bodyH)
                                .shadow(color: .black.opacity(0.5), radius: 30, y: 18)
                                .allowsHitTesting(false)
                            }
                        }
                        .frame(width: IPodMetrics.bodyW, height: IPodMetrics.bodyH)
                        .scaleEffect(scale, anchor: .top)
                        .frame(width: IPodMetrics.bodyW * scale, height: IPodMetrics.bodyH * scale, alignment: .top)
                        .padding(.top, 16)

                        if typeSize.isAccessibilitySize {
                            NowPlayingIdentity(state: wall.state, link: wall.link, accent: accent)
                                .padding(20)
                                .background(Ink.ground.opacity(0.94), in: RoundedRectangle(cornerRadius: 22))
                                .padding(.horizontal, 20)
                        }
                        DisplayDetailLinks(accent: accent).padding(.horizontal, 24)
                        status
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { statusHeight = $0 }
                        if wall.state.mode == "timer", let remaining = wall.state.timerRemaining {
                            timer(remaining)
                        }
                    }
                    .padding(.bottom, typeSize.isAccessibilitySize ? 30 : 12)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .clipped()
            }
        }
        .onChange(of: replay) { _, requested in
            guard requested else { return }
            replay = false
            if !reducedMotion, IntroFlip.available,
               !StingFilm.styles.contains(UserDefaults.standard.string(forKey: "intro.style") ?? "film") {
                introDone = false
            }
        }
        .onDisappear { onPanel = false; dragLight = nil }
        .fullScreenCover(isPresented: $zoomed) { expandedWall }
    }

    private var header: some View {
        HStack(spacing: 12) {
            RecordMark(accent: accent, lit: 1, side: 21)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("TESSERA").font(.custom(Face.display, fixedSize: 19)).tracking(2.2)
                    .foregroundStyle(Ink.ink)
                Text("POCKET CONTROL").font(.custom(Face.mono, fixedSize: 8)).tracking(1.2)
                    .foregroundStyle(Ink.dim)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            Button(action: onStudio) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Open Studio")
            Button(action: onSetup) {
                Image(systemName: wall.link.isLive ? "wifi" : wall.link.isStandIn ? "iphone" : "wifi.slash")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(wall.link.isLive ? Ink.moss : Ink.ink)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Wall settings. " + connectionDescription)
        }
        .foregroundStyle(Ink.ink)
        .buttonStyle(PressStyle(scale: 0.94))
        .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6)
        .background(Ink.ground.opacity(0.95), in: Capsule())
        .overlay { Capsule().strokeBorder(Ink.hairline, lineWidth: 1) }
    }

    @ViewBuilder private var status: some View {
        switch wall.link {
        case .offline:
            Button { Task { await wall.poll() } } label: {
                Label("Reconnect to the wall", systemImage: "arrow.clockwise")
                    .font(.ui(13, .medium)).foregroundStyle(accent)
                    .padding(.horizontal, 16).frame(minHeight: 44)
                    .background(Ink.ground.opacity(0.95), in: Capsule())
            }
            .buttonStyle(PressStyle(scale: 0.97))
            .padding(.horizontal, 20)
        case .searching:
            statusLabel("Finding your wall", symbol: "antenna.radiowaves.left.and.right")
        case .standIn:
            statusLabel("Preview on this phone", symbol: "iphone")
        case .live:
            statusLabel(wheelHint, symbol: isOff ? "moon.zzz" : "sun.max")
        }
    }

    private func statusLabel(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.ui(12)).foregroundStyle(Ink.ink.opacity(0.85))
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(Ink.ground.opacity(0.94), in: Capsule())
            .padding(.horizontal, 20)
    }

    private var connectionDescription: String {
        switch wall.link {
        case .live: "Connected to the wall."
        case .offline: "The wall is offline."
        case .searching: "Looking for the wall."
        case .standIn: "Previewing on this phone."
        }
    }

    private func timer(_ remaining: Int) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("TIMER").font(.machine(9)).tracking(1).foregroundStyle(Ink.dim)
                Text(PlaybackIdentity.clock(Double(remaining)))
                    .font(.machine(24)).monospacedDigit().foregroundStyle(Ink.ink)
                    .contentTransition(.numericText(countsDown: true))
            }
            Spacer(minLength: 8)
            Button("Stop") { wall.send(["timer_min": 0.0]); Taps.commit() }
                .font(.ui(14, .semibold)).foregroundStyle(accent).frame(minWidth: 64, minHeight: 44)
                .buttonStyle(PressStyle(scale: 0.96))
                .accessibilityLabel("Stop timer")
        }
        .padding(18)
        .background(Ink.ground.opacity(0.95), in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 20)
    }

    private var expandedWall: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    WallHero(reading: light.reading, confirmed: isOff ? 0.05 : wall.state.brightness,
                             dragging: $dragLight, link: wall.link, arrivalKey: wall.arrivalKey,
                             touching: $onPanel, onCommit: { wall.send(["brightness": $0]) },
                             onHold: { wall.send(["mode": isOff ? "art" : "off"]) },
                             onFlickPrev: { skip(previous: true) }, onFlickNext: { skip(previous: false) })
                        .aspectRatio(1, contentMode: .fit)
                    NowPlayingIdentity(state: wall.state, link: wall.link, accent: accent)
                        .padding(.horizontal, 24)
                }
                .padding(.top, 16).padding(.bottom, 32)
            }
            .background(Ink.ground)
            .navigationTitle("On the wall")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { zoomed = false } label: {
                        Image(systemName: "xmark").font(.system(size: 14, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .foregroundStyle(Ink.ink)
                    .accessibilityLabel("Close expanded wall")
                }
            }
        }
        .preferredColorScheme(.dark)
        .onDisappear { onPanel = false; dragLight = nil }
    }

    private func skip(previous: Bool) {
        guard MPMediaLibrary.authorizationStatus() == .authorized else { return }
        let player = MPMusicPlayerController.systemMusicPlayer
        if previous { player.skipToPreviousItem() } else { player.skipToNextItem() }
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
    @AppStorage("design") private var design = Design.room.rawValue
    let light: Lighting
    @Binding var dragLight: Double?
    @Binding var onPanel: Bool
    var onSetup: () -> Void
    var onStudio: () -> Void
    var onArchive: () -> Void = {}

    var body: some View {
        switch Design(rawValue: design) ?? .room {
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
