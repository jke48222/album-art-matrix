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
    var recordQuad: [[Double]]?    // the record's square on its plane, four corners
    var badgeBox: [Double]?        // x0, y0, x1, y1 of the plates' render
    var recordBox: [Double]?       // x0, y0, x1, y1 of the record's shading render
    var overRecordQuad: [[Double]]? // from above: the record's square, four corners
    var overRecordBox: [Double]?    // from above: x0, y0, x1, y1 of the record's shading render
    var overLabel: [Double]?        // from above: the label's disc

    private enum CodingKeys: String, CodingKey {
        case face, record, label, needle, lead, track, lifts, cover, placard, badge
        case recordQuad = "record_quad"
        case badgeBox = "badge_box"
        case recordBox = "record_box"
        case overRecordQuad = "over_record_quad"
        case overRecordBox = "over_record_box"
        case overLabel = "over_label"
    }

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
    // Read on appear, never here: this view is made on every evaluation of
    // the screen above it, ten times a second while the stand-in ticks, and
    // a system player read is an XPC call.
    @State private var localPlaying = false
    /// Whether this phone's own player holds the song at all.
    @State private var hasLocalItem = false
    /// How far into the song, 0 to 1, read once a second; nil with no record on.
    @State private var songProgress: Double? = nil
    @State private var introDone = (!IntroTrack.available && !CommandLine.arguments.contains("-intro2") && UserDefaults.standard.string(forKey: "intro.style") != "mark") || CommandLine.arguments.contains("-nointro")
    /// The opening has faded and the room is itself: only then does the
    /// needle set off, so the move is seen and not lost in the crossfade.
    @State private var introSettled = (!IntroTrack.available && !CommandLine.arguments.contains("-intro2") && UserDefaults.standard.string(forKey: "intro.style") != "mark") || CommandLine.arguments.contains("-nointro")
    @State private var introKey = 0
    /// The sleeve of the song that is on, for the record's label.
    @State private var sleeve = SleeveArt()
    /// The song's pressing, rendered flat once, put on the platter by the shader,
    /// and its printed label.
    @State private var pressing: (key: String, image: UIImage, label: UIImage)? = nil
    @State private var pressingTask: Task<Void, Never>? = nil
    /// Your own choices of record, by song.
    @State private var pressings = PressingStore.shared
    /// In close on the record: the arm lifts home, the camera dives over the
    /// deck as the cover swings up, and the pressing is yours to shape from
    /// straight above. Then the same way back.
    enum Close { case none, lifting, diving, close, rising }
    @State private var close: Close = CommandLine.arguments.contains("-pressingsheet") || CommandLine.arguments.contains("-recordzoom") ? .close : .none
    @State private var overheadShown = CommandLine.arguments.contains("-pressingsheet") || CommandLine.arguments.contains("-recordzoom")
    /// The pressing as you are shaping it, on the record before it is kept.
    @State private var previewChoice: PressingChoice? = nil
    /// Which opening: the film, or the mark building on the wall.
    @AppStorage("intro.style") private var introStyle = "film"
    @State private var pressingRequest = UUID()
    @AppStorage("intro.replay") private var replay = false
    /// The record's turn: what it had turned to when it last stopped, and
    /// when it started again.
    @State private var turned: Double = 0
    @State private var turningSince: Date? = nil
    /// The tuning board's height, so the wall is fitted above it rather
    /// than under it: the lamp's board is tall enough to reach the wall.
    @State private var tuningHeight: CGFloat = 0
    /// Held as state: built inline in onReceive, the publisher was replaced
    /// on every body evaluation, which the stand-in causes ten times a
    /// second, and it never got its second to fire. The needle sat still.
    @State private var second = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
                if introDone, close == .none || close == .lifting { picture(fit: fit, g: g, size: geo.size) }
                if !zoomed {
                    chrome(size: geo.size, fit: fit, g: g)
                        .opacity(introDone && close == .none ? 1 : 0)
                        .animation(.easeInOut(duration: 0.25), value: close == .none)
                        .allowsHitTesting(close == .none)
                }
                if let g {
                    let r = rect(g.face, in: fit)
                    // the wall is a place you can go, and in close, the control
                    wallTarget(r)
                    // and so is the record: its pressing is yours to change
                    if !zoomed, close == .none, let rq = g.recordQuad, introDone {
                        let rr = rect(rq, in: fit).insetBy(dx: -8, dy: -10)
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: rr.width, height: rr.height)
                            .position(x: rr.midX, y: rr.midY)
                            .onTapGesture { openRecord() }
                            .accessibilityLabel("The pressing")
                            .accessibilityAddTraits(.isButton)
                    }
                }
                if zoomed { tuning(size: geo.size) }
                if overheadShown { overhead(size: geo.size, fit: fit, g: g) }
                if close == .close { pressingClose(size: geo.size, fit: fit, g: g) }
                if DiveTrack.available, introDone {
                    // the stage is always up, its films warm; it plays on the way in and out
                    DiveFilm(light: light, duty: dragLight ?? wall.state.brightness, fit: fit,
                             pressing: pressing?.image, angle: turned,
                             out: close == .diving ? false : close == .rising ? true : nil) {
                        diveLog.notice("film done from \(String(describing: close))")
                        if close == .diving { overheadShown = true; close = .close }
                        else if close == .rising { close = .none; previewChoice = nil }
                    }
                    .zIndex(1)
                }
                if !introDone {
                    if introStyle == "mark" || CommandLine.arguments.contains("-intro2"), IntroFilms.mark.available {
                        // the second opening, in the room's own scene: the mark builds before
                        // the wall and grows into it as the deck builds up out of blocks
                        RoomIntro(light: light, duty: dragLight ?? wall.state.brightness, fit: fit, sleeve: pressing?.label, pressing: pressing?.image, films: .mark) {
                            withAnimation(.easeInOut(duration: 1.0)) { introDone = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { introSettled = true }
                        }
                        .id(introKey)
                        .zIndex(1)
                        .allowsHitTesting(false)
                    } else if introStyle == "mark" || CommandLine.arguments.contains("-intro2"), let g {
                        // without its films, the flat version: the room's picture drawn in
                        RoomIntro2(light: light, duty: dragLight ?? wall.state.brightness, fit: fit, face: rect(g.face, in: fit),
                                   picture: AnyView(picture(fit: fit, g: g, size: geo.size))) {
                            withAnimation(.easeOut(duration: 0.3)) { introDone = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { introSettled = true }
                        }
                        .id(introKey)
                        .zIndex(1)
                    } else {
                        RoomIntro(light: light, duty: dragLight ?? wall.state.brightness, fit: fit, sleeve: pressing?.label, pressing: pressing?.image) {
                            withAnimation(.easeInOut(duration: 1.4)) { introDone = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { introSettled = true }
                        }
                        .id(introKey)
                        .zIndex(1)
                        .allowsHitTesting(false)
                    }
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
        // the page marks would sit on the boards, the close-up and the
        // opening, all of which cover the whole screen: they step aside
        .preference(key: PageMarksHidden.self, value: controls || zoomed || close != .none || !introDone)
        .onChange(of: replay) { _, on in
            // always put the switch back, or a build without the film
            // latches it on and the pill in Settings goes dead
            guard on else { return }
            replay = false
            if IntroTrack.available || introStyle == "mark" { introKey += 1; introDone = false; introSettled = false }
        }
        .onDisappear { pressingTask?.cancel(); pressingRequest = UUID() }
        .onChange(of: wall.state.title) { _, _ in sleeve.refresh(title: wall.state.title, artist: wall.state.artist, album: wall.state.album, host: wall.host) }
        .onChange(of: sleeve.revision) { _, _ in refreshPressing() }
        .onChange(of: pressings.overrides) { _, _ in refreshPressing() }
        .onChange(of: previewChoice) { _, _ in refreshPressing() }
        .onChange(of: needleDown) { _, down in
            let now = Date()
            if down { turningSince = now }
            else { turned = turnAngle(at: now); turningSince = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .MPMusicPlayerControllerPlaybackStateDidChange)) { _ in
            let m = MPMusicPlayerController.systemMusicPlayer
            localPlaying = m.playbackState == .playing
            hasLocalItem = m.nowPlayingItem != nil
            songProgress = songProgressNow()
        }
        .onReceive(second) { _ in
            let m = MPMusicPlayerController.systemMusicPlayer
            localPlaying = m.playbackState == .playing
            hasLocalItem = m.nowPlayingItem != nil
            songProgress = songProgressNow()
            // the wall keeps the pressing in memory; if it has lost it, send it again
            if let p = pressing {
                wall.pushPressing(p.image, track: sleeve.songKey, stamp: p.key)
            }
            sleeve.refresh(title: wall.state.title, artist: wall.state.artist, album: wall.state.album, host: wall.host)
        }
        .onAppear {
            // `-recorddemo`: in on the record two seconds in, out again at eight,
            // so the way in and out can be watched without a hand on the screen
            if CommandLine.arguments.contains("-recorddemo") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { openRecord() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { closeRecord() }
            }
            let m = MPMusicPlayerController.systemMusicPlayer
            m.beginGeneratingPlaybackNotifications()
            localPlaying = m.playbackState == .playing
            hasLocalItem = m.nowPlayingItem != nil
            songProgress = songProgressNow()
            sleeve.refresh(title: wall.state.title, artist: wall.state.artist, album: wall.state.album, host: wall.host)
            refreshPressing()
        }
    }

    // MARK: - The pressing

    /// The colour of the table's front edge, read from the render once, so
    /// the table can be carried past the bottom of the picture.
    private static let tableFoot: Color = {
        guard let cg = UIImage(named: "RoomBase")?.cgImage else { return Ink.ground }
        var px = [UInt8](repeating: 0, count: 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1,
                                      bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            // the middle of the bottom edge, drawn into one pixel
            let h = CGFloat(cg.height), w = CGFloat(cg.width)
            ctx.draw(cg, in: CGRect(x: -w / 2 + 0.5, y: 0, width: w, height: h * 60))
            return true
        }
        guard ok, px[3] > 0 else { return Ink.ground }
        return Color(red: Double(px[0]) / 255, green: Double(px[1]) / 255, blue: Double(px[2]) / 255)
    }()

    /// A stand-in sleeve for `-pressing` in the simulator: deep blue with white bars.
    private static let testSleeve: UIImage = {
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: fmt).image { rc in
            UIColor(red: 0.05, green: 0.08, blue: 0.85, alpha: 1).setFill(); rc.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            UIColor.white.setFill()
            for y in [60, 118, 176] { rc.fill(CGRect(x: 28, y: y, width: 200, height: 26)) }
        }
    }()

    /// `-pressing N` forces a kind, and gives the simulator a record with no song on.
    private static let forcedPressing: Int? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "-pressing"), i + 1 < a.count else { return nil }
        return Int(a[i + 1])
    }()

    /// Only the current song's sleeve can colour the pressing. While artwork
    /// loads, the neutral platter stays visible instead of a guessed colourway.
    private func refreshPressing() {
        let demo = Self.forcedPressing != nil && sleeve.songKey.isEmpty
        // nothing on, but a record being shaped: a preview on a plain
        // record, so the kinds can be looked at before there is a song to
        // keep one for
        let previewing = !demo && sleeve.songKey.isEmpty && previewChoice != nil
        let key = demo ? "girlset|chat" : (previewing ? "preview" : sleeve.songKey)
        // your choice for this album, if you made one, or the one you are
        // shaping now: kind, colours, photo, label. A shaped record is the
        // same on every song of the album, so its design keys on the album
        let albumKey = demo ? "girlset|chat" : sleeve.albumKey
        let choice = previewChoice ?? pressings.choice(for: albumKey)
        let seed = choice == nil ? key : (previewing ? key : albumKey)
        let art = pressings.photo(choice?.photo) ?? (demo ? Self.testSleeve : sleeve.image)
        let stamp = key + "|" + String(sleeve.revision) + "|" + (choice.map { String(describing: $0) } ?? "")
        guard pressing?.key != stamp else { return }
        pressingTask?.cancel()
        let request = UUID(); pressingRequest = request
        // a new song: the record clears; the same song reshaped: the old
        // pressing stays until the new one is drawn, then they cross
        if pressing?.key.hasPrefix(key + "|") != true { pressing = nil }
        guard !key.isEmpty, art != nil || previewing else { return }
        let title = demo ? "CHAT" : sleeve.title
        let artist = demo ? "GIRLSET" : sleeve.artist
        let forced = choice?.kind ?? Self.forcedPressing
        let chosenColours = choice?.colours?.map { Pressing.RGB(r: $0[0], g: $0[1], b: $0[2]) }
        let chosenLabel = choice?.label.flatMap { LabelStyle(rawValue: $0) }
        pressingTask = Task.detached(priority: .userInitiated) {
            let palette = chosenColours ?? Pressing.palette(of: art)
            let p = Pressing.make(key: seed, palette: palette, hasPicture: true,
                                 title: title, artist: artist, forced: forced)
            // the printed label goes into the pressing itself, so it turns with
            // the record and sits in the platter's own perspective
            let label = RecordLabel.styled(sleeve: art, title: title, artist: artist, palette: palette, key: stamp, forcedStyle: chosenLabel)
            guard let img = RecordDesign.render(p, sleeve: art, printed: label), !Task.isCancelled else { return }
            await MainActor.run {
                guard pressingRequest == request else { return }
                pressing = (stamp, img, label)
                // the wall's spin face turns this too, so the deck and the
                // wall are playing the same record
                wall.pushPressing(img, track: key, stamp: stamp)
            }
        }
    }

    // MARK: - The picture, layer by layer

    @ViewBuilder
    private func picture(fit: CGRect, g: RoomGeometry?, size: CGSize) -> some View {
        let duty = dragLight ?? wall.state.brightness
        let accent = light.steadyAccent
        let second = light.palette.count > 1 ? light.palette[1] : accent
        // The render stops at the table's front edge. Zoomed, or on a screen
        // the room does not fill, what is under that is the app's ground: a
        // black band below a lit table. The table's own colour carries on
        // down instead.
        if fit.maxY < size.height {
            Rectangle().fill(Self.tableFoot)
                .frame(width: size.width, height: size.height - fit.maxY + 2)
                .position(x: size.width / 2, y: (fit.maxY + size.height) / 2)
                .allowsHitTesting(false)
        }
        // the room
        Image("RoomBase")
            .resizable()
            .interpolation(.high)
            .frame(width: fit.size.width, height: fit.size.height)
            .offset(x: fit.origin.x, y: fit.origin.y)
        if let g {
            // the pressing on the platter, its printed label in it, turning
            // while the needle is down; gated on the record's own square,
            // which is what the block draws with
            if let rq = g.recordQuad {
                TimelineView(.animation(paused: turningSince == nil)) { tl in
                    let a = turnAngle(at: tl.date)
                    ZStack(alignment: .topLeading) {
                        if let pressing {
                            // the record's own shading from the render, the pressing
                            // multiplied into it, the vinyl's reflections back on top:
                            // the pressing is lit by the deck, not laid over it
                            if let rb = g.recordBox {
                                let sr = rect(box: rb, in: fit)
                                Image("RecordShade").resizable().interpolation(.high)
                                    .frame(width: sr.width, height: sr.height)
                                    .position(x: sr.midX, y: sr.midY)
                            }
                            RecordView(image: pressing.image, quad: rq.map { CGPoint(x: fit.origin.x + fit.width * $0[0], y: fit.origin.y + fit.height * $0[1]) }, angle: a,
                                       blend: g.recordBox == nil ? .normal : .multiply)
                                .frame(width: size.width, height: size.height)
                            if let rb = g.recordBox {
                                let sr = rect(box: rb, in: fit)
                                Image("RecordSpec").resizable().interpolation(.high)
                                    .blendMode(.plusLighter)
                                    .opacity(0.85)
                                    .frame(width: sr.width, height: sr.height)
                                    .position(x: sr.midX, y: sr.midY)
                            }
                        }
                    }
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    // a pressing arrives a beat after the room (it is drawn on
                    // a background task): it fades on rather than popping
                    .animation(.easeInOut(duration: 0.35), value: pressing?.key)
                }
            }
            if let n = g.needle, let lead = g.lead, let track = g.track, let lifts = g.lifts {
                let nr = rect(box: n, in: fit)
                NeedleView(lead: lead, track: track, lifts: lifts, playing: introSettled && playing && close == .none,
                           progress: introSettled && close == .none ? songProgress : nil,
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
            // the mark on the cover: the plates as rendered, in white, tinted
            // with the wall's colour, so they keep their bevels and their shading
            if let bb = g.badgeBox {
                let br = rect(box: bb, in: fit)
                Image("RoomBadge").resizable().interpolation(.high)
                    .colorMultiply(accent)
                    .frame(width: br.width, height: br.height)
                    .position(x: br.midX, y: br.midY)
                    .allowsHitTesting(false)
            } else if let b = g.badge {
                BadgeView(quads: b, fit: fit, accent: accent, lit: max(0.4, light.room))
            }
            // the wall's light on the room, from the second render, laid over
            // everything on the table as well as the room, so the deck, the
            // cover, the arm and the mark on the glass all take it together:
            // the sleeve's first colour where the wall throws it, a second
            // colour under that
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
            let face = rect(g.face, in: fit)
            // the bloom behind the wall: the colour spilling onto the back wall
            RadialGradient(colors: [accent.opacity(0.45 * light.room), second.opacity(0.18 * light.room), .clear],
                           center: .center, startRadius: face.width * 0.35, endRadius: face.width * 1.7)
                .frame(width: face.width * 3.6, height: face.width * 3.6)
                .position(x: face.midX, y: face.midY)
                .blendMode(.screen)
                .allowsHitTesting(false)
            // the wall itself, over its own light
            RoomPanel(px: light.reading.px, duty: duty)
                .frame(width: face.width, height: face.height)
                .position(x: face.midX, y: face.midY)
                .allowsHitTesting(false)
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
    private var playing: Bool {
        if NeedleDemo.on { return NeedleDemo.sample().playing }
        // A paused phone used to keep the arm moving: the wall's last word
        // still said "playing", because the app only ever pushed while it
        // was. When this phone holds the song, this phone decides.
        return hasLocalItem ? localPlaying : wall.state.songPlaying
    }

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
                               onClose: { withAnimation(Motion.scene) { zoomed = false } }, layout: .tuning,
                               sleeve: sleeve.image)
                // measured, so the wall above can make room for a tall board
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                    if abs(h - tuningHeight) > 0.5 { withAnimation(Motion.scene) { tuningHeight = h } }
                }
                // clear of the page marks at the foot of the screen
                .padding(.bottom, 60)
        }
        .frame(width: size.width, height: size.height)
        .transition(.opacity)
    }

    // MARK: - The wall as the control

    /// Where the finger began, as a light level, and whether it has moved.
    @State private var lightStart: Double? = nil
    @State private var lightMoved = false
    @State private var lightDetent = -1

    private func lightNorm(_ v: Double) -> CGFloat { CGFloat((v - 0.05) / 0.95) }

    /// Tapping the wall goes in close. In close, the wall is the light: drag
    /// up or down on it and the wall dims under your finger, relative to
    /// where the finger landed so a grab never jumps it. A hairline marks
    /// where the light is; a lit line and a big number are the finger, and
    /// only exist mid-drag. A tap goes back out. It is the same light as the
    /// LIGHT rail in the controls: one thing, two places to hold it.
    @ViewBuilder
    private func wallTarget(_ r: CGRect) -> some View {
        if zoomed {
            let level = dragLight ?? wall.state.brightness
            ZStack(alignment: .bottomLeading) {
                Color.clear
                // where the light is
                Rectangle().fill(Color.white.opacity(0.28)).frame(height: 1)
                    .padding(.bottom, r.height * lightNorm(wall.state.brightness))
                    .allowsHitTesting(false)
                if dragLight != nil {
                    // the finger: a lit line across the wall, and the number
                    Rectangle().fill(Color.white).frame(height: 2)
                        .shadow(color: light.steadyAccent.opacity(0.9), radius: 6)
                        .shadow(color: .white.opacity(0.6), radius: 2)
                        .padding(.bottom, r.height * lightNorm(level))
                        .allowsHitTesting(false)
                    VStack(spacing: -6) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("\(Int(level * 100))").font(.display(64))
                            Text("%").font(.ui(18, .medium)).opacity(0.7)
                        }
                        Text("LIGHT").font(.machine(10)).kerning(1.8).opacity(0.7)
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 10, y: 2)
                    .frame(width: r.width, height: r.height)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .frame(width: r.width, height: r.height)
            .contentShape(Rectangle())
            .position(x: r.midX, y: r.midY)
            .animation(.easeOut(duration: 0.15), value: dragLight == nil)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if lightStart == nil {
                            lightStart = wall.state.brightness; lightMoved = false; Taps.warm()
                        }
                        guard let start = lightStart else { return }
                        if !lightMoved, abs(g.translation.height) > 6 { lightMoved = true }
                        guard lightMoved else { return }
                        // relative to touch-down; one percent steps, a detent every five
                        let delta = -Double(g.translation.height / max(1, r.height)) * 0.95
                        let v = min(1.0, max(0.05, ((start + delta) / 0.01).rounded() * 0.01))
                        if v != dragLight {
                            dragLight = v
                            let d = Int(v * 20)
                            if d != lightDetent { Taps.detent(intensity: 0.25 + 0.45 * v); lightDetent = d }
                        }
                    }
                    .onEnded { _ in
                        if lightMoved, let v = dragLight { wall.send(["brightness": v]); Taps.commit() }
                        else { withAnimation(Motion.scene) { zoomed = false } }
                        lightStart = nil; lightMoved = false; dragLight = nil
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("The wall")
            .accessibilityValue("Light \(Int(level * 100)) percent")
            .accessibilityHint("Drag up or down to set the light. Tap to go back.")
        } else {
            Color.clear
                .contentShape(Rectangle())
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .onTapGesture { if close == .none { withAnimation(Motion.scene) { zoomed.toggle() } } }
                .accessibilityLabel("Tune the wall")
                .accessibilityAddTraits(.isButton)
        }
    }

    /// From straight above: the overhead still, the pressing on the record
    /// in its shading, the wall's light on the deck. The end of the dive.
    @ViewBuilder
    private func overhead(size: CGSize, fit: CGRect, g: RoomGeometry?) -> some View {
        let accent = light.steadyAccent
        ZStack(alignment: .topLeading) {
            Image("OverheadBase")
                .resizable()
                .interpolation(.high)
                .frame(width: fit.size.width, height: fit.size.height)
                .offset(x: fit.origin.x, y: fit.origin.y)
            if let g, let pressing, let rq = g.overRecordQuad {
                if let rb = g.overRecordBox {
                    let sr = rect(box: rb, in: fit)
                    Image("OverheadShade").resizable().interpolation(.high)
                        .frame(width: sr.width, height: sr.height)
                        .position(x: sr.midX, y: sr.midY)
                }
                RecordView(image: pressing.image, quad: rq.map { CGPoint(x: fit.origin.x + fit.width * $0[0], y: fit.origin.y + fit.height * $0[1]) },
                           angle: turned, blend: g.overRecordBox == nil ? .normal : .multiply)
                    .frame(width: size.width, height: size.height)
                    .id(pressing.key)
                    .transition(.opacity)
                if let rb = g.overRecordBox {
                    let sr = rect(box: rb, in: fit)
                    Image("OverheadSpec").resizable().interpolation(.high)
                        .blendMode(.plusLighter)
                        .opacity(0.85)
                        .frame(width: sr.width, height: sr.height)
                        .position(x: sr.midX, y: sr.midY)
                }
            }
            Image("OverheadLight")
                .resizable()
                .interpolation(.high)
                .frame(width: fit.size.width, height: fit.size.height)
                .colorMultiply(accent)
                .blendMode(.screen)
                .opacity(min(1, 1.1 * light.room))
                .offset(x: fit.origin.x, y: fit.origin.y)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.3), value: pressing?.key)
        .allowsHitTesting(false)
    }

    /// Close on the record: the pressing to shape, under it; the record itself
    /// and Done are the way back.
    @ViewBuilder
    private func pressingClose(size: CGSize, fit: CGRect, g: RoomGeometry?) -> some View {
        let demo = Self.forcedPressing != nil && sleeve.songKey.isEmpty
        let albumKey = demo ? "girlset|chat" : sleeve.albumKey
        ZStack(alignment: .topLeading) {
            // the deck is pale from above: a shade over its lower half so the
            // panel reads, and the record above it stays the bright thing
            LinearGradient(stops: [.init(color: .clear, location: 0.42), .init(color: .black.opacity(0.62), location: 0.62), .init(color: .black.opacity(0.78), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
            if let g, let rq = g.overRecordQuad {
                let rr = rect(rq, in: fit)
                Color.clear
                    .contentShape(Circle())
                    .frame(width: rr.width, height: rr.height)
                    .position(x: rr.midX, y: rr.midY)
                    .onTapGesture { closeRecord() }
                    .accessibilityLabel("Back to the room")
                    .accessibilityAddTraits(.isButton)
            }
            VStack(spacing: 0) {
                HStack {
                    // over the pale deck, not the dark room: dark ink up here
                    Text("THE RECORD").font(.machine(10)).kerning(1.6).foregroundStyle(Color.black.opacity(0.55))
                    Spacer()
                    Button { closeRecord() } label: {
                        Text("Done").font(.ui(14, .semibold)).foregroundStyle(Ink.ink)
                            .padding(.horizontal, 18).frame(height: 38)
                            .background(Capsule().fill(.ultraThinMaterial))
                            .overlay(Capsule().strokeBorder(light.chrome.opacity(0.18), lineWidth: 1))
                    }
                    .buttonStyle(PressStyle(scale: 0.94))
                }
                .padding(.horizontal, 24)
                .padding(.top, 62)
                Spacer()
                PressingPanel(choice: Binding(get: { previewChoice ?? pressings.choice(for: albumKey) ?? PressingChoice() },
                                              set: { previewChoice = $0 }),
                              albumKey: albumKey, sleeve: demo ? Self.testSleeve : sleeve.image,
                              accent: light.steadyAccent, ink: panelInk)
                    // clear of the page marks at the foot of the screen
                    .padding(.bottom, 60)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .transition(.opacity)
    }

    /// The way in: the arm lifts home and the record stops, then the dive.
    /// Without the film, a plain crossfade to the overhead.
    private func openRecord() {
        diveLog.notice("openRecord from \(String(describing: close))")
        guard close == .none else { return }
        previewChoice = nil
        close = .lifting
        Taps.detent(intensity: 0.4)
        let lift = needleDown ? 0.85 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + lift) {
            guard close == .lifting else { return }
            if DiveTrack.available {
                // the film's first frame is the room; the room goes as it starts,
                // and the overhead takes its place beneath once the wall is out of shot
                close = .diving
                // a film that never reports its end (a stalled player) must
                // not strand the room mid-dive with the record untappable
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.diveLength + 1.0) {
                    if close == .diving { overheadShown = true; close = .close }
                }
            } else {
                withAnimation(.easeInOut(duration: 0.7)) { overheadShown = true; close = .close }
            }
        }
    }

    /// How long the dive film runs, for the way in and the way out alike.
    private static let diveLength: Double = {
        guard let t = DiveTrack.loaded, t.fps > 0 else { return 1.2 }
        return Double(t.frames.count) / t.fps
    }()

    /// And out: the film backwards, the room back beneath it, then the arm
    /// drops back where the song has got to. What was not kept goes.
    private func closeRecord() {
        diveLog.notice("closeRecord from \(String(describing: close))")
        guard close == .close else { return }
        Taps.detent(intensity: 0.3)
        if DiveTrack.available {
            // the panel goes as the film starts on the overhead, which it matches;
            // the overhead itself goes once the film has it covered
            // the film opens on the overhead still, so the scene itself can go now
            withAnimation(.easeOut(duration: 0.2)) { close = .rising }
            overheadShown = false
            // and the same insurance on the way out: the draft is let go
            // and the record is tappable again whatever the film reports
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.diveLength + 1.0) {
                if close == .rising { overheadShown = false; close = .none; previewChoice = nil }
            }
        } else {
            withAnimation(.easeInOut(duration: 0.7)) { overheadShown = false; close = .none }
            previewChoice = nil
        }
    }

    // MARK: - Fitting the render to the screen

    /// The render is 390 x 844 at 3x. Scaled to fill, centred, so a taller
    /// or wider phone crops the room's edges and never stretches it. Zoomed,
    /// the same picture is scaled about the wall until the wall spans most
    /// of the width, or as much as fits above the tuning board, and carried
    /// up so the board sits under it and never over it.
    private func fitting(_ size: CGSize) -> CGRect {
        let iw: CGFloat = 390, ih: CGFloat = 844
        let s = max(size.width / iw, size.height / ih)
        var fit = CGRect(x: (size.width - iw * s) / 2, y: (size.height - ih * s) / 2, width: iw * s, height: ih * s)
        if zoomed, let g = RoomGeometry.loaded {
            let face = rect(g.face, in: fit)
            // the strip the wall may use: under the title row, above the board
            let top: CGFloat = 62 + 38 + 16
            let bottom = size.height - 60 - tuningHeight - 14
            let side = min(size.width * 0.84, max(150, bottom - top))
            // Held between covering the screen and a single step closer. Above
            // the top of that range the room is scaled until the wall fills the
            // width and the table is cropped away; below it, under a tall
            // board, the picture shrinks off the edges of the screen and the
            // app's own dark ground shows down both sides.
            let k = max(1.0, min(1.22, side / face.width))
            let centre = min(size.height * 0.33, bottom - side / 2)
            let target = CGPoint(x: size.width / 2, y: max(top + side / 2, centre))
            fit = CGRect(x: target.x - (face.midX - fit.origin.x) * k,
                         y: target.y - (face.midY - fit.origin.y) * k,
                         width: fit.width * k, height: fit.height * k)
            // The room still fills the screen. Carrying the wall up used to
            // lift the picture's own bottom edge above the foot of the screen
            // and leave a slab of flat table colour under it.
            fit.origin.y = min(0, max(size.height - fit.height, fit.origin.y))
            fit.origin.x = min(0, max(size.width - fit.width, fit.origin.x))
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
    // read on appear: the keys are remade with every evaluation of the
    // room, and a system player read is an XPC call
    @State private var playing = false
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
        .onAppear { playing = MPMusicPlayerController.systemMusicPlayer.playbackState == .playing }
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
