// Everything you've ever sent to the wall, kept on the phone: raw 64x64
// RGB frames per creation, newest first. A doodle or photo is one frame,
// a video is many at a set rate, so both replay from the same shelf.
import Foundation
import UIKit

struct Creation: Identifiable, Codable {
    let ts: Int
    let file: String          // <ts>.rgb, frames concatenated
    var frameCount: Int
    var fps: Int

    var id: Int { ts }
    var isClip: Bool { frameCount > 1 }

    init(ts: Int, file: String, frameCount: Int = 1, fps: Int = 12) {
        self.ts = ts
        self.file = file
        self.frameCount = frameCount
        self.fps = fps
    }

    /// Tolerant decode so creations saved before clips existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ts = try c.decode(Int.self, forKey: .ts)
        file = try c.decode(String.self, forKey: .file)
        frameCount = (try? c.decode(Int.self, forKey: .frameCount)) ?? 1
        fps = (try? c.decode(Int.self, forKey: .fps)) ?? 12
    }
}

final class CreationStore: ObservableObject {
    static let frameBytes = 64 * 64 * 3

    @Published private(set) var creations: [Creation] = []

    private let dir: URL = {
        let d = FileManager.default.urls(for: .documentDirectory,
                                         in: .userDomainMask)[0]
            .appendingPathComponent("creations", isDirectory: true)
        try? FileManager.default.createDirectory(at: d,
                                                 withIntermediateDirectories: true)
        return d
    }()

    private var indexURL: URL { dir.appendingPathComponent("index.json") }

    init() {
        if let data = try? Data(contentsOf: indexURL),
           let list = try? JSONDecoder().decode([Creation].self, from: data) {
            creations = list
        }
    }

    func add(_ px: Data) {
        store(frames: [px], fps: 12)
    }

    func addClip(_ frames: [Data], fps: Int) {
        store(frames: frames, fps: fps)
    }

    private func store(frames: [Data], fps: Int) {
        guard !frames.isEmpty,
              frames.allSatisfy({ $0.count == Self.frameBytes }) else { return }
        let ts = Int(Date().timeIntervalSince1970)
        let c = Creation(ts: ts, file: "\(ts).rgb",
                         frameCount: frames.count, fps: fps)
        var blob = Data()
        frames.forEach { blob.append($0) }
        try? blob.write(to: dir.appendingPathComponent(c.file))
        creations.insert(c, at: 0)
        while creations.count > 40 {
            let gone = creations.removeLast()
            try? FileManager.default.removeItem(
                at: dir.appendingPathComponent(gone.file))
        }
        save()
    }

    /// First frame only: the thumbnail and the single-frame send path.
    func pixels(_ c: Creation) -> Data? {
        guard let blob = try? Data(contentsOf: dir.appendingPathComponent(c.file)),
              blob.count >= Self.frameBytes else { return nil }
        return blob.prefix(Self.frameBytes)
    }

    /// Every frame, for re-sending a clip.
    func frames(_ c: Creation) -> [Data] {
        guard let blob = try? Data(contentsOf: dir.appendingPathComponent(c.file))
        else { return [] }
        return stride(from: 0, to: blob.count, by: Self.frameBytes).compactMap {
            let end = $0 + Self.frameBytes
            guard end <= blob.count else { return nil }
            return blob.subdata(in: $0..<end)
        }
    }

    func image(_ c: Creation) -> UIImage? {
        pixels(c).flatMap(UIImage.fromRGB64)
    }

    func remove(_ c: Creation) {
        creations.removeAll { $0.ts == c.ts }
        try? FileManager.default.removeItem(
            at: dir.appendingPathComponent(c.file))
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(creations) {
            try? data.write(to: indexURL)
        }
    }
}
