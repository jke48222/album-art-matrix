import Foundation
import Observation

/// A document is a manifest and a contiguous RGB payload. Only the first frame
/// lives in the gallery; animation frames are read when a document is opened.
@MainActor @Observable
final class MadeStore {
    struct Made: Identifiable, Equatable {
        let id: String
        let title: String
        let date: Date
        let side: Int
        let frameCount: Int
        let fps: Double
        let px: [UInt8]
        var animated: Bool { frameCount > 1 }
        var duration: Double { Double(frameCount) / fps }
    }
    struct Manifest: Codable {
        let version: Int
        let title: String
        let date: Date
        let side: Int
        let frameCount: Int
        let fps: Double
    }
    struct Content {
        let frames: [[UInt8]]
        let fps: Double
    }
    enum StoreError: LocalizedError {
        case invalid, missing, unreadable
        var errorDescription: String? {
            switch self {
            case .invalid: "This creation has incomplete or unsupported frame data."
            case .missing: "This creation is no longer on this iPhone."
            case .unreadable: "Some saved creations could not be read. Your files have been kept."
            }
        }
    }
    private(set) var made: [Made] = []
    private(set) var error: String?
    private(set) var removedTitle: String?
    private var removed: (original: URL, trash: URL)?
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("made", isDirectory: true)
    }

    func load() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey], options: [.skipsHiddenFiles])
            var loaded: [Made] = [], unreadable = false
            for file in files {
                do { loaded.append(try readSummary(file)) }
                catch { unreadable = true }
            }
            made = loaded.sorted { $0.date > $1.date }
            error = unreadable ? StoreError.unreadable.localizedDescription : nil
        } catch { self.error = error.localizedDescription }
    }

    private func readSummary(_ url: URL) throws -> Made {
        if url.pathExtension == "tessera" {
            let m = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url.appendingPathComponent("document.json")))
            guard m.version == 1, (16...512).contains(m.side), (1...240).contains(m.frameCount),
                  m.fps.isFinite, (1...24).contains(m.fps) else { throw StoreError.invalid }
            let pixels = url.appendingPathComponent("frames.rgb")
            let size = try pixels.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size == m.side * m.side * 3 * m.frameCount else { throw StoreError.invalid }
            let handle = try FileHandle(forReadingFrom: pixels)
            defer { try? handle.close() }
            guard let data = try handle.read(upToCount: m.side * m.side * 3), data.count == m.side * m.side * 3 else { throw StoreError.invalid }
            return Made(id: url.lastPathComponent, title: m.title, date: m.date, side: m.side,
                        frameCount: m.frameCount, fps: m.fps, px: [UInt8](data))
        }
        // Legacy frames stay intact and become ordinary stills in the library.
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let side = Panel.square(data.count), side <= 512 else { throw StoreError.invalid }
        let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        return Made(id: url.lastPathComponent, title: "Untitled study", date: date, side: side,
                    frameCount: 1, fps: 12, px: [UInt8](data))
    }

    @discardableResult
    func keep(_ frames: [[UInt8]], fps: Double = 12, title: String = "Untitled study") -> Made? {
        do {
            guard let first = frames.first, let side = Panel.square(first.count), side <= 512,
                  (1...240).contains(frames.count), frames.allSatisfy({ $0.count == first.count }),
                  fps.isFinite, (1...24).contains(fps) else { throw StoreError.invalid }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let id = UUID().uuidString + ".tessera"
            let destination = directory.appendingPathComponent(id, isDirectory: true)
            let temporary = directory.appendingPathComponent("." + id, isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let cleanTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            let manifest = Manifest(version: 1, title: cleanTitle.isEmpty ? "Untitled study" : cleanTitle,
                                    date: Date(), side: side, frameCount: frames.count, fps: fps)
            try JSONEncoder().encode(manifest).write(to: temporary.appendingPathComponent("document.json"), options: .atomic)
            let payload = temporary.appendingPathComponent("frames.rgb")
            guard FileManager.default.createFile(atPath: payload.path, contents: nil) else { throw StoreError.invalid }
            let handle = try FileHandle(forWritingTo: payload)
            do { for frame in frames { try handle.write(contentsOf: Data(frame)) }; try handle.close() }
            catch { try? handle.close(); throw error }
            try FileManager.default.moveItem(at: temporary, to: destination)
            let item = try readSummary(destination)
            made.insert(item, at: 0); error = nil
            return item
        } catch { self.error = error.localizedDescription; return nil }
    }

    func content(_ item: Made) -> Content? {
        do {
            guard made.contains(where: { $0.id == item.id }) else { throw StoreError.missing }
            let url = directory.appendingPathComponent(item.id)
            let data = try Data(contentsOf: item.id.hasSuffix(".tessera") ? url.appendingPathComponent("frames.rgb") : url,
                                options: .mappedIfSafe)
            let bytes = item.side * item.side * 3
            guard data.count == bytes * item.frameCount else { throw StoreError.invalid }
            let frames = (0..<item.frameCount).map { [UInt8](data[($0 * bytes)..<(($0 + 1) * bytes)]) }
            error = nil
            return Content(frames: frames, fps: item.fps)
        } catch { self.error = error.localizedDescription; return nil }
    }

    func remove(_ item: Made) {
        do {
            guard made.contains(where: { $0.id == item.id }) else { throw StoreError.missing }
            let original = directory.appendingPathComponent(item.id)
            let trash = directory.appendingPathComponent(".deleted-" + UUID().uuidString)
            try FileManager.default.moveItem(at: original, to: trash)
            if let previous = removed { try? FileManager.default.removeItem(at: previous.trash) }
            removed = (original, trash); removedTitle = item.title
            made.removeAll { $0.id == item.id }; error = nil
        } catch { self.error = error.localizedDescription }
    }

    func undoRemove() {
        guard let removed else { return }
        do {
            try FileManager.default.moveItem(at: removed.trash, to: removed.original)
            self.removed = nil; removedTitle = nil; load()
        } catch { self.error = error.localizedDescription }
    }
}
