import Foundation

/// One physical touch owns one action, even after a hold or a cancelled gesture.
struct PanelInteraction {
    enum Phase: Equatable { case idle, pending, brightness, song, held }
    enum Outcome: Equatable { case brightness(Double), previous, next }

    private(set) var phase: Phase = .idle
    private(set) var value: Double?
    private var origin = 1.0
    private var travelled = false
    var canHold: Bool { phase == .pending && !travelled }

    mutating func begin(brightness: Double) {
        guard phase == .idle else { return }
        origin = Self.clamp(brightness)
        value = nil
        travelled = false
        phase = .pending
    }

    mutating func update(dx: Double, dy: Double, height: Double) -> Double? {
        guard phase != .idle && phase != .held else { return nil }
        let x = abs(dx), y = abs(dy)
        if hypot(x, y) > 8 { travelled = true }
        if phase == .pending {
            if y > 8 && y > x * 1.3 { phase = .brightness }
            else if x > 12 && x > y * 1.3 { phase = .song }
        }
        guard phase == .brightness else { return nil }
        value = Self.clamp(((origin - dy / max(1, height) * 0.95) * 100).rounded() / 100)
        return value
    }

    mutating func hold() -> Bool {
        guard canHold else { return false }
        phase = .held
        value = nil
        return true
    }

    mutating func end(dx: Double) -> Outcome? {
        defer { cancel() }
        if phase == .brightness, let value { return .brightness(value) }
        if phase == .song && abs(dx) > 44 { return dx < 0 ? .next : .previous }
        return nil
    }

    mutating func cancel() {
        phase = .idle
        value = nil
        travelled = false
    }

    private static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0.05, value)) : 1
    }
}
