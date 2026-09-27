import Foundation

/// Ordered taps are different from analog steering: retain order, but never replay stale input.
struct GameCommandBuffer {
    private struct Entry { let command: [String: Any]; let session: String?; let at: TimeInterval }
    private var entries: [Entry] = []
    mutating func offer(_ command: [String: Any], session: String?, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        entries.removeAll { $0.session != session || (now - $0.at > 0.6 && $0.command["pause"] as? Bool != true) }
        if command["pause"] as? Bool == true { entries.removeAll() }
        if let last = entries.last, NSDictionary(dictionary: last.command).isEqual(to: command),
           command["dir"] != nil || command["start"] != nil || command["resume"] != nil || command["pause"] != nil { return true }
        guard entries.count < 4 else { return false }
        entries.append(Entry(command: command, session: session, at: now))
        return true
    }
    mutating func take(session: String?, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [String: Any]? {
        entries.removeAll { $0.session != session || (now - $0.at > 0.6 && $0.command["pause"] as? Bool != true) }
        return entries.isEmpty ? nil : entries.removeFirst().command
    }
    mutating func clear() { entries.removeAll() }
}
