// Your pressings.
//
// The song picks its own record, but you can overrule it: any kind, your
// own colours, your own photo in the disc, and pressings you have made and
// named, kept to use again. Choices are kept by song; photos are kept as
// files under the app's own support folder.

import Observation
import UIKit

/// What a person chose for a record, over what the song would have had.
struct PressingChoice: Codable, Equatable {
    var kind: Int? = nil                 // Pressing.Kind raw value; nil = the song's own
    var colours: [[Float]]? = nil        // up to three, r g b; nil = the sleeve's
    var photo: String? = nil             // a file in the photos folder; nil = the sleeve
    var label: Int? = nil                // label style raw value; nil = chosen from the sleeve
    var isEmpty: Bool { kind == nil && colours == nil && photo == nil && label == nil }
}

/// A pressing kept under a name, to put on any song.
struct SavedPressing: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var choice: PressingChoice
    var made: Date = Date()
}

@MainActor
@Observable
final class PressingStore {
    static let shared = PressingStore()

    private(set) var overrides: [String: PressingChoice] = [:]
    private(set) var library: [SavedPressing] = []

    private let folder: URL
    private let file: URL

    init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        folder = base.appendingPathComponent("Pressings", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("pressings.json")
        load()
    }

    func choice(for song: String) -> PressingChoice? { overrides[song] }

    func set(_ choice: PressingChoice?, for song: String) {
        if let choice, !choice.isEmpty { overrides[song] = choice } else { overrides.removeValue(forKey: song) }
        save()
    }

    func keep(_ choice: PressingChoice, named name: String) {
        library.insert(SavedPressing(name: name, choice: choice), at: 0)
        save()
    }

    func forget(_ saved: SavedPressing) {
        library.removeAll { $0.id == saved.id }
        save()
    }

    // MARK: Photos

    /// Keeps a photo for a pressing and returns its file name.
    func keepPhoto(_ image: UIImage) -> String? {
        let name = UUID().uuidString + ".jpg"
        guard let data = image.squared(1024).jpegData(compressionQuality: 0.88) else { return nil }
        do { try data.write(to: folder.appendingPathComponent(name)); return name } catch { return nil }
    }

    private var photoCache: [String: UIImage] = [:]
    func photo(_ name: String?) -> UIImage? {
        guard let name else { return nil }
        if let c = photoCache[name] { return c }
        guard let img = UIImage(contentsOfFile: folder.appendingPathComponent(name).path) else { return nil }
        photoCache[name] = img
        return img
    }

    // MARK: On disk

    private struct Disk: Codable { var overrides: [String: PressingChoice]; var library: [SavedPressing] }

    private func load() {
        guard let data = try? Data(contentsOf: file), let d = try? JSONDecoder().decode(Disk.self, from: data) else { return }
        overrides = d.overrides; library = d.library
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Disk(overrides: overrides, library: library)) { try? data.write(to: file) }
    }
}
