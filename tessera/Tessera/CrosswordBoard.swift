import SwiftUI

private enum CrosswordInk {
    static let ground = Color(hex: 0x0B0A09)
    static let square = Color(hex: 0x1C2022)
    static let block = Color(hex: 0x0E0D0B)
    static let word = Color(hex: 0x25343B)
    static let selected = Color(hex: 0x365B66)
    static let rule = Color(hex: 0x65727A)
    static let number = Color(hex: 0xBBC9CF)
    static let cursor = Color(hex: 0xA2D3F0)
    static let wrong = Color(hex: 0xEC6959)
    static let solved = Color(hex: 0xA3CF9B)
}

/// Selection and letters are authoritative on the wall. Drafts belong to a
/// clue and survive changing direction, failed requests, and polling updates.
struct CrosswordBoard: View {
    let game: GameStatus.Game
    let accent: Color
    let send: ([String: Any]) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var drafts: [String: String] = [:]
    @State private var pending: Pending?
    @State private var letterMode = false
    @State private var showClues = true
    @State private var clearClue: Clue?
    @FocusState private var entering: Bool

    private struct Cell: Hashable {
        let row: Int
        let column: Int
        var pair: [Int] { [row, column] }
        init(_ row: Int, _ column: Int) { self.row = row; self.column = column }
        init?(_ value: JSONValue) {
            let pair = value.ints
            guard pair.count == 2, (0..<5).contains(pair[0]), (0..<5).contains(pair[1]) else { return nil }
            self.init(pair[0], pair[1])
        }
    }
    private struct Clue: Identifiable {
        let id: String
        let number: Int
        let direction: String
        let text: String
        let cells: [Cell]
        var title: String { "\(number) \(direction)" }
    }
    private struct Pending {
        let token: String
        let clueID: String
        let word: String?
        let letter: String?
        let move: [String: Any]
    }

    private var grid: [[String]] { game.state["grid"].array.map(\.strings) }
    private var validGrid: Bool { grid.count == 5 && grid.allSatisfy { $0.count == 5 } }
    private var clues: [Clue] {
        game.state["slots"].array.compactMap { value in
            guard let id = value["id"].string, let number = value["n"].int,
                  let direction = value["dir"].string, ["across", "down"].contains(direction),
                  let text = value["clue"].string else { return nil }
            let cells = value["cells"].array.compactMap(Cell.init)
            guard !cells.isEmpty else { return nil }
            return Clue(id: id, number: number, direction: direction, text: text, cells: cells)
        }.sorted { $0.direction == $1.direction ? $0.number < $1.number : $0.direction == "across" }
    }
    private var chosen: Clue? { clues.first { $0.id == game.state["chosen"].string } ?? clues.first }
    private var selected: Cell? { Cell(game.state["selected"]) ?? chosen?.cells.first }
    private var wrong: Set<Cell> { Set(game.state["wrong"].array.compactMap(Cell.init)) }
    private var filledSlots: Set<String> {
        Set(clues.filter { $0.cells.allSatisfy { !letter(at: $0).isEmpty } }.map(\.id))
    }
    private var filled: Int { grid.flatMap { $0 }.filter { !$0.isEmpty && $0 != "#" }.count }
    private var total: Int { grid.flatMap { $0 }.filter { $0 != "#" }.count }
    private var direction: String { chosen?.direction ?? "across" }
    private var entry: Binding<String> {
        Binding(get: { drafts[chosen?.id ?? ""] ?? "" }, set: { value in
            guard let clue = chosen else { return }
            drafts[clue.id] = String(value.uppercased().filter { $0.isASCII && $0.isLetter }.prefix(clue.cells.count))
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: typeSize.isAccessibilitySize ? 20 : 14) {
            progress
            if validGrid {
                board.frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : 270)
                    .frame(maxWidth: .infinity)
                if game.over { completed }
                else if let clue = chosen {
                    focusedClue(clue)
                    entryControls(clue)
                    feedback
                    toolRow(clue)
                }
                clueList
            } else {
                MessageNotice(title: "Waiting for your crossword", detail: "The wall hasn’t sent a complete grid yet. Your draft stays here.", symbol: "square.grid.3x3", tint: CrosswordInk.cursor)
            }
        }
        .onChange(of: game.seq) { _, _ in
            if let pending, game.state["last_move_id"].string == pending.token {
                if let word = pending.word, drafts[pending.clueID] == word { drafts[pending.clueID] = "" }
                self.pending = nil
            }
        }
        .onChange(of: game.over) { _, over in
            if over {
                entering = false
                showClues = false
                UIAccessibility.post(notification: .announcement, argument: "Crossword solved.")
            }
        }
        .confirmationDialog("Clear \(clearClue?.title ?? "this answer")?", isPresented: Binding(get: { clearClue != nil }, set: { if !$0 { clearClue = nil } }), titleVisibility: .visible) {
            if let clue = clearClue {
                Button("Clear \(clue.title)", role: .destructive) { move(["clear": clue.id]); clearClue = nil }
            }
            Button("Keep letters", role: .cancel) { clearClue = nil }
        } message: {
            Text("Crossing clues share these squares. Your unsent answer draft stays here.")
        }
        .onAppear {
            if game.over { showClues = false }
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "-crossword-draft"), index + 1 < arguments.count, let clue = chosen {
                drafts[clue.id] = String(arguments[index + 1].uppercased().filter { $0.isASCII && $0.isLetter }.prefix(clue.cells.count))
            }
            if arguments.contains("-crossword-letters") { letterMode = true }
            #endif
        }
    }

    private var progress: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 7)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        return layout {
            Text(game.over ? "SOLVED" : "THE MINI")
                .font(.machine(10)).foregroundStyle(game.over ? CrosswordInk.solved : CrosswordInk.cursor)
            if !typeSize.isAccessibilitySize { Spacer() }
            Text("\(filled) / \(total) squares").font(.ui(13, .medium)).monospacedDigit().foregroundStyle(Ink.dim)
        }.accessibilityElement(children: .combine)
    }

    private var board: some View {
        GeometryReader { geometry in
            let side = geometry.size.width
            let margin = (side * 2 / 64).rounded()
            let line = max(1, (side / 192).rounded())
            let width = side - margin * 2
            let lit = Set(chosen?.cells ?? [])
            ZStack(alignment: .topLeading) {
                Rectangle().fill(game.over ? CrosswordInk.solved : CrosswordInk.rule)
                    .frame(width: width, height: width).offset(x: margin, y: margin)
                ForEach(0..<25, id: \.self) { index in
                    let cell = Cell(index / 5, index % 5)
                    let x = margin + (CGFloat(cell.column) * width / 5).rounded() + line
                    let y = margin + (CGFloat(cell.row) * width / 5).rounded() + line
                    let right = margin + (CGFloat(cell.column + 1) * width / 5).rounded()
                    let bottom = margin + (CGFloat(cell.row + 1) * width / 5).rounded()
                    let isSelected = selected == cell && !game.over
                    let isWrong = wrong.contains(cell)
                    let value = letter(at: cell)
                    let number = clues.first { $0.cells.first == cell }?.number
                    Button {
                        guard !game.over, value != "#" else { return }
                        entering = false
                        move(["select": cell.pair])
                    } label: {
                        ZStack(alignment: .topLeading) {
                            Rectangle().fill(value == "#" ? CrosswordInk.block : isSelected ? CrosswordInk.selected : lit.contains(cell) && !game.over ? CrosswordInk.word : CrosswordInk.square)
                            if value != "#" {
                                Text(value.uppercased()).font(.custom(Face.display, fixedSize: (bottom - y) * 0.57))
                                    .foregroundStyle(Color.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                                if let number {
                                    Text(String(number)).font(.custom(Face.mono, fixedSize: max(9, (bottom - y) * 0.16)))
                                        .foregroundStyle(CrosswordInk.number).padding(line + 1)
                                }
                                if isSelected {
                                    Rectangle().strokeBorder(CrosswordInk.cursor, lineWidth: line)
                                    VStack { Spacer(); Rectangle().fill(CrosswordInk.cursor).frame(width: (right - x) / 3, height: line).padding(.bottom, line) }
                                        .frame(maxWidth: .infinity)
                                }
                                if isWrong {
                                    HStack { Spacer(); Image(systemName: "xmark").font(.system(size: max(9, (bottom - y) * 0.16), weight: .bold)).foregroundStyle(CrosswordInk.wrong).padding(line + 1) }
                                }
                            }
                        }.frame(width: right - x, height: bottom - y)
                    }.buttonStyle(.plain).offset(x: x, y: y)
                        .allowsHitTesting(value != "#" && !game.over)
                        .accessibilityHidden(value == "#")
                        .accessibilityLabel(cellDescription(cell))
                        .accessibilityValue(isSelected ? "Selected" : "")
                        .accessibilityHint(game.over ? "Completed puzzle" : "Select this square. Select again to switch across and down.")
                }
                Rectangle().strokeBorder(game.over ? CrosswordInk.solved : CrosswordInk.rule, lineWidth: line)
                    .frame(width: width, height: width).offset(x: margin, y: margin).allowsHitTesting(false)
            }.frame(width: side, height: side)
        }.aspectRatio(1, contentMode: .fit).background(CrosswordInk.ground)
            .accessibilityElement(children: .contain).accessibilityLabel("Mini crossword grid")
    }

    private func focusedClue(_ clue: Clue) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { switchDirection(direction == "across" ? "down" : "across") } label: {
                    HStack(spacing: 7) {
                        Image(systemName: direction == "across" ? "arrow.right" : "arrow.down")
                        Text("\(clue.title.uppercased()), \(clue.cells.count) LETTERS")
                            .font(.machine(10)).fixedSize(horizontal: false, vertical: true)
                    }.foregroundStyle(CrosswordInk.cursor).frame(minHeight: 44, alignment: .leading)
                }.buttonStyle(.plain).accessibilityLabel("\(clue.title), \(clue.cells.count) letters. Switch direction")
                Spacer(minLength: 0)
                Button { previousClue(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .accessibilityLabel("Previous clue")
                Button { previousClue(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .accessibilityLabel("Next clue")
            }.font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.ink)
            Text(clue.text).font(.ui(20, .semibold)).foregroundStyle(Color.white).fixedSize(horizontal: false, vertical: true)
        }.padding(14).background(CrosswordInk.word.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
    }

    private func entryControls(_ clue: Clue) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Entry method", selection: $letterMode) {
                Text("Whole answer").tag(false)
                Text("One letter").tag(true)
            }.pickerStyle(.segmented).onChange(of: letterMode) { _, _ in entering = false }
            if letterMode {
                Text("Letters move to the next empty square.").font(.ui(13)).foregroundStyle(Ink.dim)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 6)], spacing: 6) {
                    ForEach(Array("QWERTYUIOPASDFGHJKLZXCVBNM"), id: \.self) { letter in
                        Button {
                            guard pending?.letter == nil else { return }
                            let token = UUID().uuidString
                            // No cell: the wall's cursor is authoritative. A cell read
                            // from the last status goes stale once the previous letter
                            // lands, and a retry would overwrite that letter.
                            let payload: [String: Any] = ["letter": String(letter).lowercased(), "client_move_id": token]
                            pending = Pending(token: token, clueID: clue.id, word: nil, letter: String(letter), move: payload)
                            send(payload)
                        } label: {
                            Text(String(letter)).font(.ui(19, .semibold)).foregroundStyle(Color.white)
                                .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 60 : 48)
                                .background(Ink.plaster, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(PressStyle(scale: 0.98)).accessibilityLabel("Enter \(String(letter))")
                    }
                }
                // One letter at a time until the wall confirms it, so a quick
                // second tap is never dropped without a trace.
                .disabled(pending?.letter != nil)
                Button { move(["backspace": true]) } label: {
                    Label("Backspace", systemImage: "delete.left").font(.ui(15, .semibold))
                        .frame(maxWidth: .infinity, minHeight: 48).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(PressStyle()).foregroundStyle(Ink.ink)
                if let pending, let letter = pending.letter {
                    HStack(alignment: .top) {
                        Text("\(letter) is waiting for confirmation.").font(.ui(13)).foregroundStyle(Ink.dim)
                        Spacer(minLength: 8)
                        Button("Retry") { send(pending.move) }.font(.ui(13, .semibold)).frame(minWidth: 44, minHeight: 44)
                        // The keyboard waits for this letter, so let the player drop it.
                        Button("Cancel") { self.pending = nil }.font(.ui(13)).foregroundStyle(Ink.dim).frame(minWidth: 44, minHeight: 44)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("Your answer").font(.ui(14, .semibold)).foregroundStyle(Ink.ink)
                    Spacer()
                    Text("\(entry.wrappedValue.count) / \(clue.cells.count)").font(.machine(11)).foregroundStyle(Ink.dim)
                }
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
                layout {
                    TextField("\(clue.cells.count) letters", text: entry)
                        .font(.machine(20)).foregroundStyle(Color.white).tracking(2)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled().keyboardType(.asciiCapable)
                        .submitLabel(.go).focused($entering).onSubmit { placeAnswer(clue) }
                        .padding(.horizontal, 14).frame(minHeight: 54)
                        .background(Ink.plaster, in: RoundedRectangle(cornerRadius: 13))
                        .accessibilityLabel("Answer for \(clue.title), \(clue.cells.count) letters")
                        .accessibilityHint("Your draft is kept until the wall confirms this answer.")
                    Button { placeAnswer(clue) } label: {
                        HStack(spacing: 9) { Text(typeSize.isAccessibilitySize ? "Place answer" : "Place"); Image(systemName: "return") }
                            .font(.ui(16, .semibold)).foregroundStyle(CrosswordInk.ground)
                            .padding(.horizontal, 16).frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil, minHeight: 54)
                            .background(CrosswordInk.cursor.opacity(entry.wrappedValue.count == clue.cells.count ? 1 : 0.45), in: RoundedRectangle(cornerRadius: 13))
                    }.buttonStyle(PressStyle()).disabled(entry.wrappedValue.count != clue.cells.count).accessibilityLabel("Place answer")
                }
                if pending?.word != nil {
                    Text("Your answer stays here until the wall confirms it.").font(.ui(12)).foregroundStyle(Ink.dim)
                }
            }
        }
    }

    @ViewBuilder private var feedback: some View {
        let kind = game.state["feedback"]["kind"].string ?? ""
        if ["incorrect", "checked", "erased"].contains(kind), let message = game.state["feedback"]["message"].string {
            Label(message, systemImage: kind == "incorrect" ? "xmark.square" : kind == "checked" ? "checkmark.circle" : "eraser")
                .font(.ui(14)).foregroundStyle(kind == "incorrect" ? CrosswordInk.wrong : CrosswordInk.cursor)
                .fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine)
        }
    }

    private func toolRow(_ clue: Clue) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            Button { entering = false; move(["check": true]) } label: {
                Label("Check grid", systemImage: "checkmark.square").font(.ui(14, .semibold))
                    .frame(maxWidth: .infinity, minHeight: 48).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(PressStyle()).foregroundStyle(Ink.ink)
            Button { entering = false; clearClue = clue } label: {
                Label("Clear answer", systemImage: "eraser").font(.ui(14, .semibold))
                    .frame(maxWidth: .infinity, minHeight: 48).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(PressStyle()).foregroundStyle(Ink.ink).disabled(clue.cells.allSatisfy { letter(at: $0).isEmpty })
        }
    }

    private var completed: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "checkmark.seal").font(.system(size: 26)).foregroundStyle(CrosswordInk.solved)
            VStack(alignment: .leading, spacing: 6) {
                Text("Solved").font(.ui(20, .semibold)).foregroundStyle(Color.white)
                Text("\(clues.count) clues, \(total) letters.")
                    .font(.ui(14)).foregroundStyle(Ink.dim)
            }.fixedSize(horizontal: false, vertical: true)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(CrosswordInk.solved.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
    }

    private var clueList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(reducedMotion ? nil : .easeInOut(duration: 0.18)) { showClues.toggle() }
            } label: {
                HStack {
                    Text("All clues").font(.ui(20, .semibold))
                    Spacer()
                    Text("\(filledSlots.count) / \(clues.count) filled").font(.ui(12)).foregroundStyle(Ink.dim)
                    Image(systemName: showClues ? "chevron.up" : "chevron.down").font(.system(size: 12, weight: .semibold))
                }.frame(minHeight: 48).foregroundStyle(Ink.ink)
            }.buttonStyle(.plain).accessibilityValue(showClues ? "Expanded" : "Collapsed")
            if showClues {
                ForEach(["across", "down"], id: \.self) { dir in
                    Label(dir.capitalized, systemImage: dir == "across" ? "arrow.right" : "arrow.down")
                        .font(.ui(14, .semibold)).foregroundStyle(CrosswordInk.cursor).padding(.top, 8)
                    ForEach(clues.filter { $0.direction == dir }) { clue in
                        Button { entering = false; move(["choose": clue.id]) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Text(String(clue.number)).font(.machine(12)).foregroundStyle(CrosswordInk.cursor).frame(minWidth: 25, alignment: .leading)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(clue.text).font(.ui(15, chosen?.id == clue.id ? .semibold : .regular)).foregroundStyle(Ink.ink)
                                    Text(clue.cells.map { letter(at: $0).isEmpty ? "_" : letter(at: $0).uppercased() }.joined(separator: " "))
                                        .font(.machine(11)).foregroundStyle(Ink.dim)
                                }.fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                if filledSlots.contains(clue.id) { Image(systemName: game.over ? "checkmark" : "square.fill").font(.system(size: 10)).foregroundStyle(game.over ? CrosswordInk.solved : Ink.dim) }
                            }.padding(.vertical, 13).padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                                .background(chosen?.id == clue.id && !game.over ? CrosswordInk.word : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).allowsHitTesting(!game.over)
                            .accessibilityLabel("\(clue.title). \(clue.text). \(clue.cells.count) letters. \(filledSlots.contains(clue.id) ? "Filled" : "Not filled").")
                            .accessibilityValue(chosen?.id == clue.id && !game.over ? "Selected" : "")
                    }
                }
                Text("Filled means every square has a letter. Check the grid to find letters that need another look.")
                    .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true).padding(.top, 5)
            }
        }
    }

    private func letter(at cell: Cell) -> String {
        guard grid.indices.contains(cell.row), grid[cell.row].indices.contains(cell.column) else { return "" }
        return grid[cell.row][cell.column]
    }
    private func cellDescription(_ cell: Cell) -> String {
        let value = letter(at: cell)
        let paths = clues.filter { $0.cells.contains(cell) }.map(\.title).joined(separator: ", ")
        return "Row \(cell.row + 1), column \(cell.column + 1). \(value.isEmpty ? "Empty" : value.uppercased()). \(paths). \(wrong.contains(cell) ? "Incorrect, crossed corner." : "")"
    }
    private func move(_ payload: [String: Any]) {
        guard !game.over else { return }
        send(payload)
    }
    private func placeAnswer(_ clue: Clue) {
        let word = drafts[clue.id] ?? ""
        guard !game.over, word.count == clue.cells.count else { return }
        let token = UUID().uuidString
        let payload: [String: Any] = ["slot": clue.id, "word": word.lowercased(), "client_move_id": token]
        pending = Pending(token: token, clueID: clue.id, word: word, letter: nil, move: payload)
        entering = false
        send(payload)
    }
    private func previousClue(_ offset: Int) {
        guard let clue = chosen, let index = clues.firstIndex(where: { $0.id == clue.id }), !clues.isEmpty else { return }
        entering = false
        move(["choose": clues[(index + offset + clues.count) % clues.count].id])
    }
    private func switchDirection(_ next: String) {
        guard next != direction, let selected else { return }
        entering = false
        if clues.contains(where: { $0.direction == next && $0.cells.contains(selected) }) {
            move(["select": selected.pair, "direction": next])
        } else if let clue = clues.first(where: { $0.direction == next }) {
            move(["choose": clue.id])
        }
    }
}
