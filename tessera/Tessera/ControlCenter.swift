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
                // three bars of different lengths: a board of controls
                VStack(alignment: .leading, spacing: 3.5) {
                    bar(16); bar(10); bar(13)
                }
            }
            FrostedKey(ink: ink, label: "Settings", action: onSetup) {
                VStack(spacing: 4) { rail(0.62); rail(0.30) }
            }
        }
    }

    private func bar(_ w: CGFloat) -> some View {
        Capsule().fill(ink.ink.opacity(0.9)).frame(width: w, height: 2.5)
    }

    private func rail(_ at: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(ink.ink.opacity(0.35)).frame(width: 16, height: 2)
            Circle().fill(ink.ink.opacity(0.95)).frame(width: 5, height: 5).offset(x: 16 * at - 2.5)
        }
    }
}

/// A round key on glass.
struct FrostedKey<Content: View>: View {
    var size: CGFloat = 40
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

    @State private var lastDetent = -1
    @State private var speedDrag: Double? = nil
    @AppStorage("lyrics.nudge") private var lyricsNudge: Double = 0
    private var accent: Color { light.steadyAccent }
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
                                    Text("CONTROLS").font(.machine(10)).kerning(1.6).foregroundStyle(ink.dim)
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
                            .padding(.bottom, 44)
                            .frame(minHeight: geo.size.height)
                            // the glass itself closes on a tap; the blocks keep their own taps
                            .background(Color.black.opacity(0.001).onTapGesture { onClose() })
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .scrollIndicators(.hidden)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            case .tuning:
                VStack(spacing: gutter) {
                    faces
                    context
                }
                .padding(.horizontal, 16)
            }
        }
        // the glass takes the room's own scheme: light over the white room,
        // dark over the dark designs, so it frosts instead of muddying
        .environment(\.colorScheme, ink.ink == Ink.ink ? .dark : .light)
    }

    /// A round key with a cross: the one sure way out.
    private var closeKey: some View {
        Button { onClose(); Taps.detent(intensity: 0.3) } label: {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                Circle().strokeBorder(ink.ink.opacity(0.14), lineWidth: 1)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 11, y: 11))
                    p.move(to: CGPoint(x: 11, y: 0)); p.addLine(to: CGPoint(x: 0, y: 11))
                }
                .stroke(ink.ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: 11, height: 11)
            }
            .frame(width: 40, height: 40)
        }
        .buttonStyle(PressStyle(scale: 0.92))
        .accessibilityLabel("Close")
    }

    // MARK: Now: the record on, and where the needle is

    /// What is on, its sleeve, and how far the needle has got; one key to
    /// hold it or let it go.
    private var nowCard: some View {
        let title = wall.state.title.flatMap { $0.isEmpty ? nil : $0 }
        let elapsed = wall.state.songNow, total = wall.state.songOf
        let fraction = wall.state.songFraction ?? 0
        return HStack(spacing: 14) {
            Group {
                if let sleeve {
                    Image(uiImage: sleeve).resizable().interpolation(.medium)
                } else if let px = light.reading.px, let img = LabelArt.flat(px) {
                    Image(uiImage: img).resizable().interpolation(.medium)
                } else {
                    PanelCanvas(px: light.reading.px, duty: value)
                }
            }
            .frame(width: 66, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(title ?? (wall.state.mode == "off" ? "Asleep" : "Nothing on"))
                    .font(.ui(15, .semibold)).foregroundStyle(ink.ink).lineLimit(1)
                Text(title == nil ? "Play something and it lands here." : [wall.state.artist, wall.state.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.ui(12)).foregroundStyle(ink.dim).lineLimit(1)
                if title != nil {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(ink.fill).frame(height: 4)
                            Capsule().fill(accent).frame(width: max(4, geo.size.width * fraction), height: 4)
                        }
                        .frame(height: 4)
                        .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 10)
                    HStack {
                        Text(Self.clock(elapsed)).font(.machine(9)).foregroundStyle(ink.dim)
                        Spacer()
                        Text(total.map { "-" + Self.clock(max(0, $0 - (elapsed ?? 0))) } ?? "").font(.machine(9)).foregroundStyle(ink.dim)
                    }
                }
            }
            if title != nil {
                Button {
                    let m = MPMusicPlayerController.systemMusicPlayer
                    if wall.state.songPlaying || m.playbackState == .playing { m.pause() } else { m.play() }
                    Taps.detent(intensity: 0.5)
                } label: {
                    ZStack {
                        Circle().fill(ink.ink)
                        GlyphShape(glyph: (wall.state.songPlaying || MPMusicPlayerController.systemMusicPlayer.playbackState == .playing) ? .pause : .play, lineWidth: 1.6)
                            .frame(width: 14, height: 14).foregroundStyle(Ink.ground)
                    }
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(PressStyle(scale: 0.92))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Slab(radius: 26, ink: ink))
    }

    private static func clock(_ s: Double?) -> String {
        guard let s, s.isFinite else { return "0:00" }
        let t = Int(s.rounded()); return String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: Light: a wide slab with a rail across it

    private var value: Double { dragLight ?? wall.state.brightness }

    private var lightSlab: some View {
        let f = (value - 0.05) / 0.95
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                PanelCanvas(px: light.reading.px, duty: value)
                    .frame(width: 112, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: accent.opacity(0.4 * light.room), radius: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text("LIGHT").font(.machine(9)).kerning(1.2).foregroundStyle(ink.dim)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(Int(value * 100))")
                            .font(.display(56)).foregroundStyle(ink.ink)
                            .contentTransition(.numericText())
                        Text("%").font(.ui(15, .medium)).foregroundStyle(ink.dim)
                    }
                    Text(wall.state.title.flatMap { $0.isEmpty ? nil : $0 } ?? (wall.state.mode == "off" ? "Asleep" : "Nothing playing"))
                        .font(.ui(13)).foregroundStyle(ink.dim).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(ink.fill).frame(height: 8)
                    Capsule().fill(accent).frame(width: max(8, geo.size.width * CGFloat(f)), height: 8)
                    Circle().fill(ink.ink).frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 1))
                        .offset(x: (geo.size.width - 26) * CGFloat(f))
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                }
                .frame(height: 26)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let t = Double((g.location.x - 13) / max(1, geo.size.width - 26))
                            let v = min(1.0, max(0.05, 0.05 + 0.95 * min(1, max(0, t))))
                            let stepped = (v / 0.01).rounded() * 0.01
                            if stepped != dragLight {
                                dragLight = stepped
                                let d = Int(stepped * 20)
                                if d != lastDetent { Taps.detent(intensity: 0.25 + 0.45 * stepped); lastDetent = d }
                            }
                        }
                        .onEnded { _ in
                            if let v = dragLight { wall.send(["brightness": v]); Taps.commit() }
                            dragLight = nil
                        }
                )
            }
            .frame(height: 26)
        }
        .padding(20)
        .background(Slab(radius: 30, ink: ink))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Light")
        .accessibilityValue("\(Int(value * 100)) percent")
    }

    // MARK: Faces: capsules you flick through

    /// The wall's faces: a grid of tiles, every one in view, the one that
    /// is on filled with the record's colour.
    private var faces: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            tile(.art, "Art", mode: "art")
            tile(.spin, "Spin", mode: "cd")
            tile(.lyrics, "Lyrics", mode: "lyrics")
            tile(.nine, "Nine", mode: "nine")
            tile(.lamp, "Lamp", mode: "ambient")
            tile(.clock, "Clock", mode: "clock")
            tile(.dark, "Off", mode: "off")
            tile(.letters, "Words", mode: "ticker")
        }
    }

    private func tile(_ g: Glyph, _ label: String, mode: String?, action: (() -> Void)? = nil) -> some View {
        let on = mode != nil && (wall.state.mode == mode || (mode == "clock" && wall.state.mode == "timer"))
        return Button {
            if let action { action() }
            else if let mode { wall.send(["mode": mode == "off" && wall.state.mode == "off" ? "art" : mode]) }
        } label: {
            VStack(spacing: 8) {
                GlyphShape(glyph: g, lineWidth: 1.5).frame(width: 22, height: 22)
                    .foregroundStyle(on ? Ink.ground : ink.ink)
                Text(label).font(.ui(14, .medium)).foregroundStyle(on ? Ink.ground : ink.ink)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 92)
            .background {
                if on { RoundedRectangle(cornerRadius: 22, style: .continuous).fill(accent) }
                else {
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(ink.ink.opacity(0.12), lineWidth: 1)
                }
            }
        }
        .buttonStyle(PressStyle(scale: 0.94))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: What this face needs

    @ViewBuilder private var context: some View {
        switch wall.state.mode {
        case "cd": speedBoard
        case "ambient": lampBoard
        case "clock", "timer": clockBoard
        case "lyrics": timingBoard
        case "off": sleepBoard
        default: finishBoard
        }
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
                .foregroundStyle(on ? Ink.ground : ink.ink)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(on ? AnyShapeStyle(accent) : AnyShapeStyle(ink.fill)))
        }
        .buttonStyle(PressStyle(scale: 0.96))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private var speedBoard: some View {
        let rpm = speedDrag ?? wall.state.rpm
        return board("Spin") {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.1f", rpm)).font(.display(28)).foregroundStyle(ink.ink).contentTransition(.numericText())
                Text("rpm").font(.ui(13)).foregroundStyle(ink.dim)
            }
            HStack(spacing: 8) {
                choice("33⅓", 33.333, rpm, { wall.send(["rpm": $0]) })
                choice("45", 45.0, rpm, { wall.send(["rpm": $0]) })
                choice("Slow", 7.5, rpm, { wall.send(["rpm": $0]) })
            }
        }
    }

    private var lampBoard: some View {
        board("Lamp") {
            let effects = [("plaid", "Plaid"), ("weave", "Weave"), ("deco", "Deco"), ("snake", "Snake"), ("solid", "Solid"),
                           ("breathe", "Breathe"), ("pulse", "Pulse"), ("rainbow", "Rainbow"), ("gradient", "Fade")]
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(effects, id: \.0) { e in
                    choice(e.1, e.0, wall.state.effect, { wall.send(["effect": $0]) })
                }
            }
            Toggle(isOn: Binding(get: { wall.state.matchArt }, set: { wall.send(["match_art": $0]) })) {
                Text("Take the album's colours").font(.ui(14)).foregroundStyle(ink.ink)
            }
            .tint(accent)
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
                HStack(spacing: 8) {
                    ForEach([5.0, 10.0, 15.0, 30.0], id: \.self) { m in
                        choice("\(Int(m)) min", m, -1.0, { wall.send(["timer_min": $0]) })
                    }
                }
                HStack(spacing: 8) {
                    choice("24 hour", true, wall.state.clock24h, { wall.send(["clock_24h": $0]) })
                    choice("12 hour", false, wall.state.clock24h, { wall.send(["clock_24h": $0]) })
                }
            }
        }
    }

    private var timingBoard: some View {
        board("Words") {
            HStack(spacing: 8) {
                choice("Sooner", -0.4, lyricsNudge, { lyricsNudge = $0 })
                choice("On time", 0.0, lyricsNudge, { lyricsNudge = $0 })
                choice("Later", 0.4, lyricsNudge, { lyricsNudge = $0 })
            }
        }
    }

    private var finishBoard: some View {
        board("Finish") {
            HStack(spacing: 8) {
                choice("Clean", "clean", wall.state.finish, { wall.send(["finish": $0]) })
                choice("Dither", "dither", wall.state.finish, { wall.send(["finish": $0]) })
                choice("Poster", "poster", wall.state.finish, { wall.send(["finish": $0]) })
            }
        }
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
