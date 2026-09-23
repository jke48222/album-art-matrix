import Foundation

/// Touch geometry is independent of rendering so interrupted gestures never
/// commit a brightness change or turn a sleep hold into a playback command.
struct IPodWheelInteraction {
    enum Sector: Equatable { case center, top, bottom, left, right }
    var radius: Double = 116
    var buttonRadius: Double = 42
    private(set) var isActive = false
    private(set) var held = false
    private(set) var moved = 0.0
    private(set) var startSector: Sector?
    private var origin = (x: 0.0, y: 0.0)
    private var lastAngle: Double?
    private var travel = 0.0
    private var turned = false

    var canHold: Bool { isActive && !held && !turned && moved < 8 && startSector == .bottom }

    @discardableResult mutating func begin(x: Double, y: Double) -> Bool {
        guard !isActive, x.isFinite, y.isFinite, hypot(x, y) <= radius else { return false }
        isActive = true
        held = false
        moved = 0
        travel = 0
        turned = false
        origin = (x, y)
        startSector = sector(x: x, y: y)
        lastAngle = startSector == .center ? nil : atan2(y, x)
        return true
    }

    mutating func move(x: Double, y: Double) -> Int {
        guard isActive, !held, x.isFinite, y.isFinite else { return 0 }
        moved = max(moved, hypot(x - origin.x, y - origin.y))
        guard startSector != .center else { return 0 }
        guard hypot(x, y) >= buttonRadius, hypot(x, y) <= radius + 32 else {
            lastAngle = nil
            return 0
        }
        let angle = atan2(y, x)
        defer { lastAngle = angle }
        guard let lastAngle else { return 0 }
        var delta = angle - lastAngle
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        travel += delta
        let detent = Double.pi / 12
        let steps = Int((travel / detent).rounded(.towardZero))
        travel -= Double(steps) * detent
        if steps != 0 { turned = true }
        return steps
    }

    @discardableResult mutating func hold() -> Bool {
        guard canHold else { return false }
        held = true
        return true
    }

    mutating func end(x: Double, y: Double, cancelled: Bool) -> Sector? {
        defer { cancel() }
        guard isActive, !cancelled, !held, !turned, moved < 8,
              x.isFinite, y.isFinite, hypot(x - origin.x, y - origin.y) < 8,
              hypot(x, y) <= radius, sector(x: x, y: y) == startSector else { return nil }
        return startSector
    }

    mutating func cancel() {
        isActive = false
        held = false
        moved = 0
        startSector = nil
        lastAngle = nil
        travel = 0
        turned = false
    }

    private func sector(x: Double, y: Double) -> Sector {
        if hypot(x, y) < buttonRadius { return .center }
        let angle = atan2(y, x) * 180 / .pi
        if angle > -135 && angle <= -45 { return .top }
        if angle > -45 && angle <= 45 { return .right }
        if angle > 45 && angle <= 135 { return .bottom }
        return .left
    }
}
