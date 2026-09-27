import SwiftUI

/// Found paths have the same normalized geometry and colour as strands.py.
struct StrandsBoard: View {
    let game: GameStatus.Game
    let accent: Color
    let send: ([String: Any]) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var trace: [Int] = []
    @State private var submitted: String?
    @State private var dragging = false
    @State private var notice: String?

    private let blue = Color(hex: 0x90C4D7)
    private let gold = Color(hex: 0xDFB965)
    private let paper = Color(hex: 0xFAF2DE)
    private let dark = Color(hex: 0x0D1519)
    private var rows: [[String]] { game.state["rows"].strings.prefix(8).map { Array($0.prefix(6)).map(String.init) } }
    private var validGrid: Bool { rows.count == 8 && rows.allSatisfy { $0.count == 6 } }
    private var found: [JSONValue] { game.state["found"].array }
    private var accepted: [String] { found.compactMap { $0["word"].string } + game.state["extra"].strings }
    private var hint: [Int] { indices(game.state["hint"]) }
    private var hints: Int { max(0, game.state["hints_available"].int ?? (game.state["extra"].strings.count / 3 - (game.state["hints"].int ?? 0))) }
    private var hintProgress: Int { max(0, min(2, game.state["hint_progress"].int ?? game.state["extra"].strings.count % 3)) }
    private var ordered: Bool { game.state["hint_ordered"].bool == true }
    private var traced: String { trace.map(letter).joined() }
    private var accessibleControls: Bool { voiceOver || typeSize.isAccessibilitySize }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("TODAY'S THREAD").font(.machine(10)).tracking(1.8).foregroundStyle(blue)
                Text(game.state["theme"].string ?? "Find the connection").font(.display(typeSize.isAccessibilitySize ? 29 : 35)).foregroundStyle(paper)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("\(found.count) of \(game.state["total"].int ?? (found.count + (game.state["left"].int ?? 0))) found").font(.ui(13)).foregroundStyle(Ink.dim)
                    Spacer()
                    if found.contains(where: { $0["spangram"].bool == true }) {
                        Label("Spangram", systemImage: "checkmark").font(.ui(12, .semibold)).foregroundStyle(gold)
                    }
                }
            }
            if validGrid {
                artwork
                if !game.over {
                    if accessibleControls { tapGrid }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(traced.isEmpty ? "Follow a thread" : traced.uppercased()).font(.display(typeSize.isAccessibilitySize ? 27 : 31))
                                .foregroundStyle(traced.isEmpty ? Ink.dim : paper).lineLimit(2).minimumScaleFactor(0.65)
                            Spacer(minLength: 8)
                            if !trace.isEmpty { Text("\(trace.count)").font(.machine(12)).foregroundStyle(Ink.dim) }
                        }.frame(minHeight: 40).accessibilityLabel(traced.isEmpty ? "No letters selected" : "Selected word, \(traced)")
                        Text(notice ?? (trace.isEmpty ? "Tap or trace neighbouring letters. Then enter your word." : "Tap the previous letter to step back, or use Delete."))
                            .font(.ui(13)).foregroundStyle(notice == nil ? Ink.dim : gold).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Button { if !trace.isEmpty { trace.removeLast(); notice = nil } } label: {
                                Label("Delete", systemImage: "delete.left").font(.ui(14, .semibold)).frame(maxWidth: .infinity, minHeight: 50)
                            }.buttonStyle(.plain).foregroundStyle(paper).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 14)).disabled(trace.isEmpty)
                            Button(action: submit) {
                                Label("Enter", systemImage: "arrow.up").font(.ui(14, .semibold)).frame(maxWidth: .infinity, minHeight: 50)
                            }.buttonStyle(PressStyle()).foregroundStyle(dark).background(trace.count >= 4 ? blue : blue.opacity(0.3), in: RoundedRectangle(cornerRadius: 14)).disabled(trace.count < 4)
                        }
                        hintControls
                    }
                }
                if !found.isEmpty { discoveries }
            } else {
                Text("Waiting for the complete letter grid.").font(.ui(15)).foregroundStyle(Ink.dim)
            }
        }
        .onChange(of: accepted) { _, words in
            if let submitted, words.contains(submitted) {
                if traced == submitted { trace = []; notice = nil }
                self.submitted = nil
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: accepted)
    }

    private var hintControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button { trace = []; submitted = nil; notice = nil } label: { Text("Clear").font(.ui(13)).frame(minWidth: 44, minHeight: 44) }
                    .foregroundStyle(Ink.dim).disabled(trace.isEmpty)
                Spacer()
                Button { send(["hint": true]) } label: {
                    Label(hint.isEmpty ? "Use hint" : "Show order", systemImage: "lightbulb")
                        .font(.ui(14, .semibold)).frame(minHeight: 44)
                }.foregroundStyle(gold).disabled(hints == 0 || ordered || (game.state["left"].int == 1 && !found.contains(where: { $0["spangram"].bool == true })))
            }
            HStack(spacing: 8) {
                ForEach(0..<3) { i in
                    RoundedRectangle(cornerRadius: 2).fill(hints > 0 || i < hintProgress ? gold : Ink.plaster).frame(width: 24, height: 5)
                }.accessibilityHidden(true)
                Text(hints > 0 ? "\(hints) hint\(hints == 1 ? "" : "s") ready" : "\(hintProgress)/3 extra words to earn a hint")
                    .font(.ui(12)).foregroundStyle(Ink.dim)
            }
            if !hint.isEmpty {
                Text(ordered ? "The dotted path shows the order." : "The outlined letters make one theme word.")
                    .font(.ui(12)).foregroundStyle(paper)
            }
        }
    }

    private var discoveries: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(game.over ? "EVERY STRAND" : "UNRAVELLED").font(.machine(10)).tracking(1.5).foregroundStyle(Ink.dim)
            ForEach(Array(found.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 12) {
                    Image(systemName: item["spangram"].bool == true ? "arrow.left.and.right" : "checkmark").frame(width: 22)
                    Text((item["word"].string ?? "").uppercased()).font(.ui(17, .semibold))
                    Spacer(minLength: 0)
                    if item["spangram"].bool == true { Text("SPANGRAM").font(.machine(9)) }
                }.foregroundStyle(item["spangram"].bool == true ? gold : blue)
                    .accessibilityElement(children: .combine)
            }
        }
    }

    private var artwork: some View {
        GeometryReader { geometry in
            let side = geometry.size.width
            ZStack {
                Canvas { context, _ in
                    for item in found {
                        stroke(indices(item["path"]), context: &context, side: side, colour: (item["spangram"].bool == true ? gold : blue).opacity(0.45), width: side * 0.038)
                    }
                    if ordered { stroke(hint, context: &context, side: side, colour: paper, width: side * 0.01, dashed: true) }
                    if !game.over && !trace.isEmpty { stroke(trace, context: &context, side: side, colour: paper, width: side * 0.024, dashed: true) }
                }.accessibilityHidden(true)
                ForEach(0..<48) { index in
                    let colour = foundColour(index)
                    let selected = !game.over && trace.contains(index)
                    VStack(spacing: 0) {
                        Text(letter(index).uppercased()).font(.custom(Face.uiMedium, fixedSize: side * 0.062))
                        Rectangle().fill(colour == nil ? .clear : dark).frame(width: side * 0.028, height: max(1, side * 0.003))
                    }
                    .foregroundStyle(selected ? dark : colour == nil ? paper : dark)
                    .frame(width: side * 0.092, height: side * 0.092)
                    .background(selected ? paper : colour ?? Color(hex: 0x1A1E1F), in: Circle())
                    .overlay { if hint.contains(index) { Circle().stroke(paper, style: StrokeStyle(lineWidth: 2, dash: ordered ? [] : [3, 3])).padding(-side * 0.008) } }
                    .frame(width: max(44, side * 0.12), height: max(44, side * 0.12)).contentShape(Rectangle())
                    .position(point(index, side: side)).accessibilityHidden(true)
                }
            }.background(Color(hex: 0x0B0A09)).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard !game.over, !accessibleControls else { return }
                    if !dragging { dragging = true }
                    if let index = hit(value.location, side: side) { append(index) }
                }.onEnded { _ in dragging = false })
                .overlay { if game.over { Rectangle().strokeBorder(gold, lineWidth: 2) } }
        }.aspectRatio(1, contentMode: .fit)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Strands board. \(found.count) words found. Use the letter buttons below to build a word.")
    }

    private var tapGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Build your word").font(.ui(16, .semibold)).foregroundStyle(paper)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(0..<48) { index in
                    Button { append(index, repeatedTap: true) } label: {
                        VStack(spacing: 4) {
                            Text(letter(index).uppercased()).font(.ui(21, .semibold))
                            Text("\(index / 6 + 1),\(index % 6 + 1)").font(.machine(10))
                        }.frame(maxWidth: .infinity, minHeight: 62)
                            .foregroundStyle(trace.contains(index) ? dark : paper)
                            .background(trace.contains(index) ? paper : Ink.plaster, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(letter(index).uppercased()), row \(index / 6 + 1), column \(index % 6 + 1)\(trace.contains(index) ? ", selected" : "")\(hint.contains(index) ? ", hinted" : "")")
                        .accessibilityHint("Adds this adjacent letter; choosing the previous letter steps back")
                }
            }
        }
    }

    private func indices(_ value: JSONValue) -> [Int] {
        value.array.compactMap { cell in
            guard let r = cell[0].int, let c = cell[1].int, (0..<8).contains(r), (0..<6).contains(c) else { return nil }
            return r * 6 + c
        }
    }
    private func letter(_ index: Int) -> String { validGrid && (0..<48).contains(index) ? rows[index / 6][index % 6] : "" }
    private func point(_ index: Int, side: CGFloat) -> CGPoint { CGPoint(x: side * (0.2 + Double(index % 6) * 0.12), y: side * (0.08 + Double(index / 6) * 0.12)) }
    private func foundColour(_ index: Int) -> Color? {
        for item in found where indices(item["path"]).contains(index) { return item["spangram"].bool == true ? gold : blue }
        return nil
    }
    private func stroke(_ indices: [Int], context: inout GraphicsContext, side: CGFloat, colour: Color, width: CGFloat, dashed: Bool = false) {
        guard let first = indices.first else { return }
        var path = Path(); path.move(to: point(first, side: side))
        for index in indices.dropFirst() { path.addLine(to: point(index, side: side)) }
        context.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: max(1, width), lineCap: .round, lineJoin: .round, dash: dashed ? [3, 5] : []))
    }
    private func hit(_ point: CGPoint, side: CGFloat) -> Int? {
        let column = Int(((point.x / side - 0.2) / 0.12).rounded())
        let row = Int(((point.y / side - 0.08) / 0.12).rounded())
        guard (0..<8).contains(row), (0..<6).contains(column) else { return nil }
        let centre = self.point(row * 6 + column, side: side)
        guard hypot(point.x - centre.x, point.y - centre.y) <= max(22, side * 0.057) else { return nil }
        return row * 6 + column
    }
    private func append(_ index: Int, repeatedTap: Bool = false) {
        guard !game.over else { return }
        if trace.last == index { if repeatedTap { trace.removeLast() }; return }
        if trace.count >= 2, trace[trace.count - 2] == index { trace.removeLast(); notice = nil; return }
        if trace.contains(index) { notice = "Use each letter cell once in a word."; return }
        if let last = trace.last, max(abs(last / 6 - index / 6), abs(last % 6 - index % 6)) != 1 {
            notice = "Choose a neighbouring letter, including diagonals."; return
        }
        trace.append(index); notice = nil; Taps.detent(intensity: 0.22)
    }
    private func submit() {
        guard trace.count >= 4, !game.over else { return }
        submitted = traced
        send(["word": traced, "path": trace.map { [$0 / 6, $0 % 6] }])
    }
}
