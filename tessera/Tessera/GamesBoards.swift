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

// MARK: - Sudoku: tap a cell, tap a digit

struct SudokuBoard: View {
    let game: GameStatus.Game
    let accent: Color
    let send: ([String: Any]) -> Void

    private var puzzle: [Character] { Array(game.state["puzzle"].string ?? "") }
    private var grid: [Character] { Array(game.state["grid"].string ?? "") }
    private var wrong: Set<Int> { Set(game.state["wrong"].ints) }
    private var chosen: Int? { game.state["chosen"].int }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 0) {
                ForEach(0..<9, id: \.self) { r in
                    HStack(spacing: 0) {
                        ForEach(0..<9, id: \.self) { c in
                            let i = r * 9 + c
                            let given = puzzle.indices.contains(i) && puzzle[i] != "0"
                            let v = grid.indices.contains(i) && grid[i] != "0" ? String(grid[i]) : ""
                            Text(v)
                                .font(.system(size: 20, weight: given ? .bold : .medium, design: .rounded))
                                .foregroundStyle(wrong.contains(i) ? tileRed : given ? Ink.ink : accent)
                                .frame(width: 38, height: 38)
                                .background(chosen == i ? accent.opacity(0.25) : Ink.plaster)
                                .overlay(alignment: .trailing) { Rectangle().fill(Ink.hairline).frame(width: c % 3 == 2 ? 2 : 0.5) }
                                .overlay(alignment: .bottom) { Rectangle().fill(Ink.hairline).frame(height: r % 3 == 2 ? 2 : 0.5) }
                                .contentShape(Rectangle())
                                .onTapGesture { if !given { send(["choose": i]) } }
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Ink.hairline, lineWidth: 1))
            HStack(spacing: 6) {
                ForEach(1...9, id: \.self) { d in
                    Button { if let i = chosen { send(["cell": i, "digit": d]) } } label: {
                        Text(String(d)).font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(Ink.ink).frame(maxWidth: .infinity, minHeight: 44)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ink.sunk))
                    }
                    .buttonStyle(PressStyle(scale: 0.92))
                }
                Button { if let i = chosen { send(["cell": i, "digit": 0]) } } label: {
                    Image(systemName: "delete.left").foregroundStyle(Ink.dim).frame(maxWidth: .infinity, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ink.sunk))
                }
                .buttonStyle(PressStyle(scale: 0.92))
            }
            Text((game.state["rating"].string ?? "").capitalized + "  ·  \(game.state["left"].int ?? 0) to fill")
                .font(.ui(12)).foregroundStyle(Ink.dim)
        }
    }
}

// MARK: - Connections: tap four, submit

struct ConnectionsBoard: View {
    let game: GameStatus.Game
    let accent: Color
    let send: ([String: Any]) -> Void

    private var words: [String] { game.state["words"].strings }
    private var picked: [String] { game.state["picked"].strings }
    private var found: [JSONValue] { game.state["found"].array }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(found.enumerated()), id: \.offset) { _, g in
                VStack(spacing: 2) {
                    Text((g["theme"].string ?? "").uppercased()).font(.system(size: 13, weight: .bold, design: .rounded))
                    Text(g["words"].strings.joined(separator: ", ")).font(.ui(12))
                }
                .foregroundStyle(Ink.ground)
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(groupColour(g["colour"].string)))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(words, id: \.self) { w in
                    let on = picked.contains(w)
                    Text(w.uppercased())
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.6).lineLimit(2).multilineTextAlignment(.center)
                        .foregroundStyle(on ? Ink.ground : Ink.ink)
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Ink.ink : Ink.plaster))
                        .contentShape(Rectangle())
                        .onTapGesture { send(["pick": w]) }
                }
            }
            HStack(spacing: 10) {
                ActionPill(title: "Shuffle", filled: false) { send(["shuffle": true]) }
                ActionPill(title: "Clear", filled: false) { send(["clear": true]) }
                ActionPill(title: "Submit", filled: picked.count == 4) { if picked.count == 4 { send(["submit": true]) } }
            }
            HStack(spacing: 6) {
                Text("Mistakes left").font(.ui(12)).foregroundStyle(Ink.dim)
                ForEach(0..<4, id: \.self) { i in
                    Circle().fill(i < (game.state["mistakes_left"].int ?? 4) ? Ink.ink : Ink.faint).frame(width: 8, height: 8)
                }
            }
        }
    }
}

// MARK: - Spelling Bee: the hive

struct SpellingBeeBoard: View {
    let game: GameStatus.Game
    let accent: Color
    let send: ([String: Any]) -> Void
    @State private var word = ""

    private var centre: String { game.state["centre"].string ?? "" }
    private var letters: [String] { (game.state["letters"].string ?? "").map { String($0) } }

    var body: some View {
        VStack(spacing: 14) {
            Text(word.uppercased()).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(Ink.ink)
                .frame(minHeight: 34)
            ZStack {
                ForEach(Array(letters.enumerated()), id: \.offset) { i, ch in
                    // a honeycomb: six cells round the centre, flat sides touching
                    let a = Double(i) * .pi / 3 + .pi / 6
                    hex(ch, fill: Ink.plaster, ink: Ink.ink).offset(x: cos(a) * 82, y: sin(a) * 82)
                }
                hex(centre, fill: tileYellow, ink: Ink.ground)
            }
            .frame(height: 250)
            HStack(spacing: 10) {
                ActionPill(title: "Delete", filled: false) { if !word.isEmpty { word.removeLast() } }
                ActionPill(title: "Enter", filled: true) {
                    if word.count >= 4 { send(["word": word]); word = "" }
                }
            }
            let found = game.state["found"].array.compactMap { $0["word"].string }
            HStack {
                Text("\(game.state["rank"].string ?? "Beginner")  ·  \(game.state["points"].int ?? 0) points  ·  \(found.count) of \(game.state["count"].int ?? 0)")
                    .font(.ui(12)).foregroundStyle(Ink.dim)
            }
            if !found.isEmpty {
                Text(found.map { $0.uppercased() }.joined(separator: "  "))
                    .font(.ui(12)).foregroundStyle(Ink.ink).multilineTextAlignment(.center)
            }
        }
    }

    private func hex(_ ch: String, fill: Color, ink: Color) -> some View {
        Button { word += ch } label: {
            Text(ch.uppercased()).font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(ink)
                .frame(width: 88, height: 88)
                .background(HexagonShape().fill(fill))
                .contentShape(HexagonShape())
        }
        .buttonStyle(PressStyle(scale: 0.9))
    }
}

/// A pointy-top hexagon that fills its frame.
struct HexagonShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX, cy = rect.midY
        let r = min(rect.width, rect.height) / 2
        var p = Path()
        for k in 0..<6 {
            let a = Double(k) * .pi / 3 - .pi / 2
            let pt = CGPoint(x: cx + CGFloat(cos(a)) * r, y: cy + CGFloat(sin(a)) * r)
            if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

// MARK: - Letter Boxed: the square

struct LetterBoxedBoard: View {
    let game: GameStatus.Game
    let accent: Color
    let send: ([String: Any]) -> Void
    @State private var word = ""

    private var sides: [String] { game.state["sides"].strings }
    private var used: Set<String> { Set(game.state["used"].strings) }
    private var words: [String] { game.state["words"].strings }

    var body: some View {
        VStack(spacing: 12) {
            Text(word.uppercased()).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(Ink.ink)
                .frame(minHeight: 34)
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height) - 60
                let x0 = (geo.size.width - side) / 2, y0 = 30.0
                ZStack {
                    Rectangle().stroke(Ink.dim, lineWidth: 2).frame(width: side, height: side).position(x: x0 + side / 2, y: y0 + side / 2)
                    ForEach(Array(sides.enumerated()), id: \.offset) { si, s in
                        ForEach(Array(s.enumerated()), id: \.offset) { k, ch in
                            let f = CGFloat(k + 1) / 4
                            let p: CGPoint = si == 0 ? CGPoint(x: x0 + side * f, y: y0)
                                : si == 1 ? CGPoint(x: x0 + side, y: y0 + side * f)
                                : si == 2 ? CGPoint(x: x0 + side * f, y: y0 + side)
                                : CGPoint(x: x0, y: y0 + side * f)
                            let label = String(ch)
                            Button { word += label } label: {
                                Text(label.uppercased()).font(.system(size: 20, weight: .bold, design: .rounded))
                                    .foregroundStyle(used.contains(label) ? Ink.ground : Ink.ink)
                                    .frame(width: 40, height: 40)
                                    .background(Circle().fill(used.contains(label) ? Ink.ink : Ink.plaster))
                            }
                            .buttonStyle(PressStyle(scale: 0.9))
                            .position(p)
                        }
                    }
                }
            }
            .frame(height: 300)
            HStack(spacing: 10) {
                ActionPill(title: "Undo word", filled: false) { send(["undo": true]) }
                ActionPill(title: "Delete", filled: false) { if !word.isEmpty { word.removeLast() } }
                ActionPill(title: "Enter", filled: true) { if word.count >= 3 { send(["word": word]); word = "" } }
            }
            Text(words.isEmpty ? "Try it in \(game.state["par"].int ?? 2)." : words.map { $0.uppercased() }.joined(separator: " → "))
                .font(.ui(13)).foregroundStyle(Ink.dim).multilineTextAlignment(.center)
        }
    }
}

// MARK: - Strands: trace a word

struct StrandsBoard: View {
    let game: GameStatus.Game
    let accent: Color
    let send: ([String: Any]) -> Void
    @State private var trace: [Int] = []

    private var rows: [String] { game.state["rows"].strings }
    private var cols: Int { rows.first?.count ?? 6 }

    private func colourOf(_ r: Int, _ c: Int) -> Color? {
        for f in game.state["found"].array {
            for cell in f["path"].array where cell[0].int == r && cell[1].int == c {
                return f["spangram"].bool == true ? tileYellow : tileBlue
            }
        }
        for cell in game.state["hint"].array where cell[0].int == r && cell[1].int == c {
            return tileYellow.opacity(0.35)
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(game.state["theme"].string ?? "").font(.ui(15, .semibold)).foregroundStyle(Ink.ink)
            Text(traced.uppercased()).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Ink.ink).frame(minHeight: 30)
            GeometryReader { geo in
                let cell = geo.size.width / CGFloat(cols)
                ZStack {
                    ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                        ForEach(Array(row.enumerated()), id: \.offset) { c, ch in
                            let i = r * cols + c
                            let on = trace.contains(i)
                            Text(String(ch).uppercased())
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundStyle(on || colourOf(r, c) != nil ? Ink.ground : Ink.ink)
                                .frame(width: cell - 6, height: cell - 6)
                                .background(Circle().fill(on ? accent : (colourOf(r, c) ?? Ink.plaster)))
                                .position(x: cell * (CGFloat(c) + 0.5), y: cell * (CGFloat(r) + 0.5))
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let c = Int(v.location.x / cell), r = Int(v.location.y / cell)
                        guard r >= 0, r < rows.count, c >= 0, c < cols else { return }
                        let i = r * cols + c
                        if let last = trace.last, last == i { return }
                        if trace.count >= 2, trace[trace.count - 2] == i { trace.removeLast(); return }
                        if !trace.contains(i) {
                            if let last = trace.last {
                                let (lr, lc) = (last / cols, last % cols)
                                guard abs(lr - r) <= 1 && abs(lc - c) <= 1 else { return }
                            }
                            trace.append(i)
                        }
                    }
                    .onEnded { _ in
                        if traced.count >= 4 { send(["word": traced]) }
                        trace = []
                    })
            }
            .aspectRatio(CGFloat(cols) / CGFloat(max(1, rows.count)), contentMode: .fit)
            HStack(spacing: 10) {
                ActionPill(title: "Hint", filled: false) { send(["hint": true]) }
                Text("\(game.state["left"].int ?? 0) to find  ·  \(game.state["extra"].array.count) extra")
                    .font(.ui(12)).foregroundStyle(Ink.dim)
            }
        }
    }

    private var traced: String {
        trace.map { i in
            let r = i / cols, c = i % cols
            return rows.indices.contains(r) ? String(Array(rows[r])[c]) : ""
        }.joined()
    }
}

// MARK: - Mini crossword: the grid and the clues

struct CrosswordBoard: View {
    let game: GameStatus.Game
    let accent: Color
    let send: ([String: Any]) -> Void
    @State private var entry = ""

    private var grid: [[String]] { game.state["grid"].array.map { $0.strings } }
    private var slots: [JSONValue] { game.state["slots"].array }
    private var chosen: String? { game.state["chosen"].string }
    private var wrong: Set<String> { Set(game.state["wrong"].array.map { "\($0[0].int ?? -1),\($0[1].int ?? -1)" }) }
    private var lit: Set<String> {
        guard let s = slots.first(where: { $0["id"].string == chosen }) else { return [] }
        return Set(s["cells"].array.map { "\($0[0].int ?? -1),\($0[1].int ?? -1)" })
    }

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                ForEach(Array(grid.enumerated()), id: \.offset) { r, row in
                    HStack(spacing: 2) {
                        ForEach(Array(row.enumerated()), id: \.offset) { c, v in
                            let key = "\(r),\(c)"
                            let n = slots.first(where: { $0["cells"][0][0].int == r && $0["cells"][0][1].int == c })?["n"].int
                            ZStack(alignment: .topLeading) {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(v == "#" ? Ink.ground : lit.contains(key) ? accent.opacity(0.3) : Ink.plaster)
                                if v != "#" {
                                    Text(v.uppercased()).font(.system(size: 22, weight: .bold, design: .rounded))
                                        .foregroundStyle(wrong.contains(key) ? tileRed : Ink.ink)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    if let n { Text(String(n)).font(.system(size: 9, weight: .semibold)).foregroundStyle(Ink.dim).padding(3) }
                                }
                            }
                            .frame(width: 62, height: 62)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if v != "#", let s = slots.first(where: { $0["cells"].array.contains { $0[0].int == r && $0[1].int == c } }),
                                   let id = s["id"].string { send(["choose": id]) }
                            }
                        }
                    }
                }
            }
            if let s = slots.first(where: { $0["id"].string == chosen }) {
                HStack(spacing: 10) {
                    TextField("\(s["id"].string ?? "")  \(s["cells"].array.count) letters", text: $entry)
                        .font(.machine(17)).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .onSubmit { enter() }
                        .padding(.horizontal, 14).frame(minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.plaster))
                    ActionPill(title: "Enter", filled: true) { enter() }
                    ActionPill(title: "Check", filled: false) { send(["check": true]) }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(["across", "down"], id: \.self) { dir in
                    Text(dir.capitalized).font(.ui(12, .semibold)).foregroundStyle(Ink.dim)
                    ForEach(Array(slots.filter { $0["dir"].string == dir }.enumerated()), id: \.offset) { _, s in
                        let id = s["id"].string ?? ""
                        Text("\(s["n"].int ?? 0). \(s["clue"].string ?? "")")
                            .font(.ui(14, chosen == id ? .semibold : .regular))
                            .foregroundStyle(chosen == id ? Ink.ink : Ink.dim)
                            .contentShape(Rectangle())
                            .onTapGesture { send(["choose": id]) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func enter() {
        let w = entry.trimmingCharacters(in: .whitespaces).lowercased()
        guard !w.isEmpty, let id = chosen else { return }
        send(["slot": id, "word": w])
        entry = ""
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
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(colour(r).opacity(0.2)))
            }
            ForEach(Array(game.state["guesses"].array.prefix(12).enumerated()), id: \.offset) { _, g in
                let r = g["rank"].int ?? 0
                HStack {
                    Text(g["word"].string ?? "").font(.ui(15)).foregroundStyle(Ink.ink)
                    Spacer()
                    Text(String(r)).font(.machine(13)).foregroundStyle(colour(r))
                }
                .padding(.horizontal, 14).frame(minHeight: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.plaster))
            }
            if let secret = game.state["secret"].string {
                Text("It was \(secret.uppercased()).").font(.ui(15, .semibold)).foregroundStyle(Ink.ink)
            }
        }
    }
}
