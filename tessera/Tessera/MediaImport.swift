import AVFoundation
import CoreTransferable
import Foundation
import UIKit
import UniformTypeIdentifiers

/// A crop expressed in source coordinates, independent of viewport or wall size.
struct MediaCrop: Equatable, Sendable {
    var zoom: CGFloat = 1
    var center = CGPoint(x: 0.5, y: 0.5)

    func rect(in size: CGSize) -> CGRect {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return .zero }
        let z = zoom.isFinite ? min(8, max(1, zoom)) : 1
        let span = min(size.width, size.height) / z
        let x = center.x.isFinite ? center.x : 0.5
        let y = center.y.isFinite ? center.y : 0.5
        let cx = min(size.width - span / 2, max(span / 2, x * size.width))
        let cy = min(size.height - span / 2, max(span / 2, y * size.height))
        return CGRect(x: cx - span / 2, y: cy - span / 2, width: span, height: span)
    }

    func normalizedRect(in size: CGSize) -> CGRect {
        let r = rect(in: size)
        guard !r.isEmpty else { return .zero }
        return CGRect(x: r.minX / size.width, y: r.minY / size.height,
                      width: r.width / size.width, height: r.height / size.height)
    }

    mutating func clamp(to size: CGSize) {
        let r = rect(in: size)
        guard !r.isEmpty else { self = MediaCrop(); return }
        zoom = zoom.isFinite ? min(8, max(1, zoom)) : 1
        center = CGPoint(x: r.midX / size.width, y: r.midY / size.height)
    }

    func moved(by translation: CGSize, viewport: CGFloat, source: CGSize) -> MediaCrop {
        guard viewport.isFinite, viewport > 0 else { return self }
        let r = rect(in: source)
        guard !r.isEmpty else { return self }
        let dx = translation.width.isFinite ? translation.width : 0
        let dy = translation.height.isFinite ? translation.height : 0
        var result = self
        result.center = CGPoint(x: (r.midX - dx * r.width / viewport) / source.width,
                                y: (r.midY - dy * r.height / viewport) / source.height)
        result.clamp(to: source)
        return result
    }
}

enum Clip {
    static let fps: Double = 12
    static let maxFrames = 120

    enum Failure: LocalizedError {
        case unreadable, noFrames, incomplete
        var errorDescription: String? {
            switch self {
            case .unreadable: return "This video could not be read. Choose a different video or download it from iCloud first."
            case .noFrames: return "This video has no playable picture."
            case .incomplete: return "A frame could not be decoded. The clip was not shortened or sent. Try another video."
            }
        }
    }

    /// Every requested frame must decode. Skipping failed frames silently speeds up a clip.
    static func decode(from url: URL, progress: @escaping @MainActor (Double) -> Void = { _ in }) async throws -> [CGImage] {
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        do { duration = try await asset.load(.duration) } catch { throw Failure.unreadable }
        let seconds = min(duration.seconds, Double(maxFrames) / fps)
        guard seconds.isFinite, seconds > 0 else { throw Failure.noFrames }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        generator.maximumSize = CGSize(width: 512, height: 512)
        let count = min(maxFrames, max(1, Int((seconds * fps).rounded(.down))))
        var frames: [CGImage] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            try Task.checkCancellation()
            do {
                let image = try await generator.image(at: CMTime(seconds: Double(index) / fps, preferredTimescale: 600)).image
                frames.append(image)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw Failure.incomplete
            }
            await progress(Double(index + 1) / Double(count))
        }
        return frames
    }

    static func frames(from url: URL) async -> [CGImage] { (try? await decode(from: url)) ?? [] }

    static func upright(_ image: UIImage, max side: CGFloat = 1200) -> CGImage? {
        let w = image.size.width, h = image.size.height
        guard w.isFinite, h.isFinite, side.isFinite, w > 0, h > 0, side >= 1 else { return nil }
        let k = min(1, side / max(w, h))
        let size = CGSize(width: max(1, (w * k).rounded()), height: max(1, (h * k).rounded()))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }

    static func squareFrame(_ src: CGImage, side: Int = Panel.side) -> [UInt8]? {
        Framing.sample(src, rect: MediaCrop().rect(in: CGSize(width: src.width, height: src.height)), side: side)
    }
}

struct FramingJob: Identifiable {
    let id = UUID()
    let source: [CGImage]
}

struct Movie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("tessera-\(UUID().uuidString).mov")
            try FileManager.default.copyItem(at: received.file, to: destination)
            return Movie(url: destination)
        }
    }
}

/// No display lift, emitter glow or interpolation: these are the bytes sent to the wall.
enum MediaRaster {
    static func image(_ pixels: [UInt8]) -> CGImage? {
        guard let side = Panel.square(pixels.count), side <= 512,
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 24,
                       bytesPerRow: side * 3, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
}
