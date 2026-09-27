import SwiftUI

private enum SnakeInk {
    static let ground = Color(hex: 0x0D1814)
    static let board = Color(hex: 0x14251C)
    static let checker = Color(hex: 0x182A20)
    static let edge = Color(hex: 0x445C41)
    static let tail = Color(hex: 0x4D7C4B)
    static let body = Color(hex: 0x99CF85)
    static let head = Color(hex: 0xE1F4B0)
    static let fruit = Color(hex: 0xF98570)
}

private struct SnakeScene {
    let body: [CGPoint]
    let food: CGPoint?
    let n: Int
    let score: Int
    let phase: String
    let direction: String
    let grid: CGRect
    init(_ game: GameStatus.Game) {
        n = max(1, min(64, game.state["n"].int ?? 32))
        body = game.state["body"].array.compactMap { item in
            guard let x = item[0].int, let y = item[1].int, x >= 0, y >= 0 else { return nil }
            return CGPoint(x: x, y: y)
        }
        if let x = game.state["food"][0].int, let y = game.state["food"][1].int {
            food = CGPoint(x: x, y: y)
        } else { food = nil }
        score = max(0, game.state["score"].int ?? 0)
        phase = game.over ? "finished" : game.state["phase"].string ?? "ready"
        direction = game.state["direction"].string ?? "right"
        let raw = game.state["grid"]
        grid = CGRect(x: raw["x"].double ?? 6 / 64, y: raw["y"].double ?? 11 / 64,
                      width: raw["size"].double ?? 52 / 64, height: raw["size"].double ?? 52 / 64)
    }
}

struct SnakeBoard: View {
    let game: GameStatus.Game
    let accent: Color
    let send: ([String: Any]) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.gameCanInteract) private var canInteract
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var scene: SnakeScene { SnakeScene(game) }
    private var active: Bool { canInteract && scenePhase == .active && scene.phase == "playing" && !game.over }
    private var summary: String {
        let head = scene.body.first ?? .zero
        let food = scene.food.map { "Fruit at column \(Int($0.x) + 1), row \(Int($0.y) + 1)." } ?? "All fruit collected."
        return "\(scene.score) fruit. Head at column \(Int(head.x) + 1), row \(Int(head.y) + 1), moving \(scene.direction). \(food)"
    }
    private var instruction: String {
        switch scene.phase {
        case "ready": return "Steer the snake to the fruit. Avoid the edges and your trail."
        case "paused": return game.message.isEmpty ? "Your trail is saved. Resume when you’re ready." : game.message
        case "finished": return "\(scene.score) fruit. \(scene.body.count) squares of trail."
        default: return "Swipe the garden or use the arrows. Two quick turns can be queued."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SnakeGarden(scene: scene)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: typeSize.isAccessibilitySize ? 220 : 300)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 14).onEnded { value in
                    let dx = value.translation.width, dy = value.translation.height
                    turn(abs(dx) > abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up"))
                })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Snake garden, \(scene.phase)")
                .accessibilityValue(summary)
                .accessibilityAction(named: "Turn up") { turn("up") }
                .accessibilityAction(named: "Turn down") { turn("down") }
                .accessibilityAction(named: "Turn left") { turn("left") }
                .accessibilityAction(named: "Turn right") { turn("right") }
            if !game.over {
                if scene.phase == "playing" {
                    HStack(alignment: .center, spacing: 10) {
                        Group {
                            if typeSize.isAccessibilitySize {
                                Color.clear.frame(height: 1).accessibilityHidden(true)
                            } else {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("FRUIT").font(.machine(9)).foregroundStyle(SnakeInk.body)
                                    Text("\(scene.score) collected").font(.ui(15, .semibold)).foregroundStyle(.white)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        direction("up", "arrow.up").keyboardShortcut(.upArrow, modifiers: [])
                        Button { send(["pause": true]) } label: {
                            Image(systemName: "pause.fill").font(.system(size: 18, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 52).foregroundStyle(SnakeInk.head)
                                .background(Ink.plaster, in: RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(PressStyle(scale: reduceMotion ? 1 : 0.96)).accessibilityLabel("Pause Snake").keyboardShortcut(.space, modifiers: [])
                            .opacity(canInteract ? 1 : 0.4)
                    }
                    HStack(spacing: 10) {
                        direction("left", "arrow.left").keyboardShortcut(.leftArrow, modifiers: [])
                        direction("down", "arrow.down").keyboardShortcut(.downArrow, modifiers: [])
                        direction("right", "arrow.right").keyboardShortcut(.rightArrow, modifiers: [])
                    }.disabled(!active)
                } else {
                    ArcadeRoundControl(name: "Snake", phase: scene.phase, tint: SnakeInk.head, send: send)
                }
            }
            Text(instruction).font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: scene.score) { old, value in if value > old && active { Taps.commit() } }
    }
    private func direction(_ name: String, _ symbol: String) -> some View {
        ArcadeKey(title: "", symbol: symbol, accessibilityTitle: "Turn \(name)", tint: SnakeInk.head) { turn(name) }
            .disabled(!active)
    }
    private func turn(_ direction: String) {
        guard active else { return }
        send(["dir": direction])
    }
}

private struct SnakeGarden: View {
    let scene: SnakeScene
    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height), u = side / 64
            let grid = CGRect(x: scene.grid.minX * side, y: scene.grid.minY * side,
                              width: scene.grid.width * side, height: scene.grid.height * side)
            let cell = grid.width / CGFloat(scene.n)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(SnakeInk.ground))
            context.stroke(Path(grid.insetBy(dx: -u * 0.7, dy: -u * 0.7)), with: .color(SnakeInk.edge), lineWidth: u * 0.4)
            for y in 0..<scene.n {
                for x in 0..<scene.n {
                    let rect = CGRect(x: grid.minX + CGFloat(x) * cell, y: grid.minY + CGFloat(y) * cell, width: cell, height: cell)
                    context.fill(Path(rect), with: .color((x + y).isMultiple(of: 2) ? SnakeInk.board : SnakeInk.checker))
                }
            }
            for (index, point) in scene.body.reversed().enumerated() {
                let f = Double(index + 1) / Double(max(1, scene.body.count))
                let color = Color(red: (77 + 76 * f) / 255, green: (124 + 83 * f) / 255, blue: (75 + 58 * f) / 255)
                let rect = CGRect(x: grid.minX + point.x * cell, y: grid.minY + point.y * cell, width: cell, height: cell)
                context.fill(Path(rect), with: .color(color))
            }
            if let head = scene.body.first {
                let rect = CGRect(x: grid.minX + head.x * cell, y: grid.minY + head.y * cell, width: cell, height: cell)
                context.fill(Path(rect), with: .color(SnakeInk.head))
                let delta: CGPoint = scene.direction == "up" ? CGPoint(x: 0, y: -1) : scene.direction == "down" ? CGPoint(x: 0, y: 1) : scene.direction == "left" ? CGPoint(x: -1, y: 0) : CGPoint(x: 1, y: 0)
                for eye in [-1.0, 1.0] {
                    let x = rect.midX + (delta.x * 0.22 - delta.y * eye * 0.22) * cell
                    let y = rect.midY + (delta.y * 0.22 + delta.x * eye * 0.22) * cell
                    context.fill(Path(ellipseIn: CGRect(x: x - cell * 0.09, y: y - cell * 0.09, width: cell * 0.18, height: cell * 0.18)), with: .color(SnakeInk.ground))
                }
            }
            if let food = scene.food {
                let rect = CGRect(x: grid.minX + food.x * cell, y: grid.minY + food.y * cell, width: cell, height: cell)
                context.fill(Path(ellipseIn: rect.insetBy(dx: cell * 0.02, dy: cell * 0.02)), with: .color(SnakeInk.fruit))
                context.fill(Path(CGRect(x: rect.midX, y: rect.minY, width: cell * 0.15, height: cell * 0.25)), with: .color(SnakeInk.head))
            }
            let label = ["ready": "READY", "paused": "PAUSE", "finished": "FINAL"][scene.phase] ?? "SNAKE"
            context.draw(Text(label).font(.system(size: 5.7 * u, weight: .semibold, design: .monospaced)).foregroundStyle(.white), at: CGPoint(x: 6 * u, y: 4.5 * u), anchor: .leading)
            context.draw(Text(String(scene.score)).font(.system(size: 5.7 * u, weight: .semibold, design: .monospaced)).foregroundStyle(SnakeInk.head), at: CGPoint(x: 59 * u, y: 4.5 * u), anchor: .trailing)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(SnakeInk.edge.opacity(0.45), lineWidth: 1))
    }
}
