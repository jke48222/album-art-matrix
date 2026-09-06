// What the share sheet leaves for the app, and what the app does with it.
//
// A link needs nothing more from the app than to be open: the wall is
// already fetching, and the app plays the sound when the wall says ready.
// A video from the library is the app's job: make a small square picture
// of it, send that up, and play the sound from the original here.

import AVFoundation
import Foundation

enum VideoHandoff {
    struct Pending: Equatable {
        var kind: String          // "link" or "file"
        var url: String?
        var path: String?
        var title: String?
        var sound: Bool
    }

    private static var defaults: UserDefaults? { UserDefaults(suiteName: WallSnapshot.group) }
    private static let key = "video.pending"

    /// The original video of the one on the wall now, for its sound.
    static var localSound: (key: String, url: URL)?

    static func read() -> Pending? {
        guard let data = defaults?.data(forKey: key),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = j["kind"] as? String else { return nil }
        return Pending(kind: kind, url: j["url"] as? String, path: j["path"] as? String,
                       title: j["title"] as? String, sound: j["sound"] as? Bool ?? true)
    }

    static func clear() {
        defaults?.removeObject(forKey: key)
    }

    /// A video the share sheet kept: the small picture, sent up, the
    /// original kept here for its sound. Progress is 0 to 1 for the
    /// picture-making, then the upload; the words say which.
    static func send(file: URL, title: String?, host: String,
                     progress: @escaping @Sendable (String, Double) -> Void) async throws -> String {
        progress("Making the picture", 0)
        let small = try await VideoPicture.make(from: file) { p in progress("Making the picture", p) }
        defer { try? FileManager.default.removeItem(at: small) }
        progress("Sending it to the wall", 0)
        var c = URLComponents(string: "http://\(host)/video/upload")!
        c.queryItems = [.init(name: "title", value: title ?? "From your library"),
                        .init(name: "clock", value: "phone")]
        guard let url = c.url else { throw Failure.wall("bad wall address") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: small)
        guard let http = resp as? HTTPURLResponse else { throw Failure.wall("no answer") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard http.statusCode == 200 else {
            throw Failure.wall(json?["error"] as? String ?? "the wall said \(http.statusCode)")
        }
        progress("On the wall", 1)
        // the wall names the video by the path it kept; the sound follows that name
        let wallKey = ((json?["video"] as? [String: Any])?["url"] as? String) ?? ""
        localSound = (wallKey, file)
        return wallKey
    }

    enum Failure: LocalizedError {
        case wall(String)
        var errorDescription: String? {
            switch self { case .wall(let s): return "The wall did not take it: \(s)." }
        }
    }
}

/// A square, small, quiet copy of a video's picture: what the wall wants.
enum VideoPicture {
    enum Failure: LocalizedError {
        case noPicture, reader, writer
        var errorDescription: String? {
            switch self {
            case .noPicture: return "There is no picture in that video."
            case .reader: return "Could not read the video."
            case .writer: return "Could not write the small picture."
            }
        }
    }

    static func make(from src: URL, side: Int = 160, fps: Int32 = 15,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: src)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure.noPicture
        }
        let duration = try await asset.load(.duration)
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)

        // upright, then the short side to `side`, then the middle square
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        let w = abs(rect.width), h = abs(rect.height)
        guard w > 0, h > 0 else { throw Failure.noPicture }
        let scale = CGFloat(side) / min(w, h)
        var t = transform
        t = t.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        t = t.concatenating(CGAffineTransform(translationX: -(w * scale - CGFloat(side)) / 2,
                                              y: -(h * scale - CGFloat(side)) / 2))

        let comp = AVMutableVideoComposition()
        comp.renderSize = CGSize(width: side, height: side)
        comp.frameDuration = CMTime(value: 1, timescale: fps)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(t, at: .zero)
        instruction.layerInstructions = [layer]
        comp.instructions = [instruction]

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [track],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = comp
        output.alwaysCopiesSampleData = false
        reader.add(output)

        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("wall-picture-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: dst, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: side,
            AVVideoHeightKey: side,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 300_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard reader.startReading() else { throw reader.error ?? Failure.reader }
        guard writer.startWriting() else { throw writer.error ?? Failure.writer }
        writer.startSession(atSourceTime: .zero)
        let total = CMTimeGetSeconds(duration)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "wall.picture")
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if let sample = output.copyNextSampleBuffer() {
                        input.append(sample)
                        if total > 0 {
                            let at = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                            progress(min(1, max(0, at / total)))
                        }
                    } else {
                        input.markAsFinished()
                        if reader.status == .failed {
                            writer.cancelWriting()
                            cont.resume(throwing: reader.error ?? Failure.reader)
                            return
                        }
                        writer.finishWriting {
                            if writer.status == .completed { cont.resume() }
                            else { cont.resume(throwing: writer.error ?? Failure.writer) }
                        }
                        return
                    }
                }
            }
        }
        return dst
    }
}
