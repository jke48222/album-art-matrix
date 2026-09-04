// The opening, live.
//
// A film of the room with a hole where the wall is. The live wall is drawn
// through the hole, warped to wherever the wall sits in that frame, and the
// record's label carries the sleeve the same way, so nothing in the opening
// is a picture of some other song. The film itself: the dust cover up, the
// mark's nine plates flying in to badge its front, the cover closing with
// the badge on it, and the pull back to the seat. Its last frame is the
// room's own picture, and the room takes over from it.

import AVFoundation
import SwiftUI
import UIKit

/// Where the wall and the label are in every frame of the film.
struct IntroTrack: Decodable {
    struct Frame: Decodable {
        var face: [[Double]]      // four corners, image fractions
        var label: [Double]       // cx, cy, ax, ay, bx, by
        var badge: [[[Double]]]?  // nine tiles, four corners each
    }
    var fps: Double
    var frames: [Frame]

    static let loaded: IntroTrack? = {
        guard let url = Bundle.main.url(forResource: "room-intro-track", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(IntroTrack.self, from: data)
    }()

    static var available: Bool { loaded != nil && IntroFlip.available(named: "room-intro") }
}

struct RoomIntro: View {
    let light: Lighting
    let duty: Double
    /// Where the room's picture sits on the screen; the film sits there too.
    let fit: CGRect
    /// The sleeve of the song that is on, for the label.
    var sleeve: UIImage? = nil
    var onDone: () -> Void

    @State private var player: AVPlayer? = nil
    @State private var ended = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // behind the film: the app's own background, the room's wall
                if let track = IntroTrack.loaded, let player, !track.frames.isEmpty {
                    // a timeline proposes no size to what it holds: each layer
                    // is given the screen outright
                    TimelineView(.animation(paused: ended)) { tl in
                        let t = player.currentTime().seconds
                        let i = max(0, min(track.frames.count - 1, Int((t.isFinite ? t : 0) * track.fps)))
                        let f = track.frames[i]
                        let quad = f.face.map { CGPoint(x: fit.origin.x + fit.width * $0[0], y: fit.origin.y + fit.height * $0[1]) }
                        ZStack(alignment: .topLeading) {
                            // the wall, through the hole
                            WarpedPanel(px: light.reading.px, duty: duty, quad: quad)
                                .frame(width: geo.size.width, height: geo.size.height)
                            FilmView(player: player)
                                .frame(width: fit.width, height: fit.height)
                                .offset(x: fit.origin.x, y: fit.origin.y)
                            // the sleeve on the label, over the film: a view of its own,
                            // because the film is one and would paint over drawing
                            LabelArtOverlay(image: sleeve, ellipse: f.label, fit: fit, angle: 0)
                                .frame(width: geo.size.width, height: geo.size.height)
                            // the mark on the cover, in the wall's colour
                            BadgeOverlay(quads: f.badge ?? [], fit: fit, accent: light.steadyAccent, lit: max(0.4, light.room))
                                .frame(width: geo.size.width, height: geo.size.height)
                        }
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .onAppear(perform: load)
        .onDisappear { player?.pause(); player = nil }
    }

    private func load() {
        guard player == nil, let url = Bundle.main.url(forResource: "room-intro", withExtension: "mov") else {
            DispatchQueue.main.async { onDone() }; return
        }
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        p.actionAtItemEnd = .pause
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            ended = true
            onDone()
        }
        player = p
        p.play()
    }
}

/// The film, with its transparency kept.
struct FilmView: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> IntroFlip.PlayerView {
        let v = IntroFlip.PlayerView()
        v.backgroundColor = .clear
        v.isOpaque = false
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resize
        v.playerLayer.pixelBufferAttributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        return v
    }
    func updateUIView(_ uiView: IntroFlip.PlayerView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }
}

/// The wall drawn straight onto four corners: every emitter's place is put
/// through the projective map itself, so the picture sits in the frame
/// however the camera is looking at it.
struct WarpedPanel: View {
    let px: [UInt8]?
    let duty: Double
    let quad: [CGPoint]

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            guard let px, px.count == 64 * 64 * 3, let h = Homography.unitSquare(to: quad) else { return }
            let d = max(0.05, min(1.0, duty))
            let warm = 0.18 * (1 - d)
            let gK = 1 - warm * 0.34, bK = 1 - warm
            // the hole is black glass behind the emitters
            var glass = Path(); glass.move(to: quad[0])
            for k in 1..<4 { glass.addLine(to: quad[k]) }
            glass.closeSubpath()
            ctx.fill(glass, with: .color(.black))
            let unlit = Color(white: 0.06)
            for j in 0..<64 {
                let v = (Double(j) + 0.5) / 64
                // the cell's size on screen along this row, for the dot's radius
                let p0 = Homography.map(h, 0.5 / 64, v), p1 = Homography.map(h, 1.5 / 64, v)
                let q0 = Homography.map(h, 0.5 / 64, v + 1.0 / 64)
                let cell = min(hypot(p1.x - p0.x, p1.y - p0.y), hypot(q0.x - p0.x, q0.y - p0.y))
                let r = cell * 0.40
                for i in 0..<64 {
                    let o = (j * 64 + i) * 3
                    let c = Homography.map(h, (Double(i) + 0.5) / 64, v)
                    let R = Double(px[o]), G = Double(px[o + 1]), B = Double(px[o + 2])
                    let lum = 0.2126 * R + 0.7152 * G + 0.0722 * B
                    if lum < 8 {
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(unlit))
                        continue
                    }
                    let colour = Color(red: R / 255 * d, green: G / 255 * d * gK, blue: B / 255 * d * bK)
                    let n = lum / 255
                    let hr = r + cell * 0.72 * n * d
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - hr, y: c.y - hr, width: 2 * hr, height: 2 * hr)),
                             with: .color(colour.opacity(0.28 * n * pow(d, 1.4))))
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(colour))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// The projective map that puts a flat picture onto four corners.
enum Homography {
    /// The 3 x 3 map from the unit square to the quad, corners in order
    /// top-left, top-right, bottom-right, bottom-left. Nil if degenerate.
    static func unitSquare(to q: [CGPoint]) -> [Double]? {
        guard q.count == 4 else { return nil }
        let src = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        var m = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for k in 0..<4 {
            let x = Double(src[k].x), y = Double(src[k].y), u = Double(q[k].x), v = Double(q[k].y)
            m[2 * k] = [x, y, 1, 0, 0, 0, -x * u, -y * u, u]
            m[2 * k + 1] = [0, 0, 0, x, y, 1, -x * v, -y * v, v]
        }
        for c in 0..<8 {
            var pivot = c
            for r in c..<8 where abs(m[r][c]) > abs(m[pivot][c]) { pivot = r }
            if abs(m[pivot][c]) < 1e-12 { return nil }
            m.swapAt(c, pivot)
            let dv = m[c][c]
            for j in 0..<9 { m[c][j] /= dv }
            for r in 0..<8 where r != c {
                let f = m[r][c]
                if f != 0 { for j in 0..<9 { m[r][j] -= f * m[c][j] } }
            }
        }
        return (0..<8).map { m[$0][8] } + [1]
    }

    /// Where (u, v) in the unit square lands.
    static func map(_ h: [Double], _ u: Double, _ v: Double) -> CGPoint {
        let w = h[6] * u + h[7] * v + h[8]
        return CGPoint(x: (h[0] * u + h[1] * v + h[2]) / w, y: (h[3] * u + h[4] * v + h[5]) / w)
    }

    /// A transform taking a view of `size` (its own coordinates, origin at
    /// its top-left) onto the quad, corners in order top-left, top-right,
    /// bottom-right, bottom-left, in the coordinates the view is laid out in.
    static func unitSquareTransform(to q: [CGPoint], from size: CGSize) -> ProjectionTransform {
        guard q.count == 4, size.width > 0, size.height > 0 else { return ProjectionTransform() }
        let src = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        // eight unknowns a..h with the ninth fixed at one:
        //   u = (a x + b y + c) / (g x + h y + 1),  v = (d x + e y + f) / (g x + h y + 1)
        var m = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for k in 0..<4 {
            let x = Double(src[k].x), y = Double(src[k].y), u = Double(q[k].x), v = Double(q[k].y)
            m[2 * k] = [x, y, 1, 0, 0, 0, -x * u, -y * u, u]
            m[2 * k + 1] = [0, 0, 0, x, y, 1, -x * v, -y * v, v]
        }
        // gaussian elimination with partial pivoting
        for c in 0..<8 {
            var pivot = c
            for r in c..<8 where abs(m[r][c]) > abs(m[pivot][c]) { pivot = r }
            if abs(m[pivot][c]) < 1e-12 { return ProjectionTransform() }
            m.swapAt(c, pivot)
            let d = m[c][c]
            for j in 0..<9 { m[c][j] /= d }
            for r in 0..<8 where r != c {
                let f = m[r][c]
                if f != 0 { for j in 0..<9 { m[r][j] -= f * m[c][j] } }
            }
        }
        let h = (0..<8).map { m[$0][8] }
        // rows of H: [a b c] [d e f] [g h 1], applied to (x / w, y / h, 1)
        let sx = 1 / Double(size.width), sy = 1 / Double(size.height)
        var p = ProjectionTransform()
        p.m11 = CGFloat(h[0] * sx); p.m21 = CGFloat(h[1] * sy); p.m31 = CGFloat(h[2])
        p.m12 = CGFloat(h[3] * sx); p.m22 = CGFloat(h[4] * sy); p.m32 = CGFloat(h[5])
        p.m13 = CGFloat(h[6] * sx); p.m23 = CGFloat(h[7] * sy); p.m33 = 1
        return p
    }
}

/// The wall as it is in the room: the emitters, and under them a soft wash
/// of the picture, so the picture reads from across the room the way a lit
/// panel does and not as a grid of dim points.
struct RoomPanel: View {
    let px: [UInt8]?
    let duty: Double
    var body: some View {
        ZStack {
            PanelCanvas(px: px, duty: duty)
            if let px, let img = LabelArt.flat(px) {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .blur(radius: 3)
                    .opacity(0.42 * max(0.05, min(1, duty)))
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(Rectangle())
    }
}

/// The sleeve on the record's label, laid into the platter's plane and
/// turned with the record.
struct LabelArt: View {
    let image: UIImage?
    let ellipse: [Double]     // cx, cy, ax, ay, bx, by as fractions of the picture
    let fit: CGRect
    let angle: Double

    static let radius: CGFloat = 40

    /// The map from the disc, drawn flat at the origin with `radius`, onto
    /// the label in the picture: disc x along the label's own x, disc y
    /// along its y, so a turn of the record is a turn in disc space.
    static func transform(ellipse: [Double], fit: CGRect, angle: Double) -> CGAffineTransform {
        guard ellipse.count == 6 else { return .identity }
        let r = radius
        let c = CGPoint(x: fit.origin.x + fit.width * ellipse[0], y: fit.origin.y + fit.height * ellipse[1])
        let a = CGPoint(x: fit.width * ellipse[2] / r, y: fit.height * ellipse[3] / r)
        let b = CGPoint(x: fit.width * ellipse[4] / r, y: fit.height * ellipse[5] / r)
        let plane = CGAffineTransform(a: a.x, b: a.y, c: b.x, d: b.y, tx: c.x, ty: c.y)
        return CGAffineTransform(translationX: -r, y: -r)
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(plane)
    }

    var body: some View {
        let r = Self.radius
        let t = Self.transform(ellipse: ellipse, fit: fit, angle: angle)
        ZStack(alignment: .topLeading) {
            if ellipse.count == 6, let img = image {
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: 2 * r, height: 2 * r)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.6))
                    .overlay(Circle().fill(Color(hex: 0xD9D5CC)).frame(width: 5, height: 5))
                    .transformEffect(t)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: The sleeve as a picture, without the gaps between emitters

    private static var cache: (key: Int, image: UIImage)? = nil

    /// The frame as a plain picture, one square per emitter, for wherever
    /// the sleeve is wanted as a sleeve and not as a wall.
    static func flat(_ px: [UInt8]) -> UIImage? {
        guard px.count == 64 * 64 * 3 else { return nil }
        let key = px.withUnsafeBufferPointer { buf -> Int in
            var h = 5381
            for i in stride(from: 0, to: buf.count, by: 7) { h = (h &* 33) &+ Int(buf[i]) }
            return h
        }
        if let c = cache, c.key == key { return c.image }
        let side = 64
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for i in 0..<(side * side) {
            bytes[i * 4] = px[i * 3]; bytes[i * 4 + 1] = px[i * 3 + 1]; bytes[i * 4 + 2] = px[i * 3 + 2]
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let img = UIImage(cgImage: cg)
        cache = (key, img)
        return img
    }
}

/// The same sleeve on the label as a view in its own right, for over the
/// film: the film's layer paints above the room's ordinary drawing, and
/// views keep their order among themselves.
struct LabelArtOverlay: UIViewRepresentable {
    let image: UIImage?
    let ellipse: [Double]
    let fit: CGRect
    let angle: Double

    func makeUIView(context: Context) -> LabelDiscView {
        let v = LabelDiscView()
        v.backgroundColor = .clear
        v.isOpaque = false
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ v: LabelDiscView, context: Context) {
        v.image = image
        v.onto = LabelArt.transform(ellipse: ellipse, fit: fit, angle: angle)
        v.setNeedsDisplay()
    }

    final class LabelDiscView: UIView {
        var image: UIImage? = nil
        var onto: CGAffineTransform = .identity
        override func draw(_ rect: CGRect) {
            guard let image, let ctx = UIGraphicsGetCurrentContext() else { return }
            let r = LabelArt.radius
            let box = CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r)
            ctx.saveGState()
            ctx.concatenate(onto)
            ctx.interpolationQuality = .medium
            ctx.addEllipse(in: box); ctx.clip()
            image.draw(in: box)
            ctx.restoreGState()
            ctx.saveGState()
            ctx.concatenate(onto)
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.35).cgColor); ctx.setLineWidth(0.6)
            ctx.strokeEllipse(in: box.insetBy(dx: 0.3, dy: 0.3))
            ctx.setFillColor(UIColor(red: 0.85, green: 0.835, blue: 0.8, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: r - 2.5, y: r - 2.5, width: 5, height: 5))
            ctx.restoreGState()
        }
    }
}

/// The mark on the dust cover: nine tiles the renders leave pale, painted
/// here in the wall's colour the way the app's own mark is, the middle one
/// lit and the rest catching a little of it.
enum Badge {
    static func paths(_ quads: [[[Double]]], fit: CGRect) -> [CGPath] {
        quads.map { q in
            let p = CGMutablePath()
            let pts = q.map { CGPoint(x: fit.origin.x + fit.width * $0[0], y: fit.origin.y + fit.height * $0[1]) }
            if let f = pts.first { p.move(to: f); for pt in pts.dropFirst() { p.addLine(to: pt) }; p.closeSubpath() }
            return p
        }
    }
    static func alpha(_ i: Int, lit: Double) -> Double { i == 4 ? 1 : 0.30 + 0.25 * lit }
}

struct BadgeView: View {
    let quads: [[[Double]]]
    let fit: CGRect
    let accent: Color
    let lit: Double
    var body: some View {
        Canvas { ctx, _ in
            let paths = Badge.paths(quads, fit: fit)
            // the glow of the lit tile on the glass
            if paths.count == 9 {
                ctx.drawLayer { l in
                    l.addFilter(.blur(radius: 5))
                    l.fill(Path(paths[4]), with: .color(accent.opacity(0.7 * lit)))
                }
            }
            for (i, p) in paths.enumerated() {
                ctx.fill(Path(p), with: .color(accent.opacity(Badge.alpha(i, lit: lit))))
            }
        }
        .allowsHitTesting(false)
    }
}

/// The same tiles as a view of their own, for over the film.
struct BadgeOverlay: UIViewRepresentable {
    let quads: [[[Double]]]
    let fit: CGRect
    let accent: Color
    let lit: Double
    func makeUIView(context: Context) -> BadgeTileView {
        let v = BadgeTileView(); v.backgroundColor = .clear; v.isOpaque = false; v.isUserInteractionEnabled = false; return v
    }
    func updateUIView(_ v: BadgeTileView, context: Context) {
        v.paths = Badge.paths(quads, fit: fit); v.accent = UIColor(accent); v.lit = lit; v.setNeedsDisplay()
    }
    final class BadgeTileView: UIView {
        var paths: [CGPath] = []; var accent = UIColor.white; var lit = 1.0
        override func draw(_ rect: CGRect) {
            guard let ctx = UIGraphicsGetCurrentContext() else { return }
            if paths.count == 9 {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 10, color: accent.withAlphaComponent(CGFloat(0.8 * lit)).cgColor)
                ctx.addPath(paths[4]); ctx.setFillColor(accent.cgColor); ctx.fillPath()
                ctx.restoreGState()
            }
            for (i, p) in paths.enumerated() {
                ctx.addPath(p); ctx.setFillColor(accent.withAlphaComponent(CGFloat(Badge.alpha(i, lit: lit))).cgColor); ctx.fillPath()
            }
        }
    }
}

extension Color {
    /// Rough brightness, for choosing ink over a colour.
    var luma: Double {
        guard let c = UIColor(self).cgColor.components, c.count >= 3 else { return 0.5 }
        return 0.2126 * Double(c[0]) + 0.7152 * Double(c[1]) + 0.0722 * Double(c[2])
    }

    /// The same colour pushed light or dark enough to read on what is
    /// behind it: toward white for a dark ground, toward black for a light
    /// one, and only as far as it takes to reach the brightness asked for.
    /// A colour already there is left alone.
    func toned(forDark ground: Bool, to target: Double? = nil) -> Color {
        guard let c = UIColor(self).cgColor.components, c.count >= 3 else { return self }
        var r = Double(c[0]), g = Double(c[1]), b = Double(c[2])
        let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let want = target ?? (ground ? 0.72 : 0.30)
        if ground, l < want {
            let t = (want - l) / max(0.001, 1 - l)
            r += (1 - r) * t; g += (1 - g) * t; b += (1 - b) * t
        } else if !ground, l > want {
            let t = (l - want) / max(0.001, l)
            r *= 1 - t; g *= 1 - t; b *= 1 - t
        }
        return Color(red: r, green: g, blue: b)
    }
}
