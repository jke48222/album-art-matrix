// The Studio.
//
// Built from the object, not from a menu of tools. The wall is 64x64 tiles,
// so there is exactly one canvas here and it is 64x64 tiles. Drawing, photos
// and words are not three apps: they are three ways of filling the same
// 4,096 cells. You are never editing a document that later becomes a frame,
// you are lighting the frame itself.
//
// Colour comes from the wall's world rather than a rainbow picker: the album
// currently on the wall lends its own palette, so what you make belongs to
// the room it will hang in.

import SwiftUI
import UIKit
import PhotosUI
import AVFoundation

// MARK: - The canvas

@MainActor
@Observable
final class Canvas64 {
    /// 64*64*3 RGB888: the exact buffer the wall consumes.
    private(set) var px = [UInt8](repeating: 0, count: 64 * 64 * 3)
    private(set) var revision = 0

    var isEmpty: Bool { !px.contains { $0 > 6 } }

    func light(x: Int, y: Int, rgb: (UInt8, UInt8, UInt8), radius: Int) {
        for dy in -radius...radius {
            for dx in -radius...radius {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < 64, ny >= 0, ny < 64 else { continue }
                // round brush, not square
                guard dx * dx + dy * dy <= radius * radius + radius else { continue }
                let o = (ny * 64 + nx) * 3
                px[o] = rgb.0; px[o + 1] = rgb.1; px[o + 2] = rgb.2
            }
        }
        revision &+= 1
    }

    /// A fast drag delivers points far apart; without interpolation the
    /// stroke comes out as dots.

    // MARK: history

    /// Undo as snapshots, because at 12KB a frame the honest approach is
    /// also the cheap one: forty snapshots is half a megabyte, and forty
    /// steps is more history than a 64-pixel drawing has ever needed.
    private(set) var canUndo = false
    private(set) var canRedo = false
    private var undoStack: [[UInt8]] = []
    private var redoStack: [[UInt8]] = []

    /// Call BEFORE a mutation: the state being left is what undo returns to.
    func checkpoint() {
        undoStack.append(px)
        if undoStack.count > 40 { undoStack.removeFirst() }
        redoStack.removeAll()
        canUndo = true
        canRedo = false
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(px)
        px = prev
        canUndo = !undoStack.isEmpty
        canRedo = true
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(px)
        px = next
        canUndo = true
        canRedo = !redoStack.isEmpty
    }

    /// The bucket. Fills the connected region under the tap with the ink,
    /// where "connected" means neighbouring tiles near the tapped tile's
    /// colour. The tolerance exists for imported photos, whose regions are
    /// never exactly one value; drawings fill exactly.
    func fill(x: Int, y: Int, rgb: (UInt8, UInt8, UInt8)) {
        let o = (y * 64 + x) * 3
        let t = (Int(px[o]), Int(px[o + 1]), Int(px[o + 2]))
        // pouring a colour onto itself is a no-op, not a 4,096-tile walk
        if abs(t.0 - Int(rgb.0)) < 4, abs(t.1 - Int(rgb.1)) < 4,
           abs(t.2 - Int(rgb.2)) < 4 { return }
        let tol = 14
        var seen = [Bool](repeating: false, count: 64 * 64)
        var stack = [(x, y)]
        seen[y * 64 + x] = true
        while let (cx, cy) = stack.popLast() {
            let ci = (cy * 64 + cx) * 3
            guard abs(Int(px[ci]) - t.0) <= tol,
                  abs(Int(px[ci + 1]) - t.1) <= tol,
                  abs(Int(px[ci + 2]) - t.2) <= tol else { continue }
            px[ci] = rgb.0; px[ci + 1] = rgb.1; px[ci + 2] = rgb.2
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = cx + dx, ny = cy + dy
                guard nx >= 0, nx < 64, ny >= 0, ny < 64,
                      !seen[ny * 64 + nx] else { continue }
                seen[ny * 64 + nx] = true
                stack.append((nx, ny))
            }
        }
    }

    /// A stroke segment between two FLOAT cell positions, stamped every 0.4
    /// cells along the way. Bresenham between quantised endpoints put every
    /// stamp on whole cells, which reads as chatter on a slow diagonal; this
    /// follows the finger's actual line and quantises per stamp.
    func sweep(from a: (Double, Double), to b: (Double, Double),
               rgb: (UInt8, UInt8, UInt8), radius: Int) {
        let d = (b.0 - a.0, b.1 - a.1)
        let len = (d.0 * d.0 + d.1 * d.1).squareRoot()
        let steps = max(1, Int(len / 0.4))
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            light(x: Int((a.0 + d.0 * t).rounded()),
                  y: Int((a.1 + d.1 * t).rounded()),
                  rgb: rgb, radius: radius)
        }
    }

    func stroke(from a: (Int, Int), to b: (Int, Int), rgb: (UInt8, UInt8, UInt8), radius: Int) {
        let steps = max(abs(b.0 - a.0), abs(b.1 - a.1))
        guard steps > 0 else {
            light(x: b.0, y: b.1, rgb: rgb, radius: radius)
            return
        }
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            light(
                x: Int((Double(a.0) + (Double(b.0) - Double(a.0)) * t).rounded()),
                y: Int((Double(a.1) + (Double(b.1) - Double(a.1)) * t).rounded()),
                rgb: rgb, radius: radius
            )
        }
    }

    func clear() {
        px = [UInt8](repeating: 0, count: 64 * 64 * 3)
        revision &+= 1
    }

    func load(_ buffer: [UInt8]) {
        guard buffer.count == 64 * 64 * 3 else { return }
        px = buffer
        revision &+= 1
    }

    /// Words are the third way of filling the canvas. Laid out in the wall's
    /// own font at the largest scale that fits, wrapped and centred, over
    /// whatever `base` already held so typing never destroys a drawing.
    func stamp(text: String, over base: [UInt8], rgb: (UInt8, UInt8, UInt8),
               size: Int? = nil, colors: [(UInt8, UInt8, UInt8)] = []) {
        var out = base
        let words = PixelFont.normalize(text)
        guard !words.trimmingCharacters(in: .whitespaces).isEmpty else {
            load(out)
            return
        }

        // Overflow is answered by getting SMALLER, not by wrapping: the
        // whole text on one line at the biggest size that holds it. Only
        // when even the smallest type cannot hold the line does it wrap,
        // whole words first, and a word is broken only when no size and no
        // wrap can save it. "tesse / ra" is never the right rendering of a
        // word that fits smaller.
        let chosen = min(4, max(1, size ?? 4))
        var scale = chosen
        var lines: [String] = []
        var settled = false
        for s in stride(from: chosen, through: 1, by: -1)
        where PixelFont.textWidth(words, scale: s) <= 62 {
            lines = [words]
            scale = s
            settled = true
            break
        }
        if !settled {
            for s in stride(from: chosen, through: 1, by: -1) {
                let rows = PixelFont.wrap(words, maxWidth: 62, scale: s)
                let blockH = rows.count * (PixelFont.height * s + s) - s
                let unbroken = rows.joined(separator: " ") == words
                if blockH <= 62, unbroken {
                    lines = rows
                    scale = s
                    settled = true
                    break
                }
            }
        }
        while !settled && scale >= 1 {
            lines = PixelFont.wrap(words, maxWidth: 62, scale: scale)
            let blockHeight = lines.count * (PixelFont.height * scale + scale) - scale
            let widest = lines.map { PixelFont.textWidth($0, scale: scale) }.max() ?? 0
            if blockHeight <= 62 && widest <= 62 { break }
            scale -= 1
        }
        scale = max(1, scale)

        let lineStep = PixelFont.height * scale + scale
        let blockHeight = lines.count * lineStep - scale
        var y = max(1, (64 - blockHeight) / 2)

        var gi = 0
        for line in lines {
            let w = PixelFont.textWidth(line, scale: scale)
            var x = (64 - w) / 2
            for ch in line {
                let (rows, gw, adv) = PixelFont.cell(ch) ?? (PixelFont.box, 5, 6)
                let glyphInk: (UInt8, UInt8, UInt8)
                if ch != " " {
                    glyphInk = gi < colors.count ? colors[gi] : rgb
                    gi += 1
                } else {
                    glyphInk = rgb
                }
                for (ry, mask) in rows.enumerated() {
                    for rx in 0..<gw where mask & (1 << (gw - 1 - rx)) != 0 {
                        for sy in 0..<scale {
                            for sx in 0..<scale {
                                let xx = x + rx * scale + sx
                                let yy = y + ry * scale + sy
                                guard xx >= 0, xx < 64, yy >= 0, yy < 64 else { continue }
                                let o = (yy * 64 + xx) * 3
                                out[o] = glyphInk.0; out[o + 1] = glyphInk.1; out[o + 2] = glyphInk.2
                            }
                        }
                    }
                }
                x += adv * scale
            }
            y += lineStep
        }
        load(out)
    }

}

// MARK: - Kept work

/// What you have made, stored on the device as raw frames. Small enough that
/// the frames themselves are kept, which is why these tiles, unlike the
/// Archive's, are exactly what the wall would light.
@MainActor
@Observable
final class MadeStore {
    private(set) var made: [Made] = []

    struct Made: Identifiable, Equatable {
        let id: String
        let px: [UInt8]
    }

    private var dir: URL? {
        try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            .appendingPathComponent("made", isDirectory: true)
    }

    func load() {
        guard let dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        made = files.sorted(by: >).prefix(24).compactMap { name in
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  d.count == 64 * 64 * 3 else { return nil }
            return Made(id: name, px: [UInt8](d))
        }
    }

    func keep(_ px: [UInt8]) {
        guard let dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = String(Int(Date().timeIntervalSince1970))
        try? Data(px).write(to: dir.appendingPathComponent(name))
        load()
    }

    func remove(_ id: String) {
        guard let dir else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(id))
        load()
    }
}

// MARK: - Screen

struct StudioScreen: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dismiss) private var dismiss

    /// The palette the album currently on the wall is making.
    let roomPalette: [Color]
    let accent: Color

    @State private var canvas = Canvas64()
    @State private var kept = MadeStore()
    @State private var ink: (UInt8, UInt8, UInt8) = (255, 255, 255)
    /// Whatever the picker last mixed, kept as a swatch of its own so a
    /// custom colour survives switching away and back.
    @State private var custom: Color = .white
    /// One hand, one tool. Pen, eraser and bucket are an exclusive set with
    /// the pen as home; a mode you can only leave by re-tapping the thing
    /// that put you in it is a trap, and both of these were.
    enum Tool { case pen, erase, fill }
    @State private var tool: Tool = .pen
    @State private var thick = false
    /// The stroke's position in CELLS, kept as floats. Quantising each touch
    /// sample to a cell before joining them is what made lines wobble: a
    /// finger riding a cell boundary flickers between neighbours. The float
    /// path is joined first and quantised last, per stamp.
    @State private var lastF: (Double, Double)? = nil
    @State private var media: PhotosPickerItem? = nil
    // Held in @State so it survives body re-evaluation: built inline in
    // onReceive, every drag stroke replaced the publisher and restarted its
    // interval, so the clip preview froze for as long as a finger moved.
    @State private var clipTimer = Timer.publish(
        every: 1 / Clip.fps, on: .main, in: .common).autoconnect()
    /// A clip loaded from a video: previewed by playing on the canvas, sent
    /// whole. Empty for a still.
    @State private var clip: [[UInt8]] = []
    @State private var clipFrame = 0
    @State private var loadingMedia = false
    /// Picked media, waiting to be aimed. Nil when there is nothing to aim.
    @State private var framing: FramingJob? = nil
    @State private var sent = false
    @State private var words = ""
    @State private var writing = false
    /// Wished glyph size for words, 1 to 4. The stamp treats it as a wish,
    /// never a warrant: it comes down until the block fits the panel, so
    /// letters cannot walk off the edges no matter what the scroller says.
    @State private var wordScale: Double = 4
    /// Per-glyph inks for the stamped words, same contract as the wall's.
    @State private var wordColors: [String] = []
    /// What the canvas held before words started, so typing composes over a
    /// drawing instead of replacing it.
    @State private var beneath: [UInt8] = []
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    board
                    if writing { compose }
                    inks
                    tools
                    penOptions
                    send
                    if !kept.made.isEmpty { keptStrip }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 50)
            }
            .scrollIndicators(.hidden)
            .background(Ink.ground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .font(.ui(15, .medium))
                        .foregroundStyle(Ink.dim)
                }
                ToolbarItemGroup(placement: .principal) {
                    HStack(spacing: 26) {
                        Button {
                            canvas.undo()
                        } label: {
                            GlyphShape(glyph: .undo, lineWidth: 1.7)
                                .frame(width: 19, height: 19)
                                .foregroundStyle(canvas.canUndo ? Ink.ink : Ink.faint)
                        }
                        .buttonStyle(PressStyle(scale: 0.88))
                        .disabled(!canvas.canUndo)
                        .accessibilityLabel("Undo")

                        Button {
                            canvas.redo()
                        } label: {
                            GlyphShape(glyph: .undo, lineWidth: 1.7)
                                .frame(width: 19, height: 19)
                                .scaleEffect(x: -1)
                                .foregroundStyle(canvas.canRedo ? Ink.ink : Ink.faint)
                        }
                        .buttonStyle(PressStyle(scale: 0.88))
                        .disabled(!canvas.canRedo)
                        .accessibilityLabel("Redo")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") {
                        canvas.checkpoint()
                        clip = []
                        canvas.clear()
                    }
                    .font(.ui(15, .medium))
                    .foregroundStyle(canvas.isEmpty ? Ink.faint : accent)
                    .disabled(canvas.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationBackground(Ink.ground)
        .onAppear {
            kept.load()
            frozen = [(255, 255, 255), (232, 176, 75)]
                + roomPalette.prefix(3).map { Self.rgb(of: $0) }
        }
        // Aiming happens on its own surface: it needs the whole screen and it
        // is a decision, not an adjustment you leave half-made.
        .fullScreenCover(item: $framing) { job in
            Framing(source: job.source, accent: accent) {
                framing = nil
                media = nil
            } onUse: { frames in
                framing = nil
                media = nil
                canvas.checkpoint()
                if frames.count > 1 {
                    clip = frames
                    clipFrame = 0
                    canvas.load(frames[0])
                } else if let one = frames.first {
                    clip = []
                    canvas.load(one)
                }
            }
        }
        .onChange(of: media) { _, item in
            guard let item else { return }
            loadingMedia = true
            clip = []
            leaveWords()
            Task {
                defer { loadingMedia = false }
                // A movie first: if it transfers as one, it is one.
                if let movie = try? await item.loadTransferable(type: Movie.self) {
                    let frames = await Clip.frames(from: movie.url)
                    try? FileManager.default.removeItem(at: movie.url)
                    if !frames.isEmpty {
                        framing = FramingJob(source: frames)
                        Taps.detent(intensity: 0.5)
                        return
                    }
                }
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data), let cg = Clip.upright(img) {
                    framing = FramingJob(source: [cg])
                    Taps.detent(intensity: 0.5)
                }
            }
        }
        // Play the clip on the canvas so the preview is the thing itself.
        .onReceive(clipTimer) { _ in
            guard clip.count > 1, !writing else { return }
            clipFrame = (clipFrame + 1) % clip.count
            canvas.load(clip[clipFrame])
        }
    }

    // MARK: Board

    /// You are not editing a picture that becomes a frame. You are lighting
    /// the frame, so the canvas is drawn in emitters at all times.
    private var board: some View {
        GeometryReader { geo in
            SwiftUI.Canvas { ctx, size in
                let cell = size.width / 64
                let r = cell * 0.36
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                for i in 0..<(64 * 64) {
                    let o = i * 3
                    let cx = CGFloat(i % 64) * cell + cell / 2
                    let cy = CGFloat(i / 64) * cell + cell / 2
                    let dot = Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                    if canvas.px[o] < 8 && canvas.px[o + 1] < 8 && canvas.px[o + 2] < 8 {
                        ctx.fill(dot, with: .color(Color(white: 0.055)))
                    } else {
                        ctx.fill(dot, with: .color(Color(
                            red: Double(canvas.px[o]) / 255,
                            green: Double(canvas.px[o + 1]) / 255,
                            blue: Double(canvas.px[o + 2]) / 255
                        )))
                    }
                }
            }
            .drawingGroup()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if lastF == nil {
                            Taps.warm()
                            if tool != .fill { canvas.checkpoint() }
                        }
                        if writing { leaveWords() }
                        guard tool != .fill else { return }   // the bucket pours on release
                        let cell = geo.size.width / 64
                        let fx = min(63.49, max(0.0, g.location.x / cell - 0.5))
                        let fy = min(63.49, max(0.0, g.location.y / cell - 0.5))
                        let rgb: (UInt8, UInt8, UInt8) = tool == .erase ? (0, 0, 0) : ink
                        let radius = thick ? 1 : 0
                        if let l = lastF {
                            // A resting finger jitters by a third of a cell;
                            // ignoring that is what keeps a held point still.
                            guard hypot(fx - l.0, fy - l.1) > 0.3 else { return }
                            canvas.sweep(from: l, to: (fx, fy), rgb: rgb, radius: radius)
                        } else {
                            canvas.light(x: Int(fx.rounded()), y: Int(fy.rounded()),
                                         rgb: rgb, radius: radius)
                        }
                        lastF = (fx, fy)
                    }
                    .onEnded { g in
                        lastF = nil
                        if tool == .fill {
                            let cell = geo.size.width / 64
                            let x = min(63, max(0, Int(g.location.x / cell)))
                            let y = min(63, max(0, Int(g.location.y / cell)))
                            canvas.checkpoint()
                            canvas.fill(x: x, y: y, rgb: ink)
                            Taps.commit()
                        } else {
                            Taps.detent(intensity: 0.3)
                        }
                    }
            )
            .accessibilityLabel("Canvas, 64 by 64 tiles. Draw with one finger.")
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: Inks

    /// White, the tile amber, and whatever the album on the wall is making.
    private var inkColor: Color {
        Color(red: Double(ink.0) / 255, green: Double(ink.1) / 255, blue: Double(ink.2) / 255)
    }

    /// The album's suggestions, captured ONCE when the studio opens. They
    /// used to track the wall live, and a track change mid-drawing would
    /// vanish the swatch you were using out from under your finger. The ink
    /// you are holding also always earns a swatch, so a colour can never
    /// become unreachable while it is in your hand.
    @State private var frozen: [(UInt8, UInt8, UInt8)] = []

    private var swatches: [(UInt8, UInt8, UInt8)] {
        var out = frozen
        if !out.contains(where: { $0 == ink }) { out.append(ink) }
        return out
    }

    private var inks: some View {
        HStack(spacing: 12) {
            ForEach(Array(swatches.enumerated()), id: \.offset) { (_, rgb) in
                swatch(rgb)
            }

            // The mixer.
            //
            // This was a ColorPicker hidden at 2% opacity under a drawn
            // circle, which looked right and did not reliably take a tap on
            // device: an all-but-invisible system control is not something to
            // rely on for hit testing. The system swatch IS the control now,
            // sized to match its neighbours and ringed so it reads as one
            // more ink rather than as a settings widget.
            ColorPicker(selection: $custom, supportsOpacity: false) { EmptyView() }
                .labelsHidden()
                .scaleEffect(1.25)
                .frame(width: 34, height: 34)
                .overlay {
                    Circle()
                        .strokeBorder(
                            AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                            center: .center),
                            lineWidth: 2
                        )
                        .padding(-4)
                        .allowsHitTesting(false)
                }
                .onChange(of: custom) { _, c in
                    ink = Self.rgb(of: c)
                    if tool == .erase { tool = .pen }
                    Taps.detent(intensity: 0.5)
                }
            .accessibilityLabel("Mix a colour")

            Spacer()
        }
    }

    private func swatch(_ rgb: (UInt8, UInt8, UInt8)) -> some View {
        let on = tool != .erase && rgb == ink
        return Button {
            ink = rgb
            // choosing a colour is choosing to make marks, not unmake them;
            // the bucket keeps it, since a pour has a colour too
            if tool == .erase { tool = .pen }
        } label: {
            Circle()
                .fill(Color(red: Double(rgb.0) / 255,
                            green: Double(rgb.1) / 255,
                            blue: Double(rgb.2) / 255))
                .frame(width: 34, height: 34)
                .overlay {
                    Circle().strokeBorder(on ? Ink.ink : .clear, lineWidth: 2).padding(-4)
                }
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("Ink")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    static func rgb(of c: Color) -> (UInt8, UInt8, UInt8) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (UInt8(max(0, min(255, r * 255))),
                UInt8(max(0, min(255, g * 255))),
                UInt8(max(0, min(255, b * 255))))
    }

    // MARK: Tools

    private var tools: some View {
        HStack(spacing: 0) {
            GlyphButton(glyph: .pen, label: "pen",
                        active: !writing,
                        accent: accent, lit: 0.6, diameter: 54) {
                leaveWords()
                tool = .pen
            }
            .frame(maxWidth: .infinity)

            GlyphButton(glyph: .letters, label: "words", active: writing,
                        accent: accent, lit: 0.6, diameter: 54) {
                tool = .pen
                if writing {
                    writing = false
                    typing = false
                } else {
                    canvas.checkpoint()
                    beneath = canvas.px
                    writing = true
                    typing = true
                }
            }
            .frame(maxWidth: .infinity)

            PhotosPicker(selection: $media, matching: .any(of: [.images, .videos])) {
                VStack(spacing: 8) {
                    ZStack {
                        Circle().fill(Ink.sunk)
                        Circle().strokeBorder(clip.isEmpty ? Ink.hairline : accent,
                                              lineWidth: clip.isEmpty ? 1 : 1.5)
                        GlyphShape(glyph: .photo, lineWidth: 1.6)
                            .frame(width: 54 * 0.42, height: 54 * 0.42)
                            .foregroundStyle(clip.isEmpty ? Ink.dim : accent)
                    }
                    .frame(width: 54, height: 54)
                    Text(loadingMedia ? "reading" : (clip.isEmpty ? "media" : "\(clip.count)f"))
                        .font(.machine(9))
                        .textCase(.uppercase)
                        .foregroundStyle(clip.isEmpty ? Ink.faint : Ink.ink)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The wall's own font, so what you type here is what it letters.
    private var compose: some View {
        VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 12) {
            TextField("say something", text: $words)
                .font(.machine(14))
                .foregroundStyle(Ink.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($typing)
                .submitLabel(.done)
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(Ink.sunk)
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.hairline, lineWidth: 1) }

            Button {
                words = ""
                canvas.load(beneath)
            } label: {
                Text("undo")
                    .font(.ui(13, .medium))
                    .foregroundStyle(Ink.dim)
            }
            .buttonStyle(.plain)
        }
        // The size is a choice, not a consequence of how much you typed;
        // the stamp still refuses to let it overflow the panel.
        SizeRail(value: wordSize, ink: inkColor) { wordScale = Double($0) }

        // The same inker the wall's words use: both buttons, one language.
        if words.contains(where: { $0 != " " }) {
            LetterInker(text: words, colors: wordColors, accent: inkColor) {
                wordColors = $0
            }
        }
        }
        .onChange(of: words) { _, new in
            canvas.stamp(text: new, over: beneath, rgb: ink, size: wordSize,
                         colors: wordInks)
        }
        .onChange(of: wordScale) { _, _ in
            Taps.detent(intensity: 0.4)
            canvas.stamp(text: words, over: beneath, rgb: ink, size: wordSize,
                         colors: wordInks)
        }
        .onChange(of: wordColors) { _, _ in
            canvas.stamp(text: words, over: beneath, rgb: ink, size: wordSize,
                         colors: wordInks)
        }
        // The return key puts the KEYBOARD away, nothing else: you stay on
        // words, where the size rail and the letter inks still apply to what
        // you just typed. Words mode ends when you pick another tool.
        .onSubmit { typing = false }
        .transition(.opacity)
    }

    private var wordSize: Int { Int(wordScale) }

    private var wordInks: [(UInt8, UInt8, UInt8)] {
        wordColors.compactMap { Color(wallHex: $0) }.map { Self.rgb(of: $0) }
    }

    /// The pen's own pocket: how it marks, and its two alter egos. Lives
    /// under the row so the top level stays three ideas: pen, words, media.
    @ViewBuilder private var penOptions: some View {
        if !writing {
            HStack(spacing: 18) {
                BrushButton(thick: thick, accent: tool == .erase ? Ink.dim : inkColor) {
                    thick.toggle()
                }
                GlyphButton(glyph: .erase, label: "erase", active: tool == .erase,
                            accent: accent, lit: 0.6, diameter: 40) {
                    tool = tool == .erase ? .pen : .erase
                }
                GlyphButton(glyph: .fill, label: "fill", active: tool == .fill,
                            accent: accent, lit: 0.6, diameter: 40) {
                    tool = tool == .fill ? .pen : .fill
                }
                Spacer()
            }
            .padding(.leading, 10)
            .transition(.opacity)
        }
    }

    /// Words mode ends the moment you reach for anything else. What was
    /// typed stays on the canvas as tiles; only the re-stamping stops, so a
    /// later brushstroke can never be wiped by an old text field.
    private func leaveWords() {
        guard writing else { return }
        writing = false
        typing = false
    }

    // MARK: Send

    private var send: some View {
        Button {
            guard !canvas.isEmpty else { return }
            if clip.count > 1 {
                wall.pushClip(clip, fps: Clip.fps)
            } else {
                wall.pushFrame(canvas.px)
            }
            kept.keep(canvas.px)
            sent = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { sent = false }
        } label: {
            Text(sent ? "On the wall"
                      : (clip.count > 1 ? "Play it on the wall" : "Put it on the wall"))
                .font(.ui(16, .semibold))
                .foregroundStyle(canvas.isEmpty ? Ink.faint : Ink.ground)
                .padding(.vertical, 15)
                .frame(maxWidth: .infinity)
                .background(Capsule().fill(canvas.isEmpty ? Ink.sunk : (sent ? Ink.moss : accent)))
        }
        .buttonStyle(.plain)
        .disabled(canvas.isEmpty)
        .animation(Motion.settle, value: sent)
        .animation(Motion.settle, value: canvas.isEmpty)
    }

    // MARK: Kept

    private var keptStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("made")
                .font(.ui(12, .medium))
                .foregroundStyle(Ink.dim)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(kept.made) { m in
                        Group {
                            if let img = EmitterTile.render(m.px, cell: 3) {
                                Image(uiImage: img).interpolation(.high).resizable()
                            } else {
                                Color.black
                            }
                        }
                        .frame(width: 76, height: 76)
                        .onTapGesture {
                            Taps.detent()
                            canvas.checkpoint()
                            canvas.load(m.px)
                        }
                        .contextMenu {
                            Button("Delete", role: .destructive) { kept.remove(m.id) }
                        }
                        .accessibilityLabel("Something you made. Tap to load it back.")
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// The brush shows its own footprint rather than a picture of a brush: one
/// tile, or the five it actually lights. The control is the thing it does.
private struct BrushButton: View {
    let thick: Bool
    let accent: Color
    var action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(Ink.sunk)
                    Circle().strokeBorder(Ink.hairline, lineWidth: 1)
                    SwiftUI.Canvas { ctx, size in
                        let cell = size.width / 5
                        let r = cell * 0.36
                        let cells: [(Int, Int)] = thick
                            ? [(2, 1), (1, 2), (2, 2), (3, 2), (2, 3)]
                            : [(2, 2)]
                        for (x, y) in cells {
                            let cx = CGFloat(x) * cell + cell / 2
                            let cy = CGFloat(y) * cell + cell / 2
                            ctx.fill(
                                Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
                                with: .color(accent)
                            )
                        }
                    }
                    .frame(width: 30, height: 30)
                }
                .frame(width: 54, height: 54)
                Text(thick ? "wide" : "fine")
                    .font(.machine(9))
                    .textCase(.uppercase)
                    .foregroundStyle(Ink.faint)
            }
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(thick ? "Wide brush" : "Fine brush")
    }
}

// MARK: - Media

/// Video, reduced to what a wall of 4,096 tiles can actually show.
///
/// Not a video editor. AlbumWall grew a trim rail, a crop viewport and an
/// fps picker, which is a lot of interface for a thing that ends as twelve
/// thousand bytes a frame. Here a clip is a clip: the first few seconds,
/// aimed once in Framing, sampled to the panel's own resolution, previewed by
/// playing it on the canvas, and sent whole.
enum Clip {
    static let fps: Double = 12
    static let maxFrames = 120        // ten seconds; the brain's ceiling is 240

    /// Frames as they came out of the video, small but uncropped: aiming the
    /// panel is Framing's job and it cannot un-crop what this threw away.
    static func frames(from url: URL) async -> [CGImage] {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return [] }
        let seconds = min(CMTimeGetSeconds(duration), Double(maxFrames) / fps)
        guard seconds > 0 else { return [] }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true      // portrait stays upright
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        gen.maximumSize = CGSize(width: 256, height: 256)

        let count = max(1, Int(seconds * fps))
        let times = (0..<count).map {
            NSValue(time: CMTime(seconds: Double($0) / fps, preferredTimescale: 600))
        }

        var out: [CGImage] = []
        for value in times {
            guard let cg = try? await gen.image(at: value.timeValue).image else { continue }
            out.append(cg)
        }
        return out
    }

    /// A photo, redrawn upright and cut down to something a gesture can
    /// resample sixty times a second. UIImage carries rotation as a flag
    /// rather than in its pixels, so a portrait shot handed straight to Core
    /// Graphics arrives on its side; this is where that gets settled.
    static func upright(_ image: UIImage, max side: CGFloat = 1200) -> CGImage? {
        let w = image.size.width, h = image.size.height
        guard w > 0, h > 0 else { return nil }
        let k = min(1, side / max(w, h))
        let size = CGSize(width: (w * k).rounded(), height: (h * k).rounded())
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }

    /// The wall is square and a phone video is not, so the middle of the
    /// frame is what survives.
    static func square64(_ src: CGImage) -> [UInt8]? {
        let count = 64 * 64 * 4
        let raw = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        raw.initialize(repeating: 0, count: count)
        defer { raw.deallocate() }
        guard let ctx = CGContext(
            data: raw, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        let w = CGFloat(src.width), h = CGFloat(src.height)
        let scale = 64 / min(w, h)
        let dw = w * scale, dh = h * scale
        ctx.draw(src, in: CGRect(x: (64 - dw) / 2, y: (64 - dh) / 2, width: dw, height: dh))

        var px = [UInt8](repeating: 0, count: 64 * 64 * 3)
        for i in 0..<(64 * 64) {
            px[i * 3] = raw[i * 4]
            px[i * 3 + 1] = raw[i * 4 + 1]
            px[i * 3 + 2] = raw[i * 4 + 2]
        }
        return px
    }
}


/// Four letters that ARE their own sizes: the control shows the choice
/// instead of describing it. Tap one, or drag across the rail.
private struct SizeRail: View {
    let value: Int
    let ink: Color
    var onPick: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let slot = geo.size.width / 4
            HStack(spacing: 0) {
                ForEach(1...4, id: \.self) { i in
                    let on = i == value
                    let size = CGFloat(9 + i * 4)
                    VStack(spacing: 6) {
                        Text("A")
                            .font(.machine(size))
                            .foregroundStyle(on ? ink : Ink.dim)
                        Rectangle()
                            .fill(on ? ink : Ink.hairline)
                            .frame(width: on ? 16 : 10, height: on ? 2 : 1)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: 44, alignment: .bottom)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let i = min(4, max(1, Int(g.location.x / slot) + 1))
                        if i != value {
                            Taps.detent(intensity: 0.25 + Double(i) * 0.12)
                            onPick(i)
                        }
                    }
            )
        }
        .frame(height: 44)
        .animation(Motion.settle, value: value)
        .accessibilityElement()
        .accessibilityLabel("Word size")
        .accessibilityValue("\(value) of 4")
        .accessibilityAdjustableAction { dir in
            onPick(min(4, max(1, value + (dir == .increment ? 1 : -1))))
        }
    }
}

/// Picked media on its way to the framing step.
struct FramingJob: Identifiable {
    let id = UUID()
    let source: [CGImage]
}

/// PhotosPicker hands a movie over as a file; this receives it into a
/// temporary URL that AVAsset can open.
struct Movie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("tessera-\(UUID().uuidString).mov")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return Movie(url: dest)
        }
    }
}
