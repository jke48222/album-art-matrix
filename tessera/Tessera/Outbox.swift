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
    private(set) var queuedAt: Date? = nil

    var isEmpty: Bool { patch.isEmpty && frame == nil }

    /// What to tell the user, in their words rather than the network's.
    var summary: String? {
        guard !isEmpty else { return nil }
        var parts: [String] = []
        if frame != nil { parts.append("a frame") }
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
        queuedAt = Date()
        save()
    }

    func add(frame f: [UInt8]) {
        guard f.count == 64 * 64 * 3 else { return }
        frame = f
        queuedAt = Date()
        save()
    }

    func clear() {
        patch = [:]
        frame = nil
        queuedAt = nil
        save()
    }

    private func save() {
        guard let store else { return }
        var blob: [String: Any] = [:]
        if !patch.isEmpty { blob["patch"] = patch }
        if let frame { blob["frame"] = Data(frame) }
        if let queuedAt { blob["at"] = queuedAt }
        store.set(blob, forKey: Self.key)
    }

    private func load() {
        guard let blob = store?.dictionary(forKey: Self.key) else { return }
        if let p = blob["patch"] as? [String: Any] { patch = p }
        if let d = blob["frame"] as? Data, d.count == 64 * 64 * 3 { frame = [UInt8](d) }
        queuedAt = blob["at"] as? Date
    }
}
