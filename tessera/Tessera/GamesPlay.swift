// The games that are played with the body, the ear or a clip: Heardle's
// player, the sliding tiles, the reaction button, the whistle bird's
// slider, the yes and no of twenty questions, the quiz card, the arcade's
// paddles and remotes. Each takes the game's JSON state and a `send`.

import SwiftUI
import AVFoundation
import CoreMotion

// MARK: - Heardle: the phone plays the clip

struct HeardleBoard: View {
    let game: GameStatus.Game
    let accent: Color
    let send: ([String: Any]) -> Void
    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var stopper: Task<Void, Never>?

    private var seconds: Int { game.state["seconds"].int ?? 1 }
    private var steps: [Int] { game.state["steps"].ints }
    private var tries: [JSONValue] { game.state["tries"].array }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 4) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                    let used = i < tries.count
                    let open = i <= (game.state["step"].int ?? 0)
                    RoundedRectangle(cornerRadius: Round.chip)
                        .fill(used ? (tries[i]["skipped"].bool == true ? Ink.faint : tileRedish) : open ? tileYellow : Ink.plaster)
                        .frame(width: CGFloat(s) * 14, height: 14)
                }
            }
            Button { play() } label: {
                HStack(spacing: 10) {
                    Image(systemName: playing ? "stop.fill" : "play.fill")
                    Text(playing ? "Playing" : "Play \(seconds) second\(seconds == 1 ? "" : "s")")
                }
                .font(.ui(16, .semibold)).foregroundStyle(Ink.ground)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(RoundedRectangle(cornerRadius: Round.card, style: .continuous).fill(accent))
            }
            .buttonStyle(PressStyle(scale: 0.96))
            .disabled(game.over)
            HStack(spacing: 10) {
                ActionPill(title: "Skip (+\(nextGain))", filled: false) { send(["skip": true]) }.disabled(game.over)
                Text("Try \(tries.count + 1) of 6  ·  \(game.state["turn"].string ?? "")").font(.ui(12)).foregroundStyle(Ink.dim)
            }
            ForEach(Array(tries.enumerated()), id: \.offset) { _, t in
                Text(t["skipped"].bool == true ? "skipped" : (t["text"].string ?? ""))
                    .font(.ui(14)).foregroundStyle(Ink.dim).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).frame(minHeight: 34)
                    .background(RoundedRectangle(cornerRadius: Round.control, style: .continuous).fill(Ink.plaster))
            }
            if game.over, let a = game.state["answer"].object["title"]?.string {
                Text("\(game.state["answer"]["artist"].string ?? "") — \(a)").font(.ui(15, .semibold)).foregroundStyle(Ink.ink)
            }
        }
        .onDisappear { stop() }
    }

    private var tileRedish: Color { Color(red: 150 / 255, green: 60 / 255, blue: 50 / 255) }
    private var nextGain: Int {
        let step = game.state["step"].int ?? 0
        return steps.indices.contains(step + 1) ? steps[step + 1] - steps[step] : 0
    }

    private func play() {
        if playing { stop(); return }
        guard let url = URL(string: game.state["preview"].string ?? "") else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        let p = AVPlayer(url: url)
        player = p
        p.seek(to: .zero)
        p.play()
        playing = true
        send(["played": true])
        let secs = seconds
        stopper?.cancel()
        stopper = Task {
            try? await Task.sleep(for: .seconds(Double(secs)))
            if !Task.isCancelled { stop() }
        }
    }

    private func stop() {
        stopper?.cancel()
        player?.pause()
        playing = false
    }
}

// MARK: - Twenty questions: the question, and yes or no

struct TwentyQBoard: View {
    let game: GameStatus.Game
    let accent: Color
    let send: ([String: Any]) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("\(game.state["number"].int ?? 1) of \(game.state["max"].int ?? 20)").font(.ui(12)).foregroundStyle(Ink.dim)
            Text(game.state["question"].string ?? (game.state["thinking"].bool == true ? "Thinking." : ""))
                .font(.display(24)).foregroundStyle(game.state["is_guess"].bool == true ? accent : Ink.ink)
                .multilineTextAlignment(.center).frame(minHeight: 90)
            if !game.over {
                HStack(spacing: 10) {
                    ActionPill(title: "Yes", filled: true) { send(["answer": "yes"]) }
                    ActionPill(title: "Sort of", filled: false) { send(["answer": "sort of"]) }
                    ActionPill(title: "No", filled: true) { send(["answer": "no"]) }
                }
                Text("Or knock once for yes, whistle for no.").font(.ui(12)).foregroundStyle(Ink.dim)
            }
            ForEach(Array(game.state["history"].array.reversed().prefix(8).enumerated()), id: \.offset) { _, h in
                HStack {
                    Text(h["q"].string ?? "").font(.ui(13)).foregroundStyle(Ink.dim)
                    Spacer()
                    Text(h["a"].string ?? "").font(.ui(13, .semibold)).foregroundStyle(Ink.ink)
                }
            }
        }
    }
}

// MARK: - Pub quiz: the question card

struct QuizBoard: View {
    let game: GameStatus.Game
    let accent: Color

    var body: some View {
        VStack(spacing: 12) {
            Text(game.state["theme"].string ?? "").font(.ui(12, .semibold)).foregroundStyle(Ink.dim)
            Text("Question \(game.state["number"].int ?? 1) of \(game.state["count"].int ?? 10)").font(.ui(12)).foregroundStyle(Ink.dim)
            Text(game.state["question"].string ?? "").font(.display(22)).foregroundStyle(Ink.ink)
                .multilineTextAlignment(.center).frame(minHeight: 80)
            if game.state["phase"].string == "question" {
                ProgressView(value: min(1, max(0, (game.state["seconds_left"].double ?? 0) / 20)))
                    .tint(accent)
            } else if let a = game.state["answer"].string {
                Text("Answer: \(a)").font(.ui(16, .semibold)).foregroundStyle(Ink.moss)
            }
            let scores = game.state["scores"].object
            HStack(spacing: 14) {
                ForEach(scores.keys.sorted(), id: \.self) { who in
                    Text("\(who) \(scores[who]?.int ?? 0)").font(.machine(13)).foregroundStyle(Ink.ink)
                }
            }
        }
    }
}

// MARK: - AI pictionary: the wall's picture and the clock

struct PictionaryBoard: View {
    @Environment(WallSession.self) private var wall
    let game: GameStatus.Game
    let accent: Color

    var body: some View {
        VStack(spacing: 10) {
            PanelCanvas(px: wall.frame.map { [UInt8]($0) }, duty: 1.0)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Round.card, style: .continuous))
            if game.state["drawing"].bool == true {
                Text("Drawing.").font(.ui(13)).foregroundStyle(Ink.dim)
            } else {
                ProgressView(value: 1 - min(1, (game.state["elapsed"].double ?? 0) / max(1, game.state["seconds"].double ?? 60))).tint(accent)
            }
            if let w = game.state["word"].string { Text("It was a \(w).").font(.ui(15, .semibold)).foregroundStyle(Ink.ink) }
        }
    }
}

// MARK: - The arcade

/// Tilt, read from the phone's motion, as a paddle position.
@Observable
final class Tilt {
    var y: Double = 0.5
    private let motion = CMMotionManager()

    func start(onChange: @escaping (Double) -> Void) {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 20.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let self, let m else { return }
            // pitch: phone flat is 0, tipped towards you is positive; a
            // quarter turn either way is the whole court
            let v = max(0, min(1, 0.5 + m.attitude.pitch / 1.2))
            if abs(v - self.y) > 0.01 { self.y = v; onChange(v) }
        }
    }

    func stop() { motion.stopDeviceMotionUpdates() }
}

struct PongBoard: View {
    @Environment(WallSession.self) private var wall
    let game: GameStatus.Game
    let accent: Color
    let send: ([String: Any]) -> Void
    @State private var tilt = Tilt()
    @State private var lastSent = Date.distantPast

    var body: some View {
        VStack(spacing: 12) {
            PanelCanvas(px: wall.frame.map { [UInt8]($0) }, duty: 1.0)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Round.card, style: .continuous))
            GeometryReader { geo in
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: Round.card, style: .continuous).fill(Ink.plaster)
                    RoundedRectangle(cornerRadius: Round.control).fill(accent).frame(width: 60, height: 12)
                        .offset(y: tilt.y * (geo.size.height - 12))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    let y = max(0, min(1, v.location.y / geo.size.height))
                    tilt.y = y
                    throttled(y)
                })
            }
            .frame(height: 140)
            let score = game.state["score"].ints
            Text("Tilt the phone, or slide. \(score.first ?? 0) to \(score.last ?? 0), first to \(game.state["to"].int ?? 7).")
                .font(.ui(12)).foregroundStyle(Ink.dim).multilineTextAlignment(.center)
            if game.over { ActionPill(title: "Again", filled: true) { send(["again": true]) } }
        }
        .onAppear { tilt.start { y in throttled(y) } }
        .onDisappear { tilt.stop() }
    }

    private func throttled(_ y: Double) {
        if Date().timeIntervalSince(lastSent) > 0.05 {
            lastSent = Date()
            send(["paddle": y])
        }
    }
}

struct SnakeBoard: View {
    @Environment(WallSession.self) private var wall
    let game: GameStatus.Game
    let accent: Color
    let send: ([String: Any]) -> Void

    var body: some View {
        VStack(spacing: 12) {
            PanelCanvas(px: wall.frame.map { [UInt8]($0) }, duty: 1.0)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Round.card, style: .continuous))
                .gesture(DragGesture(minimumDistance: 12).onEnded { v in
                    let dx = v.translation.width, dy = v.translation.height
                    send(["dir": abs(dx) > abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up")])
                })
            DPad(send: send)
            Text("Swipe or press. Score \(game.state["score"].int ?? 0).").font(.ui(12)).foregroundStyle(Ink.dim)
            if game.over { ActionPill(title: "Again", filled: true) { send(["again": true]) } }
        }
    }
}

struct DPad: View {
    let send: ([String: Any]) -> Void
    var body: some View {
        VStack(spacing: 6) {
            key("chevron.up", "up")
            HStack(spacing: 6) { key("chevron.left", "left"); key("chevron.down", "down"); key("chevron.right", "right") }
        }
    }
    private func key(_ symbol: String, _ dir: String) -> some View {
        Button { send(["dir": dir]) } label: {
            Image(systemName: symbol).font(.system(size: 20, weight: .bold)).foregroundStyle(Ink.ink)
                .frame(width: 64, height: 48)
                .background(RoundedRectangle(cornerRadius: Round.card, style: .continuous).fill(Ink.plaster))
        }
        .buttonStyle(PressStyle(scale: 0.92))
    }
}

struct TetrisBoard: View {
    @Environment(WallSession.self) private var wall
    let game: GameStatus.Game
    let accent: Color
    let send: ([String: Any]) -> Void

    var body: some View {
        VStack(spacing: 12) {
            PanelCanvas(px: wall.frame.map { [UInt8]($0) }, duty: 1.0)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Round.card, style: .continuous))
                .gesture(DragGesture(minimumDistance: 12).onEnded { v in
                    let dx = v.translation.width, dy = v.translation.height
                    if abs(dx) > abs(dy) { send(["move": dx > 0 ? "right" : "left"]) }
                    else { send(["move": dy > 0 ? "drop" : "rotate"]) }
                })
            HStack(spacing: 6) {
                pad("chevron.left", "left"); pad("arrow.clockwise", "rotate"); pad("chevron.right", "right")
                pad("chevron.down", "down"); pad("arrow.down.to.line", "drop")
            }
            Text("Score \(game.state["score"].int ?? 0)  ·  \(game.state["lines"].int ?? 0) lines  ·  level \(game.state["level"].int ?? 1)")
                .font(.ui(12)).foregroundStyle(Ink.dim)
            if game.over { ActionPill(title: "Again", filled: true) { send(["again": true]) } }
        }
    }

    private func pad(_ symbol: String, _ move: String) -> some View {
        Button { send(["move": move]) } label: {
            Image(systemName: symbol).font(.system(size: 18, weight: .bold)).foregroundStyle(Ink.ink)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(RoundedRectangle(cornerRadius: Round.card, style: .continuous).fill(Ink.plaster))
        }
        .buttonStyle(PressStyle(scale: 0.92))
    }
}
