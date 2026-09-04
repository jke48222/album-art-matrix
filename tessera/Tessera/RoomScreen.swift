// The room, third design: the rendered view of the wall.
//
// A dim room, the table a third of the way up, the record player on it and
// the wall above, rendered in Blender and shown one to one. What keeps it
// alive: the wall in the frame is the live frame, drawn as emitters over
// the render; a second render of the room lit only by the wall is laid over
// the first, tinted with the sleeve's colours and scaled by how much light
// the wall is giving, so the walls, the table and the deck take the
// record's colour the way they do in the room; the sleeve is on the
// record's label and turns with it; the needle sits where the song is
// (Needle.swift); and the dust cover, with the mark on its front, is its
// own layer over all of that. Tap the wall and the room comes in close for
// tuning it. The opening is live too (RoomIntro.swift).

import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

/// Where things are in the render, as fractions of the image.
struct RoomGeometry: Decodable {
    var face: [[Double]]           // four corners, clockwise from top-left
    var record: [Double]           // x0, y0, x1, y1 of the record's box
    var label: [Double]?           // cx, cy, ax, ay, bx, by of the label's disc
    var needle: [Double]?          // x0, y0, x1, y1 of the arm renders' box
    var lead: Int?                 // the arm grid: index of the lead-in groove
    var track: Int?                // groove positions after it
    var lifts: Int?                // heights at each; the renders count them up to down
    var cover: [Double]?           // x0, y0, x1, y1 of the cover render's box
    var placard: Double?           // where the table's front edge ends, top of the words
    var badge: [[[Double]]]?       // the mark's nine tiles on the cover, four corners each

    static let loaded: RoomGeometry? = {
        guard let url = Bundle.main.url(forResource: "room-geometry", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RoomGeometry.self, from: data)
    }()
}

struct RoomWallScreen: View {
    @Environment(WallSession.self) private var wall
    let light: Lighting
    @Binding var dragLight: Double?
    @Binding var onPanel: Bool
    var onSetup: () -> Void
    var onStudio: () -> Void
    var onArchive: () -> Void

    @State private var controls = CommandLine.arguments.contains("-controls")
    /// Close on the wall, with its tuning underneath.
    @State private var zoomed = CommandLine.arguments.contains("-zoomed")
    /// The needle is down: the record turns.
    @State private var needleDown = false
    @State private var localPlaying = MPMusicPlayerController.systemMusicPlayer.playbackState == .playing
    /// How far into the song, 0 to 1, read once a second; nil with no record on.
    @State private var songProgress: Double? = nil
    @State private var introDone = !IntroTrack.available || CommandLine.arguments.contains("-nointro")
    /// The opening has faded and the room is itself: only then does the
    /// needle set off, so the move is seen and not lost in the crossfade.
    @State private var introSettled = !IntroTrack.available || CommandLine.arguments.contains("-nointro")
    @State private var introKey = 0
    /// The sleeve of the song that is on, for the record's label.
    @State private var sleeve = SleeveArt()
    @AppStorage("intro.replay") private var replay = false
    /// The record's turn: what it had turned to when it last stopped, and
    /// when it started again.
    @State private var turned: Double = 0
    @State private var turningSince: Date? = nil

    /// The words sit in the dark under the table: light ink, always.
    private let inkLight = Color(hex: 0xF1EEE8)
    private let inkLightDim = Color(hex: 0xDCD7CD)
    /// The glass takes the room's own tone.
    private var panelInk: GlassInk { light.roomBright ? .light : .dark }

    var body: some View {
        GeometryReader { geo in
            let fit = fitting(geo.size)
            let g = RoomGeometry.loaded
            ZStack(alignment: .topLeading) {
                // the app's own background is the room's back wall: the render
                // leaves the wall clear but for its shadows
                if introDone { picture(fit: fit, g: g) }
                if !zoomed {
                    chrome(size: geo.size, fit: fit, g: g)
                        .opacity(introDone ? 1 : 0)
                }
                if let g {
                    let r = rect(g.face, in: fit)
                    // the wall is a place you can go
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .onTapGesture { withAnimation(Motion.scene) { zoomed.toggle() } }
                        .accessibilityLabel(zoomed ? "Back to the room" : "Tune the wall")
                        .accessibilityAddTraits(.isButton)
                }
                if zoomed { tuning(size: geo.size) }
                if !introDone {
                    RoomIntro(light: light, duty: dragLight ?? wall.state.brightness, fit: fit, sleeve: sleeve.image) {
                        withAnimation(.easeInOut(duration: 1.4)) { introDone = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { introSettled = true }
                    }
                    .id(introKey)
                    .zIndex(1)
                    .allowsHitTesting(false)
                }
                if controls {
                    ControlCenterPanel(light: light, ink: panelInk, dragLight: $dragLight,
                                       onStudio: onStudio, onArchive: onArchive, onSetup: onSetup,
                                       onClose: { withAnimation(Motion.scene) { controls = false } }, sleeve: sleeve.image)
                        .zIndex(2)
                }
            }
        }
        .ignoresSafeArea()
        .onChange(of: replay) { _, on in
            if on, IntroTrack.available { replay = false; introKey += 1; introDone = false; introSettled = false }
        }
        .onChange(of: wall.state.title) { _, _ in sleeve.refresh(title: wall.state.title, artist: wall.state.artist, host: wall.host) }
        .onChange(of: needleDown) { _, down in
            let now = Date()
            if down { turningSince = now }
            else { turned = turnAngle(at: now); turningSince = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .MPMusicPlayerControllerPlaybackStateDidChange)) { _ in
            localPlaying = MPMusicPlayerController.systemMusicPlayer.playbackState == .playing
            songProgress = songProgressNow()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            songProgress = songProgressNow()
            sleeve.refresh(title: wall.state.title, artist: wall.state.artist, host: wall.host)
        }
        .onAppear {
            MPMusicPlayerController.systemMusicPlayer.beginGeneratingPlaybackNotifications()
            songProgress = songProgressNow()
            sleeve.refresh(title: wall.state.title, artist: wall.state.artist, host: wall.host)
        }
    }

    // MARK: - The picture, layer by layer

    @ViewBuilder
    private func picture(fit: CGRect, g: RoomGeometry?) -> some View {
        let duty = dragLight ?? wall.state.brightness
        let accent = light.steadyAccent
        let second = light.palette.count > 1 ? light.palette[1] : accent
        // the room
        Image("RoomBase")
            .resizable()
            .interpolation(.high)
            .frame(width: fit.size.width, height: fit.size.height)
            .offset(x: fit.origin.x, y: fit.origin.y)
        // the wall's light on the room, from the second render: the sleeve's
        // first colour where the wall throws it, a second colour under that
        Image("RoomLight")
            .resizable()
            .interpolation(.high)
            .colorMultiply(second)
            .blendMode(.screen)
            .opacity(0.5 * light.room)
            .frame(width: fit.size.width, height: fit.size.height)
            .offset(x: fit.origin.x, y: fit.origin.y)
            .allowsHitTesting(false)
        Image("RoomLight")
            .resizable()
            .interpolation(.high)
            .colorMultiply(accent)
            .blendMode(.screen)
            .opacity(min(1, 1.1 * light.room))
            .frame(width: fit.size.width, height: fit.size.height)
            .offset(x: fit.origin.x, y: fit.origin.y)
            .allowsHitTesting(false)
        if let g {
            let face = rect(g.face, in: fit)
            // the bloom behind the wall: the colour spilling onto the back wall
            RadialGradient(colors: [accent.opacity(0.45 * light.room), second.opacity(0.18 * light.room), .clear],
                           center: .center, startRadius: face.width * 0.35, endRadius: face.width * 1.7)
                .frame(width: face.width * 3.6, height: face.width * 3.6)
                .position(x: face.midX, y: face.midY)
                .blendMode(.screen)
                .allowsHitTesting(false)
            // the wall itself
            RoomPanel(px: light.reading.px, duty: duty)
                .frame(width: face.width, height: face.height)
                .position(x: face.midX, y: face.midY)
                .allowsHitTesting(false)
            // the sleeve on the label, turning while the needle is down
            if let e = g.label, e.count == 6 {
                TimelineView(.animation(paused: turningSince == nil)) { tl in
                    LabelArt(image: sleeve.image, ellipse: e, fit: fit, angle: turnAngle(at: tl.date))
                }
            }
            if let n = g.needle, let lead = g.lead, let track = g.track, let lifts = g.lifts {
                let nr = rect(box: n, in: fit)
                NeedleView(lead: lead, track: track, lifts: lifts, playing: introSettled && playing,
                           progress: introSettled ? songProgress : nil,
                           onDown: { needleDown = $0 })
                    .frame(width: nr.width, height: nr.height)
                    .position(x: nr.midX, y: nr.midY)
                    .allowsHitTesting(false)
            }
            // the dust cover, closed, and the mark on it in the wall's colour
            if let c = g.cover {
                let cr = rect(box: c, in: fit)
                Image("RoomCover")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: cr.width, height: cr.height)
                    .position(x: cr.midX, y: cr.midY)
                    .allowsHitTesting(false)
            }
            if let b = g.badge {
                BadgeView(quads: b, fit: fit, accent: accent, lit: max(0.4, light.room))
            }
        }
    }

    // MARK: - The record's turn

    /// 33 1/3 a minute, or the wall's own rate while it spins.
    private var turnsPerSecond: Double {
        let rpm = wall.state.mode == "cd" ? wall.state.rpm : 33.333
        return max(0.05, rpm) / 60
    }

    private func turnAngle(at date: Date) -> Double {
        guard let since = turningSince else { return turned }
        return turned + date.timeIntervalSince(since) * turnsPerSecond * 2 * .pi
    }

    // MARK: - What is playing

    /// Music is on: this phone's player says so, or the wall does.
    private var playing: Bool { NeedleDemo.on ? NeedleDemo.sample().playing : (localPlaying || wall.state.songPlaying) }

    /// Where the song is, 0 to 1: this phone's player while it plays, else
    /// the wall's word on what it is showing, else a song this phone has
    /// paused. Nil when there is no record on, and the arm goes home.
    private func songProgressNow() -> Double? {
        if NeedleDemo.on { return NeedleDemo.sample().progress }
        let m = MPMusicPlayerController.systemMusicPlayer
        let local: Double? = {
            guard let item = m.nowPlayingItem, item.playbackDuration > 1 else { return nil }
            return min(1, max(0, m.currentPlaybackTime / item.playbackDuration))
        }()
        if localPlaying, let local { return local }
        if let t = wall.state.title, !t.isEmpty {
            if let f = wall.state.songFraction { return f }
            if wall.state.songPlaying { return 0 }
        }
        if m.playbackState == .paused, let local { return local }
        return nil
    }

    // MARK: - Chrome

    /// The name over the room, the keys to the room, and the words and keys
    /// for the record, centred in the grey under the table.
    @ViewBuilder
    private func chrome(size: CGSize, fit: CGRect, g: RoomGeometry?) -> some View {
        // The sleeve's colour, always the light cut of it: the name is the
        // pale thing on the wall whatever the record is.
        let word = light.steadyAccent.toned(forDark: true)
        HStack(alignment: .center, spacing: 12) {
            TesseraMark(accent: word, lit: max(0.6, light.room), side: 17)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
            Text("TESSERA").font(.display(18)).kerning(3.0).foregroundStyle(word)
                .shadow(color: .black.opacity(0.45), radius: 5, y: 1)
            Spacer()
            ControlCenterButtons(ink: light.roomBright ? .light : .dark, onControls: {
                withAnimation(Motion.scene) { controls.toggle() }
            }, onSetup: onSetup)
        }
        .padding(.horizontal, 24)
        .padding(.top, 62)
        .frame(width: size.width, alignment: .leading)

        let bandTop = fit.origin.y + fit.height * (g?.placard ?? 0.78) + 6
        let bandBottom = size.height - 40
        let bandHeight = max(120, bandBottom - bandTop)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                if let t = wall.state.title, !t.isEmpty {
                    Text(t).font(.display(28)).foregroundStyle(inkLight)
                        .lineLimit(1).minimumScaleFactor(0.62)
                    Text([wall.state.artist, wall.state.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.ui(15)).foregroundStyle(inkLightDim).lineLimit(1).truncationMode(.tail)
                } else {
                    Text(wall.state.mode == "off" ? "Asleep" : "Nothing playing")
                        .font(.display(24)).foregroundStyle(inkLight)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            RoomKeys(accent: light.steadyAccent)
                .padding(.top, 18)
        }
        .frame(width: size.width, height: bandHeight)
        .position(x: size.width / 2, y: bandTop + bandHeight / 2)
    }

    /// Close on the wall: what it shows and how, right under it.
    @ViewBuilder
    private func tuning(size: CGSize) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("THE WALL").font(.machine(10)).kerning(1.6).foregroundStyle(light.chromeDim)
                Spacer()
                Button { withAnimation(Motion.scene) { zoomed = false } } label: {
                    Text("Done").font(.ui(14, .semibold)).foregroundStyle(light.roomBright ? Ink.ground : Ink.ink)
                        .padding(.horizontal, 18).frame(height: 38)
                        .background(Capsule().fill(.ultraThinMaterial))
                        .overlay(Capsule().strokeBorder(light.chrome.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(PressStyle(scale: 0.94))
            }
            .padding(.horizontal, 24)
            .padding(.top, 62)
            Spacer()
            ControlCenterPanel(light: light, ink: panelInk, dragLight: $dragLight,
                               onStudio: onStudio, onArchive: onArchive, onSetup: onSetup,
                               onClose: { withAnimation(Motion.scene) { zoomed = false } }, layout: .tuning)
                .padding(.bottom, 44)
        }
        .frame(width: size.width, height: size.height)
        .transition(.opacity)
    }

    // MARK: - Fitting the render to the screen

    /// The render is 390 x 844 at 3x. Scaled to fill, centred, so a taller
    /// or wider phone crops the room's edges and never stretches it. Zoomed,
    /// the same picture is scaled about the wall until the wall spans most
    /// of the width, and carried up so the tuning fits under it.
    private func fitting(_ size: CGSize) -> CGRect {
        let iw: CGFloat = 390, ih: CGFloat = 844
        let s = max(size.width / iw, size.height / ih)
        var fit = CGRect(x: (size.width - iw * s) / 2, y: (size.height - ih * s) / 2, width: iw * s, height: ih * s)
        if zoomed, let g = RoomGeometry.loaded {
            let face = rect(g.face, in: fit)
            let k = (size.width * 0.84) / face.width
            let target = CGPoint(x: size.width / 2, y: size.height * 0.33)
            fit = CGRect(x: target.x - (face.midX - fit.origin.x) * k,
                         y: target.y - (face.midY - fit.origin.y) * k,
                         width: fit.width * k, height: fit.height * k)
        }
        return fit
    }

    private func rect(_ corners: [[Double]], in fit: CGRect) -> CGRect {
        let xs = corners.map { $0[0] }, ys = corners.map { $0[1] }
        return rect(box: [xs.min() ?? 0, ys.min() ?? 0, xs.max() ?? 0, ys.max() ?? 0], in: fit)
    }

    private func rect(box b: [Double], in fit: CGRect) -> CGRect {
        CGRect(x: fit.origin.x + fit.width * b[0], y: fit.origin.y + fit.height * b[1],
               width: fit.width * (b[2] - b[0]), height: fit.height * (b[3] - b[1]))
    }
}

/// A pretend side for the simulator: `-needle-demo` plays a minute-long
/// record with a pause in the middle, so the arm's moves can be watched
/// without a wall or a song.
enum NeedleDemo {
    static let on = CommandLine.arguments.contains("-needle-demo")
    private static let began = Date()
    static func sample() -> (playing: Bool, progress: Double?) {
        let t = Date().timeIntervalSince(began).truncatingRemainder(dividingBy: 64)
        switch t {
        case ..<4: return (false, nil)                          // nothing on
        case ..<30: return (true, (t - 4) / 44)                 // playing, first stretch
        case ..<38: return (false, 26 / 44)                     // paused, arm up where it is
        case ..<56: return (true, (t - 12) / 44)                // playing on to the run-out
        default: return (false, nil)                            // side over, arm home
        }
    }
}

/// The three keys under the words, in the wall's colour.
private struct RoomKeys: View {
    let accent: Color
    @State private var playing = MPMusicPlayerController.systemMusicPlayer.playbackState == .playing
    var body: some View {
        HStack(spacing: 18) {
            key(.rewind, 48) { MPMusicPlayerController.systemMusicPlayer.skipToPreviousItem() }
            key(playing ? .pause : .play, 60) {
                let m = MPMusicPlayerController.systemMusicPlayer
                if playing { m.pause() } else { StandIn.requestMusicAccess { m.play() } }
                playing.toggle()
            }
            key(.forward, 48) { MPMusicPlayerController.systemMusicPlayer.skipToNextItem() }
        }
        .frame(maxWidth: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: .MPMusicPlayerControllerPlaybackStateDidChange)) { _ in
            playing = MPMusicPlayerController.systemMusicPlayer.playbackState == .playing
        }
    }
    private func key(_ g: Glyph, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        // Pale keys, and the record's own colour for the mark on each,
        // darkened only as far as it takes to read on the cream.
        let mark = accent.toned(forDark: false, to: 0.42)
        return Button(action: action) {
            ZStack {
                Circle().fill(Color(hex: 0xF4F2EE))
                Circle().strokeBorder(Color.black.opacity(0.10), lineWidth: 1)
                GlyphShape(glyph: g, lineWidth: 1.7)
                    .frame(width: size * 0.3, height: size * 0.3)
                    .foregroundStyle(mark)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.28), radius: 8, y: 4)
        }
        .buttonStyle(PressStyle(scale: 0.92))
    }
}
