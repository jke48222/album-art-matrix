import SwiftUI

private enum PuzzleInk {
    static let ground = Color(hex: 0x0B0A09)
    static let exact = Color(hex: 0x4E9654)
    static let elsewhere = Color(hex: 0xC4A638)
    static let absent = Color(hex: 0x2E2D2B)
    static let empty = Color(hex: 0x161513)
    static let current = Color(hex: 0x1A1C19)
    static let darkLetter = Color(hex: 0x0A140C)
    static let green = Color(hex: 0xA3CF9B)
    static let blue = Color(hex: 0xA2D3F0)
    static let grid = Color(hex: 0x16181B)
    static let rule = Color(hex: 0x363E45)
    static let boxRule = Color(hex: 0x747E86)
    static let entry = Color(hex: 0x9DCDE7)
    static let error = Color(hex: 0xE04C3F)
}

/// The same centered five-column composition as Wordle.frame_at. Input stays
/// outside the artwork; only an acknowledged row clears the local draft.
struct WordleBoard: View {
    let game: GameStatus.Game
    let accent: Color
    let send: ([String: Any]) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var typed = ""
    @State private var submitted: String?
    @State private var revealRow: Int?
    @State private var revealedColumns = 5
    @State private var revealTask: Task<Void, Never>?

    private struct Row {
        let letters: [Character]
        let marks: [Character]
        var word: String { String(letters) }
    }
    private var rows: [Row] {
        game.state["rows"].array.prefix(6).compactMap { row in
            guard let word = row["word"].string, let marks = row["marks"].string,
                  word.count == 5, marks.count == 5 else { return nil }
            return Row(letters: Array(word.uppercased()), marks: Array(marks))
        }
    }
    private var keys: [String: String] { game.state["keys"].object.compactMapValues(\.string) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(game.over ? (game.won ? "FOUND IN \(rows.count)" : "SIX GUESSES") : "GUESS \(min(rows.count + 1, 6)) OF 6")
                    .font(.machine(10)).tracking(0.7).foregroundStyle(PuzzleInk.green)
                Spacer()
                if !game.over, game.players.count > 1, let turn = game.state["turn"].string {
                    Text("\(turn)’s turn").font(.ui(13, .semibold)).foregroundStyle(Ink.dim)
                }
            }
            grid
            legend
            if !game.over { keyboard }
            else if let answer = game.state["answer"].string {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("THE WORD").font(.machine(10)).foregroundStyle(Ink.dim)
                    Text(answer.uppercased()).font(.display(30)).tracking(3).foregroundStyle(PuzzleInk.green)
                }.accessibilityElement(children: .combine)
            }
        }
        .onChange(of: rows.count) { oldCount, newCount in
            guard newCount > oldCount else { return }
            if let submitted, rows.dropFirst(oldCount).contains(where: { $0.word.lowercased() == submitted }) {
                if typed.lowercased() == submitted { typed = "" }
                self.submitted = nil
            }
            revealTask?.cancel()
            if reducedMotion { revealRow = nil; revealedColumns = 5 }
            else {
                revealRow = newCount - 1; revealedColumns = 0
                revealTask = Task { @MainActor in
                    for count in 1...5 {
                        try? await Task.sleep(for: .milliseconds(count == 1 ? 210 : 140))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.2)) { revealedColumns = count }
                    }
                }
            }
            if let last = rows.last { UIAccessibility.post(notification: .announcement, argument: rowDescription(last, index: newCount - 1)) }
        }
        .onDisappear { revealTask?.cancel(); revealRow = nil; revealedColumns = 5 }
        .onAppear {
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "-wordle-draft"), index + 1 < arguments.count {
                typed = String(arguments[index + 1].uppercased().filter { $0.isASCII && $0.isLetter }.prefix(5))
            }
            #endif
        }
    }

    private var grid: some View {
        GeometryReader { geometry in
            let side = geometry.size.width
            let cell = (side * 9 / 64).rounded(.down)
            let gap = (side / 64).rounded(.down)
            let width = cell * 5 + gap * 4
            let height = cell * 6 + gap * 5
            VStack(spacing: gap) {
                ForEach(0..<6, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<5, id: \.self) { column in
                            let filled = row < rows.count
                            let draft = Array(typed)
                            let letter = filled ? String(rows[row].letters[column]) : row == rows.count && column < draft.count ? String(draft[column]) : ""
                            let revealed = row != revealRow || column < revealedColumns
                            let mark: Character? = filled && revealed ? rows[row].marks[column] : nil
                            WordleTile(letter: letter, mark: mark, current: row == rows.count && !game.over, side: cell)
                        }
                    }.accessibilityElement(children: .ignore)
                        .accessibilityLabel(row < rows.count ? rowDescription(rows[row], index: row) : row == rows.count && !game.over ? "Current guess: \(typed.isEmpty ? "empty" : typed)" : "Guess \(row + 1), empty")
                }
            }.frame(width: width, height: height)
                .overlay(alignment: .top) {
                    if game.over { Rectangle().fill(game.won ? PuzzleInk.green : PuzzleInk.elsewhere).frame(height: 2).offset(y: -gap) }
                }
                .position(x: side / 2, y: side / 2)
        }.aspectRatio(1, contentMode: .fit).background(PuzzleInk.ground)
    }

    private var legend: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            legendItem("g", "Right spot")
            legendItem("y", "Elsewhere")
            legendItem("x", "No more")
        }.frame(maxWidth: .infinity, alignment: .center)
    }

    private func legendItem(_ mark: Character, _ text: String) -> some View {
        HStack(spacing: 7) {
            WordleMark(mark: mark).foregroundStyle(mark == "g" ? PuzzleInk.green : mark == "y" ? PuzzleInk.elsewhere : Ink.dim).frame(width: 12, height: 6)
            Text(text).font(.ui(12, .medium)).foregroundStyle(Ink.dim)
        }.accessibilityElement(children: .combine)
            .accessibilityLabel(mark == "g" ? "Solid line: correct position" : mark == "y" ? "Two dots: in another position" : "Dash: no remaining copies of this letter")
    }

    private var keyboard: some View {
        VStack(spacing: 8) {
            if typeSize.isAccessibilitySize {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                    ForEach(Array("QWERTYUIOPASDFGHJKLZXCVBNM"), id: \.self) { key in keyButton(key) }
                }
            } else {
                ForEach(["QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM"], id: \.self) { row in
                    HStack(spacing: 4) { ForEach(Array(row), id: \.self) { key in keyButton(key) } }
                        .padding(.horizontal, row.count == 9 ? 12 : row.count == 7 ? 35 : 0)
                }
            }
            HStack(spacing: 10) {
                Button {
                    guard typed.count == 5 else { return }
                    submitted = typed.lowercased()
                    send(["guess": typed.lowercased()])
                } label: {
                    HStack(spacing: 9) { Text("Enter guess"); Image(systemName: "return").font(.system(size: 14, weight: .semibold)) }
                        .font(.ui(16, .semibold)).foregroundStyle(PuzzleInk.darkLetter).frame(maxWidth: .infinity, minHeight: 52)
                        .background(PuzzleInk.green.opacity(typed.count == 5 ? 1 : 0.45), in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(PressStyle()).disabled(typed.count != 5)
                Button { if !typed.isEmpty { typed.removeLast(); Taps.detent(intensity: 0.3) } } label: {
                    Image(systemName: "delete.left").font(.system(size: 21)).foregroundStyle(Ink.ink).frame(width: 60, height: 52)
                        .background(Ink.plaster, in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(PressStyle()).disabled(typed.isEmpty).accessibilityLabel("Delete last letter")
            }.padding(.top, 3)
        }
    }

    private func keyButton(_ letter: Character) -> some View {
        let mark = keys[String(letter).lowercased()]?.first
        return Button {
            guard typed.count < 5 else { return }
            typed.append(letter); Taps.detent(intensity: 0.22)
        } label: {
            VStack(spacing: 4) {
                Text(String(letter)).font(.ui(typeSize.isAccessibilitySize ? 19 : 17, .semibold))
                if let mark { WordleMark(mark: mark).frame(width: 10, height: 3) }
                else { Color.clear.frame(height: 3) }
            }.foregroundStyle(mark == "g" || mark == "y" ? PuzzleInk.darkLetter : mark == "x" ? Ink.dim : Ink.ink)
                .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 62 : 48)
                .background(WordleTile.colour(mark), in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(PressStyle(scale: 0.97)).disabled(typed.count >= 5)
            .accessibilityLabel("\(String(letter)), \(Self.markDescription(mark))")
    }

    private static func markDescription(_ mark: Character?) -> String {
        switch mark { case "g": "correct position"; case "y": "in another position"; case "x": "no remaining copies"; default: "not tried" }
    }

    private func rowDescription(_ row: Row, index: Int) -> String {
        "Guess \(index + 1), \(row.word). " + zip(row.letters, row.marks).map { "\($0.0), \(Self.markDescription($0.1))" }.joined(separator: ". ")
    }
}

private struct WordleTile: View {
    let letter: String
    let mark: Character?
    let current: Bool
    let side: CGFloat
    static func colour(_ mark: Character?) -> Color {
        switch mark { case "g": PuzzleInk.exact; case "y": PuzzleInk.elsewhere; case "x": PuzzleInk.absent; default: PuzzleInk.empty }
    }
    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: max(2, side / 12)).fill(mark == nil && current ? PuzzleInk.current : Self.colour(mark))
            if mark == nil { RoundedRectangle(cornerRadius: max(2, side / 12)).strokeBorder(current ? Color(hex: 0x6E826C) : Color(hex: 0x3B3933), lineWidth: 1) }
            Text(letter).font(.custom(Face.display, fixedSize: side * 0.64))
                .foregroundStyle(mark == "g" || mark == "y" ? PuzzleInk.darkLetter : Ink.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let mark {
                WordleMark(mark: mark).foregroundStyle(mark == "x" ? Ink.ink : PuzzleInk.darkLetter)
                    .frame(width: side * 0.5, height: max(2, side / 25)).padding(.bottom, max(2, side / 15))
            }
        }.frame(width: side, height: side).accessibilityHidden(true)
    }
}

private struct WordleMark: View {
    let mark: Character
    var body: some View {
        GeometryReader { geometry in
            if mark == "y" {
                HStack { Circle().frame(width: geometry.size.height); Spacer(minLength: 0); Circle().frame(width: geometry.size.height) }
            } else { Capsule().frame(width: geometry.size.width * (mark == "x" ? 0.45 : 1)).frame(maxWidth: .infinity) }
        }
    }
}

struct SudokuBoard: View {
    let game: GameStatus.Game
    let accent: Color
    let send: ([String: Any]) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var pencil = false
    private var puzzle: [Character] { Array(game.state["puzzle"].string ?? "") }
    private var grid: [Character] { Array(game.state["grid"].string ?? "") }
    private var wrong: Set<Int> { Set(game.state["wrong"].ints) }
    private var chosen: Int? { game.state["chosen"].int.flatMap { (0..<81).contains($0) ? $0 : nil } }
    private var notes: [String: JSONValue] { game.state["notes"].object }
    private var editable: Bool { !game.over && chosen.map { !given($0) } == true }
    private var remaining: Int { game.state["remaining"].int ?? (game.state["left"].int ?? 0) + wrong.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text((game.state["rating"].string ?? "Sudoku").uppercased()).font(.machine(10)).tracking(0.8).foregroundStyle(PuzzleInk.blue)
                Spacer()
                Text(game.over ? "81 IN HARMONY" : "\(remaining) TO SOLVE").font(.machine(10)).foregroundStyle(Ink.dim)
            }
            board
            selection
            if !game.over {
                tools
                keypad
            }
            Text("Each row, column and outlined box needs 1–9, once each.")
                .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var board: some View {
        GeometryReader { geometry in
            let side = geometry.size.width
            let cell = side / 9
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<9, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<9, id: \.self) { column in
                                cellButton(row * 9 + column, size: cell)
                            }
                        }
                    }
                }
                Path { path in
                    for line in 0...9 where line % 3 != 0 {
                        let position = CGFloat(line) * cell
                        path.move(to: CGPoint(x: position, y: 0)); path.addLine(to: CGPoint(x: position, y: side))
                        path.move(to: CGPoint(x: 0, y: position)); path.addLine(to: CGPoint(x: side, y: position))
                    }
                }.stroke(PuzzleInk.rule, lineWidth: 0.6).allowsHitTesting(false)
                Path { path in
                    for line in stride(from: 0, through: 9, by: 3) {
                        let position = min(side - 1, max(1, CGFloat(line) * cell))
                        path.move(to: CGPoint(x: position, y: 0)); path.addLine(to: CGPoint(x: position, y: side))
                        path.move(to: CGPoint(x: 0, y: position)); path.addLine(to: CGPoint(x: side, y: position))
                    }
                }.stroke(game.over ? PuzzleInk.green : PuzzleInk.boxRule, lineWidth: 1.5).allowsHitTesting(false)
                if let chosen, !game.over {
                    Rectangle().strokeBorder(PuzzleInk.blue, lineWidth: 2).frame(width: cell, height: cell)
                        .offset(x: CGFloat(chosen % 9) * cell, y: CGFloat(chosen / 9) * cell).allowsHitTesting(false)
                }
            }
        }.aspectRatio(1, contentMode: .fit)
    }

    private func cellButton(_ index: Int, size: CGFloat) -> some View {
        let value = value(index)
        let fixed = given(index)
        let marks = notes[String(index)]?.ints ?? []
        return Button { guard !game.over else { return }; send(["choose": index]); Taps.detent(intensity: 0.22) } label: {
            ZStack(alignment: .bottom) {
                Rectangle().fill(background(index))
                if value != "0" {
                    Text(value).font(.custom(fixed ? Face.uiSemibold : Face.ui, fixedSize: size * 0.59))
                        .foregroundStyle(wrong.contains(index) ? PuzzleInk.error : fixed ? Color(hex: 0xFCFAF6) : PuzzleInk.entry)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if wrong.contains(index) { Rectangle().fill(Color(hex: 0xFFA78F)).frame(width: size * 0.55, height: 2).padding(.bottom, 3) }
                } else if !marks.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(0..<3, id: \.self) { row in
                            HStack(spacing: 0) {
                                ForEach(1...3, id: \.self) { column in
                                    let digit = row * 3 + column
                                    Text(marks.contains(digit) ? String(digit) : " ")
                                        .font(.custom(Face.uiMedium, fixedSize: max(8, size * 0.22))).foregroundStyle(Color(hex: 0x87A2B5))
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                        }
                    }.padding(3)
                }
            }.frame(width: size, height: size).contentShape(Rectangle())
        }.buttonStyle(.plain).allowsHitTesting(!game.over)
            .accessibilityRemoveTraits(game.over ? .isButton : [])
            .accessibilityLabel("Row \(index / 9 + 1), column \(index % 9 + 1)")
            .accessibilityValue(cellDescription(index))
            .accessibilityHint(game.over ? "Completed puzzle." : fixed ? "Given number. Select to highlight matching numbers." : "Select this cell, then choose a number below.")
            .accessibilityAddTraits(chosen == index ? .isSelected : [])
    }

    private var selection: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: chosen.map { wrong.contains($0) } == true ? "exclamationmark.circle" : "scope")
                .font(.system(size: 21)).foregroundStyle(PuzzleInk.blue).frame(width: 26).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(selectionTitle).font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                Text(selectionDetail).font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !game.over {
                Button { selectNext() } label: {
                    Image(systemName: "arrow.right").font(.system(size: 16, weight: .semibold)).foregroundStyle(PuzzleInk.blue)
                        .frame(width: 44, height: 44).background(PuzzleInk.blue.opacity(0.08), in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("Select next empty cell")
            }
        }.padding(16).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 18))
    }

    private var selectionTitle: String {
        if game.over { return "A complete picture." }
        guard let chosen else { return "Find your first number." }
        return "Row \(chosen / 9 + 1) · Column \(chosen % 9 + 1)"
    }
    private var selectionDetail: String {
        if game.over { return "Every row, column and box is complete." }
        guard let chosen else { return "Tap a cell or use the arrow to begin." }
        if given(chosen) { return "A given number. Choose an empty cell to add your own." }
        if wrong.contains(chosen) { return "Underlined means incorrect. Try another number, erase or undo." }
        let marks = notes[String(chosen)]?.ints ?? []
        if !marks.isEmpty { return "Pencil notes: " + marks.map(String.init).joined(separator: ", ") }
        return pencil ? "Pencil is on. Tap numbers to keep or remove possibilities." : "Choose a number below. You can always undo it."
    }

    private var tools: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            tool(pencil ? "Pencil on" : "Pencil", symbol: "pencil.tip", active: pencil, enabled: true) { pencil.toggle(); Taps.detent(intensity: 0.3) }
            tool("Erase", symbol: "eraser", active: false, enabled: editable && chosen.map { value($0) != "0" || !(notes[String($0)]?.ints ?? []).isEmpty } == true) {
                if let chosen { send(["cell": chosen, "digit": 0]) }
            }
            tool("Undo", symbol: "arrow.uturn.backward", active: false, enabled: game.state["can_undo"].bool == true) { send(["undo": true]) }
        }
    }

    private func tool(_ title: String, symbol: String, active: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.ui(14, .semibold)).foregroundStyle(active ? Ink.ground : enabled ? Ink.ink : Ink.dim)
                .padding(.horizontal, 11).frame(maxWidth: .infinity, minHeight: 48)
                .background(active ? PuzzleInk.blue : Ink.plaster, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(PressStyle()).disabled(!enabled).accessibilityAddTraits(active ? .isSelected : [])
    }

    private var keypad: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(1...9, id: \.self) { number in
                let remaining = max(0, 9 - grid.enumerated().filter { String($0.element) == String(number) && !wrong.contains($0.offset) }.count)
                let noted = chosen.map { notes[String($0)]?.ints.contains(number) == true } == true
                Button {
                    guard let chosen else { return }
                    send(pencil ? ["cell": chosen, "note": number] : ["cell": chosen, "digit": number])
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(String(number)).font(.display(28))
                        if pencil { Image(systemName: noted ? "checkmark" : "plus").font(.system(size: 10, weight: .semibold)) }
                        else { Text(remaining == 0 ? "done" : "\(remaining) left").font(.ui(11)) }
                    }.foregroundStyle(noted && pencil ? Ink.ground : PuzzleInk.blue)
                        .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 72 : 58)
                        .background(noted && pencil ? PuzzleInk.blue : Color(hex: 0x182129), in: RoundedRectangle(cornerRadius: 14))
                        .opacity(editable ? 1 : 0.5)
                }.buttonStyle(PressStyle()).disabled(!editable || pencil && chosen.map { value($0) != "0" } == true)
                    .accessibilityLabel(pencil ? "\(noted ? "Remove" : "Add") pencil note \(number)" : "Enter \(number)")
                    .accessibilityValue(pencil ? "" : "\(remaining) remaining")
            }
        }
    }

    private func given(_ index: Int) -> Bool { puzzle.indices.contains(index) && puzzle[index] != "0" }
    private func value(_ index: Int) -> String { grid.indices.contains(index) ? String(grid[index]) : "0" }
    private func cellDescription(_ index: Int) -> String {
        let digit = value(index)
        if digit != "0" { return "\(digit), \(given(index) ? "given" : wrong.contains(index) ? "incorrect, underlined" : "your entry")" }
        let marks = notes[String(index)]?.ints ?? []
        return marks.isEmpty ? "Empty" : "Pencil notes " + marks.map(String.init).joined(separator: ", ")
    }
    private func background(_ index: Int) -> Color {
        guard let chosen, !game.over else { return PuzzleInk.grid }
        if chosen == index { return Color(hex: 0x2B4355) }
        if value(chosen) != "0", value(index) == value(chosen) { return Color(hex: 0x263541) }
        if index / 27 == chosen / 27 && index % 9 / 3 == chosen % 9 / 3 { return Color(hex: 0x202831) }
        if index / 9 == chosen / 9 || index % 9 == chosen % 9 { return Color(hex: 0x1D242C) }
        return PuzzleInk.grid
    }
    private func selectNext() {
        let start = chosen ?? -1
        for offset in 1...81 {
            let index = (start + offset) % 81
            if !given(index) && (value(index) == "0" || wrong.contains(index)) { send(["choose": index]); return }
        }
    }
}
