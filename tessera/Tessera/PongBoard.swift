import SwiftUI
@preconcurrency import CoreMotion

/// Motion is deliberately opt-in. Each session learns the player's current
/// posture and paddle position, so enabling it never recentres the paddle.
@MainActor @Observable
final class PongTilt {
    private let motion = CMMotionManager()
    private var token = UUID()
    private var samples: [Double] = []
    private var baseline: Double?
    private var origin = 0.5
    private(set) var running = false
    private(set) var calibrating = false
    private(set) var problem: String?
    private(set) var y = 0.5

    func start(at position: Double, onChange: @escaping (Double) -> Void) {
        stop()
        problem = nil
        guard motion.isDeviceMotionAvailable else {
            problem = "Tilt isn’t available on this device. Slide or use the paddle buttons instead."
            return
        }
        origin = position; y = position; samples = []; baseline = nil
        running = true; calibrating = true
        let session = token
        motion.deviceMotionUpdateInterval = 1 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] sample, error in
            let pitch = sample?.attitude.pitch
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard let self, self.running, self.token == session else { return }
                guard !failed, let pitch, pitch.isFinite else {
                    self.stop()
                    self.problem = "Motion paused. You can keep playing with touch."
                    return
                }
                if self.baseline == nil {
                    self.samples.append(pitch)
                    if self.samples.count >= 12 {
                        self.baseline = self.samples.reduce(0, +) / Double(self.samples.count)
                        self.calibrating = false
                    }
                    return
                }
                let raw = min(0.89, max(0.11, self.origin + (pitch - (self.baseline ?? pitch)) / 1.1))
                let next = self.y * 0.68 + raw * 0.32
                if abs(next - self.y) >= 0.004 {
                    self.y = next
                    onChange(next)
                }
            }
        }
    }
    func stop() {
        token = UUID()
        running = false; calibrating = false
        motion.stopDeviceMotionUpdates()
    }
}

private enum CourtInk {
    static let ground = Color(hex: 0x0C171C)
    static let court = Color(hex: 0x102127)
    static let line = Color(hex: 0x3A5051)
    static let left = Color(hex: 0x95CFB5)
    static let right = Color(hex: 0x85B7DE)
    static let ball = Color(hex: 0xF7C964)
    static let trail = Color(hex: 0x665A3B)
}

private struct PongScene {
    var ball: [Double]
    var paddles: [Double]
    let score: [Int]
    let phase: String
    let point: Int
    let rally: Int
    let velocity: [Double]
    let top: Double
    let bottom: Double
    let paddleHeight: Double
    let paddleX: Double
    let paddleWidth: Double
    let radius: Double
    let trail: [[Double]]
    init(_ game: GameStatus.Game) {
        func number(_ name: String, _ fallback: Double) -> Double {
            guard let value = game.state[name].double, value.isFinite else { return fallback }
            return value
        }
        func pair(_ name: String, fallback: [Double]) -> [Double] {
            (0..<2).map { index in
                guard let value = game.state[name][index].double, value.isFinite else { return fallback[index] }
                return value
            }
        }
        ball = pair("ball", fallback: [0.5, 0.5])
        paddles = pair("paddles", fallback: [0.5, 0.5])
        velocity = pair("velocity", fallback: [0, 0])
        score = (0..<2).map { max(0, game.state["score"][$0].int ?? 0) }
        phase = game.over ? "finished" : game.state["phase"].string ?? "rally"
        point = game.state["point_number"].int ?? 0
        rally = game.state["rally"].int ?? 0
        top = number("court_top", 0.22); bottom = number("court_bottom", 0.94)
        paddleHeight = number("paddle_height", 0.22)
        paddleX = number("paddle_x", 0.055); paddleWidth = number("paddle_width", 0.018)
        radius = number("ball_radius", 1.15 / 64)
        trail = game.state["trail"].array.compactMap { value in
            guard let x = value[0].double, x.isFinite, let y = value[1].double, y.isFinite else { return nil }
            return [x, y]
        }
    }
    func interpolated(from previous: PongScene, fraction: Double) -> PongScene {
        // A bounce or a point changes direction: snap to the received pose
        // rather than drawing an invented path through the court boundary.
        guard phase == "rally", previous.phase == phase, point == previous.point,
              rally == previous.rally, velocity[0] * previous.velocity[0] >= 0,
              velocity[1] * previous.velocity[1] >= 0 else { return self }
        let amount = min(1, max(0, fraction))
        var result = self
        result.ball = zip(previous.ball, ball).map { pair in pair.0 + (pair.1 - pair.0) * amount }
        result.paddles = zip(previous.paddles, paddles).map { pair in pair.0 + (pair.1 - pair.0) * amount }
        return result
    }
}

struct PongBoard: View {
    let game: GameStatus.Game
    let accent: Color
    let player: String
    let send: ([String: Any]) -> Void
    @Environment(\.isEnabled) private var enabled
    @Environment(\.gameCanInteract) private var gameCanInteract
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var tilt = PongTilt()
    @State private var useTilt = false
    @State private var localTarget: Double?
    @State private var lastSent = Date.distantPast
    @State private var previous: PongScene?
    @State private var current: PongScene?
    @State private var received = Date.distantPast
    @State private var sceneHeight: CGFloat = 1

    private var scene: PongScene { PongScene(game) }
    private var side: Int { game.players.firstIndex(of: player) == 1 ? 1 : 0 }
    private var colour: Color { side == 0 ? CourtInk.left : CourtInk.right }
    private var phase: String { scene.phase }
    private var target: Double { min(0.89, max(0.11, localTarget ?? scene.paddles[side])) }
    private var canControl: Bool { enabled && gameCanInteract && scenePhase == .active && !game.over }
    private var marker: String { "\(game.state["sample_time"].double ?? Double(game.seq))|\(phase)|\(scene.point)" }
    private var statusLine: String {
        switch phase {
        case "ready": return "Find your position. Serve when you’re ready."
        case "serve": return "Serve coming. Keep your paddle ready."
        case "point":
            let scorer = game.state["last_point"].int ?? 0
            return "Point to \(scorer < game.players.count ? game.players[scorer] : "the wall"). Next serve coming."
        case "paused": return "Your court is saved. Resume when you’re ready."
        case "finished": return "Match complete. Longest rally: \(game.state["longest_rally"].int ?? 0) returns."
        default: return "\(scene.rally) \(scene.rally == 1 ? "return" : "returns") this rally · First to \(game.state["to"].int ?? 7)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                playerLabel(game.players.first ?? "You", side: 0)
                Spacer(minLength: 8)
                playerLabel(game.players.count > 1 ? game.players[1] : "The wall", side: 1)
            }
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reducedMotion || phase != "rally" || !enabled || scenePhase != .active)) { time in
                PongCourt(scene: presentation(at: time.date), reduceMotion: reducedMotion)
            }.aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: typeSize.isAccessibilitySize ? 220 : 300)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sceneHeight = max(1, $0) }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    stopTilt()
                    let position = Double(value.location.y / sceneHeight)
                    steer((position - scene.top) / (scene.bottom - scene.top), final: false)
                }.onEnded { _ in if let localTarget { steer(localTarget, final: true) } })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Pong court")
                .accessibilityValue("\(scene.score[0]) to \(scene.score[1]). Your \(side == 0 ? "left" : "right") paddle is \(Int((1 - target) * 100)) percent high. \(statusLine)")
                .accessibilityHint(game.over ? "Match finished" : "Adjust up or down, or use the paddle controls below.")
                .accessibilityAdjustableAction { direction in
                    stopTilt()
                    switch direction {
                    case .increment: steer(target - 0.08, final: true)
                    case .decrement: steer(target + 0.08, final: true)
                    @unknown default: break
                    }
                }
            if !game.over {
                matchControl
                paddleControls
            }
            Text(statusLine).font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            if !game.over { motionControls }
            if !typeSize.isAccessibilitySize && !game.over {
                Text("Slide on the court, use Up and Down, or turn on tilt.")
                    .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { current = scene; received = Date() }
        .onDisappear { stopTilt() }
        .onChange(of: enabled) { _, value in if !value { stopTilt() } }
        .onChange(of: gameCanInteract) { _, value in if !value { stopTilt() } }
        .onChange(of: player) { _, _ in stopTilt(); localTarget = nil }
        .onChange(of: scenePhase) { _, value in if value != .active { stopTilt() } }
        .onChange(of: tilt.problem) { _, value in if value != nil { useTilt = false } }
        .onChange(of: game.over) { _, value in if value { stopTilt() } }
        .onChange(of: marker) { _, _ in
            let now = Date()
            previous = !reducedMotion && now.timeIntervalSince(received) < 0.3 ? presentation(at: now) : nil
            let oldPoint = current?.point
            current = scene; received = now
            if let localTarget, abs(scene.paddles[side] - localTarget) < 0.002 { self.localTarget = nil }
            if let oldPoint, oldPoint != scene.point {
                Taps.commit()
                UIAccessibility.post(notification: .announcement, argument: statusLine)
            }
        }
    }

    private func playerLabel(_ name: String, side index: Int) -> some View {
        VStack(alignment: index == 0 ? .leading : .trailing, spacing: 3) {
            Text(index == 0 ? "LEFT" : "RIGHT").font(.machine(9)).foregroundStyle(Ink.dim)
            Text(name).font(.ui(14, .semibold)).foregroundStyle(index == 0 ? CourtInk.left : CourtInk.right)
                .fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
    @ViewBuilder private var matchControl: some View {
        if phase == "ready" || phase == "paused" {
            Button { let command = phase == "ready" ? "serve" : "resume"; send([command: true]) } label: {
                HStack { Text(phase == "ready" ? "Serve" : "Resume rally"); Spacer(); Image(systemName: "play.fill") }
                    .font(.ui(16, .semibold)).foregroundStyle(CourtInk.ground)
                    .padding(.horizontal, 16).frame(minHeight: 50).background(colour, in: RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(PressStyle())
        }
    }
    private var paddleControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
            layout {
                paddleButton("Up", symbol: "arrow.up", amount: -0.08)
                paddleButton("Down", symbol: "arrow.down", amount: 0.08)
            }
            Slider(value: Binding(get: { 1 - target }, set: { stopTilt(); steer(1 - $0, final: false) }), in: 0.11 ... 0.89, onEditingChanged: { editing in
                if !editing, let localTarget { steer(localTarget, final: true) }
            }).tint(colour).frame(minHeight: 44)
                .accessibilityLabel("\(side == 0 ? "Left" : "Right") paddle height")
                .accessibilityValue("\(Int((1 - target) * 100)) percent")
        }
    }
    private func paddleButton(_ title: String, symbol: String, amount: Double) -> some View {
        Button { stopTilt(); steer(target + amount, final: true) } label: {
            Label(title, systemImage: symbol).font(.ui(16, .semibold)).foregroundStyle(colour)
                .frame(maxWidth: .infinity, minHeight: 48).padding(.vertical, typeSize.isAccessibilitySize ? 5 : 0)
                .background(Ink.plaster, in: RoundedRectangle(cornerRadius: 13))
        }.buttonStyle(PressStyle()).accessibilityLabel("Paddle \(title.lowercased())")
    }
    private var motionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Tilt control", isOn: Binding(get: { useTilt }, set: { value in
                if value { startTilt() } else { stopTilt() }
            })).font(.ui(15, .semibold)).tint(colour).frame(minHeight: 44)
            if useTilt {
                Text(tilt.calibrating ? "Hold comfortably for a moment. Setting your neutral position…" : "Tip gently to move. Touch takes over immediately.")
                    .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                Button("Recalibrate tilt") { startTilt() }.font(.ui(14, .semibold)).foregroundStyle(colour).frame(minHeight: 44)
            }
            if let problem = tilt.problem { Text(problem).font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true) }
            if ["serve", "rally", "point"].contains(phase) {
                Button("Pause rally", systemImage: "pause") { stopTilt(); send(["pause": true]) }
                    .font(.ui(14, .semibold)).foregroundStyle(colour).frame(minHeight: 44)
            }
        }
    }
    private func presentation(at date: Date) -> PongScene {
        let latest = current ?? scene
        guard !reducedMotion, let previous else { return latest }
        return latest.interpolated(from: previous, fraction: date.timeIntervalSince(received) / 0.1)
    }
    private func startTilt() {
        guard canControl else { return }
        tilt.start(at: target) { value in steer(value, final: false) }
        useTilt = tilt.running
    }
    private func stopTilt() { useTilt = false; tilt.stop() }
    private func steer(_ value: Double, final: Bool) {
        guard canControl, value.isFinite else { return }
        let position = min(0.89, max(0.11, value))
        localTarget = position
        let now = Date()
        if final || now.timeIntervalSince(lastSent) >= 0.05 {
            lastSent = now
            send(["paddle": position])
        }
    }
}

private struct PongCourt: View {
    let scene: PongScene
    let reduceMotion: Bool
    var body: some View {
        Canvas { context, size in
            let s = size.width
            let courtHeight = scene.bottom - scene.top
            func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ colour: Color, radius: Double = 0) {
                context.fill(Path(roundedRect: CGRect(x: x * s, y: y * s, width: width * s, height: height * s), cornerRadius: radius * s), with: .color(colour))
            }
            rect(0, 0, 1, 1, CourtInk.ground)
            let court = CGRect(x: 0.025 * s, y: scene.top * s, width: 0.95 * s, height: courtHeight * s)
            context.fill(Path(court), with: .color(CourtInk.court))
            context.stroke(Path(court), with: .color(CourtInk.line), lineWidth: max(1, s / 256))
            for index in 0..<10 { rect(0.5, scene.top + courtHeight * (Double(index) / 10 + 0.02), 1 / 256, courtHeight * 0.045, CourtInk.line) }
            for side in 0..<2 {
                let colour = side == 0 ? CourtInk.left : CourtInk.right
                let x = side == 0 ? scene.paddleX : 1 - scene.paddleX
                rect(x - scene.paddleWidth / 2, scene.top + (scene.paddles[side] - scene.paddleHeight / 2) * courtHeight,
                     scene.paddleWidth, scene.paddleHeight * courtHeight, colour, radius: 1 / 256)
                context.draw(Text("\(scene.score[side])").font(.custom(Face.display, fixedSize: s * 0.14)).foregroundStyle(colour),
                             at: CGPoint(x: s * (side == 0 ? 0.28 : 0.72), y: s * 0.09))
            }
            if !reduceMotion {
                for (index, position) in scene.trail.dropLast().enumerated() {
                    let opacity = Double(index + 1) / Double(max(1, scene.trail.count)) * 0.65
                    let radius = scene.radius * 0.6 * s
                    context.fill(Path(ellipseIn: CGRect(x: position[0] * s - radius, y: (scene.top + position[1] * courtHeight) * s - radius, width: 2 * radius, height: 2 * radius)), with: .color(CourtInk.trail.opacity(opacity)))
                }
            }
            let radius = scene.radius * s
            context.fill(Path(ellipseIn: CGRect(x: scene.ball[0] * s - radius, y: (scene.top + scene.ball[1] * courtHeight) * s - radius, width: 2 * radius, height: 2 * radius)), with: .color(CourtInk.ball))
            let labels = ["ready": "READY", "serve": "SERVE", "paused": "PAUSED", "finished": "FINAL"]
            if let label = labels[scene.phase] {
                context.draw(Text(label).font(.custom(Face.mono, fixedSize: s * 0.033)).foregroundStyle(Color.white), at: CGPoint(x: s * 0.5, y: s * 0.167))
            }
        }.clipped().accessibilityHidden(true)
    }
}
