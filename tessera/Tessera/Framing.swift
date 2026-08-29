// Aiming the panel at a photo.
//
// Until now a picked photo was centre-cropped and that was that, which is
// fine for a sleeve and wrong for everything else: the subject of a phone
// photo is almost never dead centre in a square. So this is a framing step.
//
// It is deliberately not a crop tool. A crop tool shows you a photo with a
// box on it and asks you to imagine the result. This shows you the result:
// the square window is the wall, live, in its own 4,096 tiles, and the photo
// bleeds out around it at a quarter brightness so you can see what you are
// leaving out. You are not cutting a picture down, you are pointing a panel
// at it, and the difference is visible the moment you find out that a face
// that looks fine in a photo is eleven tiles wide.

import SwiftUI
import UIKit

/// The screen's own edges, read from UIKit.
///
/// This screen is presented over two other full-screen covers, and by that
/// depth SwiftUI reports no insets at all: the layout ran to the glass, under
/// the clock and over the home indicator. Asking the window directly is the
/// one answer that does not depend on how many presentations deep we are.
enum Safe {
    private static var insets: UIEdgeInsets {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first(where: { $0.isKeyWindow })?.safeAreaInsets ?? .zero
    }
    static var top: CGFloat { insets.top }
    static var bottom: CGFloat { insets.bottom }
}

struct Framing: View {
    /// One image for a still, many for a clip. The window applies to all of
    /// them: a clip is one shot, not a hundred separately-aimed ones.
    let source: [CGImage]
    let accent: Color
    var onCancel: () -> Void
    var onUse: ([[UInt8]]) -> Void

    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panBase: CGSize = .zero
    @State private var preview: [UInt8] = [UInt8](repeating: 0, count: 64 * 64 * 3)
    @State private var playhead = 0
    @State private var working = false
    /// The window's side in points, measured once the layout knows it. Every
    /// piece of the arithmetic below is in these units.
    @State private var side: CGFloat = 0

    private var isClip: Bool { source.count > 1 }
    private var still: CGImage? { source.first }

    var body: some View {
        VStack(spacing: 0) {
            head
                .padding(.horizontal, 20)
                .padding(.bottom, 18)

            GeometryReader { geo in
                ZStack {
                    // What you are leaving out, still visible, still dim.
                    if let cg = still {
                        Image(decorative: cg, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: side, height: side)
                            .scaleEffect(zoom)
                            .offset(pan)
                            .opacity(0.3)
                            .allowsHitTesting(false)
                    }

                    // What the wall gets. Same square, same place, in tiles.
                    PanelCanvas(px: preview, duty: 1)
                        .frame(width: side, height: side)
                        .overlay {
                            Rectangle()
                                .strokeBorder(accent.opacity(0.55), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.6), radius: 18, y: 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    SimultaneousGesture(
                        DragGesture()
                            .onChanged { g in
                                pan = CGSize(width: panBase.width + g.translation.width,
                                             height: panBase.height + g.translation.height)
                                redraw(side: side)
                            }
                            .onEnded { _ in panBase = pan; Taps.detent(intensity: 0.3) },
                        MagnifyGesture()
                            .onChanged { g in
                                zoom = min(8, max(1, zoomBase * g.magnification))
                                redraw(side: side)
                            }
                            .onEnded { _ in zoomBase = zoom; Taps.detent(intensity: 0.4) }
                    )
                )
                .onTapGesture(count: 2) {
                    Taps.commit()
                    withAnimation(Motion.settle) {
                        zoom = 1; zoomBase = 1; pan = .zero; panBase = .zero
                    }
                    redraw(side: side)
                }
                .onAppear {
                    side = min(geo.size.width * 0.8, geo.size.height - 24)
                    redraw(side: side)
                }
            }

            foot
                .padding(.horizontal, 20)
                .padding(.top, 18)
        }
        .padding(.top, Safe.top + 12)
        .padding(.bottom, Safe.bottom + 12)
        // A clip plays while you aim it, because a clip's subject moves and
        // framing a frozen first frame is framing the wrong thing.
        .onReceive(Timer.publish(every: 1 / Clip.fps, on: .main, in: .common).autoconnect()) { _ in
            guard isClip else { return }
            playhead = (playhead + 1) % source.count
            redraw(side: side)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.ground)
        .preferredColorScheme(.dark)
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("AIM IT")
                .font(.display(18))
                .kerning(3.0)
                .foregroundStyle(Ink.ink)
            Text(isClip
                 ? "Drag and pinch. The square is the wall, all \(source.count) frames of it."
                 : "Drag and pinch. The square is the wall. Double tap to start over.")
                .font(.ui(13))
                .foregroundStyle(Ink.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var foot: some View {
        HStack(spacing: 18) {
            Button("Back") { Taps.detent(intensity: 0.3); onCancel() }
                .buttonStyle(PressStyle(scale: 0.96))
                .font(.ui(15))
                .foregroundStyle(Ink.dim)

            Spacer()

            Text(zoom > 1.02 ? String(format: "%.1f×", zoom) : "whole frame")
                .font(.machine(10))
                .foregroundStyle(Ink.faint)

            Button(working ? "Working" : "Use it") {
                Taps.commit()
                commit()
            }
            .buttonStyle(PressStyle(scale: 0.96))
            .font(.ui(15, .semibold))
            .foregroundStyle(accent)
            .disabled(working)
        }
    }

    // MARK: - The window, in image pixels

    /// The square of the source that the panel is currently pointed at.
    ///
    /// Everything on screen is laid out from `side`, so the arithmetic is the
    /// same in both directions: the photo is drawn aspect-fill into a square
    /// of `side` points, then scaled and moved, and the window is that same
    /// square standing still. Invert that and you have the rect.
    private func window(_ cg: CGImage, side: CGFloat) -> CGRect {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let fill = max(side / w, side / h)      // aspect fill at zoom 1
        let ppp = fill * zoom                   // points per image pixel
        let span = side / ppp                   // window width, in image px
        var cx = w / 2 - pan.width / ppp
        var cy = h / 2 - pan.height / ppp
        // Do not let the window walk off the photo: the edge of a picture is
        // black on a wall, and nobody frames a shot to include black.
        if span < w { cx = min(max(cx, span / 2), w - span / 2) } else { cx = w / 2 }
        if span < h { cy = min(max(cy, span / 2), h - span / 2) } else { cy = h / 2 }
        return CGRect(x: cx - span / 2, y: cy - span / 2, width: span, height: span)
    }

    private func redraw(side: CGFloat) {
        guard side > 0, let cg = source[min(playhead, source.count - 1)] as CGImage? else { return }
        guard let first = still else { return }
        // The rect is measured against the first frame so a clip does not
        // re-aim itself every time a frame is a different size.
        if let px = Framing.sample(cg, rect: window(first, side: side)) { preview = px }
    }

    private func commit() {
        guard let first = still, side > 0 else { return }
        working = true
        let rect = window(first, side: side)
        let frames = source.compactMap { Framing.sample($0, rect: rect) }
        working = false
        guard !frames.isEmpty else { onCancel(); return }
        onUse(frames)
    }

    /// One 64×64 RGB frame, taken from a rect of a CGImage.
    static func sample(_ src: CGImage, rect: CGRect) -> [UInt8]? {
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

        // Draw the whole image scaled so that `rect` lands on the 64 square.
        // Cropping first and drawing second would be one allocation per
        // gesture tick; this is none.
        //
        // `rect` is in the coordinates the gesture thinks in, y downward from
        // the top of the photo. A bitmap context counts y upward from the
        // bottom, so the vertical offset is measured from the rect's far
        // edge. Getting this backwards puts the window an equal distance the
        // wrong side of centre, which looks plausible and is not.
        let k = 64 / rect.width
        let h = CGFloat(src.height)
        ctx.translateBy(x: -rect.origin.x * k, y: -(h - rect.maxY) * k)
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: CGFloat(src.width) * k, height: h * k))

        var px = [UInt8](repeating: 0, count: 64 * 64 * 3)
        for i in 0..<(64 * 64) {
            px[i * 3] = raw[i * 4]
            px[i * 3 + 1] = raw[i * 4 + 1]
            px[i * 3 + 2] = raw[i * 4 + 2]
        }
        return px
    }
}
