// Push a photo — any picture from the library, framed by hand: pinch to
// zoom, drag to place. The preview IS the honest 64x64 downscale, live,
// so what you frame is exactly what the wall gets.
import PhotosUI
import SwiftUI
import UIKit

struct PhotoPushView: View {
    @Environment(\.theme) private var t
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var wall: WallAPI
    @EnvironmentObject var creations: CreationStore

    @State private var pick: PhotosPickerItem? = nil
    @State private var image: UIImage? = nil
    @State private var zoom: CGFloat = 1
    @State private var zoomAnchor: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var offsetAnchor: CGSize = .zero
    @State private var sent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(t.ink)
                }
                .padding(.trailing, 8)
                Text("A photo")
                    .font(.displayWide(28)).foregroundStyle(t.ink)
                Spacer()
                if image != nil {
                    Button { resetFraming() } label: {
                        Text("RESET").font(.mono(12, .medium)).kerning(1)
                            .foregroundStyle(t.ink70)
                    }
                }
            }
            .padding(.top, 8)

            WallPanel(captionLeft: image == nil ? "PREVIEW" : "PINCH · DRAG TO FRAME",
                      captionRight: image == nil ? "PICK SOMETHING" : "64×64 LIVE") {
                GeometryReader { geo in
                    let side = geo.size.width
                    ZStack {
                        Theme.panel
                        if let cropped = cropped64(viewport: side) {
                            Image(uiImage: cropped)
                                .resizable()
                                .interpolation(.none)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(frameGesture(viewport: side))
                }
                .aspectRatio(1, contentMode: .fit)
            }
            .padding(.horizontal, 20)

            PhotosPicker(selection: $pick, matching: .images) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(image == nil ? "Choose a photo" : "Choose another")
                            .font(.display(16, .semibold)).foregroundStyle(t.ink)
                        Text("Pinch and drag to crop")
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
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let ui = UIImage(data: data) {
                        await MainActor.run {
                            image = ui.normalizedUp()
                            resetFraming()
                            sent = false
                        }
                    }
                }
            }

            Spacer()

            PrimaryButton(label: sent ? "On the wall" : "Send to the wall",
                          enabled: image != nil && wall.reachable && !sent) {
                if let cropped = cropped64(viewport: 320),
                   let data = cropped.rgbBytes64() {
                    wall.sendFrame(data, preview: cropped)
                    creations.add(data)
                    withAnimation { sent = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        dismiss()
                    }
                }
            }
            if !wall.reachable {
                HStack { Spacer(); MonoTag("NO LINK"); Spacer() }
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 30)
        .background(t.ground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    // ---- framing math ---------------------------------------------------
    private func resetFraming() {
        zoom = 1; zoomAnchor = 1
        offset = .zero; offsetAnchor = .zero
        sent = false
    }

    private func frameGesture(viewport: CGFloat) -> some Gesture {
        let drag = DragGesture()
            .onChanged { g in
                offset = CGSize(width: offsetAnchor.width + g.translation.width,
                                height: offsetAnchor.height + g.translation.height)
                sent = false
            }
            .onEnded { _ in
                clamp(viewport: viewport)
                offsetAnchor = offset
            }
        let pinch = MagnificationGesture()
            .onChanged { m in
                zoom = min(6, max(1, zoomAnchor * m))
                sent = false
            }
            .onEnded { _ in
                zoomAnchor = zoom
                clamp(viewport: viewport)
                offsetAnchor = offset
            }
        return drag.simultaneously(with: pinch)
    }

    /// Keep the image covering the whole square.
    private func clamp(viewport: CGFloat) {
        guard let image else { return }
        let d = displayedSize(image: image, viewport: viewport)
        let maxX = max(0, (d.width - viewport) / 2)
        let maxY = max(0, (d.height - viewport) / 2)
        withAnimation(.easeOut(duration: 0.15)) {
            offset = CGSize(width: min(maxX, max(-maxX, offset.width)),
                            height: min(maxY, max(-maxY, offset.height)))
        }
    }

    private func displayedSize(image: UIImage, viewport: CGFloat) -> CGSize {
        let fill = viewport / min(image.size.width, image.size.height)
        return CGSize(width: image.size.width * fill * zoom,
                      height: image.size.height * fill * zoom)
    }

    /// The framed 64x64 — same math as display, rendered small.
    private func cropped64(viewport: CGFloat) -> UIImage? {
        guard let image, viewport > 0 else { return nil }
        let d = displayedSize(image: image, viewport: viewport)
        let k = 64 / viewport
        let origin = CGPoint(
            x: (viewport / 2 + offset.width - d.width / 2) * k,
            y: (viewport / 2 + offset.height - d.height / 2) * k)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64),
                                       format: fmt).image { ctx in
            UIColor.black.setFill()
            ctx.cgContext.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            image.draw(in: CGRect(origin: origin,
                                  size: CGSize(width: d.width * k,
                                               height: d.height * k)))
        }
    }
}

extension UIImage {
    /// Bakes in orientation so CG drawing math is sane.
    func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
