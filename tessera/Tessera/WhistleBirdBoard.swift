import SwiftUI

private enum FlightInk {
    static let sky = Color(hex: 0x0D1725)
    static let horizon = Color(hex: 0x162831)
    static let star = Color(hex: 0x4C5D6F)
    static let moon = Color(hex: 0x2B3D4D)
    static let pipe = Color(hex: 0x478C84)
    static let pipeLight = Color(hex: 0x8DC0A9)
    static let pipeShade = Color(hex: 0x29595C)
    static let bird = Color(hex: 0xF1BF57)
    static let wing = Color(hex: 0xBC8139)
    static let beak = Color(hex: 0xE98C4A)
    static let eye = Color(hex: 0x111C23)
    static let ground = Color(hex: 0x3B5042)
    static let groundEdge = Color(hex: 0x97AF89)
}

private struct FlightScene {
    struct Pipe {
        let id: Int
        var x: Double
        let gap: Double
    }
    var y: Double
    var distance: Double
    var elapsed: Double
    let score: Int
    let phase: String
    var pipes: [Pipe]
    let gapSize: Double
    let ground: Double
    init(_ game: GameStatus.Game) {
        func finite(_ value: JSONValue, fallback: Double) -> Double {
            guard let number = value.double, number.isFinite else { return fallback }
            return number
        }
        y = min(1, max(0, finite(game.state["y"], fallback: 0.5)))
        distance = finite(game.state["distance"], fallback: 0)
        elapsed = finite(game.state["elapsed"], fallback: 0)
        score = max(0, game.state["score"].int ?? 0)
        phase = game.over || game.state["dead"].bool == true ? "finished" : game.state["phase"].string ?? "flying"
        gapSize = min(0.8, max(0.1, finite(game.state["gap_size"], fallback: 0.34)))
        ground = min(1, max(0.5, finite(game.state["ground"], fallback: 60 / 64)))
        let obstacles = game.state["obstacles"].array
        if obstacles.isEmpty {
            pipes = game.state["pipes"].array.enumerated().compactMap { index, value in
                guard let x = value[0].double, x.isFinite, let gap = value[1].double, gap.isFinite else { return nil }
                return Pipe(id: index, x: x, gap: gap)
            }
        } else {
            pipes = obstacles.compactMap { value in
                guard let id = value["id"].int, let x = value["x"].double, x.isFinite,
                      let gap = value["gap"].double, gap.isFinite else { return nil }
                return Pipe(id: id, x: x, gap: gap)
            }
        }
    }
    func blended(from old: FlightScene, fraction: Double) -> FlightScene {
        guard phase == "flying", old.phase == phase else { return self }
        let amount = min(1, max(0, fraction))
        var result = self
        result.y = old.y + (y - old.y) * amount
        result.distance = old.distance + (distance - old.distance) * amount
        result.elapsed = old.elapsed + (elapsed - old.elapsed) * amount
        result.pipes = pipes.map { pipe in
            guard let before = old.pipes.first(where: { $0.id == pipe.id }) else { return pipe }
            return Pipe(id: pipe.id, x: before.x + (pipe.x - before.x) * amount, gap: pipe.gap)
        }
        return result
    }
}

struct WhistleBirdBoard: View {
    let game: GameStatus.Game
    let accent: Color
    let send: ([String: Any]) -> Void
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var previous: FlightScene?
    @State private var current: FlightScene?
    @State private var received = Date.distantPast
    @State private var lastSent = Date.distantPast
    @State private var touchHeight: Double?
    @State private var sceneHeight: CGFloat = 1

    private var scene: FlightScene { FlightScene(game) }
    private var phase: String { scene.phase }
    private var marker: String { "\(game.state["sample_time"].double ?? Double(game.seq))|\(phase)|\(game.state["y"].double ?? 0.5)" }
    private var target: Double {
        let value = touchHeight ?? game.state["target"].double ?? scene.y
        return value.isFinite ? min(0.90, max(0.06, value)) : 0.5
    }
    private var title: String {
        switch phase {
        case "ready": "A little night flight."
        case "calibrating": "Finding your range."
        case "paused": "Your place is saved."
        case "finished": "A soft landing."
        default: "Find the opening."
        }
    }
    private var explanation: String {
        switch phase {
        case "ready": "Whistle low, then high. Or start with touch and slide to set your height. The bird will wait for you."
        case "calibrating": "Try a low whistle, then a high one. The world stays still while your range is set."
        case "paused": "The flight paused while the wall caught up. Continue when you’re ready."
        case "finished": game.state["reason"].string == "ground" ? "The bird reached the ground. \(scene.score) openings cleared this flight." : "The bird caught an edge. \(scene.score) openings cleared this flight."
        default: game.state["source"].string == "phone" ? "Slide on the sky to choose a height. Touch holds it steady until you move again." : "Whistle high to climb, low to descend. Between whistles, the bird glides down."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(phase == "finished" ? "FLIGHT COMPLETE" : "THE NIGHT IS YOURS")
                    .font(.machine(10)).foregroundStyle(FlightInk.pipeLight)
                Spacer(minLength: 5)
                if let best = game.state["best"].int, best > 0 {
                    Text("Best \(best)").font(.ui(12)).foregroundStyle(Ink.dim)
                }
            }.fixedSize(horizontal: false, vertical: true)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reducedMotion || phase != "flying")) { time in
                FlightArtwork(scene: presentation(at: time.date))
            }.aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: typeSize.isAccessibilitySize ? 230 : 300)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sceneHeight = max(1, $0) }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("bird-sky")).onChanged { value in
                    guard !game.over else { return }
                    // The gesture's coordinate space belongs to the fixed scene,
                    // rather than the surrounding ScrollView or the live LEDs.
                    steer(Double(value.location.y / sceneHeight), final: false)
                }.onEnded { _ in if let touchHeight { steer(touchHeight, final: true) } })
                .coordinateSpace(name: "bird-sky")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Whistle bird flight")
                .accessibilityValue(accessibilityStatus)
                .accessibilityHint(game.over ? "Flight finished" : "Adjust up or down to steer. You can also use Climb and Descend below.")
                .accessibilityAdjustableAction { direction in
                    guard !game.over else { return }
                    switch direction {
                    case .increment: steer(target - 0.08, final: true)
                    case .decrement: steer(target + 0.08, final: true)
                    @unknown default: break
                    }
                }
            if typeSize.isAccessibilitySize {
                launchControls
                if phase == "flying" { steeringControls }
            }
            VStack(alignment: .leading, spacing: 7) {
                if !typeSize.isAccessibilitySize || phase != "flying" {
                    Text(title).font(.ui(22, .semibold)).foregroundStyle(Color.white)
                }
                Text(explanation).font(.ui(14)).foregroundStyle(Ink.dim)
            }.fixedSize(horizontal: false, vertical: true)
            if !typeSize.isAccessibilitySize { launchControls }
            if phase == "flying" && !typeSize.isAccessibilitySize { steeringControls }
            if !game.over {
                Label("The wall runs the flight. This view follows its latest position; network delay can affect touch steering.", systemImage: "wifi")
                    .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { current = scene; received = Date() }
        .onChange(of: marker) { _, _ in
            let now = Date()
            previous = !reducedMotion && now.timeIntervalSince(received) < 0.3 ? presentation(at: now) : nil
            let justFinished = current?.phase != "finished" && phase == "finished"
            current = scene; received = now
            if game.state["source"].string != "phone" || phase == "finished" {
                touchHeight = nil
            } else if let acknowledged = game.state["target"].double, let touchHeight,
                      abs(acknowledged - touchHeight) < 0.001 {
                self.touchHeight = nil
            }
            if justFinished {
                UIAccessibility.post(notification: .announcement, argument: "Flight finished. \(scene.score) openings cleared.")
            }
        }
    }

    @ViewBuilder
    private var launchControls: some View {
        if phase == "ready" || phase == "paused" {
            Button { send(["start": true]) } label: {
                HStack { Text(phase == "paused" ? "Continue flight" : "Start with touch"); Spacer(); Image(systemName: "arrow.up.right") }
                    .font(.ui(16, .semibold)).foregroundStyle(FlightInk.sky)
                    .padding(.horizontal, 18).frame(minHeight: 52)
                    .background(FlightInk.bird, in: RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(PressStyle())
        } else if phase == "calibrating" {
            ProgressView(value: min(1, max(0, game.state["calibration"].double ?? 0)))
                .tint(FlightInk.bird).accessibilityLabel("Learning your whistle range")
            Button("Use touch instead") { send(["start": true]) }
                .font(.ui(15, .semibold)).foregroundStyle(FlightInk.bird).frame(minHeight: 44)
        }
    }

    private var steeringControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
            layout {
                steeringButton("Climb", symbol: "arrow.up", amount: -0.08)
                steeringButton("Descend", symbol: "arrow.down", amount: 0.08)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack { Text("Flight height"); Spacer(); Text("\(Int((1 - target) * 100))%").monospacedDigit() }
                    .font(.ui(12)).foregroundStyle(Ink.dim)
                Slider(value: Binding(get: { 1 - target }, set: { steer(1 - $0, final: false) }), in: 0.1...0.94, onEditingChanged: { editing in
                    if !editing, let touchHeight { steer(touchHeight, final: true) }
                }).tint(FlightInk.bird).frame(minHeight: 44).accessibilityLabel("Flight height")
            }
        }
    }

    private var accessibilityStatus: String {
        let next = scene.pipes.filter { $0.x + 6 / 64 > 0.25 }.min { $0.x < $1.x }
        let gap = next.map { "Next opening is \(Int((1 - $0.gap) * 100)) percent high." } ?? "Open sky ahead."
        return "\(scene.score) openings cleared. Bird is \(Int((1 - scene.y) * 100)) percent high. \(gap)"
    }
    private func presentation(at date: Date) -> FlightScene {
        let latest = current ?? scene
        guard !reducedMotion, let previous else { return latest }
        // Interpolate only between two received poses. After 120ms, hold the
        // latest authoritative pose; never predict through a pipe or an outage.
        return latest.blended(from: previous, fraction: date.timeIntervalSince(received) / 0.12)
    }
    private func steeringButton(_ text: String, symbol: String, amount: Double) -> some View {
        Button { steer(target + amount, final: true) } label: {
            Label(text, systemImage: symbol).font(.ui(16, .semibold)).foregroundStyle(FlightInk.bird)
                .frame(maxWidth: .infinity, minHeight: 52).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 13))
        }.buttonStyle(PressStyle())
    }
    private func steer(_ value: Double, final: Bool) {
        guard !game.over, value.isFinite else { return }
        let next = min(0.90, max(0.06, value))
        touchHeight = next
        let now = Date()
        if final || now.timeIntervalSince(lastSent) >= 0.06 {
            lastSent = now
            send(["y": next])
        }
    }
}

private struct FlightArtwork: View {
    let scene: FlightScene
    private let stars: [(Double, Double)] = [(4,10),(12,6),(22,15),(37,5),(55,13),(61,25),(30,26),(7,32),(42,21),(18,44),(51,39),(33,47),(58,50),(3,52)]
    var body: some View {
        Canvas { context, size in
            let side = size.width
            func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ colour: Color, radius: Double = 0) {
                guard w > 0, h > 0 else { return }
                let rect = CGRect(x: x * side, y: y * side, width: w * side, height: h * side)
                context.fill(Path(roundedRect: rect, cornerRadius: radius * side), with: .color(colour))
            }
            box(0, 0, 1, 1, FlightInk.sky)
            box(0, 0.78, 1, 0.22, FlightInk.horizon)
            context.fill(Path(ellipseIn: CGRect(x: 0.745 * side, y: 0.125 * side, width: 0.11 * side, height: 0.11 * side)), with: .color(FlightInk.moon))
            for (x, y) in stars {
                let shifted = (x / 64 - scene.distance * 0.08).truncatingRemainder(dividingBy: 1)
                box(shifted < 0 ? shifted + 1 : shifted, y / 64, 0.45 / 64, 0.45 / 64, FlightInk.star)
            }
            box(0, scene.ground, 1, 1 - scene.ground, FlightInk.ground)
            box(0, scene.ground, 1, 1 / 64, FlightInk.groundEdge)
            for pipe in scene.pipes {
                let top = max(0, pipe.gap - scene.gapSize / 2)
                let bottom = pipe.gap + scene.gapSize / 2
                for (y, h) in [(0.0, top), (bottom, scene.ground - bottom)] {
                    box(pipe.x, y, 5 / 64, h, FlightInk.pipe)
                    box(pipe.x, y, 1 / 64, h, FlightInk.pipeLight)
                    box(pipe.x + 4 / 64, y, 1 / 64, h, FlightInk.pipeShade)
                }
                box(pipe.x - 1 / 64, top - 2 / 64, 7 / 64, 2 / 64, FlightInk.pipeLight)
                box(pipe.x - 1 / 64, bottom, 7 / 64, 2 / 64, FlightInk.pipeLight)
            }
            let flap = Int(scene.elapsed * 6) % 2 == 0 && scene.phase == "flying"
            box(14 / 64, scene.y - 2 / 64, 5 / 64, 4 / 64, FlightInk.bird, radius: 1 / 64)
            box(14 / 64, scene.y + (flap ? 0 : 1 / 64), 2 / 64, 1 / 64, FlightInk.wing)
            box(19 / 64, scene.y, 1 / 64, 1 / 64, FlightInk.beak)
            box(17 / 64, scene.y - 1 / 64, 1 / 64, 1 / 64, FlightInk.eye)
            let label = scene.phase == "ready" ? "READY" : scene.phase == "calibrating" ? "RANGE" : scene.phase == "paused" ? "PAUSED" : String(scene.score)
            context.draw(Text(label).font(.custom(Face.display, fixedSize: side * (label.count < 3 ? 0.10 : 0.055))).foregroundStyle(Color.white), at: CGPoint(x: side / 2, y: side * 0.11))
            if scene.phase == "finished" {
                context.draw(Text("LANDED").font(.custom(Face.mono, fixedSize: side * 0.045)).foregroundStyle(Color.white), at: CGPoint(x: side / 2, y: side * 0.72))
            }
        }.clipped().accessibilityHidden(true)
    }
}
