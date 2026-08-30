// Snake, on the wall.
//
// The phone runs the game; the wall is only the display. Every tick renders
// one 12KB frame that goes out over the existing frame push, which on a LAN
// is nothing, and lands on the stand-in identically when no wall exists. The
// game plays on a 32x32 grid so every segment is a 2x2 block of emitters:
// at one pixel a snake is a crawling ant, at two it is a snake.
//
// Steering is the whole interface. Swipe anywhere, any distance: the first
// direction your finger commits to is the turn. No d-pad, because a d-pad on
// glass is four buttons you cannot feel, and a swipe is a direction you can.
//
// The board wraps: edges are doors, and the only way to die is to meet
// yourself. Dying is not a modal. The snake unravels from the tail at speed, the score
// letters itself on the panel in the wall's own font, and a tap deals again.
//
// Left alone, it plays itself. The autopilot is a flood-fill greedy that
// chases the meal without boxing itself in, and the first swipe hands you
// the wheel mid-run: the snake you take over is the one that was already
// moving. Walk away and, after a death, it takes the wheel back. That makes
// the game double as a thing the wall does when nobody is playing, and it
// never touches your best score or your Taptic Engine while it drives.

import SwiftUI

// MARK: - The game

@MainActor @Observable
final class SnakeGame {
    enum Phase { case ready, alive, unraveling, over }

    static let grid = 32

    private(set) var phase: Phase = .ready
    private(set) var score = 0
    /// True while the snake is driving itself. Autoplay earns no best score
    /// and makes no haptics: the phone in your pocket is not playing.
    private(set) var auto = false
    private(set) var px = [UInt8](repeating: 0, count: 64 * 64 * 3)
    @ObservationIgnored @AppStorage("snake.best") var best = 0

    @ObservationIgnored private var body: [(Int, Int)] = []
    @ObservationIgnored private var dir = (1, 0)
    @ObservationIgnored private var queued: (Int, Int)? = nil
    @ObservationIgnored private var food = (24, 16)
    @ObservationIgnored private var grow = 0
    @ObservationIgnored private var rng = SystemRandomNumberGenerator()
    @ObservationIgnored private var readyAt = Date()
    @ObservationIgnored private var overAt = Date()

    var accent: (Double, Double, Double) = (0.91, 0.69, 0.29)
    /// The body's colour. Cream by default; the lamp effect hands it the
    /// album's own thread so the wall snake wears the record.
    var ink: (Double, Double, Double) = (0.918, 0.894, 0.847)

    /// Seconds per move. Starts easy and tightens as the snake earns it.
    var interval: Double { max(0.07, 0.14 * pow(0.975, Double(score))) }

    /// The table, set but not moving: the snake and its first meal, waiting.
    /// A game that starts the moment the screen opens is dead before the
    /// player has found their hands.
    func prepare() {
        let n = Self.grid
        body = (0..<4).map { (n / 2 - $0, n / 2) }
        dir = (1, 0)
        queued = nil
        grow = 0
        score = 0
        phase = .ready
        readyAt = Date()
        dropFood()
        render()
    }

    func deal(auto driven: Bool = false) {
        prepare()
        auto = driven
        phase = .alive
    }

    /// One request per tick, applied at the moment the head moves. A second
    /// swipe before the tick replaces the first rather than queueing behind
    /// it: the player means the last thing they said.
    func steer(_ d: (Int, Int)) {
        if phase == .ready { phase = .alive }          // the first swipe deals
        guard phase == .alive else { return }
        auto = false                                   // your wheel now
        guard d != (-dir.0, -dir.1) else { return }   // no folding in half
        queued = d
    }

    func tick() {
        switch phase {
        case .alive:
            if auto, queued == nil { queued = autopilot() }
            step()
        case .unraveling:
            unravel()
        case .ready:
            // Nobody moved: it starts without you.
            if Date().timeIntervalSince(readyAt) > 1.4 {
                auto = true
                phase = .alive
            }
        case .over:
            // A player gets time to read the score; an empty room does not
            // need it. Either way the wall goes back to having a snake.
            if Date().timeIntervalSince(overAt) > (auto ? 1.8 : 7.0) {
                deal(auto: true)
            }
        }
    }

    private func step() {
        if let q = queued { dir = q; queued = nil }
        let n = Self.grid
        // The board is a torus: run off an edge and come back on the other
        // side. On a panel hanging on a wall this is the honest topology,
        // since the frame of the panel is a bezel, not a fence, and it turns
        // the only death into the one that is always your own doing.
        let head = ((body[0].0 + dir.0 + n) % n, (body[0].1 + dir.1 + n) % n)

        if body.dropLast(grow > 0 ? 0 : 1).contains(where: { $0 == head }) {
            phase = .unraveling
            if !auto { Taps.error() }
            return
        }

        body.insert(head, at: 0)
        if head == food {
            score += 1
            grow += 2
            if !auto { Taps.detent(intensity: min(1.0, 0.35 + Double(score) * 0.02)) }
            dropFood()
        }
        if grow > 0 { grow -= 1 } else { body.removeLast() }
        render()
    }

    private func unravel() {
        if body.count > 3 {
            body.removeLast(3)
        } else if !body.isEmpty {
            body.removeAll()
        } else {
            phase = .over
            overAt = Date()
            if !auto {
                if score > best { best = score }
                Taps.landed()
            }
        }
        render()
    }

    // MARK: the autopilot

    /// Greedy toward the meal, but never into a pocket smaller than itself.
    /// Flood-filling from each candidate square is what separates a snake
    /// that plays from one that walls itself in by minute two; at 32x32 the
    /// fill is a thousand cells at worst and runs in nothing.
    private func autopilot() -> (Int, Int)? {
        let n = Self.grid
        let head = body[0]
        var occupied = Set(body.dropLast(grow > 0 ? 0 : 1).map { $0.1 * n + $0.0 })
        occupied.remove(head.1 * n + head.0)

        func wrap(_ p: (Int, Int)) -> (Int, Int) { ((p.0 + n) % n, (p.1 + n) % n) }
        func open(_ p: (Int, Int)) -> Bool { !occupied.contains(p.1 * n + p.0) }
        func room(_ start: (Int, Int)) -> Int {
            let want = body.count + 8
            var seen: Set<Int> = [start.1 * n + start.0]
            var queue = [start], i = 0
            while i < queue.count, seen.count < want {
                let c = queue[i]; i += 1
                for d in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let q = wrap((c.0 + d.0, c.1 + d.1))
                    if open(q), seen.insert(q.1 * n + q.0).inserted { queue.append(q) }
                }
            }
            return seen.count
        }
        // Distance the way the board actually measures it: across the seam
        // when the seam is shorter. Without this the pilot walks the long
        // way round and looks like it has never seen its own edges.
        func span(_ a: Int, _ b: Int) -> Int { let d = abs(a - b); return min(d, n - d) }

        let options = [(1, 0), (-1, 0), (0, 1), (0, -1)]
            .filter { $0 != (-dir.0, -dir.1) }
            .map { (d: $0, p: wrap((head.0 + $0.0, head.1 + $0.1))) }
            .filter { open($0.p) }
        guard !options.isEmpty else { return nil }     // cornered; so be it

        let scored = options.map { o in
            (d: o.d,
             space: room(o.p),
             dist: span(o.p.0, food.0) + span(o.p.1, food.1),
             straight: o.d == dir)
        }
        let need = min(body.count + 4, body.count + 8)
        let roomy = scored.filter { $0.space >= need }
        let pool = roomy.isEmpty ? scored : roomy
        // closest to the meal; ties go straight on, so it does not wiggle
        return pool.min {
            ($0.dist, $0.straight ? 0 : 1) < ($1.dist, $1.straight ? 0 : 1)
        }?.d
    }

    private func dropFood() {
        let n = Self.grid
        while true {
            let p = (Int.random(in: 0..<n, using: &rng), Int.random(in: 0..<n, using: &rng))
            if !body.contains(where: { $0 == p }) { food = p; break }
        }
    }

    // MARK: render

    private func block(_ gx: Int, _ gy: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
        let x = gx * 2, y = gy * 2
        for dy in 0..<2 {
            for dx in 0..<2 {
                let o = ((y + dy) * 64 + (x + dx)) * 3
                px[o] = r; px[o + 1] = g; px[o + 2] = b
            }
        }
    }

    private func render() {
        px = [UInt8](repeating: 0, count: 64 * 64 * 3)

        if phase == .over {
            // Driving itself, a death is a beat of dark, not a scoreboard:
            // a wall has no one to report to.
            if auto { return }
            let ink: (UInt8, UInt8, UInt8) = (234, 228, 216)
            let a: (UInt8, UInt8, UInt8) = (UInt8(accent.0 * 255),
                                            UInt8(accent.1 * 255),
                                            UInt8(accent.2 * 255))
            let sTxt = "\(score)"
            let w1 = PixelFont.textWidth(sTxt, scale: 2)
            PixelDraw.text(&px, sTxt, x: (64 - w1) / 2, y: 18, rgb: a, scale: 2)
            let bTxt = "BEST \(best)"
            let w2 = PixelFont.textWidth(bTxt, scale: 1)
            PixelDraw.text(&px, bTxt, x: (64 - w2) / 2, y: 38, rgb: ink, scale: 1)
            return
        }

        // the meal, in the room's accent
        if phase == .alive {
            block(food.0, food.1,
                  UInt8(accent.0 * 255), UInt8(accent.1 * 255), UInt8(accent.2 * 255))
        }

        // the snake, in ink, dimming toward the tail so direction reads
        // even in a still frame
        let count = max(1, body.count)
        for (i, seg) in body.enumerated() {
            let k = 1.0 - 0.55 * Double(i) / Double(count)
            block(seg.0, seg.1,
                  UInt8(min(255, ink.0 * 255 * k)),
                  UInt8(min(255, ink.1 * 255 * k)),
                  UInt8(min(255, ink.2 * 255 * k)))
        }
        if let head = body.first {
            block(head.0, head.1,
                  UInt8(min(255, ink.0 * 255 * 1.25 + 30)),
                  UInt8(min(255, ink.1 * 255 * 1.25 + 30)),
                  UInt8(min(255, ink.2 * 255 * 1.25 + 30)))
        }
    }
}


