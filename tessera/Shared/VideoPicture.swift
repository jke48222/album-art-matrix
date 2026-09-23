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
    private let queue = DispatchQueue(label: "wall.picture")
    private let lock = NSLock()
    private var cancelled = false
    private var completed = false
    private var continuation: CheckedContinuation<Void, Error>?

    init(reader: AVAssetReader, writer: AVAssetWriter,
         input: AVAssetWriterInput, output: AVAssetReaderVideoCompositionOutput) {
        self.reader = reader; self.writer = writer; self.input = input; self.output = output
    }
    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return cancelled
    }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        queue.async { self.cancelOnQueue() }
    }
    private func cancelOnQueue() {
        guard continuation != nil, !completed else { return }
        reader.cancelReading(); writer.cancelWriting()
        finish(.failure(CancellationError()))
    }
    private func finish(_ result: Result<Void, Error>) {
        guard !completed else { return }
        completed = true
        continuation?.resume(with: result); continuation = nil
    }
    func start(total: Double, progress: @escaping @Sendable (Double) -> Void,
               continuation: CheckedContinuation<Void, Error>) {
        queue.async {
            self.continuation = continuation
            if self.isCancelled { self.cancelOnQueue(); return }
            self.input.requestMediaDataWhenReady(on: self.queue) {
                guard !self.completed else { return }
                while self.input.isReadyForMoreMediaData {
                    if self.isCancelled { self.cancelOnQueue(); return }
                    if let sample = self.output.copyNextSampleBuffer() {
                        guard self.input.append(sample) else {
                            let error = self.writer.error ?? VideoPicture.Failure.writer
                            self.reader.cancelReading(); self.writer.cancelWriting()
                            self.finish(.failure(error)); return
                        }
                        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        if total > 0, time.isFinite { progress(min(1, max(0, time / total))) }
                    } else {
                        self.input.markAsFinished()
                        if self.reader.status == .failed {
                            self.writer.cancelWriting()
                            self.finish(.failure(self.reader.error ?? VideoPicture.Failure.reader)); return
                        }
                        self.writer.finishWriting {
                            self.queue.async {
                                if self.isCancelled { self.cancelOnQueue() }
                                else if self.writer.status == .completed { self.finish(.success(())) }
                                else { self.finish(.failure(self.writer.error ?? VideoPicture.Failure.writer)) }
                            }
                        }
                        return
                    }
                }
            }
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

    static func make(from src: URL, side: Int = 160, fps: Int32 = 15, crop: CGRect? = nil,
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
        guard w.isFinite, h.isFinite, w > 0, h > 0, (16...512).contains(side), fps > 0,
              duration.seconds.isFinite, duration.seconds > 0 else { throw Failure.noPicture }
        let window: CGRect
        if let crop {
            guard crop.minX.isFinite, crop.minY.isFinite, crop.width.isFinite, crop.height.isFinite,
                  crop.width > 0, crop.height > 0, crop.minX >= 0, crop.minY >= 0,
                  crop.maxX <= 1.000001, crop.maxY <= 1.000001 else { throw Failure.noPicture }
            window = CGRect(x: crop.minX * w, y: crop.minY * h, width: crop.width * w, height: crop.height * h)
        } else {
            let span = min(w, h)
            window = CGRect(x: (w - span) / 2, y: (h - span) / 2, width: span, height: span)
        }
        let scale = CGFloat(side) / window.width
        var t = transform
        t = t.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        t = t.concatenating(CGAffineTransform(translationX: -window.minX * scale, y: -window.minY * scale))

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
        guard reader.canAdd(output) else { throw Failure.reader }
        reader.add(output)

        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("wall-picture-\(UUID().uuidString).mp4")
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: dst) } }
        try Task.checkCancellation()
        let writer = try AVAssetWriter(outputURL: dst, fileType: .mp4)
        defer { if !succeeded { reader.cancelReading(); writer.cancelWriting() } }
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
        guard writer.canAdd(input) else { throw Failure.writer }
        writer.add(input)
        guard reader.startReading() else { throw reader.error ?? Failure.reader }
        guard writer.startWriting() else { throw writer.error ?? Failure.writer }
        writer.startSession(atSourceTime: .zero)
        let total = CMTimeGetSeconds(duration)

        let job = Transcode(reader: reader, writer: writer, input: input, output: output)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                job.start(total: total, progress: progress, continuation: continuation)
            }
        } onCancel: {
            job.cancel()
        }
        try Task.checkCancellation()
        succeeded = true
        return dst
    }
}
