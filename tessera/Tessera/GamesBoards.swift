// The word games, drawn natively on the phone: the same board the wall
// shows, at a size a thumb can use. Every board takes the game's JSON
// state and a `send` that posts one move; the wall answers with the state
// and the screen redraws.

import SwiftUI

let tileGreen = Color(red: 83 / 255, green: 141 / 255, blue: 78 / 255)
let tileYellow = Color(red: 181 / 255, green: 159 / 255, blue: 59 / 255)
let tileBlue = Color(red: 72 / 255, green: 118 / 255, blue: 200 / 255)
let tilePurple = Color(red: 146 / 255, green: 96 / 255, blue: 180 / 255)
let tileRed = Color(red: 190 / 255, green: 60 / 255, blue: 50 / 255)

func groupColour(_ name: String?) -> Color {
    switch name {
    case "yellow": return tileYellow
    case "green": return tileGreen
    case "blue": return tileBlue
    case "purple": return tilePurple
    default: return Ink.plaster
    }
}

// MARK: - Contexto: the ranked guesses

struct ContextoBoard: View {
    let game: GameStatus.Game
    let accent: Color

    private func colour(_ r: Int) -> Color { r <= 300 ? tileGreen : r <= 1500 ? tileYellow : tileRed }

    var body: some View {
        VStack(spacing: 8) {
            if let last = game.state["last"].object["word"]?.string, let r = game.state["last"]["rank"].int {
                HStack {
                    Text(last.uppercased()).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Ink.ink)
                    Spacer()
                    Text(String(r)).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(colour(r))
                }
                .padding(.horizontal, 14).frame(minHeight: 52)
                .background(RoundedRectangle(cornerRadius: Round.card, style: .continuous).fill(colour(r).opacity(0.2)))
            }
            ForEach(Array(game.state["guesses"].array.prefix(12).enumerated()), id: \.offset) { _, g in
                let r = g["rank"].int ?? 0
                HStack {
                    Text(g["word"].string ?? "").font(.ui(15)).foregroundStyle(Ink.ink)
                    Spacer()
                    Text(String(r)).font(.machine(13)).foregroundStyle(colour(r))
                }
                .padding(.horizontal, 14).frame(minHeight: 36)
                .background(RoundedRectangle(cornerRadius: Round.control, style: .continuous).fill(Ink.plaster))
            }
            if let secret = game.state["secret"].string {
                Text("It was \(secret.uppercased()).").font(.ui(15, .semibold)).foregroundStyle(Ink.ink)
            }
        }
    }
}
