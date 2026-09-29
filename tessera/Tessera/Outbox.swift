// What you asked for while the wall was not listening.
//
// The app was optimistic and silent: a control changed locally, the POST
// failed, a haptic buzzed, and the next poll quietly undid it. That is the
// one thing this project has said it will not do. So intent is now durable.
//
// Two kinds of thing are kept, and they are kept differently on purpose:
//
//   settings   coalesced. Dragging brightness across ten steps while the wall
//              is away is one instruction, not ten, and the last value wins.
//
//   a frame    latest only. A wall shows one thing; queuing four drawings so
//              they all flash past on reconnect would be obedience, not sense.
//
// The queue is visible on the Connection page (ConnectionPage), which lists
// what is waiting, sends it now or discards it, and says how the last
// delivery went. Nothing here is invisible magic.

import Foundation

@MainActor
@Observable
final class Outbox {
    /// Settings waiting to be sent, already merged.
    private(set) var patch: [String: Any] = [:]
    /// The most recent frame waiting to be sent.
    private(set) var frame: [UInt8]? = nil
    /// The most recent clip. Session-only: a clip can run to ~3 MB, which is
    /// not something to park in the app-group plist. It survives being
    /// offline, not a relaunch, and the Connection page says so.
    private(set) var clip: (frames: [[UInt8]], fps: Double)? = nil
    /// When each kind was queued, so a flush can replay them in the order
    /// they were meant: the brain force-sets mode on a frame push, and
    /// whichever intent came LAST must win.
    private(set) var patchAt: Date? = nil
    private(set) var frameAt: Date? = nil
    private(set) var clipAt: Date? = nil
    var queuedAt: Date? { [patchAt, frameAt, clipAt].compactMap { $0 }.max() }

    var isEmpty: Bool { patch.isEmpty && frame == nil && clip == nil }

    /// What is waiting, without the payloads: enough to name it (see
    /// OutboxWords) and to say when it was queued.
    struct Contents: Equatable {
        /// Setting keys, sorted, so equal contents compare equal.
        var keys: [String] = []
        var frame = false
        var clip = false
        var queuedAt: Date? = nil

        var isEmpty: Bool { keys.isEmpty && !frame && !clip }
        /// "Display mode and brightness", "A picture".
        var words: String { OutboxWords.describe(keys: keys, frame: frame, clip: clip) }
        /// The same, lower case, for the middle of a sentence.
        var phrase: String { OutboxWords.describe(keys: keys, frame: frame, clip: clip, sentenceCase: false) }
        /// "2 changes waiting".
        var count: String { OutboxWords.count(keys: keys, frame: frame, clip: clip) }
    }

    var contents: Contents {
        Contents(keys: patch.keys.sorted(), frame: frame != nil, clip: clip != nil, queuedAt: queuedAt)
    }

    /// How a delivery went. `again` went back into the queue because the
    /// wall stopped answering. `refused` was heard and turned down, and is
    /// dropped, since sending it again would only be turned down again.
    struct Delivery: Equatable {
        var at: Date
        var sent: Contents
        var again: Contents
        var refused: Contents
        var complete: Bool { again.isEmpty && refused.isEmpty }
    }

    /// The last delivery, for this session only: it describes a moment, and
    /// the connection history keeps the lasting record.
    private(set) var lastDelivery: Delivery? = nil

    func record(_ delivery: Delivery) { lastDelivery = delivery }

    // MARK: Persistence

    private static let key = "tessera.outbox"
    private var store: UserDefaults? { UserDefaults(suiteName: WallSnapshot.group) }

    init() { load() }

    private var saveQueued = false

    func add(patch p: [String: Any]) {
        for (k, v) in p { patch[k] = v }
        patchAt = Date()
        // a live rpm drag lands forty patches in four seconds; one disk
        // write a second remembers them just as well
        guard !saveQueued else { return }
        saveQueued = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.saveQueued = false
            self?.save()
        }
    }

    func add(frame f: [UInt8]) {
        guard Panel.square(f.count) != nil else { return }
        frame = f
        frameAt = Date()
        save()
    }

    func add(clip frames: [[UInt8]], fps: Double) {
        guard !frames.isEmpty else { return }
        clip = (frames, fps)
        clipAt = Date()
    }

    func clear() {
        patch = [:]
        frame = nil
        clip = nil
        patchAt = nil
        frameAt = nil
        clipAt = nil
        save()
    }

    // Putting back what a delivery could not send. Something queued while
    // the delivery ran is newer than what it took, and newer intent wins: a
    // restored key never overwrites one queued since, and a restored frame
    // or clip is kept only when nothing newer took its place.

    func restore(patch p: [String: Any], at: Date) {
        guard !p.isEmpty else { return }
        for (k, v) in p where patch[k] == nil { patch[k] = v }
        // Merged into a newer patch, the stamp stays the newer one, so the
        // replay order still puts the latest intent last.
        if patchAt == nil { patchAt = at }
        save()
    }

    func restore(frame f: [UInt8], at: Date) {
        guard Panel.square(f.count) != nil, frame == nil || (frameAt ?? .distantPast) < at else { return }
        frame = f
        frameAt = at
        save()
    }

    func restore(clip frames: [[UInt8]], fps: Double, at: Date) {
        guard !frames.isEmpty, clip == nil || (clipAt ?? .distantPast) < at else { return }
        clip = (frames, fps)
        clipAt = at
    }

    #if DEBUG
    /// Captures of the delivered, partial and refused states.
    func debugSetDelivery(_ delivery: Delivery?) { lastDelivery = delivery }
    #endif

    private func save() {
        guard let store else { return }
        var blob: [String: Any] = [:]
        if !patch.isEmpty { blob["patch"] = patch }
        if let frame { blob["frame"] = Data(frame) }
        if let patchAt { blob["patchAt"] = patchAt }
        if let frameAt { blob["frameAt"] = frameAt }
        store.set(blob, forKey: Self.key)
    }

    private func load() {
        guard let blob = store?.dictionary(forKey: Self.key) else { return }
        if let p = blob["patch"] as? [String: Any] { patch = p }
        if let d = blob["frame"] as? Data, Panel.square(d.count) != nil { frame = [UInt8](d) }
        // tolerate the old single-stamp format
        patchAt = (blob["patchAt"] as? Date) ?? (blob["at"] as? Date)
        frameAt = (blob["frameAt"] as? Date) ?? (blob["at"] as? Date)
    }
}
