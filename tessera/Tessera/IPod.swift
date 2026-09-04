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
    case root, speed, effect, colours, finish, timer, timing, clock
    var title: String {
        switch self {
        case .root: "Tessera"
        case .speed: "Speed"
        case .effect: "Lamp"
        case .colours: "Colours"
        case .finish: "Finish"
        case .timer: "Timer"
        case .timing: "Timing"
        case .clock: "Clock"
        }
    }
}

// MARK: - The object

struct IPodView: View {
    @Environment(WallSession.self) private var wall
    let light: Lighting
    @Binding var dragLight: Double?
    @Binding var touching: Bool
    var onSetup: () -> Void
    var onStudio: () -> Void
    var onArchive: () -> Void
    var onZoom: () -> Void

    @State private var pages: [IPodPage] = []            // empty = Now Playing
    @State private var selected: [IPodPage: Int] = [:]
    @State private var scrub: Scrub = .light
    @State private var scrubbing: Double? = nil
    @State private var scrubShownUntil: Date = .distantPast
    @State private var playing = MPMusicPlayerController.systemMusicPlayer.playbackState == .playing
    @AppStorage("lyrics.nudge") private var lyricsNudge: Double = 0
    @AppStorage("spin.beat") private var beatOn = false

    private enum Scrub { case light, speed }
    private var page: IPodPage? { pages.last }
    private var accent: Color { light.steadyAccent }

    var body: some View {
        ZStack(alignment: .topLeading) {
            IPodBody()
            screen
                .frame(width: IPodMetrics.screen.width, height: IPodMetrics.screen.height)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .offset(x: IPodMetrics.screen.minX, y: IPodMetrics.screen.minY)
            ClickWheel(
                accent: accent,
                onTurn: { turn($0) },
                onMenu: { menu() },
                onSelect: { select() },
                onPrev: { MPMusicPlayerController.systemMusicPlayer.skipToPreviousItem(); Taps.commit() },
                onNext: { MPMusicPlayerController.systemMusicPlayer.skipToNextItem(); Taps.commit() },
                onPlay: { togglePlay() },
                onHoldPlay: { wall.send(["mode": wall.state.mode == "off" ? "art" : "off"]); Taps.found() },
                onTouch: { on in
                    touching = on
                    if !on, let v = scrubbing {
                        if scrub == .light { wall.send(["brightness": v]); dragLight = nil }
                        else { wall.send(["rpm": v]) }
                        scrubbing = nil
                        Taps.commit()
                    }
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
        .onAppear { MPMusicPlayerController.systemMusicPlayer.beginGeneratingPlaybackNotifications() }
    }

    // MARK: - Screen

    @ViewBuilder private var screen: some View {
        ZStack {
            Color.black
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
                    showScrub: scrubbing != nil || Date() < scrubShownUntil,
                    accent: accent,
                    onTapWall: onZoom
                )
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(Motion.settle, value: pages)
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
        scrubShownUntil = Date().addingTimeInterval(1.6)
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
                scrubShownUntil = Date().addingTimeInterval(1.6)
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
        if playing { m.pause() } else { StandIn.requestMusicAccess { m.play() } }
        playing.toggle()
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
                mode("ambient", "Lamp"), mode("clock", "Clock"), mode("off", "Off"),
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
            case "clock", "timer":
                out.append(IPodItem(id: "timer", title: "Timer", value: s.mode == "timer" ? "running" : nil, kind: .submenu(.timer)))
                out.append(IPodItem(id: "clock24", title: "Clock", value: s.clock24h ? "24 hour" : "12 hour", kind: .submenu(.clock)))
            case "lyrics":
                out.append(IPodItem(id: "timing", title: "Timing", value: lyricsNudge == 0 ? "on time" : lyricsNudge < 0 ? "sooner" : "later", kind: .submenu(.timing)))
            default: break
            }
            out.append(IPodItem(id: "studio", title: "Studio", kind: .action { onStudio() }))
            out.append(IPodItem(id: "archive", title: "Archive", kind: .action { onArchive() }))
            out.append(IPodItem(id: "settings", title: "Settings", kind: .action { onSetup() }))
            return out
        case .speed:
            return [("33⅓", 33.333), ("45", 45.0), ("78", 45.0), ("Slow", 7.5), ("Free", s.rpm)].enumerated().map { i, o in
                IPodItem(id: "sp\(i)", title: o.0, value: abs(s.rpm - o.1) < 0.2 && o.0 != "Free" ? "on" : nil,
                         kind: .pick(abs(s.rpm - o.1) < 0.2) { wall.send(["rpm": min(45.0, o.1)]) })
            } + [IPodItem(id: "beat", title: "Spin on the beat", value: beatOn ? "on" : "off",
                          kind: .toggle(beatOn) { beatOn = $0 })]
        case .effect:
            return ["plaid", "weave", "deco", "snake", "solid", "breathe", "pulse", "rainbow", "gradient"].map { e in
                IPodItem(id: e, title: e == "gradient" ? "Fade" : e.capitalized, value: s.effect == e ? "on" : nil,
                         kind: .pick(s.effect == e) { wall.send(["effect": e]) })
            }
        case .colours:
            return [IPodItem(id: "c1", title: "Colour", value: s.color, kind: .action {}),
                    IPodItem(id: "c2", title: "Second colour", value: s.color2, kind: .action {}),
                    IPodItem(id: "hint", title: "Pick them in Studio", kind: .action { onStudio() })]
        case .finish:
            return [("clean", "Clean"), ("dither", "Dither"), ("poster", "Poster")].map { f in
                IPodItem(id: f.0, title: f.1, value: s.finish == f.0 ? "on" : nil,
                         kind: .pick(s.finish == f.0) { wall.send(["finish": f.0]) })
            }
        case .timer:
            let mins: [Double] = [5, 10, 15, 30, 60]
            return mins.map { m in
                IPodItem(id: "t\(Int(m))", title: "\(Int(m)) minutes", kind: .pick(false) { wall.send(["timer_min": m]) })
            } + [IPodItem(id: "tstop", title: "Stop", kind: .pick(false) { wall.send(["timer_min": 0.0]) })]
        case .timing:
            return [("Sooner", -0.4), ("On time", 0.0), ("Later", 0.4)].map { o in
                IPodItem(id: o.0, title: o.0, value: lyricsNudge == o.1 ? "on" : nil,
                         kind: .pick(lyricsNudge == o.1) { lyricsNudge = o.1 })
            }
        case .clock:
            return [("24 hour", true), ("12 hour", false)].map { o in
                IPodItem(id: o.0, title: o.0, value: s.clock24h == o.1 ? "on" : nil,
                         kind: .pick(s.clock24h == o.1) { wall.send(["clock_24h": o.1]) })
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
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black)
                .frame(width: IPodMetrics.bezel.width, height: IPodMetrics.bezel.height)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
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
    var onTurn: (Int) -> Void
    var onMenu: () -> Void
    var onSelect: () -> Void
    var onPrev: () -> Void
    var onNext: () -> Void
    var onPlay: () -> Void
    var onHoldPlay: () -> Void
    var onTouch: (Bool) -> Void

    @State private var lastAngle: Double? = nil
    @State private var travel: Double = 0
    @State private var moved: CGFloat = 0
    @State private var down = false
    @State private var startSector: Sector? = nil
    @State private var holdWork: DispatchWorkItem? = nil
    @State private var held = false
    @State private var pressed: Sector? = nil
    @State private var downAt: CGPoint = .zero

    enum Sector { case center, top, bottom, left, right }

    private let r = IPodMetrics.wheelR
    private let br = IPodMetrics.buttonR

    var body: some View {
        ZStack {
            // the ring: a shade lighter than the body, faintly concave.
            // With the render underneath, the ring is already there.
            if drawn {
                Circle()
                    .fill(RadialGradient(colors: [Color(hex: 0x1A1816), Color(hex: 0x232020)],
                                         center: .center, startRadius: br, endRadius: r))
                Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                Circle().strokeBorder(Color.black.opacity(0.5), lineWidth: 1).padding(1)
            }
            // labels, in the wheel's own quiet ink
            Text("MENU")
                .font(.display(10)).kerning(1.6)
                .foregroundStyle(pressed == .top ? Ink.ink : Ink.dim)
                .offset(y: -(r - 24))
            GlyphShape(glyph: .rewind, lineWidth: 1.5).frame(width: 16, height: 16)
                .foregroundStyle(pressed == .left ? Ink.ink : Ink.dim)
                .offset(x: -(r - 24))
            GlyphShape(glyph: .forward, lineWidth: 1.5).frame(width: 16, height: 16)
                .foregroundStyle(pressed == .right ? Ink.ink : Ink.dim)
                .offset(x: r - 24)
            HStack(spacing: 3) {
                GlyphShape(glyph: .play, lineWidth: 1.5).frame(width: 10, height: 10)
                GlyphShape(glyph: .pause, lineWidth: 1.5).frame(width: 10, height: 10)
            }
            .foregroundStyle(pressed == .bottom ? Ink.ink : Ink.dim)
            .offset(y: r - 24)
            // the centre button, a dish; on the render, only its press shows
            Circle()
                .fill(drawn
                      ? AnyShapeStyle(RadialGradient(colors: [Color(hex: 0x0C0B0A), Color(hex: 0x141210)],
                                                     center: .center, startRadius: 0, endRadius: br))
                      : AnyShapeStyle(Color.white.opacity(pressed == .center ? 0.06 : 0)))
                .frame(width: br * 2, height: br * 2)
                .overlay { Circle().strokeBorder(Color.white.opacity(pressed == .center ? 0.22 : (drawn ? 0.09 : 0)), lineWidth: 1) }
                .scaleEffect(pressed == .center ? 0.97 : 1)
        }
        // The ZStack takes the size of its children, and with the rendered
        // front underneath the ring is no longer one of them: only the 84
        // point button is. Everything below assumes a square the size of
        // the whole wheel, so give it that size, or touches land in a
        // coordinate space a third the size with its centre in the wrong
        // place, which is exactly how the wheel felt.
        .frame(width: r * 2, height: r * 2)
        .contentShape(Circle())
        // The touches come through UIKit, not a SwiftUI DragGesture: the
        // paging scroll view around the screen took every circular drag as
        // a page swipe and every tap as the start of one. A UIKit recognizer
        // can tell the pager's pan to wait for it, and it never yields once
        // a finger is on the wheel. See WheelTouches below.
        .overlay {
            WheelTouches(radius: r,
                         onDown: { began(at: $0) },
                         onMove: { moved(to: $0) },
                         onUp: { p, cancelled in ended(at: p, cancelled: cancelled) })
        }
        .animation(Motion.blink, value: pressed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Click wheel")
    }

    private func began(at p: CGPoint) {
        let c = CGPoint(x: r, y: r)
        let dx = p.x - c.x, dy = p.y - c.y
        let dist = hypot(dx, dy)
        down = true
        downAt = p
        onTouch(true)
        Taps.warm()
        travel = 0; moved = 0; held = false
        lastAngle = dist > br * 0.7 ? atan2(dy, dx) : nil
        startSector = sector(dx: dx, dy: dy, dist: dist)
        pressed = startSector
        if startSector == .bottom { scheduleHold() }
    }

    private func moved(to p: CGPoint) {
        guard down else { return }
        let c = CGPoint(x: r, y: r)
        let dx = p.x - c.x, dy = p.y - c.y
        let dist = hypot(dx, dy)
        moved = max(moved, hypot(p.x - downAt.x, p.y - downAt.y))
        if moved > 8 { cancelHold(); pressed = nil }
        guard dist > br * 0.7 else { lastAngle = nil; return }   // the button does not turn
        let a = atan2(dy, dx)
        if let last = lastAngle {
            var d = a - last
            if d > .pi { d -= 2 * .pi } else if d < -.pi { d += 2 * .pi }
            travel += d
            let step = Double.pi / 12                   // 24 detents a turn
            while travel >= step { travel -= step; onTurn(1) }
            while travel <= -step { travel += step; onTurn(-1) }
        }
        lastAngle = a
    }

    private func ended(at p: CGPoint, cancelled: Bool) {
        guard down else { return }
        cancelHold()
        let tap = !cancelled && moved < 8 && !held
        if tap, let s = startSector {
            switch s {
            case .center: onSelect()
            case .top: onMenu()
            case .left: onPrev()
            case .right: onNext()
            case .bottom: onPlay()
            }
        }
        pressed = nil
        down = false
        onTouch(false)
    }

    private func sector(dx: CGFloat, dy: CGFloat, dist: CGFloat) -> Sector {
        if dist < br { return .center }
        let a = atan2(dy, dx) * 180 / .pi     // 0 = right, 90 = down
        if a > -135 && a <= -45 { return .top }
        if a > -45 && a <= 45 { return .right }
        if a > 45 && a <= 135 { return .bottom }
        return .left
    }

    private func scheduleHold() {
        let w = DispatchWorkItem { held = true; onHoldPlay() }
        holdWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: w)
    }

    private func cancelHold() {
        holdWork?.cancel(); holdWork = nil
    }
}

// MARK: - Touches for the wheel

/// The wheel's touch surface. UIKit, on purpose: the screen sits inside a
/// paging scroll view, and SwiftUI cannot tell that scroll view to keep its
/// hands off one control. UIKit can. The pager's pan is made to wait for
/// this recognizer to fail, and this recognizer takes the touch the instant
/// it lands on the wheel, so a circular drag turns the wheel and a tap
/// presses it, and neither becomes a page swipe. A touch outside the ring
/// is not this view's at all, so pages still swipe from anywhere else.
struct WheelTouches: UIViewRepresentable {
    let radius: CGFloat
    var onDown: (CGPoint) -> Void
    var onMove: (CGPoint) -> Void
    var onUp: (CGPoint, Bool) -> Void

    func makeUIView(context: Context) -> WheelTouchView {
        let v = WheelTouchView()
        v.backgroundColor = .clear
        v.isMultipleTouchEnabled = false
        return v
    }

    func updateUIView(_ v: WheelTouchView, context: Context) {
        v.radius = radius
        v.onDown = onDown
        v.onMove = onMove
        v.onUp = onUp
    }
}

final class WheelTouchView: UIControl {
    // A UIControl, not a plain view: a scroll view will not cancel a
    // control's touches when it decides to scroll (touchesShouldCancel says
    // no for controls), which is half of why a slider inside a scroll view
    // keeps working. The other half is below.
    var radius: CGFloat = 0
    var onDown: ((CGPoint) -> Void)?
    var onMove: ((CGPoint) -> Void)?
    var onUp: ((CGPoint, Bool) -> Void)?
    private let touch = ImmediateTouch()
    private weak var pager: UIScrollView?
    override init(frame: CGRect) {
        super.init(frame: frame)
        touch.cancelsTouchesInView = false
        touch.addTarget(self, action: #selector(handle(_:)))
        addGestureRecognizer(touch)
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Only the ring and the button are the wheel; the corners of the
    /// square belong to the body behind them.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        return hypot(point.x - c.x, point.y - c.y) <= radius
    }

    /// The paging scroll view this wheel sits in, found when a finger
    /// lands, by which time the view is certainly in place.
    private func findPager() -> UIScrollView? {
        var v = superview
        while let s = v {
            if let sv = s as? UIScrollView { return sv }
            v = s.superview
        }
        return nil
    }

    @objc private func handle(_ g: UIGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            // Take the pager's pan away for the length of this touch, right
            // now and synchronously. SwiftUI's scrollDisabled arrives a
            // render later, and by then the pan had begun and cancelled us.
            if let sv = findPager() {
                pager = sv
                sv.panGestureRecognizer.isEnabled = false
            }
            onDown?(p)
        case .changed:
            onMove?(p)
        case .ended:
            pager?.panGestureRecognizer.isEnabled = true
            onUp?(p, false)
        case .cancelled, .failed:
            pager?.panGestureRecognizer.isEnabled = true
            onUp?(p, true)
        default:
            break
        }
    }
}

/// A recognizer that begins the moment a finger lands and follows it until
/// it lifts. There is nothing to recognise: the wheel wants every touch.
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

    var body: some View {
        VStack(spacing: 0) {
            StatusStrip(title: "Now Playing", playing: playing, link: link)
            HStack(alignment: .top, spacing: 12) {
                Button(action: onTapWall) {
                    PanelCanvas(px: reading.px, duty: duty)
                        .frame(width: 150, height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("The wall. Opens large.")
                VStack(alignment: .leading, spacing: 5) {
                    Text(headline)
                        .font(.display(15))
                        .foregroundStyle(Ink.ink)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                    if let a = state.artist, !a.isEmpty, !(state.title ?? "").isEmpty {
                        Text(a).font(.ui(12)).foregroundStyle(Ink.dim).lineLimit(2)
                    }
                    if let al = state.album, !al.isEmpty, al != state.artist, !(state.title ?? "").isEmpty {
                        Text(al).font(.ui(11)).foregroundStyle(Ink.faint).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Text(modeWord)
                        .font(.machine(9))
                        .textCase(.uppercase)
                        .kerning(0.8)
                        .foregroundStyle(Ink.faint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            Spacer(minLength: 0)
            bar
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
        }
    }

    private var headline: String {
        if let t = state.title, !t.isEmpty { return t }
        if state.mode == "off" { return "Asleep" }
        switch state.mode {
        case "ambient": return "Lamp"
        case "clock": return "Clock"
        case "timer": return "Timer"
        case "ticker": return "Lettering"
        default: return "Nothing playing"
        }
    }

    private var modeWord: String {
        switch state.mode {
        case "cd": "spinning"
        case "ambient": "lamp"
        case "lyrics": "lyrics"
        case "nine": "nine"
        case "clock": "clock"
        case "timer": "timer"
        case "off": "off"
        default: "art"
        }
    }

    /// The bar the classic put at the bottom: the song's progress, or while
    /// the wheel turns, the thing it is turning.
    @ViewBuilder private var bar: some View {
        if showScrub {
            HStack(spacing: 8) {
                Text(scrub).font(.machine(9)).kerning(0.8).foregroundStyle(Ink.dim)
                ScreenRule(fraction: scrubValue.0, tint: Ink.ink)
                Text(scrubValue.1).font(.machine(9)).foregroundStyle(Ink.ink)
            }
        } else if let f = songFraction {
            HStack(spacing: 8) {
                Text(clock(state.songNow)).font(.machine(9)).foregroundStyle(Ink.dim)
                ScreenRule(fraction: f, tint: accent)
                Text(clock(state.songOf)).font(.machine(9)).foregroundStyle(Ink.dim)
            }
        } else {
            ScreenRule(fraction: 0, tint: accent)
        }
    }

    private var songFraction: Double? {
        guard let of = state.songOf, of > 1, let at = state.songNow else { return nil }
        return min(1, max(0, at / of))
    }

    private func clock(_ s: Double?) -> String {
        guard let s, s.isFinite, s >= 0 else { return "-:--" }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

/// The screen's top strip, as the classic drew it: what this screen is on
/// the left, the state of things on the right.
struct StatusStrip: View {
    let title: String
    let playing: Bool
    let link: LinkState

    var body: some View {
        HStack {
            Text(title).font(.ui(11, .semibold)).foregroundStyle(Ink.ink)
            Spacer()
            HStack(spacing: 6) {
                GlyphShape(glyph: playing ? .play : .pause, lineWidth: 1.4)
                    .frame(width: 8, height: 8)
                    .foregroundStyle(Ink.dim)
                Circle()
                    .fill(link.isLive ? Ink.moss : link.isStandIn ? Ink.faint : Ink.tile)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 20)
        .background(Color.white.opacity(0.05))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }
}

/// A rule of marks, like the lock screen's.
struct ScreenRule: View {
    let fraction: Double
    let tint: Color
    var body: some View {
        GeometryReader { geo in
            let n = 36
            let cell = geo.size.width / CGFloat(n)
            let filled = Int((max(0, min(1, fraction)) * Double(n)).rounded())
            HStack(spacing: cell * 0.35) {
                ForEach(0..<n, id: \.self) { i in
                    Rectangle()
                        .fill(i < filled ? tint : Color.white.opacity(0.14))
                        .frame(width: cell * 0.65)
                }
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Menu

struct IPodMenuView: View {
    let title: String
    let items: [IPodItem]
    let selected: Int
    let accent: Color
    var onTap: (Int) -> Void

    private let rowH: CGFloat = 26

    var body: some View {
        VStack(spacing: 0) {
            StatusStrip(title: title, playing: false, link: .live)
                .overlay(alignment: .trailing) { Color.black.opacity(0.001).frame(width: 40) } // no state on menus
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                            let on = i == selected
                            HStack(spacing: 8) {
                                Text(item.title)
                                    .font(.ui(13, on ? .semibold : .regular))
                                    .foregroundStyle(on ? Ink.ground : Ink.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                if let v = item.value {
                                    Text(v)
                                        .font(.ui(11))
                                        .foregroundStyle(on ? Ink.ground.opacity(0.7) : Ink.dim)
                                        .lineLimit(1)
                                }
                                if case .submenu = item.kind {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(on ? Ink.ground.opacity(0.7) : Ink.faint)
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(height: rowH)
                            .background(on ? Ink.ink : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { onTap(i) }
                            .id(i)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onChange(of: selected) { _, new in
                    withAnimation(Motion.blink) { proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
    }
}
