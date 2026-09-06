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
                            // clear of the page marks at the foot of the screen
                            .padding(.bottom, 60)
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
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                .frame(maxHeight: 452)
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
                } else {
                    RoundedRectangle(cornerRadius: 12).fill(ink.fill)
                        .overlay(Image(systemName: "music.note").font(.system(size: 23)).foregroundStyle(ink.dim))
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
                        Circle().fill(accent)
                        GlyphShape(glyph: (wall.state.songPlaying || MPMusicPlayerController.systemMusicPlayer.playbackState == .playing) ? .pause : .play, lineWidth: 1.6)
                            .frame(width: 14, height: 14).foregroundStyle(onAccent)
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
                    Circle().fill(Color.white).frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.14), lineWidth: 1))
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
    @State private var videoOpen = false

    private var faces: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            tile(.art, "Art", mode: "art")
            tile(.spin, "Spin", mode: "cd")
            tile(.lyrics, "Lyrics", mode: "lyrics")
            tile(.nine, "Nine", mode: "nine")
            tile(.palette, "Design", mode: "frame")
            // A video needs a link before it is a face, so the tile opens
            // the page that asks for one; the wall goes to "video" itself.
            tile(.video, "Video", mode: "video") { videoOpen = true }
            tile(.lamp, "Lamp", mode: "ambient")
            tile(.clock, "Clock", mode: "clock")
            tile(.dark, "Off", mode: "off")
        }
        .sheet(isPresented: $videoOpen) { VideoPage(accent: accent) }
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
        case "ticker": wordsBoard
        case "off": sleepBoard
        case "frame", "clip": designBoard
        case "video": videoBoard
        default: finishBoard
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
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ink.fill))
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
        let rpm = rail(key: "rpm") ?? wall.state.rpm
        return board("Spin") {
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
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
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
    private var videoBoard: some View {
        VStack(spacing: gutter) {
            board("Video") { VideoBoard(accent: accent) { videoOpen = true } }
            board("Finish") { finishes }
        }
    }

    private var designBoard: some View {
        VStack(spacing: gutter) {
            board("Design") {
                StudioScreen(roomPalette: light.palette, accent: accent, inline: true)
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
            ], height: 44, stroke: ink.ink.opacity(0.14), enabled: !album)
            Toggle(isOn: Binding(get: { wall.state.matchArt }, set: { wall.send(["match_art": $0]) })) {
                Text("Album's").font(.ui(14)).foregroundStyle(ink.ink)
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
        let f = (value - lo) / (hi - lo)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(ink.fill).frame(height: 8)
                Capsule().fill(accent).frame(width: max(8, geo.size.width * CGFloat(f)), height: 8)
                Circle().fill(Color.white).frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.14), lineWidth: 1))
                    .offset(x: (geo.size.width - 26) * CGFloat(min(1, max(0, f))))
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            }
            .frame(height: 26)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let t = Double((g.location.x - 13) / max(1, geo.size.width - 26))
                        let v = lo + (hi - lo) * min(1, max(0, t))
                        let stepped = (v / step).rounded() * step
                        if railDrag?.1 != stepped {
                            railDrag = (key, stepped)
                            let d = Int((stepped - lo) / (hi - lo) * 20)
                            if d != lastDetent { Taps.detent(intensity: 0.3); lastDetent = d }
                        }
                    }
                    .onEnded { _ in
                        if let v = rail(key: key) { commit(v); Taps.commit() }
                        railDrag = nil
                    }
            )
        }
        .frame(height: 26)
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
