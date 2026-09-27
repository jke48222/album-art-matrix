import SwiftUI

private enum StackInk {
    static let ground = Color(hex: 0x11141F)
    static let well = Color(hex: 0x181D2C)
    static let grid = Color(hex: 0x232A39)
    static let edge = Color(hex: 0x586277)
    static let dim = Color(hex: 0x9BA7BC)
    static let colours: [String: Color] = ["I": Color(hex: 0x75CCDA), "O": Color(hex: 0xF5CD6F),
        "T": Color(hex: 0xB194DD), "S": Color(hex: 0x97CA8E), "Z": Color(hex: 0xE68487),
        "J": Color(hex: 0x80A9E1), "L": Color(hex: 0xECA970)]
}

private struct StackScene {
    let well: [[String]]
    let cells: [CGPoint]
    let nextCells: [CGPoint]
    let kind: String
    let nextKind: String
    let ghostOffset: CGFloat?
    let score: Int
    let lines: Int
    let level: Int
    let phase: String
    let values: [String]
    let origin: CGPoint
    let cell: CGFloat
    init(_ game: GameStatus.Game) {
        func points(_ value: JSONValue) -> [CGPoint] {
            value.array.compactMap { pair in
                guard let x = pair[0].int, let y = pair[1].int else { return nil }
                return CGPoint(x: x, y: y)
            }
        }
        well = game.state["well"].array.map { $0.array.map { $0.string ?? "" } }
        let piece = game.state["piece"]
        cells = points(piece["cells"])
        kind = piece["kind"].string ?? "T"
        nextCells = points(game.state["next"]["cells"])
        nextKind = game.state["next"]["kind"].string ?? "I"
        if let ghost = game.state["ghost_y"].int, let y = piece["y"].int {
            ghostOffset = CGFloat(ghost - y)
        } else { ghostOffset = nil }
        score = max(0, game.state["score"].int ?? 0)
        lines = max(0, game.state["lines"].int ?? 0)
        level = max(1, game.state["level"].int ?? 1)
        phase = game.over ? "finished" : game.state["phase"].string ?? "ready"
        values = [game.state["score_display"].string ?? String(score), game.state["lines_display"].string ?? String(lines), game.state["level_display"].string ?? String(level)]
        let geometry = game.state["well_geometry"]
        origin = CGPoint(x: geometry["x"].double ?? 4 / 64, y: geometry["y"].double ?? 2 / 64)
        cell = geometry["cell"].double ?? 3 / 64
    }
}

struct TetrisBoard: View {
    let game: GameStatus.Game
    let accent: Color
    let send: ([String: Any]) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.gameCanInteract) private var canInteract
    @Environment(\.scenePhase) private var scenePhase
    private var scene: StackScene { StackScene(game) }
    private var active: Bool { canInteract && scenePhase == .active && scene.phase == "playing" && !game.over }
    private var instruction: String {
        switch scene.phase {
        case "ready": return "Fill a row to clear it. The outline shows where your piece will land."
        case "paused": return game.message.isEmpty ? "Your stack is saved. Resume when you’re ready." : game.message
        case "finished": return "\(scene.lines) lines cleared · Level \(scene.level)"
        default: return "Swipe to move or lower. Tap to rotate. Hard drop places the piece immediately."
        }
    }
    private var summary: String {
        let row = (game.state["piece"]["y"].int ?? 0) + 1
        let column = (game.state["piece"]["x"].int ?? 0) + 1
        let landing = (game.state["ghost_y"].int ?? 0) + 1
        return "\(scene.score) points. \(scene.lines) lines. Level \(scene.level). \(scene.kind) piece at column \(column), row \(row). Landing row \(landing). Next, \(scene.nextKind)."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StackCourt(scene: scene)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: typeSize.isAccessibilitySize ? 220 : 300)
                .frame(maxWidth: .infinity).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 16).onEnded { value in
                    let dx = value.translation.width, dy = value.translation.height
                    move(abs(dx) > abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "rotate"))
                })
                .onTapGesture { move("rotate") }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Tetris well, \(scene.phase)")
                .accessibilityValue(summary)
                .accessibilityAction(named: "Move left") { move("left") }
                .accessibilityAction(named: "Move right") { move("right") }
                .accessibilityAction(named: "Rotate piece") { move("rotate") }
                .accessibilityAction(named: "Soft drop") { move("down") }
                .accessibilityAction(named: "Hard drop") { move("drop") }
            if !game.over {
                if scene.phase == "playing" {
                    HStack(spacing: 10) {
                        key("", "arrow.left", "Move left", "left").keyboardShortcut(.leftArrow, modifiers: [])
                        key("", "arrow.clockwise", "Rotate piece", "rotate").keyboardShortcut(.upArrow, modifiers: [])
                        key("", "arrow.right", "Move right", "right").keyboardShortcut(.rightArrow, modifiers: [])
                    }.disabled(!active)
                    HStack(spacing: 10) {
                        key("Lower", "arrow.down", "Soft drop", "down").keyboardShortcut(.downArrow, modifiers: [])
                        key("Drop", "arrow.down.to.line", "Hard drop", "drop", prominent: true).keyboardShortcut(.return, modifiers: [])
                        ArcadeKey(title: "Pause", symbol: "pause.fill", accessibilityTitle: "Pause Tetris", tint: StackInk.dim) {
                            send(["pause": true])
                        }.keyboardShortcut(.space, modifiers: [])
                    }
                } else {
                    ArcadeRoundControl(name: "Tetris", phase: scene.phase, tint: StackInk.colours["T"] ?? accent, send: send)
                }
            }
            Text(instruction).font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            if scene.phase == "playing" && (game.state["last_clear"].int ?? 0) > 0 {
                Label("\(game.state["last_clear"].int ?? 0) lines cleared on the last piece", systemImage: "sparkle")
                    .font(.ui(12)).foregroundStyle(StackInk.colours["O"] ?? accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: scene.lines) { old, value in if value > old && active { Taps.commit() } }
    }
    private func key(_ title: String, _ symbol: String, _ label: String, _ command: String, prominent: Bool = false) -> some View {
        ArcadeKey(title: title, symbol: symbol, accessibilityTitle: label, tint: StackInk.colours[scene.kind] ?? accent, prominent: prominent) { move(command) }
            .disabled(!active)
    }
    private func move(_ command: String) {
        guard active else { return }
        send(["move": command])
    }
}

private struct StackCourt: View {
    let scene: StackScene
    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height), u = side / 64
            let cell = scene.cell * side
            let origin = CGPoint(x: scene.origin.x * side, y: scene.origin.y * side)
            let well = CGRect(x: origin.x, y: origin.y, width: cell * 10, height: cell * 20)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(StackInk.ground))
            context.fill(Path(well), with: .color(StackInk.well))
            context.stroke(Path(well.insetBy(dx: -u * 0.6, dy: -u * 0.6)), with: .color(StackInk.edge), lineWidth: u * 0.3)
            for row in 1..<20 {
                var line = Path(); line.move(to: CGPoint(x: well.minX, y: well.minY + CGFloat(row) * cell)); line.addLine(to: CGPoint(x: well.maxX, y: well.minY + CGFloat(row) * cell))
                context.stroke(line, with: .color(StackInk.grid), lineWidth: u * 0.2)
            }
            for column in 1..<10 {
                var line = Path(); line.move(to: CGPoint(x: well.minX + CGFloat(column) * cell, y: well.minY)); line.addLine(to: CGPoint(x: well.minX + CGFloat(column) * cell, y: well.maxY))
                context.stroke(line, with: .color(StackInk.grid), lineWidth: u * 0.2)
            }
            func block(_ point: CGPoint, kind: String, ghost: Bool = false, at start: CGPoint? = nil, width: CGFloat? = nil) {
                guard point.y >= 0 else { return }
                let start = start ?? origin, width = width ?? cell
                let rect = CGRect(x: start.x + point.x * width, y: start.y + point.y * width, width: width - u * 0.15, height: width - u * 0.15)
                let colour = StackInk.colours[kind] ?? .white
                if ghost {
                    context.stroke(Path(rect.insetBy(dx: u * 0.15, dy: u * 0.15)), with: .color(colour.opacity(0.65)), lineWidth: u * 0.25)
                } else {
                    context.fill(Path(rect), with: .color(colour))
                    context.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: u * 0.25)), with: .color(.white.opacity(0.35)))
                    context.fill(Path(CGRect(x: rect.minX, y: rect.maxY - u * 0.25, width: rect.width, height: u * 0.25)), with: .color(StackInk.ground.opacity(0.35)))
                    // Letters, outlines and geometry keep the well readable without colour.
                    context.draw(Text(kind).font(.system(size: width * 0.43, weight: .bold, design: .monospaced)).foregroundStyle(StackInk.ground), at: CGPoint(x: rect.midX, y: rect.midY))
                }
            }
            for (y, row) in scene.well.prefix(20).enumerated() {
                for (x, kind) in row.prefix(10).enumerated() where !kind.isEmpty {
                    block(CGPoint(x: x, y: y), kind: kind)
                }
            }
            if scene.phase != "finished" {
                if let offset = scene.ghostOffset {
                    for point in scene.cells { block(CGPoint(x: point.x, y: point.y + offset), kind: scene.kind, ghost: true) }
                }
                for point in scene.cells { block(point, kind: scene.kind) }
            }
            let label = ["ready": "READY", "paused": "PAUSED", "finished": "FINAL"][scene.phase] ?? "NEXT"
            context.draw(Text(label).font(.system(size: 3.2 * u, weight: .semibold, design: .monospaced)).foregroundStyle(.white), at: CGPoint(x: 40 * u, y: 5.5 * u), anchor: .leading)
            for point in scene.nextCells { block(point, kind: scene.nextKind, at: CGPoint(x: 40 * u, y: 11 * u), width: 4 * u) }
            for item in [("PTS", scene.values[0], 24.0), ("LINES", scene.values[1], 37.0), ("LEVEL", scene.values[2], 50.0)] {
                context.draw(Text(item.0).font(.system(size: 2.8 * u, weight: .medium, design: .monospaced)).foregroundStyle(StackInk.dim), at: CGPoint(x: 40 * u, y: (item.2 + 2.5) * u), anchor: .leading)
                let digits = item.1
                let font = min(5.5, 36 / Double(max(1, digits.count))) * u
                context.draw(Text(digits).font(.system(size: font, weight: .semibold, design: .monospaced)).foregroundStyle(.white), at: CGPoint(x: 40 * u, y: (item.2 + 10) * u), anchor: .leading)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(StackInk.edge.opacity(0.4), lineWidth: 1))
    }
}
