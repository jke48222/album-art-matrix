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
    func stamp(text: String, over base: [UInt8], rgb: (UInt8, UInt8, UInt8)) {
        var out = base
        let words = PixelFont.normalize(text)
        guard !words.trimmingCharacters(in: .whitespaces).isEmpty else {
            load(out)
            return
        }

        // biggest scale whose wrapped block still fits the panel
        var scale = 4
        var lines: [String] = []
        while scale >= 1 {
            lines = PixelFont.wrap(words, maxWidth: 62, scale: scale)
            let blockHeight = lines.count * (PixelFont.height * scale + scale) - scale
            let widest = lines.map { PixelFont.textWidth($0, scale: scale) }.max() ?? 0
            if blockHeight <= 62 && widest <= 62 { break }
            scale -= 1
        }
        scale = max(1, scale)

        let lineStep = PixelFont.height * scale + scale
        let blockHeight = lines.count * lineStep - scale
        var y = (64 - blockHeight) / 2

        for line in lines {
            let w = PixelFont.textWidth(line, scale: scale)
            var x = (64 - w) / 2
            for ch in line {
                let rows = PixelFont.glyph(ch)
                for (ry, mask) in rows.enumerated() {
                    for rx in 0..<PixelFont.width where mask & (1 << (4 - rx)) != 0 {
                        for sy in 0..<scale {
                            for sx in 0..<scale {
                                let xx = x + rx * scale + sx
                                let yy = y + ry * scale + sy
                                guard xx >= 0, xx < 64, yy >= 0, yy < 64 else { continue }
                                let o = (yy * 64 + xx) * 3
                                out[o] = rgb.0; out[o + 1] = rgb.1; out[o + 2] = rgb.2
                            }
                        }
                    }
                }
                x += PixelFont.advance * scale
            }
            y += lineStep
        }
        load(out)
    }

    /// A photo becomes 4,096 tiles immediately, on this same canvas, so it can
    /// be drawn on afterwards.
    func load(image: UIImage) {
        guard let cg = image.cgImage else { return }
        let count = 64 * 64 * 4
        let raw = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        raw.initialize(repeating: 0, count: count)
        defer { raw.deallocate() }
        guard let ctx = CGContext(
            data: raw, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return }
        ctx.interpolationQuality = .high

        // fill the square, centre-cropped: the wall is square and the photo is not
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let side = min(w, h)
        let scale = 64 / side
        let dw = w * scale, dh = h * scale
        ctx.draw(cg, in: CGRect(x: (64 - dw) / 2, y: (64 - dh) / 2, width: dw, height: dh))

        var out = [UInt8](repeating: 0, count: 64 * 64 * 3)
        for i in 0..<(64 * 64) {
            out[i * 3] = raw[i * 4]
            out[i * 3 + 1] = raw[i * 4 + 1]
            out[i * 3 + 2] = raw[i * 4 + 2]
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
    @State private var erasing = false
    @State private var thick = false
    @State private var last: (Int, Int)? = nil
    @State private var media: PhotosPickerItem? = nil
    /// A clip loaded from a video: previewed by playing on the canvas, sent
    /// whole. Empty for a still.
    @State private var clip: [[UInt8]] = []
    @State private var clipFrame = 0
    @State private var loadingMedia = false
    @State private var sent = false
    @State private var words = ""
    @State private var writing = false
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") {
                        Taps.detent()
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
        .onAppear { kept.load() }
        .onChange(of: media) { _, item in
            guard let item else { return }
            loadingMedia = true
            clip = []
            Task {
                defer { loadingMedia = false }
                // A movie first: if it transfers as one, it is one.
                if let movie = try? await item.loadTransferable(type: Movie.self) {
                    let frames = await Clip.frames(from: movie.url)
                    try? FileManager.default.removeItem(at: movie.url)
                    if !frames.isEmpty {
                        clip = frames
                        clipFrame = 0
                        canvas.load(frames[0])
                        Taps.commit()
                        return
                    }
                }
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    canvas.load(image: img)
                    Taps.commit()
                }
            }
        }
        // Play the clip on the canvas so the preview is the thing itself.
        .onReceive(Timer.publish(every: 1 / Clip.fps, on: .main, in: .common).autoconnect()) { _ in
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
                        if last == nil { Taps.warm() }
                        let cell = geo.size.width / 64
                        let x = min(63, max(0, Int(g.location.x / cell)))
                        let y = min(63, max(0, Int(g.location.y / cell)))
                        let rgb: (UInt8, UInt8, UInt8) = erasing ? (0, 0, 0) : ink
                        let radius = thick ? 1 : 0
                        if let l = last {
                            canvas.stroke(from: l, to: (x, y), rgb: rgb, radius: radius)
                        } else {
                            canvas.light(x: x, y: y, rgb: rgb, radius: radius)
                        }
                        last = (x, y)
                    }
                    .onEnded { _ in
                        last = nil
                        Taps.detent(intensity: 0.3)
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

    private var swatches: [(UInt8, UInt8, UInt8)] {
        var out: [(UInt8, UInt8, UInt8)] = [(255, 255, 255), (232, 176, 75)]
        for c in roomPalette.prefix(3) { out.append(Self.rgb(of: c)) }
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
                    erasing = false
                    Taps.detent(intensity: 0.5)
                }
            .accessibilityLabel("Mix a colour")

            Spacer()
        }
    }

    private func swatch(_ rgb: (UInt8, UInt8, UInt8)) -> some View {
        let on = !erasing && rgb == ink
        return Button {
            Taps.detent(intensity: 0.5)
            ink = rgb
            erasing = false
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
            GlyphButton(glyph: .erase, label: "erase", active: erasing,
                        accent: accent, lit: 0.6, diameter: 54) {
                erasing.toggle()
            }
            .frame(maxWidth: .infinity)

            BrushButton(thick: thick, accent: erasing ? Ink.dim : inkColor) { thick.toggle() }
                .frame(maxWidth: .infinity)

            GlyphButton(glyph: .letters, label: "words", active: writing,
                        accent: accent, lit: 0.6, diameter: 54) {
                if writing {
                    writing = false
                    typing = false
                } else {
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
        HStack(spacing: 12) {
            TextField("say something", text: $words)
                .font(.machine(14))
                .foregroundStyle(Ink.ink)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled()
                .focused($typing)
                .submitLabel(.done)
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(Ink.sunk)
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.hairline, lineWidth: 1) }

            Button {
                Taps.detent()
                words = ""
                canvas.load(beneath)
            } label: {
                Text("undo")
                    .font(.ui(13, .medium))
                    .foregroundStyle(Ink.dim)
            }
            .buttonStyle(.plain)
        }
        .onChange(of: words) { _, new in
            canvas.stamp(text: new, over: beneath, rgb: erasing ? (255, 255, 255) : ink)
        }
        .transition(.opacity)
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
            Taps.landed()
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
            Taps.detent(intensity: 0.5)
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
/// centre-cropped square, sampled to the panel's own resolution, previewed by
/// playing it on the canvas, and sent whole.
enum Clip {
    static let fps: Double = 12
    static let maxFrames = 120        // ten seconds; the brain's ceiling is 240

    static func frames(from url: URL) async -> [[UInt8]] {
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

        var out: [[UInt8]] = []
        for value in times {
            guard let cg = try? await gen.image(at: value.timeValue).image else { continue }
            if let px = square64(cg) { out.append(px) }
        }
        return out
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
