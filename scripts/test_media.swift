import UIKit
import AVFoundation

@main
struct MediaTests {
    static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var checks: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label)
            checks.append(label)
        }
        let sourceSize = CGSize(width: 400, height: 200)
        let center = MediaCrop().rect(in: sourceSize)
        check(center == CGRect(x: 100, y: 0, width: 200, height: 200), "Landscape square is centered")
        check(MediaCrop().rect(in: CGSize(width: 200, height: 400)) == CGRect(x: 0, y: 100, width: 200, height: 200), "Portrait square is centered")
        for zoom in [CGFloat.nan, -CGFloat.infinity, -3, 1, 4, 8, 500] {
            var crop = MediaCrop(zoom: zoom, center: CGPoint(x: -20, y: 40))
            crop.clamp(to: sourceSize)
            let rect = crop.rect(in: sourceSize)
            check(rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= 400 && rect.maxY <= 200, "Finite crop bounds at zoom \(zoom)")
            check(crop.zoom >= 1 && crop.zoom <= 8, "Zoom is bounded at \(zoom)")
        }
        let moved = MediaCrop(zoom: 2).moved(by: CGSize(width: 100_000, height: -100_000), viewport: 300, source: sourceSize)
        check(moved.rect(in: sourceSize) == CGRect(x: 0, y: 100, width: 100, height: 100), "Large gesture stops at source edges")
        let viewA = MediaCrop().moved(by: CGSize(width: 30, height: 0), viewport: 300, source: sourceSize)
        let viewB = MediaCrop().moved(by: CGSize(width: 60, height: 0), viewport: 600, source: sourceSize)
        check(viewA == viewB, "Viewport changes preserve proportional crop")
        check(MediaCrop().rect(in: .zero).isEmpty, "Zero source is safe")
        let invalid = MediaCrop(zoom: .nan, center: CGPoint(x: CGFloat.nan, y: CGFloat.infinity))
        check(invalid.rect(in: sourceSize) == center, "Nonfinite crop uses center")
        // A top-left-origin RGB image: red above, blue below, a narrow white center.
        var source = [UInt8](repeating: 0, count: 256 * 256 * 3)
        for y in 0..<256 { for x in 0..<256 {
            let offset = (y * 256 + x) * 3
            if (112..<144).contains(x) { source[offset] = 255; source[offset+1] = 255; source[offset+2] = 255 }
            else { source[offset + (y < 128 ? 0 : 2)] = 255 }
        }}
        let image = MediaRaster.image(source)!
        try UIImage(cgImage: image).pngData()!.write(to: output.appendingPathComponent("source.png"))
        for side in [64, 192, 512] {
            let whole = Framing.sample(image, rect: CGRect(x: 0, y: 0, width: 256, height: 256), side: side)!
            check(whole.count == side * side * 3, "RGB888 length \(side)")
            check(whole[0] > 250 && whole[2] == 0, "Top remains red at \(side)")
            let bottom = ((side - 1) * side) * 3
            check(whole[bottom] == 0 && whole[bottom + 2] > 250, "Bottom remains blue at \(side)")
            let topCrop = Framing.sample(image, rect: CGRect(x: 0, y: 0, width: 64, height: 64), side: side)!
            check(stride(from: 0, to: topCrop.count, by: 3).allSatisfy { topCrop[$0] == 255 && topCrop[$0 + 2] == 0 }, "Top-left crop is precise at \(side)")
            let bottomCrop = Framing.sample(image, rect: CGRect(x: 160, y: 160, width: 64, height: 64), side: side)!
            check(stride(from: 0, to: bottomCrop.count, by: 3).allSatisfy { bottomCrop[$0] == 0 && bottomCrop[$0 + 2] == 255 }, "Bottom-right crop is precise at \(side)")
            try UIImage(cgImage: MediaRaster.image(whole)!).pngData()!.write(to: output.appendingPathComponent("wall-\(side).png"))
        }
        check(Framing.sample(image, rect: .zero) == nil, "Zero crop rejected")
        check(Framing.sample(image, rect: CGRect(x: -1, y: 0, width: 10, height: 10)) == nil, "Outside crop rejected")
        check(Framing.sample(image, rect: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10)) == nil, "Infinite crop rejected")
        check(Framing.sample(image, rect: CGRect(x: 0, y: 0, width: 10, height: 10), side: 100_000) == nil, "Unbounded allocation rejected")
        check(MediaRaster.image([1, 2, 3]) == nil, "Malformed frame rejected")
        check(WallVideo.clock(.nan) == "0:00", "NaN clock cannot trap")
        check(WallVideo.clock(.infinity) == "0:00", "Infinite clock cannot trap")
        check(WallVideo.clock(-3) == "0:00", "Negative clock clamped")
        check(WallVideo.clock(59.9) == "0:59", "Elapsed time floors instead of jumps early")
        check(WallVideo.clock(3_661) == "1:01:01", "Long video clock")
        let landscape = MediaQA.source()
        try UIImage(cgImage: landscape).pngData()!.write(to: output.appendingPathComponent("framing-source-1200.png"))
        for n in [64, 192] {
            let window = MediaCrop().rect(in: CGSize(width: landscape.width, height: landscape.height))
            let pixels = Framing.sample(landscape, rect: window, side: n)!
            try UIImage(cgImage: MediaRaster.image(pixels)!).pngData()!.write(to: output.appendingPathComponent("framing-wall-\(n).png"))
        }
        let movie = try await fixtureMovie(in: output)
        defer { try? FileManager.default.removeItem(at: movie) }
        let framedMovie = try await VideoPicture.make(from: movie, side: 64, crop: CGRect(x: 0, y: 0, width: 0.5, height: 1)) { _ in }
        defer { try? FileManager.default.removeItem(at: framedMovie) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: framedMovie))
        let first = try await generator.image(at: .zero).image
        check(first.width == 64 && first.height == 64, "Video converter delivers requested square")
        let videoBytes = Framing.sample(first, rect: CGRect(x: 0, y: 0, width: 64, height: 64), side: 64)!
        check(videoBytes[0] > 220 && videoBytes[2] < 30, "Full video uses chosen left crop instead of center")
        let temp = FileManager.default.temporaryDirectory
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: temp.path).filter { $0.hasPrefix("wall-picture-") })
        let cancellation = CancelVideo()
        let task = Task {
            try await VideoPicture.make(from: movie, side: 192) { value in
                if value > 0 { cancellation.cancel() }
            }
        }
        cancellation.install(task)
        var cancelled = false
        do { let result = try await task.value; try? FileManager.default.removeItem(at: result) }
        catch is CancellationError { cancelled = true }
        check(cancelled, "Conversion cancellation throws promptly after decoding starts")
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: temp.path).filter { $0.hasPrefix("wall-picture-") })
        check(after == before, "Cancelled conversion removes partial output")
        let result: [String: Any] = ["count": checks.count, "passed": checks, "status": "passed", "source": "Exact production MediaCrop, Framing.sample, MediaRaster, WallVideo declarations compiled for iOS simulator"]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("checks.json"))
        print("\(checks.count) media checks passed")
    }

    static func fixtureMovie(in output: URL) async throws -> URL {
        let url = output.appendingPathComponent("source-video.mp4")
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                        AVVideoWidthKey: 320, AVVideoHeightKey: 160])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 160])
        writer.add(input); precondition(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for frame in 0..<300 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var optional: CVPixelBuffer?
            precondition(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, adaptor.pixelBufferPool!, &optional) == kCVReturnSuccess)
            let buffer = optional!
            CVPixelBufferLockBaseAddress(buffer, [])
            let row = CVPixelBufferGetBytesPerRow(buffer)
            let pixels = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<160 { for x in 0..<320 {
                let offset = y * row + x * 4
                pixels[offset] = x < 160 ? 0 : 255
                pixels[offset + 1] = 0
                pixels[offset + 2] = x < 160 ? 255 : 0
                pixels[offset + 3] = 255
            }}
            CVPixelBufferUnlockBaseAddress(buffer, [])
            precondition(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished(); await writer.finishWriting()
        precondition(writer.status == .completed)
        return url
    }
}

private final class CancelVideo: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<URL, Error>?
    private var cancelled = false
    func install(_ value: Task<URL, Error>) {
        lock.lock(); task = value; let pending = cancelled; lock.unlock()
        if pending { value.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let current = task; lock.unlock(); current?.cancel()
    }
}
