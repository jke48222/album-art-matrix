import Combine
import SwiftUI
import UIKit

/// Kept for older immersive surfaces. New editors use native safe areas.
enum Safe {
    private static var insets: UIEdgeInsets {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first(where: { $0.isKeyWindow })?.safeAreaInsets ?? .zero
    }
    static var top: CGFloat { insets.top }
    static var bottom: CGFloat { insets.bottom }
}

struct Framing: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let source: [CGImage]
    let accent: Color
    var onCancel: () -> Void
    var onUse: ([[UInt8]]) -> Void
    var onCrop: ((MediaCrop) -> Void)? = nil
    var commitTitle = "Use framing"

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var crop = MediaCrop()
    @State private var dragBase: MediaCrop?
    @State private var zoomBase: CGFloat?
    @State private var preview: [UInt8] = []
    @State private var playhead = 0
    @State private var playing = true
    @State private var working = false
    @State private var progress = 0.0
    @State private var problem: String?
    @State private var outputSide = Panel.side
    @State private var fineAdjustment = false
    @State private var commitTask: Task<Void, Never>?
    @State private var clipTimer = Timer.publish(every: 1 / Clip.fps, on: .main, in: .common).autoconnect()

    private var isClip: Bool { source.count > 1 }
    private var sourceSize: CGSize {
        guard let first = source.first else { return .zero }
        return CGSize(width: first.width, height: first.height)
    }
    private var current: CGImage? { source.indices.contains(playhead) ? source[playhead] : source.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                VStack(alignment: .leading, spacing: 8) {
                    viewport
                    Text("Wall pixels · Outside the frame is dimmed")
                        .font(.ui(11)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                }
                if isClip { transport }
                adjustment
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .font(.ui(14)).foregroundStyle(Ink.signal).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .background(Ink.ground).preferredColorScheme(.dark)
        .onAppear { outputSide = Panel.side; playing = !reduceMotion; redraw() }
        .onDisappear { commitTask?.cancel() }
        .onReceive(clipTimer) { _ in
            guard isClip, playing, !working, scenePhase == .active else { return }
            playhead = (playhead + 1) % source.count
            redraw()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(isClip ? "Motion study" : "Photo study", systemImage: isClip ? "film" : "photo")
                    .font(.machine(typeSize.isAccessibilitySize ? 8 : 11)).textCase(.uppercase).tracking(1.3).foregroundStyle(accent)
                Spacer()
                Text("\(outputSide) × \(outputSide)").font(.machine(11)).foregroundStyle(Ink.dim)
            }
            Text("Find the frame.").font(.display(typeSize.isAccessibilitySize ? 17 : 32)).foregroundStyle(Ink.ink)
            Text("Move the picture. Keep what matters.")
                .font(.ui(typeSize.isAccessibilitySize ? 12 : 15)).foregroundStyle(Ink.dim)
        }
    }

    private var viewport: some View {
        GeometryReader { geometry in
            let outer = geometry.size.width
            let side = outer * 0.84
            let rect = crop.rect(in: sourceSize)
            ZStack {
                Color.black.opacity(0.22)
                if let current, !rect.isEmpty {
                    let scale = side / rect.width
                    Image(decorative: current, scale: 1).resizable()
                        .frame(width: sourceSize.width * scale, height: sourceSize.height * scale)
                        .offset(x: (sourceSize.width / 2 - rect.midX) * scale,
                                y: (sourceSize.height / 2 - rect.midY) * scale)
                        .opacity(0.26).allowsHitTesting(false)
                }
                ZStack {
                    Color.black
                    if let image = MediaRaster.image(preview) {
                        Image(decorative: image, scale: 1).resizable().interpolation(.none)
                    }
                }
                .frame(width: side, height: side)
                .overlay { Rectangle().strokeBorder(Ink.ink.opacity(0.5), lineWidth: 0.5) }
                .overlay(alignment: .topLeading) { corner.rotationEffect(.degrees(0), anchor: .topLeading) }
                .overlay(alignment: .bottomTrailing) { corner.rotationEffect(.degrees(180)) }
                .accessibilityLabel("Exact wall pixel preview")
                .accessibilityValue("\(outputSide) by \(outputSide) pixels, zoom \(String(format: "%.1f", crop.zoom)) times")
            }
            .frame(width: outer, height: outer).clipped()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in
                    guard !working else { return }
                    if dragBase == nil { dragBase = crop }
                    var base = dragBase ?? crop
                    base.zoom = crop.zoom
                    crop = base.moved(by: value.translation, viewport: side, source: sourceSize)
                    redraw()
                }
                .onEnded { _ in dragBase = nil; Taps.detent(intensity: 0.25) })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in
                    guard !working else { return }
                    if zoomBase == nil { zoomBase = crop.zoom }
                    crop.zoom = (zoomBase ?? crop.zoom) * value.magnification
                    crop.clamp(to: sourceSize); redraw()
                }
                .onEnded { _ in zoomBase = nil })
            .onTapGesture(count: 2, perform: reset)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var corner: some View {
        Path { p in p.move(to: CGPoint(x: 0, y: 14)); p.addLine(to: .zero); p.addLine(to: CGPoint(x: 14, y: 0)) }
            .stroke(accent, lineWidth: 2).frame(width: 14, height: 14)
    }

    private var transport: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                ForEach(0..<min(8, source.count), id: \.self) { index in
                    let frame = index * max(1, source.count - 1) / max(1, min(8, source.count) - 1)
                    Button {
                        playing = false; playhead = frame; redraw()
                    } label: {
                        Image(decorative: source[frame], scale: 1).resizable().scaledToFill()
                            .frame(height: 38).clipped()
                    }
                    .accessibilityLabel("Preview at \(WallVideo.clock(Double(frame) / Clip.fps))")
                }
            }.clipShape(RoundedRectangle(cornerRadius: 4))
            HStack(spacing: 12) {
                Button { playing.toggle(); Taps.detent() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold)).frame(width: 44, height: 44)
                        .background(Ink.sunk, in: Circle())
                }.accessibilityLabel(playing ? "Pause preview" : "Play preview")
                Slider(value: Binding(get: { Double(playhead) }, set: {
                    playing = false; playhead = min(source.count - 1, max(0, Int($0))); redraw()
                }), in: 0...Double(max(1, source.count - 1)), step: 1)
                .tint(accent).accessibilityLabel("Clip playhead")
                Text(WallVideo.clock(Double(playhead) / Clip.fps)).font(.machine(12)).monospacedDigit()
            }
            Text(onCrop == nil
                 ? "\(String(format: "%.1f", Double(source.count) / Clip.fps)) seconds · 12 frames/s · silent loop"
                 : "First \(String(format: "%.1f", Double(source.count) / Clip.fps)) seconds shown. This framing applies to the entire video.")
                .font(.ui(12)).foregroundStyle(Ink.dim).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var adjustment: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Zoom").font(.ui(14, .medium))
                Spacer()
                Text(String(format: "%.1f×", crop.zoom)).font(.machine(13)).foregroundStyle(accent)
                Button("Reset", action: reset).font(.ui(13, .medium)).frame(minWidth: 44, minHeight: 44)
            }
            Slider(value: Binding(get: { Double(crop.zoom) }, set: {
                crop.zoom = CGFloat($0); crop.clamp(to: sourceSize); redraw()
            }), in: 1...8).tint(accent).accessibilityLabel("Photo zoom")
            DisclosureGroup("Fine adjustment", isExpanded: $fineAdjustment) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Horizontal position").font(.ui(12)).foregroundStyle(Ink.dim)
                    Slider(value: Binding(get: { Double(crop.center.x) }, set: {
                        crop.center.x = CGFloat($0); crop.clamp(to: sourceSize); redraw()
                    }), in: 0...1).accessibilityLabel("Horizontal crop position")
                    Text("Vertical position").font(.ui(12)).foregroundStyle(Ink.dim)
                    Slider(value: Binding(get: { Double(crop.center.y) }, set: {
                        crop.center.y = CGFloat($0); crop.clamp(to: sourceSize); redraw()
                    }), in: 0...1).accessibilityLabel("Vertical crop position")
                }.padding(.top, 10)
            }.font(.ui(13)).tint(accent)
        }.foregroundStyle(Ink.ink).disabled(working)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if working { ProgressView(value: progress).tint(accent).accessibilityLabel("Preparing wall pixels") }
            HStack(spacing: 14) {
                Button("Back") { commitTask?.cancel(); onCancel() }
                    .font(.ui(15, .medium)).foregroundStyle(Ink.dim).frame(minWidth: 56, minHeight: 52)
                Button(action: commit) {
                    HStack(spacing: 8) {
                        if working { ProgressView().tint(Ink.ground) }
                        Text(working ? "Preparing pixels…" : commitTitle).font(.ui(15, .semibold))
                        if !working { Image(systemName: "arrow.right").font(.system(size: 14, weight: .semibold)) }
                    }.foregroundStyle(Ink.ground).frame(maxWidth: .infinity).frame(minHeight: 52)
                        .background(accent, in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(PressStyle()).disabled(working || source.isEmpty)
            }
        }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 10).background(Ink.ground)
    }

    private func reset() {
        guard !working else { return }
        crop = MediaCrop(); dragBase = nil; zoomBase = nil; redraw(); Taps.detent()
    }

    private func redraw() {
        guard let image = current else { preview = []; return }
        let normalized = crop.normalizedRect(in: sourceSize)
        let rect = CGRect(x: normalized.minX * CGFloat(image.width), y: normalized.minY * CGFloat(image.height),
                          width: normalized.width * CGFloat(image.width), height: normalized.height * CGFloat(image.height))
        preview = Self.sample(image, rect: rect, side: outputSide) ?? []
    }

    private func commit() {
        guard !source.isEmpty, !working else { return }
        if let onCrop { onCrop(crop); return }
        working = true; playing = false; progress = 0; problem = nil
        let normalized = crop.normalizedRect(in: sourceSize), n = outputSide
        commitTask = Task { @MainActor in
            var result: [[UInt8]] = []
            for image in source {
                guard !Task.isCancelled else { working = false; return }
                let rect = CGRect(x: normalized.minX * CGFloat(image.width), y: normalized.minY * CGFloat(image.height),
                                  width: normalized.width * CGFloat(image.width), height: normalized.height * CGFloat(image.height))
                guard let pixels = Self.sample(image, rect: rect, side: n) else {
                    problem = "The picture could not be framed. Your original is unchanged."
                    working = false; return
                }
                result.append(pixels); progress = Double(result.count) / Double(source.count)
                await Task.yield()
            }
            working = false; onUse(result)
        }
    }

    /// `rect` is top-left source coordinates. Bounds are rejected, never padded or silently shifted.
    static func sample(_ source: CGImage, rect: CGRect, side: Int = Panel.side) -> [UInt8]? {
        guard (16...512).contains(side), rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0,
              rect.minX >= -0.001, rect.minY >= -0.001,
              rect.maxX <= CGFloat(source.width) + 0.001, rect.maxY <= CGFloat(source.height) + 0.001 else { return nil }
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .high
            let sx = CGFloat(side) / rect.width, sy = CGFloat(side) / rect.height
            context.translateBy(x: -rect.minX * sx, y: -(CGFloat(source.height) - rect.maxY) * sy)
            context.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(source.width) * sx, height: CGFloat(source.height) * sy))
            return true
        }
        guard drawn else { return nil }
        var rgb = [UInt8](repeating: 0, count: side * side * 3)
        for i in 0..<(side * side) {
            rgb[i * 3] = rgba[i * 4]; rgb[i * 3 + 1] = rgba[i * 4 + 1]; rgb[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return rgb
    }
}
