// A square, small, quiet copy of a video's picture: what the wall wants,
// and all it can decode. Shared, because both the app and the share sheet
// send videos up, and neither may hand the wall a 4K phone video: the Pi
// decodes in software, and it would not keep up.

import AVFoundation
import Foundation

/// The reader, the writer and their two ends, carried into the pull closure
/// as one value. AVFoundation's transcode types are not Sendable and the
/// closure `requestMediaDataWhenReady(on:)` takes is, so without this the
/// four captures are four warnings, and four errors in Swift 6. They are
/// touched only from the single serial queue passed to that call, which is
/// the guarantee @unchecked is standing in for.
private final class Transcode: @unchecked Sendable {
    let reader: AVAssetReader
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let output: AVAssetReaderVideoCompositionOutput
    init(reader: AVAssetReader, writer: AVAssetWriter,
         input: AVAssetWriterInput, output: AVAssetReaderVideoCompositionOutput) {
        self.reader = reader; self.writer = writer
        self.input = input; self.output = output
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

        let job = Transcode(reader: reader, writer: writer, input: input, output: output)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "wall.picture")
            job.input.requestMediaDataWhenReady(on: queue) {
                while job.input.isReadyForMoreMediaData {
                    if let sample = job.output.copyNextSampleBuffer() {
                        job.input.append(sample)
                        if total > 0 {
                            let at = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                            progress(min(1, max(0, at / total)))
                        }
                    } else {
                        job.input.markAsFinished()
                        if job.reader.status == .failed {
                            job.writer.cancelWriting()
                            cont.resume(throwing: job.reader.error ?? Failure.reader)
                            return
                        }
                        job.writer.finishWriting {
                            if job.writer.status == .completed { cont.resume() }
                            else { cont.resume(throwing: job.writer.error ?? Failure.writer) }
                        }
                        return
                    }
                }
            }
        }
        return dst
    }
}
