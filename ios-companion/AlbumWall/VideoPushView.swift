// Video — pick a clip, cut it, frame it, ship it. Trim with a filmstrip
// rail, pinch and drag to crop (or letterbox the whole frame), choose the
// frame rate, preview the exact frames, send. Rotation metadata is
// respected, so portrait videos arrive upright.
import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

struct VideoPushView: View {
    @Environment(\.theme) private var t
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var wall: WallAPI
    @EnvironmentObject var creations: CreationStore

    // source
    @State private var pick: PhotosPickerItem? = nil
    @State private var url: URL? = nil
    @State private var duration = 0.0
    @State private var strip: [UIImage] = []      // filmstrip thumbnails
    @State private var midFrame: UIImage? = nil   // working frame for crop
    // edit
    @State private var trimStart = 0.0
    @State private var trimEnd = 0.0
    @State private var fps = 12
    @State private var fit = "fill"               // fill (crop) | fit (bars)
    @State private var zoom: CGFloat = 1
    @State private var zoomAnchor: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var offsetAnchor: CGSize = .zero
    // result
    @State private var frames: [Data] = []
    @State private var previews: [UIImage] = []
    @State private var extractedKey = ""
    @State private var extracting = false
    @State private var progress = 0.0
    @State private var sent = false
    // scrubbing
    @State private var scrubbing: String? = nil       // start | end | window
    @State private var dragAnchor: CGFloat? = nil
    @State private var windowAnchor: (start: Double, x: CGFloat)? = nil

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                header
                panel
                if url != nil {
                    trimRail
                    HStack(spacing: 10) {
                        StripControl(options: [
                            (id: "fill", label: "FILL"), (id: "fit", label: "FIT"),
                        ], selection: Binding(
                            get: { fit },
                            set: { fit = $0; invalidate() }),
                            height: 38, fontSize: 11, kern: 1)
                        .frame(width: 130)
                        StripControl(options: [
                            (id: 6, label: "6"), (id: 12, label: "12"),
                            (id: 24, label: "24"),
                        ], selection: Binding(
                            get: { fps },
                            set: { fps = $0; clampTrim(); invalidate() }),
                            height: 38, fontSize: 11, kern: 1)
                        .frame(width: 130)
                        MicroLabel(text: "FPS")
                        Spacer()
                    }
                    if fit == "fill" {
                        MonoTag("PINCH AND DRAG THE PREVIEW TO FRAME")
                    }
                }
                picker
                if extracting { progressBar }
                Spacer(minLength: 8)
                if url != nil && !upToDate && !extracting {
                    GhostButton(label: "Preview these frames") { extract() }
                }
                PrimaryButton(label: sent ? "On the wall" : "Send to the wall",
                              enabled: url != nil && wall.reachable
                                       && !sent && !extracting) {
                    if upToDate {
                        ship()
                    } else {
                        extract { ship() }
                    }
                }
                if !wall.reachable {
                    HStack { Spacer(); MonoTag("NO LINK"); Spacer() }
                }
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 30)
        }
        .background(t.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    // ---- pieces ---------------------------------------------------------
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(t.ink)
            }
            .buttonStyle(Pressable())
            .padding(.trailing, 8)
            Text("Video")
                .font(.displayWide(28)).foregroundStyle(t.ink)
            Spacer()
            if url != nil {
                MonoTag(rangeLabel)
            }
        }
        .padding(.top, 8)
    }

    private var panel: some View {
        WallPanel(captionLeft: captionLeft, captionRight: captionRight) {
            GeometryReader { geo in
                let side = geo.size.width
                ZStack {
                    Theme.panel
                    if scrubbing == nil && upToDate && !previews.isEmpty {
                        TimelineView(.animation(minimumInterval: 1.0 / Double(fps))) { tl in
                            let i = Int(tl.date.timeIntervalSinceReferenceDate
                                        * Double(fps)) % previews.count
                            PixelImage(image: previews[i], alreadyTiny: true)
                        }
                    } else if let working = scrubPreview ?? midFrame,
                              let still = render64(working, viewport: side) {
                        PixelImage(image: still, alreadyTiny: true)
                    }
                }
                .contentShape(Rectangle())
                .gesture(frameGesture(viewport: side))
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .padding(.horizontal, 14)
    }

    private var trimRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            MicroLabel(text: "TRIM")
            GeometryReader { geo in
                let w = geo.size.width
                let x0 = xFor(trimStart, width: w)
                let x1 = xFor(trimEnd, width: w)
                ZStack(alignment: .topLeading) {
                    filmstrip(width: w)
                    Rectangle().fill(t.ground.opacity(0.7))
                        .frame(width: max(0, x0), height: 48)
                    Rectangle().fill(t.ground.opacity(0.7))
                        .frame(width: max(0, w - x1), height: 48)
                        .offset(x: x1)
                    Rectangle().stroke(t.ink, lineWidth: 2)
                        .frame(width: max(4, x1 - x0), height: 48)
                        .offset(x: x0)
                    // grab the middle to slide the whole window
                    Rectangle().fill(Color.clear)
                        .contentShape(Rectangle())
                        .frame(width: max(4, x1 - x0), height: 48)
                        .offset(x: x0)
                        .gesture(windowDrag(width: w))
                    grip(x: x0, edge: "start", width: w)
                    grip(x: x1, edge: "end", width: w)
                }
                .frame(width: w, height: 48, alignment: .topLeading)
                .coordinateSpace(name: "rail")
            }
            .frame(height: 48)
            HStack {
                MonoTag(clock(trimStart))
                Spacer()
                MonoTag("\(Int(span.rounded()))S, \(Int(span * Double(fps))) FRAMES")
                Spacer()
                MonoTag(clock(trimEnd))
            }
        }
    }

    private func filmstrip(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(strip.enumerated()), id: \.offset) { _, img in
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width / CGFloat(max(1, strip.count)), height: 48)
                    .clipped()
            }
        }
        .frame(width: width, height: 48)
        .clipped()
    }

    /// A grip with a real 44pt touch target, dragged in RAIL coordinates
    /// and anchored where you grabbed it, so nothing jumps.
    private func grip(x: CGFloat, edge: String, width: CGFloat) -> some View {
        let active = scrubbing == edge
        return ZStack {
            Color.clear.frame(width: 44, height: 68)
            RoundedRectangle(cornerRadius: 3)
                .fill(t.ink)
                .frame(width: active ? 16 : 13, height: 58)
                .overlay(RoundedRectangle(cornerRadius: 1)
                    .fill(t.ground).frame(width: 2, height: 20))
        }
        .offset(x: x - 22, y: -5)
        .animation(.easeOut(duration: 0.12), value: active)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("rail"))
                .onChanged { g in
                    if dragAnchor == nil {
                        dragAnchor = g.location.x - x
                        scrubbing = edge
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    let px = g.location.x - (dragAnchor ?? 0)
                    let time = Double(max(0, min(width, px)) / width) * duration
                    setEdge(edge, to: time)
                }
                .onEnded { _ in
                    dragAnchor = nil
                    scrubbing = nil
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    refreshMidFrame()
                }
        )
    }

    private func windowDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("rail"))
            .onChanged { g in
                if windowAnchor == nil {
                    windowAnchor = (trimStart, g.location.x)
                    scrubbing = "window"
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                guard let a = windowAnchor else { return }
                let sp = span
                let dt = Double((g.location.x - a.x) / width) * duration
                let s = max(0, min(duration - sp, a.start + dt))
                trimStart = s
                trimEnd = s + sp
                invalidate()
            }
            .onEnded { _ in
                windowAnchor = nil
                scrubbing = nil
                refreshMidFrame()
            }
    }

    private func xFor(_ time: Double, width: CGFloat) -> CGFloat {
        duration > 0 ? width * CGFloat(time / duration) : 0
    }

    private func setEdge(_ edge: String, to time: Double) {
        if edge == "start" {
            trimStart = min(max(0, time), trimEnd - minSpan)
            trimStart = max(trimStart, trimEnd - maxSpan)
        } else {
            trimEnd = max(min(duration, time), trimStart + minSpan)
            trimEnd = min(trimEnd, trimStart + maxSpan)
        }
        invalidate()
    }

    /// Nearest filmstrip thumbnail, so scrubbing previews instantly
    /// instead of waiting on the frame generator.
    private func stripImage(at time: Double) -> UIImage? {
        guard !strip.isEmpty, duration > 0 else { return nil }
        let i = Int((time / duration) * Double(strip.count))
        return strip[max(0, min(strip.count - 1, i))]
    }

    private var scrubPreview: UIImage? {
        guard let scrubbing else { return nil }
        return stripImage(at: scrubbing == "end" ? trimEnd : trimStart)
    }

    private var picker: some View {
        PhotosPicker(selection: $pick, matching: .videos) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(url == nil ? "Choose a video" : "Choose another")
                        .font(.display(16, .semibold)).foregroundStyle(t.ink)
                    Text("Cut it, frame it, send it")
                        .font(.display(13, .medium)).foregroundStyle(t.ink45)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(t.ink45)
            }
            .padding(.vertical, 14)
            .overlay(alignment: .top) { Rectangle().fill(t.hairline).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(t.hairline).frame(height: 1) }
        }
        .onChange(of: pick) { _, item in
            guard let item else { return }
            loadVideo(item)
        }
    }

    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            MicroLabel(text: "READING FRAMES")
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(t.hairlineSoft)
                    Rectangle().fill(t.ink)
                        .frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 2)
        }
    }

    // ---- state helpers --------------------------------------------------
    private var maxSpan: Double { min(240.0 / Double(fps), 20) }
    private var minSpan: Double { 0.5 }
    private var span: Double { trimEnd - trimStart }

    private var paramsKey: String {
        String(format: "%.2f|%.2f|%d|%@|%.3f|%.1f|%.1f",
               trimStart, trimEnd, fps, fit, zoom,
               offset.width, offset.height)
    }

    private var upToDate: Bool { !frames.isEmpty && extractedKey == paramsKey }

    private var rangeLabel: String {
        String(format: "%@ TO %@, %.0fS",
               clock(trimStart), clock(trimEnd), span)
    }

    private var captionLeft: String {
        extracting ? "READING" : (url == nil ? "PREVIEW" : (upToDate ? "64x64 LIVE" : "FRAME IT"))
    }

    private var captionRight: String {
        url == nil ? "PICK A CLIP"
            : upToDate ? "\(previews.count) FRAMES" : "\(Int(span * Double(fps))) FRAMES"
    }

    private func clock(_ s: Double) -> String {
        "\(Int(s) / 60):" + String(format: "%02d", Int(s) % 60)
    }

    private func clampTrim() {
        trimEnd = min(trimEnd, duration)
        if span > maxSpan { trimEnd = trimStart + maxSpan }
        if span < minSpan { trimEnd = min(duration, trimStart + minSpan) }
    }

    private func invalidate() { sent = false }

    // ---- crop gesture (shared math with the photo editor) ---------------
    private func frameGesture(viewport: CGFloat) -> some Gesture {
        let drag = DragGesture()
            .onChanged { g in
                guard fit == "fill" else { return }
                offset = CGSize(width: offsetAnchor.width + g.translation.width,
                                height: offsetAnchor.height + g.translation.height)
                invalidate()
            }
            .onEnded { _ in
                guard fit == "fill" else { return }
                clampOffset(viewport: viewport)
                offsetAnchor = offset
            }
        let pinch = MagnificationGesture()
            .onChanged { m in
                guard fit == "fill" else { return }
                zoom = min(6, max(1, zoomAnchor * m))
                invalidate()
            }
            .onEnded { _ in
                guard fit == "fill" else { return }
                zoomAnchor = zoom
                clampOffset(viewport: viewport)
                offsetAnchor = offset
            }
        return drag.simultaneously(with: pinch)
    }

    private func clampOffset(viewport: CGFloat) {
        let d = viewport * zoom
        let maxOff = max(0, (d - viewport) / 2)
        withAnimation(.easeOut(duration: 0.15)) {
            offset = CGSize(width: min(maxOff, max(-maxOff, offset.width)),
                            height: min(maxOff, max(-maxOff, offset.height)))
        }
    }

    /// Working image (square-cropped or aspect-fit source) -> final 64px.
    private func render64(_ image: UIImage, viewport: CGFloat) -> UIImage? {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64),
                                       format: fmt).image { ctx in
            UIColor.black.setFill()
            ctx.cgContext.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            if fit == "fit" {
                let s = 64 / max(image.size.width, image.size.height)
                let w = image.size.width * s, h = image.size.height * s
                image.draw(in: CGRect(x: (64 - w) / 2, y: (64 - h) / 2,
                                      width: w, height: h))
            } else {
                let square = image.led256()
                let k = 64 / viewport
                let d = viewport * zoom
                let origin = CGPoint(
                    x: (viewport / 2 + offset.width - d / 2) * k,
                    y: (viewport / 2 + offset.height - d / 2) * k)
                square.draw(in: CGRect(origin: origin,
                                       size: CGSize(width: d * k, height: d * k)))
            }
        }
    }

    // ---- loading --------------------------------------------------------
    private func loadVideo(_ item: PhotosPickerItem) {
        Task {
            guard let movie = try? await item.loadTransferable(type: PickedMovie.self)
            else { return }
            if let old = url { try? FileManager.default.removeItem(at: old) }
            let asset = AVURLAsset(url: movie.url)
            let dur = (try? await asset.load(.duration).seconds) ?? 0
            let thumbs = await Self.filmstrip(asset: asset, count: 16)
            await MainActor.run {
                url = movie.url
                duration = max(1, dur)
                trimStart = 0
                trimEnd = min(duration, maxSpan)
                zoom = 1; zoomAnchor = 1
                offset = .zero; offsetAnchor = .zero
                strip = thumbs
                frames = []; previews = []; extractedKey = ""
                sent = false
            }
            refreshMidFrame()
        }
    }

    private func refreshMidFrame() {
        guard let url else { return }
        Task {
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 512, height: 512)
            gen.requestedTimeToleranceBefore = .init(seconds: 0.2, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = .init(seconds: 0.2, preferredTimescale: 600)
            let mid = CMTime(seconds: (trimStart + trimEnd) / 2,
                             preferredTimescale: 600)
            if let cg = try? await gen.image(at: mid).image {
                await MainActor.run { midFrame = UIImage(cgImage: cg) }
            }
        }
    }

    static func filmstrip(asset: AVAsset, count: Int) async -> [UIImage] {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 120, height: 120)
        let dur = (try? await asset.load(.duration).seconds) ?? 0
        guard dur > 0 else { return [] }
        var out: [UIImage] = []
        for i in 0..<count {
            let t = CMTime(seconds: dur * (Double(i) + 0.5) / Double(count),
                           preferredTimescale: 600)
            if let cg = try? await gen.image(at: t).image {
                out.append(UIImage(cgImage: cg))
            }
        }
        return out
    }

    // ---- extraction -----------------------------------------------------
    private func extract(then: (() -> Void)? = nil) {
        guard let url else { return }
        extracting = true
        progress = 0
        let key = paramsKey
        let cfg = (start: trimStart, span: span, fps: fps,
                   fit: fit, zoom: zoom, offset: offset)
        Task {
            let (fr, im) = await Self.readFrames(
                url: url, cfg: cfg,
                render: { working, viewport in
                    self.render64(working, viewport: viewport)
                }) { p in
                Task { @MainActor in progress = p }
            }
            await MainActor.run {
                frames = fr
                previews = im
                extractedKey = key
                extracting = false
                then?()
            }
        }
    }

    private func ship() {
        let send = wall.sendClip(frames, fps: fps, preview: previews.first)
        creations.addClip(frames, fps: fps)     // lands in Create history
        withAnimation { sent = true }
        Task {
            // Dismiss only on a confirmed 200; a rejected or dropped clip
            // un-flips the button instead of pretending it landed.
            let ok = await send.value
            try? await Task.sleep(nanoseconds: 900_000_000)
            await MainActor.run {
                if ok { dismiss() } else { withAnimation { sent = false } }
            }
        }
    }

    static func readFrames(url: URL,
                           cfg: (start: Double, span: Double, fps: Int,
                                 fit: String, zoom: CGFloat, offset: CGSize),
                           render: @escaping (UIImage, CGFloat) -> UIImage?,
                           onProgress: @escaping (Double) -> Void)
        async -> ([Data], [UIImage]) {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset)
        else { return ([], []) }

        // composition output applies preferredTransform — portrait stays up
        guard let comp = try? await AVMutableVideoComposition
            .videoComposition(withPropertiesOf: asset)
        else { return ([], []) }
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [track],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_32BGRA])
        output.videoComposition = comp
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: cfg.start, preferredTimescale: 600),
            duration: CMTime(seconds: cfg.span, preferredTimescale: 600))
        reader.startReading()

        var frames: [Data] = []
        var images: [UIImage] = []
        var nextT = cfg.start
        let step = 1.0 / Double(cfg.fps)
        let ciCtx = CIContext(options: [.useSoftwareRenderer: false])

        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts >= nextT,
                  let buf = CMSampleBufferGetImageBuffer(sample) else { continue }
            nextT += step
            let ci = CIImage(cvPixelBuffer: buf)
            let maxSide = max(ci.extent.width, ci.extent.height)
            let scale = 256 / maxSide
            let scaled = ci.transformed(by: CGAffineTransform(
                scaleX: scale, y: scale))
            guard let cg = ciCtx.createCGImage(scaled, from: scaled.extent)
            else { continue }
            let working = UIImage(cgImage: cg)
            guard let final = render(working, 320),
                  let rgb = final.rgbBytes64() else { continue }
            frames.append(rgb)
            images.append(UIImage.fromRGB64(rgb) ?? final)
            onProgress(min(1, (pts - cfg.start) / max(0.1, cfg.span)))
            // hard cap at the brain's /clip limit; the old "+ 1" could
            // collect a 241st frame and earn a 400 at full trim
            if frames.count >= min(240, max(1, Int((cfg.span * Double(cfg.fps)).rounded()))) { break }
        }
        reader.cancelReading()
        return (frames, images)
    }
}

extension UIImage {
    /// Center-square at 256 — the crop editor's working size.
    func led256() -> UIImage {
        let side = min(size.width, size.height)
        let crop = CGRect(x: (size.width - side) / 2,
                          y: (size.height - side) / 2,
                          width: side, height: side)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256),
                                       format: fmt).image { _ in
            let source = cgImage.flatMap { $0.cropping(to: crop) }
                .map { UIImage(cgImage: $0) } ?? self
            source.draw(in: CGRect(x: 0, y: 0, width: 256, height: 256))
        }
    }
}

/// Copies the picked video to a temp file so AVFoundation can read it.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent("wall-\(UUID().uuidString).mov")
            try FileManager.default.copyItem(at: received.file, to: dst)
            return PickedMovie(url: dst)
        }
    }
}
