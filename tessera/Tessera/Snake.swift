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
// Dying is not a modal. The snake unravels from the tail at speed, the score
// letters itself on the panel in the wall's own font, and a tap deals again.

import SwiftUI

// MARK: - The game

@MainActor @Observable
final class SnakeGame {
    enum Phase { case ready, alive, unraveling, over }

    static let grid = 32

    private(set) var phase: Phase = .ready
    private(set) var score = 0
    private(set) var px = [UInt8](repeating: 0, count: 64 * 64 * 3)
    @ObservationIgnored @AppStorage("snake.best") var best = 0

    @ObservationIgnored private var body: [(Int, Int)] = []
    @ObservationIgnored private var dir = (1, 0)
    @ObservationIgnored private var queued: (Int, Int)? = nil
    @ObservationIgnored private var food = (24, 16)
    @ObservationIgnored private var grow = 0
    @ObservationIgnored private var rng = SystemRandomNumberGenerator()

    var accent: (Double, Double, Double) = (0.91, 0.69, 0.29)

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
        dropFood()
        render()
    }

    func deal() {
        prepare()
        phase = .alive
    }

    /// One request per tick, applied at the moment the head moves. A second
    /// swipe before the tick replaces the first rather than queueing behind
    /// it: the player means the last thing they said.
    func steer(_ d: (Int, Int)) {
        if phase == .ready { phase = .alive }          // the first swipe deals
        guard phase == .alive else { return }
        guard d != (-dir.0, -dir.1) else { return }   // no folding in half
        queued = d
    }

    func tick() {
        switch phase {
        case .alive: step()
        case .unraveling: unravel()
        case .ready, .over: break
        }
    }

    private func step() {
        if let q = queued { dir = q; queued = nil }
        let head = (body[0].0 + dir.0, body[0].1 + dir.1)
        let n = Self.grid

        // The walls are walls. A wrapping snake never has to commit.
        if head.0 < 0 || head.0 >= n || head.1 < 0 || head.1 >= n
            || body.dropLast(grow > 0 ? 0 : 1).contains(where: { $0 == head }) {
            phase = .unraveling
            Taps.error()
            return
        }

        body.insert(head, at: 0)
        if head == food {
            score += 1
            grow += 2
            Taps.detent(intensity: min(1.0, 0.35 + Double(score) * 0.02))
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
            if score > best { best = score }
            Taps.landed()
        }
        render()
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
            let v = UInt8(min(255, 234 * k))
            block(seg.0, seg.1, v, UInt8(min(255, 228 * k)), UInt8(min(255, 216 * k)))
        }
        if let head = body.first {
            block(head.0, head.1, 255, 250, 240)
        }
    }
}

// MARK: - The screen

struct SnakeScreen: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dismiss) private var dismiss

    let accent: Color

    @State private var game = SnakeGame()
    @State private var latched = false
    /// What the wall was doing before the game took it, put back on the way
    /// out. A game that leaves the wall stuck on its corpse is a bad guest.
    @State private var before = "art"

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("SNAKE")
                    .font(.display(18))
                    .kerning(3.0)
                    .foregroundStyle(Ink.ink)
                Spacer()
                Text("\(game.score)")
                    .font(.machine(22))
                    .foregroundStyle(game.phase == .alive ? accent : Ink.dim)
                    .contentTransition(.numericText())
                    .animation(.linear(duration: 0.15), value: game.score)
                Text("best \(game.best)")
                    .font(.machine(11))
                    .foregroundStyle(Ink.faint)
                    .padding(.leading, 10)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            PanelCanvas(px: game.px, duty: 1)
                .aspectRatio(1, contentMode: .fit)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
                .gesture(steering)
                .onTapGesture {
                    switch game.phase {
                    case .ready: Taps.commit(); game.deal()
                    case .over: Taps.commit(); game.deal()
                    default: break
                    }
                }

            Text(caption)
                .font(.ui(13))
                .foregroundStyle(Ink.dim)
                .padding(.top, 18)
                .animation(Motion.settle, value: game.phase)

            Spacer(minLength: 0)

            Button("Done") {
                Taps.detent(intensity: 0.3)
                dismiss()
            }
            .buttonStyle(PressStyle(scale: 0.96))
            .font(.ui(15))
            .foregroundStyle(Ink.dim)
            .padding(.bottom, 8)
        }
        .padding(.top, Safe.top + 12)
        .padding(.bottom, Safe.bottom + 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.ground)
        .preferredColorScheme(.dark)
        .onAppear {
            let m = wall.state.mode
            before = ["frame", "clip", "timer"].contains(m) ? "art" : m
            if let c = accent.wallRGB { game.accent = c }
            game.prepare()
        }
        .onDisappear {
            wall.send(["mode": before])
        }
        .task {
            // The game clock. Sleeping the interval each lap means speed-ups
            // take hold at the next move, which is exactly when they should.
            while !Task.isCancelled {
                game.tick()
                if game.phase == .alive || game.phase == .unraveling {
                    wall.beam(game.px)
                }
                let wait = game.phase == .unraveling ? 0.05 : game.interval
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    private var caption: String {
        switch game.phase {
        case .ready: "swipe to start, swipe to steer"
        case .alive: game.score == 0 ? "swipe to steer" : " "
        case .unraveling: " "
        case .over: "tap to deal again"
        }
    }

    /// The first committed direction of a drag, latched until the finger
    /// lifts. Distance does not matter; direction is the entire message.
    private var steering: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { g in
                guard !latched else { return }
                latched = true
                let dx = g.translation.width, dy = g.translation.height
                if abs(dx) > abs(dy) {
                    game.steer((dx > 0 ? 1 : -1, 0))
                } else {
                    game.steer((0, dy > 0 ? 1 : -1))
                }
                Taps.detent(intensity: 0.25)
            }
            .onEnded { _ in latched = false }
    }
}

private extension Color {
    /// The accent as linear RGB for the renderer, when it resolves.
    var wallRGB: (Double, Double, Double)? {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return (Double(r), Double(g), Double(b))
    }
}
