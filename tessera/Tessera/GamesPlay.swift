// The games that are played with the body, the ear or a clip: Heardle's
// player, the sliding tiles, the reaction button, the whistle bird's
// slider, the yes and no of twenty questions, the quiz card, the arcade's
// paddles and remotes. Each takes the game's JSON state and a `send`.

import SwiftUI
import AVFoundation
import CoreMotion

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
