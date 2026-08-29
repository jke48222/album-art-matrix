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
// The queue is visible in the UI. Nothing here is invisible magic.

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
    /// offline, not a relaunch, and the summary says it is queued.
    private(set) var clip: (frames: [[UInt8]], fps: Double)? = nil
    /// When each kind was queued, so a flush can replay them in the order
    /// they were meant: the brain force-sets mode on a frame push, and
    /// whichever intent came LAST must win.
    private(set) var patchAt: Date? = nil
    private(set) var frameAt: Date? = nil
    private(set) var clipAt: Date? = nil
    var queuedAt: Date? { [patchAt, frameAt, clipAt].compactMap { $0 }.max() }

    var isEmpty: Bool { patch.isEmpty && frame == nil && clip == nil }

    /// What to tell the user, in their words rather than the network's.
    var summary: String? {
        guard !isEmpty else { return nil }
        var parts: [String] = []
        if frame != nil { parts.append("a frame") }
        if clip != nil { parts.append("a clip") }
        if !patch.isEmpty {
            parts.append(patch.count == 1 ? "one change" : "\(patch.count) changes")
        }
        return parts.joined(separator: " and ") + " waiting for the wall"
    }

    // MARK: Persistence

    private static let key = "tessera.outbox"
    private var store: UserDefaults? { UserDefaults(suiteName: WallSnapshot.group) }

    init() { load() }

    func add(patch p: [String: Any]) {
        for (k, v) in p { patch[k] = v }
        patchAt = Date()
        save()
    }

    func add(frame f: [UInt8]) {
        guard f.count == 64 * 64 * 3 else { return }
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
        if let d = blob["frame"] as? Data, d.count == 64 * 64 * 3 { frame = [UInt8](d) }
        // tolerate the old single-stamp format
        patchAt = (blob["patchAt"] as? Date) ?? (blob["at"] as? Date)
        frameAt = (blob["frameAt"] as? Date) ?? (blob["at"] as? Date)
    }
}
