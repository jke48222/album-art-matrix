// The Studio.
//
// Built from the object, not from a menu of tools. The wall is a square of
// tiles, so there is exactly one canvas here and it is that same square, at
// whatever size the wall actually is: 64 for one panel, 192 for the nine
// panel wall, so a drawing is drawn at the resolution it will be lit at,
// never blown up to fit afterwards. Drawing, photos
// and words are not three apps: they are three ways of filling the same
// 4,096 cells. You are never editing a document that later becomes a frame,
// you are lighting the frame itself.
//
// Colour comes from the wall's world rather than a rainbow picker: the album
// currently on the wall lends its own palette, so what you make belongs to
// the room it will hang in.

import Combine
import PhotosUI
import SwiftUI
import UIKit

// MARK: - The canvas

@MainActor
@Observable
final class WallCanvas {
    /// The exact buffer the wall consumes, at the wall's own size.
    let side = Panel.side
    private(set) var px = Panel.blank()
    private(set) var revision = 0

    var isEmpty: Bool { !px.contains { $0 > 6 } }

    func light(x: Int, y: Int, rgb: (UInt8, UInt8, UInt8), radius: Int) {
        guard x >= -side, x < side * 2, y >= -side, y < side * 2 else { return }
        let radius = min(side / 4, max(0, radius))
        for dy in -radius...radius {
            for dx in -radius...radius {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < side, ny >= 0, ny < side else { continue }
                // round brush, not square
                guard dx * dx + dy * dy <= radius * radius + radius else { continue }
                let o = (ny * side + nx) * 3
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
    /// steps is more history than a drawing on a wall has ever needed.
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
        revision &+= 1
        canUndo = !undoStack.isEmpty
        canRedo = true
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(px)
        px = next
        revision &+= 1
        canUndo = true
        canRedo = !redoStack.isEmpty
    }

    /// The bucket. Fills the connected region under the tap with the ink,
    /// where "connected" means neighbouring tiles near the tapped tile's
    /// colour. The tolerance exists for imported photos, whose regions are
    /// never exactly one value; drawings fill exactly.
    func fill(x: Int, y: Int, rgb: (UInt8, UInt8, UInt8)) {
        guard x >= 0, x < side, y >= 0, y < side else { return }
        let o = (y * side + x) * 3
        let t = (Int(px[o]), Int(px[o + 1]), Int(px[o + 2]))
        // pouring a colour onto itself is a no-op, not a 4,096-tile walk
        if abs(t.0 - Int(rgb.0)) < 4, abs(t.1 - Int(rgb.1)) < 4,
           abs(t.2 - Int(rgb.2)) < 4 { return }
        let tol = 14
        var seen = [Bool](repeating: false, count: side * side)
        var stack = [(x, y)]
        seen[y * side + x] = true
        while let (cx, cy) = stack.popLast() {
            let ci = (cy * side + cx) * 3
            guard abs(Int(px[ci]) - t.0) <= tol,
                  abs(Int(px[ci + 1]) - t.1) <= tol,
                  abs(Int(px[ci + 2]) - t.2) <= tol else { continue }
            px[ci] = rgb.0; px[ci + 1] = rgb.1; px[ci + 2] = rgb.2
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = cx + dx, ny = cy + dy
                guard nx >= 0, nx < side, ny >= 0, ny < side,
                      !seen[ny * side + nx] else { continue }
                seen[ny * side + nx] = true
                stack.append((nx, ny))
            }
        }
        revision &+= 1
    }

    /// A stroke segment between two FLOAT cell positions, stamped every 0.4
    /// cells along the way. Bresenham between quantised endpoints put every
    /// stamp on whole cells, which reads as chatter on a slow diagonal; this
    /// follows the finger's actual line and quantises per stamp.
    func sweep(from a: (Double, Double), to b: (Double, Double),
               rgb: (UInt8, UInt8, UInt8), radius: Int) {
        guard [a.0, a.1, b.0, b.1].allSatisfy(\.isFinite) else { return }
        let limit = Double(side - 1)
        let a = (min(limit, max(0, a.0)), min(limit, max(0, a.1)))
        let b = (min(limit, max(0, b.0)), min(limit, max(0, b.1)))
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
        sweep(from: (Double(a.0), Double(a.1)), to: (Double(b.0), Double(b.1)), rgb: rgb, radius: radius)
    }

    func clear() {
        px = [UInt8](repeating: 0, count: side * side * 3)
        revision &+= 1
    }

    /// Anything square goes on the canvas. A drawing kept when the wall was
    /// one panel is 64 pixels and the canvas may now be 192, so it is blown
    /// up by whole tiles rather than refused: pixel art scaled by threes is
    /// still pixel art, and a rejected drawing just vanishes with no reason
    /// given.
    func load(_ buffer: [UInt8]) {
        guard let from = Panel.square(buffer.count) else { return }
        if from == side {
            px = buffer
        } else {
            var out = [UInt8](repeating: 0, count: side * side * 3)
            for y in 0..<side {
                let sy = y * from / side
                for x in 0..<side {
                    let o = (y * side + x) * 3, i = (sy * from + x * from / side) * 3
                    out[o] = buffer[i]; out[o + 1] = buffer[i + 1]; out[o + 2] = buffer[i + 2]
                }
            }
            px = out
        }
        revision &+= 1
    }

    @discardableResult
    func stamp(text: String, over base: [UInt8], rgb: (UInt8, UInt8, UInt8),
               size: Int? = nil, colors: [(UInt8, UInt8, UInt8)] = [],
               horizontal: Double = 0.5, vertical: Double = 0.5) -> LetteringLayout {
        let layout = LetteringLayout(text: text, side: side, size: size ?? 4,
                                     horizontal: horizontal, vertical: vertical)
        load(layout.render(over: base, rgb: rgb, colors: colors))
        return layout
    }

}

// MARK: - Kept work
// Saved documents live in MadeStore.swift.

// MARK: - Screen

struct StudioScreen: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(WallSession.self) private var wall
    @Environment(\.dismiss) private var dismiss

    /// The palette the album currently on the wall is making.
    let roomPalette: [Color]
    let accent: Color
    /// Laid into the wall's own controls rather than presented over them:
    /// no navigation chrome, no page background, and its own row of undo,
    /// redo and clear where the toolbar would have been.
    var inline: Bool = false

    @State private var canvas = WallCanvas()
    @State private var kept: MadeStore = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("made-sample") {
            return MadeStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("tessera-qa-made-" + UUID().uuidString, isDirectory: true))
        }
        #endif
        return MadeStore()
    }()
    @State private var ink: (UInt8, UInt8, UInt8) = (255, 255, 255)
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
        every: 1 / 60, on: .main, in: .common).autoconnect()
    /// A clip loaded from a video: previewed by playing on the canvas, sent
    /// whole. Empty for a still.
    @State private var clip: [[UInt8]] = []
    @State private var clipFrame = 0
    @State private var clipFPS = Clip.fps
    @State private var clipPlaying = true
    @State private var clipTick: Date?
    @State private var importProgress: Double = 0
    @State private var importTask: Task<Void, Never>?
    @State private var showingMade = false
    @State private var creationTitle = ""
    @State private var savedID: String?
    @State private var savedTitle = ""
    @State private var importID = UUID()
    @State private var savedPixels: [UInt8]?
    @State private var savedClip: [[UInt8]]?
    @State private var horizontal = 0.5
    @State private var vertical = 0.5
    @State private var moveOrigin: (Double, Double)?
    @State private var loadingMedia = false
    /// Picked media, waiting to be aimed. Nil when there is nothing to aim.
    @State private var framing: FramingJob? = nil
    @State private var sent = false
    @State private var sending = false
    @State private var sendError: String?
    @State private var emitterPreview = false
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
        Group { if inline { editor } else { screen } }
            .onAppear(perform: prepare)
            .fullScreenCover(item: $framing) { job in
                Framing(source: job.source, accent: accent) {
                    framing = nil; media = nil
                } onUse: { frames in
                    framing = nil; media = nil
                    guard let first = frames.first else { return }
                    leaveWords(); canvas.checkpoint()
                    clip = frames.count > 1 ? frames : []
                    clipFrame = 0; clipFPS = Clip.fps; clipPlaying = !reduceMotion
                    canvas.load(first); savedID = nil; sent = false; sendError = nil
                }
            }
            .onChange(of: media) { _, item in if let item { importMedia(item) } }
            .onChange(of: canvas.revision) { _, _ in
                if clip.isEmpty { sent = false; sendError = nil }
            }
            .onReceive(clipTimer) { now in
                guard scenePhase == .active, clip.count > 1, clipPlaying, !writing, !showingMade else { clipTick = nil; return }
                guard let tick = clipTick else { clipTick = now; return }
                let advance = Int(max(0, now.timeIntervalSince(tick)) * clipFPS)
                guard advance > 0 else { return }
                clipTick = tick.addingTimeInterval(Double(advance) / clipFPS)
                clipFrame = (clipFrame + advance) % clip.count
                canvas.load(clip[clipFrame])
            }
            .onDisappear { importTask?.cancel() }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 20) {
            studioHeading
            Picker("Studio section", selection: $showingMade) {
                Text("Create").tag(false)
                Text("Made · \(kept.made.count)").tag(true)
            }.pickerStyle(.segmented)
            if showingMade {
                madeCollection
            } else {
                board
                if !clip.isEmpty { clipTransport }
                if writing { compose } else { penOptions }
                inks
                tools
                if loadingMedia {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Reading media").font(.ui(13, .medium)); Spacer()
                            Button("Cancel") { importTask?.cancel(); importID = UUID(); media = nil; loadingMedia = false }
                                .font(.ui(13, .medium)).foregroundStyle(accent)
                        }
                        ProgressView(value: importProgress).tint(accent)
                    }
                }
                if let sendError { Text(sendError).font(.ui(13)).foregroundStyle(Ink.dim).accessibilityLabel(sendError) }
                if let error = kept.error { Text(error).font(.ui(13)).foregroundStyle(Ink.dim) }
                if inline { send }
            }
        }
    }

    private var screen: some View {
        NavigationStack {
            ScrollView { editor.padding(.horizontal, 24).padding(.bottom, 32) }
                .safeAreaInset(edge: .bottom) {
                    if !showingMade {
                        send.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 8).background(Ink.ground)
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .background(Ink.ground.ignoresSafeArea())
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }.font(.ui(15, .medium)).foregroundStyle(Ink.dim)
                    }
                    ToolbarItemGroup(placement: .principal) {
                        Button { leaveWords(); clip = []; canvas.undo() } label: {
                            Image(systemName: "arrow.uturn.backward").frame(width: 32, height: 44)
                        }.disabled(!canvas.canUndo || showingMade).accessibilityLabel("Undo canvas change")
                        Button { leaveWords(); clip = []; canvas.redo() } label: {
                            Image(systemName: "arrow.uturn.forward").frame(width: 32, height: 44)
                        }.disabled(!canvas.canRedo || showingMade).accessibilityLabel("Redo canvas change")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear") {
                            leaveWords(); canvas.checkpoint(); clip = []; canvas.clear(); savedID = nil
                        }.font(.ui(15, .medium)).disabled(canvas.isEmpty || showingMade)
                    }
                }.tint(accent)
        }.preferredColorScheme(.dark).presentationBackground(Ink.ground)
    }

    private func prepare() {
        kept.load()
        guard frozen.isEmpty else { return }
        var row: [(UInt8, UInt8, UInt8)] = [(255, 255, 255), (232, 176, 75)]
        for color in roomPalette.prefix(3).map({ Self.rgb(of: $0) })
        where !row.contains(where: { Self.near($0, color) }) { row.append(color) }
        frozen = row
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-studio-tool"), args.indices.contains(index + 1) {
            switch args[index + 1] {
            case "lettering":
                beginWords(focus: false); words = "MAKE\nLIGHT"; wordScale = 2
                wordColors = Array(repeating: "#E8B04B", count: 4) + Array(repeating: "#F7EDDC", count: 5)
                creationTitle = "Make light"; restamp()
            case "framing": framing = FramingJob(source: [MediaQA.source()])
            case "made": showingMade = true
            case "made-sample":
                let side = canvas.side, blank = canvas.px
                let first = LetteringLayout(text: "MAKE\nLIGHT", side: side, size: 2)
                    .render(over: blank, rgb: (247, 237, 220), colors: Array(repeating: (232, 176, 75), count: 4))
                let second = LetteringLayout(text: "STAY\nLATE", side: side, size: 2)
                    .render(over: blank, rgb: (119, 164, 156))
                _ = kept.keep([first], title: "Make light")
                _ = kept.keep([second], title: "Stay late")
                var frames: [[UInt8]] = []
                for phase in 0..<24 {
                    var px = blank
                    for y in 0..<side { for x in 0..<side {
                        let offset = (y * side + x) * 3
                        let light = 0.5 + 0.5 * sin(Double(x + y) / Double(side) * .pi * 3 + Double(phase) / 24 * .pi * 2)
                        px[offset] = UInt8(35 + light * 130); px[offset + 1] = UInt8(42 + light * 48); px[offset + 2] = UInt8(70 + light * 42)
                    } }
                    frames.append(px)
                }
                _ = kept.keep(frames, fps: 12, title: "Evening tide")
                showingMade = true
            default: break
            }
        }
        #endif
    }

    private func importMedia(_ item: PhotosPickerItem) {
        importTask?.cancel(); importID = UUID(); let requestID = importID
        loadingMedia = true; importProgress = 0; sendError = nil
        importTask = Task {
            defer { if importID == requestID { loadingMedia = false } }
            do {
                if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                    guard let movie = try await item.loadTransferable(type: Movie.self) else { throw Clip.Failure.unreadable }
                    defer { try? FileManager.default.removeItem(at: movie.url) }
                    let frames = try await Clip.decode(from: movie.url) { if importID == requestID { importProgress = $0 } }
                    try Task.checkCancellation()
                    framing = FramingJob(source: frames)
                } else {
                    guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                          let upright = Clip.upright(image) else { throw Clip.Failure.unreadable }
                    try Task.checkCancellation()
                    framing = FramingJob(source: [upright]); importProgress = 1
                }
                Taps.detent()
            } catch is CancellationError { }
            catch { if !Task.isCancelled && importID == requestID { sendError = "Couldn’t open this media. " + error.localizedDescription; Taps.error() } }
            if importID == requestID { media = nil }
        }
    }

    // MARK: Board

    /// Exact native pixels by default; the optional emitter simulation is
    /// labeled separately because software cannot certify physical LED colour.
    private var board: some View {
        GeometryReader { geo in
            SwiftUI.Canvas { ctx, size in
                let n = canvas.side
                let cell = size.width / CGFloat(n)
                let r = cell * 0.36
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                for i in 0..<(n * n) {
                    let o = i * 3
                    let cx = CGFloat(i % n) * cell + cell / 2
                    let cy = CGFloat(i / n) * cell + cell / 2
                    let dot = Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                    if !emitterPreview {
                        let pixel = Path(CGRect(x: CGFloat(i % n) * cell, y: CGFloat(i / n) * cell, width: cell + 0.1, height: cell + 0.1))
                        ctx.fill(pixel, with: .color(Color(red: Double(canvas.px[o]) / 255, green: Double(canvas.px[o + 1]) / 255, blue: Double(canvas.px[o + 2]) / 255)))
                        continue
                    }
                    // drawn as the wall will light it: below 16 is off, 16 up
                    // to 64 is lifted to 64, the panel's lowest steady level,
                    // the colour kept; from 64 up, as it is
                    let peak = max(canvas.px[o], canvas.px[o + 1], canvas.px[o + 2])
                    if peak < 16 {
                        ctx.fill(dot, with: .color(Color(white: 0.055)))
                    } else {
                        let lift = peak < 64 ? 64.0 / Double(peak) : 1.0
                        ctx.fill(dot, with: .color(Color(
                            red: min(1, Double(canvas.px[o]) * lift / 255),
                            green: min(1, Double(canvas.px[o + 1]) * lift / 255),
                            blue: min(1, Double(canvas.px[o + 2]) * lift / 255)
                        )))
                    }
                }
            }
            .drawingGroup()
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if writing {
                            if moveOrigin == nil { moveOrigin = (horizontal, vertical) }
                            if let origin = moveOrigin {
                                horizontal = min(1, max(0, origin.0 + g.translation.width / geo.size.width))
                                vertical = min(1, max(0, origin.1 + g.translation.height / geo.size.height))
                                restamp()
                            }
                            return
                        }
                        if lastF == nil {
                            Taps.warm()
                            if tool != .fill { canvas.checkpoint() }
                        }
                        if writing { leaveWords() }
                        if !clip.isEmpty { clip = [] }
                        guard tool != .fill else { return }   // the bucket pours on release
                        let cell = geo.size.width / CGFloat(canvas.side)
                        let fx = min(Double(canvas.side) - 0.51, max(0.0, g.location.x / cell - 0.5))
                        let fy = min(Double(canvas.side) - 0.51, max(0.0, g.location.y / cell - 0.5))
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
                        if writing { moveOrigin = nil; Taps.detent(); return }
                        lastF = nil
                        if tool == .fill {
                            let cell = geo.size.width / CGFloat(canvas.side)
                            let x = min(canvas.side - 1, max(0, Int(g.location.x / cell)))
                            let y = min(canvas.side - 1, max(0, Int(g.location.y / cell)))
                            canvas.checkpoint()
                            canvas.fill(x: x, y: y, rgb: ink)
                            Taps.commit()
                        } else {
                            Taps.detent(intensity: 0.3)
                        }
                    }
            )
            .accessibilityLabel("Canvas, \(canvas.side) by \(canvas.side) pixels. \(writing ? "Drag to place your lettering, or use the alignment and height controls below." : "Draw with one finger.")")
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay {
            if canvas.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "plus").font(.system(size: 28, weight: .ultraLight))
                    Text("Start with a mark").font(.ui(15, .medium))
                }.foregroundStyle(Ink.dim.opacity(0.6)).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .padding(1)
        .background(Ink.ink.opacity(0.2), in: RoundedRectangle(cornerRadius: 5))
        .clipShape(RoundedRectangle(cornerRadius: 5))

    }

    private var studioHeading: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) { studioTitle; Spacer(); canvasSize }
                VStack(alignment: .leading, spacing: 8) { studioTitle; canvasSize }
            }
            HStack {
                Text(showingMade ? "Your little collection of light." : writing ? "Drag the words into place." : clip.isEmpty ? "Every pixel is yours." : "A moving picture, made for your wall.").font(.ui(13)).foregroundStyle(Ink.dim)
                Spacer()
                Button { emitterPreview.toggle() } label: {
                    Image(systemName: emitterPreview ? "square.grid.3x3.fill" : "square.fill")
                        .foregroundStyle(accent).frame(width: 44, height: 44)
                }.accessibilityLabel(emitterPreview ? "Show exact pixels" : "Show LED simulation")
            }
            if emitterPreview { Text("LED simulation · colours are approximate").font(.ui(11)).foregroundStyle(Ink.dim) }
        }
    }

    private var studioTitle: some View {
        Text(showingMade ? "Made" : "Studio").font(.display(typeSize.isAccessibilitySize ? 20 : 38)).foregroundStyle(Ink.ink)
            .fixedSize(horizontal: true, vertical: false)
    }
    private var canvasSize: some View {
        Text("\(canvas.side) × \(canvas.side)").font(.machine(9)).foregroundStyle(Ink.dim)
            .fixedSize(horizontal: true, vertical: false)
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
        HStack(spacing: 10) {
            Text("Ink").font(.ui(13, .medium)).foregroundStyle(Ink.dim)
            ScrollView(.horizontal) { HStack(spacing: 4) {
            ForEach(Array(swatches.enumerated()), id: \.offset) { _, rgb in
                Button {
                    ink = rgb
                    if tool == .erase { tool = .pen }
                    Taps.detent()
                } label: {
                    Circle().fill(Color(red: Double(rgb.0) / 255, green: Double(rgb.1) / 255, blue: Double(rgb.2) / 255))
                        .frame(width: 28, height: 28)
                        .padding(5)
                        .overlay(Circle().strokeBorder(ink == rgb ? Ink.ink : .clear, lineWidth: 1.5))
                        .frame(minWidth: 44, minHeight: 44)
                }.buttonStyle(PressStyle()).accessibilityLabel(String(format: "Ink %02X%02X%02X", rgb.0, rgb.1, rgb.2))
                    .accessibilityAddTraits(ink == rgb ? .isSelected : [])
            }
            } }.scrollIndicators(.hidden).frame(height: 44)
            ColorPicker("Custom ink", selection: Binding(get: { inkColor }, set: { value in
                ink = Self.rgb(of: value)
                if tool == .erase { tool = .pen }
            }), supportsOpacity: false).labelsHidden().frame(width: 44, height: 44)
        }
    }

    static func rgb(of c: Color) -> (UInt8, UInt8, UInt8) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (UInt8(max(0, min(255, r * 255))),
                UInt8(max(0, min(255, g * 255))),
                UInt8(max(0, min(255, b * 255))))
    }

    /// Close enough to be the same swatch: two inks a few steps apart are
    /// one choice, not two.
    static func near(_ a: (UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8)) -> Bool {
        abs(Int(a.0) - Int(b.0)) < 14 && abs(Int(a.1) - Int(b.1)) < 14 && abs(Int(a.2) - Int(b.2)) < 14
    }

    // MARK: Tools

    private var tools: some View {
        HStack(spacing: 12) {
            Button {
                if writing { leaveWords() } else { beginWords() }
            } label: {
                Label(writing ? "Keep lettering" : "Lettering", systemImage: writing ? "checkmark" : "textformat")
                    .font(.ui(13, .medium)).frame(maxWidth: .infinity, minHeight: 48)
            }.buttonStyle(PressStyle()).foregroundStyle(writing ? accent : Ink.dim)
            PhotosPicker(selection: $media, matching: .any(of: [.images, .videos])) {
                Label("Import", systemImage: "photo.on.rectangle")
                    .font(.ui(13, .medium)).frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(Ink.dim)
            }.disabled(loadingMedia)
        }
    }

    private func beginWords(focus: Bool = true) {
        tool = .pen; clip = []; canvas.checkpoint(); beneath = canvas.px
        words = ""; wordColors = []; horizontal = 0.5; vertical = 0.5
        writing = true; typing = focus
    }

    private var lettering: LetteringLayout {
        LetteringLayout(text: words, side: canvas.side, size: wordSize,
                        horizontal: horizontal, vertical: vertical)
    }

    private func restamp() {
        guard writing else { return }
        canvas.stamp(text: words, over: beneath, rgb: ink, size: wordSize,
                     colors: wordInks, horizontal: horizontal, vertical: vertical)
    }

    private var compose: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("Lettering").font(.ui(18, .semibold)).foregroundStyle(Ink.ink)
                Spacer()
                Text("\(words.count) / 96").font(.machine(10)).foregroundStyle(Ink.dim)
            }
            TextField("Make yourself at home", text: $words, axis: .vertical)
                .lineLimit(1...3).font(.ui(20, .medium)).foregroundStyle(Ink.ink)
                .textInputAutocapitalization(.never).autocorrectionDisabled().focused($typing)
                .padding(16).background(Ink.sunk, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Words on your canvas")
            HStack {
                Text("Size").font(.ui(13, .medium)).foregroundStyle(Ink.dim)
                Spacer()
                Text(lettering.fits ? "\(lettering.scale * 7) px tall" : "Shorten your words to fit")
                    .font(.machine(10)).foregroundStyle(lettering.fits ? Ink.dim : accent)
            }
            SizeRail(value: wordSize, ink: inkColor) { wordScale = Double($0) }
            HStack(spacing: 8) {
                alignmentButton("Left", "text.alignleft", value: 0)
                alignmentButton("Center", "text.aligncenter", value: 0.5)
                alignmentButton("Right", "text.alignright", value: 1)
            }
            HStack {
                Text("Height").font(.ui(13, .medium)).foregroundStyle(Ink.dim)
                Slider(value: $vertical, in: 0...1).tint(accent).accessibilityLabel("Vertical position")
                Button("Reset") { horizontal = 0.5; vertical = 0.5 }.font(.ui(12, .medium)).foregroundStyle(accent)
            }
            if lettering.scale < lettering.requestedScale && lettering.fits {
                Text("Sized down to keep every letter on the wall.").font(.ui(12)).foregroundStyle(Ink.dim)
            }
            if words.contains(where: { !$0.isWhitespace }) {
                LetterInker(text: words, colors: wordColors, accent: inkColor, base: inkColor.wallHex) { wordColors = $0 }
            }
            Button("Remove this lettering") { canvas.load(beneath); writing = false; typing = false }
                .font(.ui(13, .medium)).foregroundStyle(Ink.dim).frame(minHeight: 44)
        }
        .onChange(of: words) { _, new in
            if new.count > 96 { words = String(new.prefix(96)) }
            restamp()
        }
        .onChange(of: wordScale) { _, _ in Taps.detent(intensity: 0.4); restamp() }
        .onChange(of: wordColors) { _, _ in restamp() }
        .onChange(of: horizontal) { _, _ in restamp() }
        .onChange(of: vertical) { _, _ in restamp() }
        .onChange(of: ink.0) { _, _ in restamp() }
        .onChange(of: ink.1) { _, _ in restamp() }
        .onChange(of: ink.2) { _, _ in restamp() }
        .onSubmit { typing = false }.transition(.opacity)
    }

    private func alignmentButton(_ title: String, _ symbol: String, value: Double) -> some View {
        Button { horizontal = value; Taps.detent() } label: {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(horizontal == value ? Ink.ground : Ink.dim)
                .background(horizontal == value ? accent : Ink.sunk, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(PressStyle()).accessibilityLabel("Align \(title)")
            .accessibilityAddTraits(horizontal == value ? .isSelected : [])
    }

    private var wordSize: Int { Int(wordScale) }

    private var wordInks: [(UInt8, UInt8, UInt8)] {
        wordColors.map { hex in Color(wallHex: hex).map { Self.rgb(of: $0) } ?? ink }
    }

    /// The pen's own pocket: how it marks, and its two alter egos. Lives
    /// under the row so the top level stays three ideas: pen, words, media.
    @ViewBuilder private var penOptions: some View {
        if !writing {
            VStack(spacing: 12) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: typeSize.isAccessibilitySize ? 1 : 3), spacing: 8) {
                    drawingTool("Pen", "pencil.tip", .pen)
                    drawingTool("Erase", "eraser", .erase)
                    drawingTool("Fill", "drop.fill", .fill)
                }
                if tool != .fill {
                    if typeSize.isAccessibilitySize {
                        Toggle("Wide brush · 3 pixels", isOn: $thick).font(.ui(14)).foregroundStyle(Ink.ink).tint(accent)
                    } else {
                        Picker("Brush width", selection: $thick) {
                            Text("Fine · 1 pixel").tag(false)
                            Text("Wide · 3 pixels").tag(true)
                        }.pickerStyle(.segmented)
                    }
                }
            }
        }
    }

    private func drawingTool(_ title: String, _ symbol: String, _ value: Tool) -> some View {
        Button { leaveWords(); tool = value; Taps.detent() } label: {
            Label(title, systemImage: symbol).font(.ui(14, .semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(tool == value ? Ink.ground : Ink.dim)
                .background(tool == value ? accent : Ink.sunk, in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(PressStyle()).accessibilityAddTraits(tool == value ? .isSelected : [])
    }

    /// Words mode ends the moment you reach for anything else. What was
    /// typed stays on the canvas as tiles; only the re-stamping stops, so a
    /// later brushstroke can never be wiped by an old text field.
    private func leaveWords() {
        guard writing else { return }
        writing = false
        typing = false
    }

    // MARK: Send and keep

    private var canSend: Bool { (!canvas.isEmpty || !clip.isEmpty) && (!writing || lettering.fits) }
    private var isSaved: Bool {
        savedID != nil && savedTitle == titleForSave && (clip.isEmpty ? savedPixels == canvas.px : savedClip == clip)
    }
    private var titleForSave: String {
        let title = creationTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        if writing && !words.isEmpty { return words.replacingOccurrences(of: "\n", with: " ") }
        return clip.isEmpty ? "Untitled study" : "Moving study"
    }

    private func saveCreation() {
        let frames = clip.isEmpty ? [canvas.px] : clip
        if let saved = kept.keep(frames, fps: clipFPS, title: titleForSave) {
            savedID = saved.id; savedTitle = titleForSave; savedPixels = canvas.px; savedClip = clip
            Taps.commit()
        } else { Taps.error() }
    }

    private var send: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                TextField("Name this creation", text: $creationTitle)
                    .font(.ui(13)).foregroundStyle(Ink.ink).lineLimit(1)
                    .onChange(of: creationTitle) { _, value in if value.count > 80 { creationTitle = String(value.prefix(80)) } }
                Button(isSaved ? "Saved" : "Save") { saveCreation() }
                    .font(.ui(13, .semibold)).foregroundStyle(isSaved ? Ink.dim : accent)
                    .frame(minWidth: 48, minHeight: 44).disabled(!canSend || isSaved)
            }
            Button {
                guard canSend, !sending else { return }
                let pixels = canvas.px, movie = clip, revision = canvas.revision
                let title = titleForSave, fps = clipFPS, alreadySaved = isSaved
                sending = true; sendError = nil
                Task {
                    let ok = movie.isEmpty ? await wall.sendDrawing(pixels) : await wall.sendClip(movie, fps: fps)
                    sending = false
                    if ok {
                        sent = movie.isEmpty ? revision == canvas.revision : movie == clip
                        if !alreadySaved, let saved = kept.keep(movie.isEmpty ? [pixels] : movie, fps: fps, title: title), sent {
                            savedID = saved.id; savedTitle = title; savedPixels = pixels; savedClip = movie
                        }
                    } else {
                        sendError = "Couldn’t reach the wall. Your creation is safe here; tap to try again."
                        Taps.error()
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    if sending { ProgressView().tint(Ink.ground) }
                    else { Image(systemName: sent ? "checkmark" : "arrow.up.right") }
                    Text(sending ? "Sending…" : sent ? (wall.link.isStandIn ? "Phone preview" : "On the wall") : sendError != nil ? "Try again" : clip.count > 1 ? "Play on wall" : "Send to wall")
                }.font(.ui(typeSize.isAccessibilitySize ? 14 : 16, .semibold))
                    .foregroundStyle(canSend ? Ink.ground : Ink.faint)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(canSend ? accent : Ink.sunk, in: RoundedRectangle(cornerRadius: 16))
            }.buttonStyle(PressStyle()).disabled(!canSend || sending)
        }
    }

    private var clipTransport: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button { clipPlaying.toggle() } label: {
                    Image(systemName: clipPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                }.foregroundStyle(accent).accessibilityLabel(clipPlaying ? "Pause clip preview" : "Play clip preview")
                Slider(value: Binding(get: { Double(clipFrame) }, set: { value in
                    clipPlaying = false; clipFrame = min(clip.count - 1, max(0, Int(value))); canvas.load(clip[clipFrame])
                }), in: 0...Double(max(1, clip.count - 1)), step: 1).tint(accent).accessibilityLabel("Clip frame")
                Text(String(format: "%.1f / %.1fs", Double(clipFrame) / clipFPS, Double(clip.count) / clipFPS))
                    .font(.machine(10)).foregroundStyle(Ink.dim)
            }
            Text("Silent clip · drawing on it keeps the current frame as a still.")
                .font(.ui(12)).foregroundStyle(Ink.dim)
        }
    }

    // MARK: Collection, in the same Studio

    private var madeCollection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let error = kept.error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.ui(13)).foregroundStyle(Ink.dim)
                    Button("Read again") { kept.load() }.foregroundStyle(accent)
                }
            }
            if let title = kept.removedTitle {
                HStack {
                    Text("Deleted \(title)").font(.ui(13)).foregroundStyle(Ink.dim)
                    Spacer(); Button("Undo") { kept.undoRemove() }.font(.ui(13, .semibold)).foregroundStyle(accent)
                }.padding(14).background(Ink.sunk, in: RoundedRectangle(cornerRadius: 12))
            }
            if kept.made.isEmpty {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(accent)
                    Text("Keep a little light.").font(.display(30)).foregroundStyle(Ink.ink)
                    Text("Save your drawings, lettering, photos and moving studies here. They stay on this iPhone, ready for another evening.")
                        .font(.ui(15)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    Button("Make your first piece") { showingMade = false }.font(.ui(15, .semibold)).foregroundStyle(accent).frame(minHeight: 44)
                }.padding(.vertical, 32)
            } else {
                Text("Tap a piece to bring it back to your canvas.").font(.ui(13)).foregroundStyle(Ink.dim)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 24) {
                    ForEach(kept.made) { item in madeTile(item) }
                }
            }
        }
    }

    private func madeTile(_ item: MadeStore.Made) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { openCreation(item) } label: {
                Group {
                    if let image = MediaRaster.image(item.px) {
                        Image(decorative: image, scale: 1).resizable().interpolation(.none).aspectRatio(1, contentMode: .fit)
                    } else { Color.black.aspectRatio(1, contentMode: .fit) }
                }.overlay(alignment: .bottomLeading) {
                    if item.animated {
                        Label(String(format: "%.1fs", item.duration), systemImage: "play.fill")
                            .font(.machine(10)).padding(8).foregroundStyle(.white).background(.black.opacity(0.7))
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 5))
            }.buttonStyle(PressStyle()).accessibilityLabel("Open \(item.title), \(item.animated ? "animated clip" : "still artwork")")
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.ui(14, .medium)).foregroundStyle(Ink.ink).lineLimit(2)
                    Text("\(item.animated ? "Clip" : "Still") · \(item.side) × \(item.side)")
                        .font(.machine(9)).foregroundStyle(Ink.dim)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Open in Studio", systemImage: "pencil") { openCreation(item) }
                    Button("Delete", systemImage: "trash", role: .destructive) { kept.remove(item) }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44).foregroundStyle(Ink.dim)
                }.accessibilityLabel("Actions for \(item.title)")
            }
        }
    }

    private func openCreation(_ item: MadeStore.Made) {
        guard let content = kept.content(item), let first = content.frames.first else { Taps.error(); return }
        leaveWords(); canvas.checkpoint(); canvas.load(first)
        // Resample every animation frame into this canvas, never only its poster.
        if content.frames.count > 1 {
            clip = content.frames.map { frame in canvas.load(frame); return canvas.px }
            canvas.load(clip[0])
        } else { clip = [] }
        clipFPS = content.fps; clipFrame = 0; clipPlaying = !reduceMotion
        savedID = item.id; savedPixels = canvas.px; savedClip = clip
        creationTitle = item.title; savedTitle = item.title; showingMade = false; sent = false; sendError = nil
        Taps.detent()
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
