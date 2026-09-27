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
