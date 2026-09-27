import SwiftUI

/// The letter centres, connecting paths and palette are shared with letterboxed.py.
struct LetterBoxedBoard: View {
    let game: GameStatus.Game
    let accent: Color
    let send: ([String: Any]) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var word = ""
    @State private var submitted: String?
    @State private var undoDraft: String?
    @State private var notice: String?

    private let gold = Color(hex: 0xDFB965)
    private let paper = Color(hex: 0xFAF2DE)
    private var sides: [[String]] { game.state["sides"].strings.prefix(4).map { Array($0.prefix(3)).map(String.init) } }
    private var letters: [String] { sides.flatMap { $0 } }
    private var used: Set<String> { Set(game.state["used"].strings) }
    private var words: [String] { game.state["words"].strings }
    private var next: String { game.over ? "" : words.last.map { String($0.suffix(1)) } ?? "" }
    private var hint: String { game.state["hint"].string ?? "" }
    private var progress: Int { min(12, used.count) }
    private var canSubmit: Bool { !game.over && word.count >= 3 && word.count <= 12 && (next.isEmpty || word.hasPrefix(next)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(game.over ? "Every letter connected." : "One word leads to another.")
                        .font(.ui(16, .semibold)).foregroundStyle(Ink.ink)
                    Text("Use all 12 letters. Try it in \(game.state["par"].int ?? 2) words.")
                        .font(.ui(13)).foregroundStyle(Ink.dim)
                }
                Spacer(minLength: 12)
                Text("\(progress)/12").font(.machine(16)).foregroundStyle(gold).accessibilityLabel("\(progress) of 12 letters used")
            }
            artwork
            if !game.over {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(word.isEmpty ? "Choose a letter" : word.uppercased())
                            .font(.display(typeSize.isAccessibilitySize ? 29 : 34)).foregroundStyle(word.isEmpty ? Ink.dim : paper)
                            .lineLimit(2).minimumScaleFactor(0.7).contentTransition(.numericText())
                        Spacer(minLength: 8)
                        Text("\(word.count)").font(.machine(13)).foregroundStyle(Ink.dim).accessibilityHidden(true)
                    }.frame(minHeight: 42).accessibilityLabel(word.isEmpty ? "No letters selected" : "Current word, \(word.uppercased())")
                    Text(notice ?? (!hint.isEmpty ? "A starting point: \(hint.uppercased())…" : next.isEmpty ? "Tap letters on different sides to build a word." : "Your next word begins with \(next.uppercased())."))
                        .font(.ui(13)).foregroundStyle(notice == nil ? Ink.dim : gold).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button { if !word.isEmpty { word.removeLast(); notice = nil } } label: {
                            Label("Delete", systemImage: "delete.left").font(.ui(14, .semibold)).frame(maxWidth: .infinity, minHeight: 50)
                        }.buttonStyle(.plain).foregroundStyle(paper).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 14)).disabled(word.isEmpty)
                        Button { submitted = word; send(["word": word]) } label: {
                            Label("Enter", systemImage: "arrow.up").font(.ui(14, .semibold)).frame(maxWidth: .infinity, minHeight: 50)
                        }.buttonStyle(PressStyle()).foregroundStyle(Ink.ground).background(canSubmit ? gold : gold.opacity(0.3), in: RoundedRectangle(cornerRadius: 14)).disabled(!canSubmit)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack { secondaryActions }
                        VStack(alignment: .leading) { secondaryActions }
                    }
                }
            }
            if !words.isEmpty {
                VStack(alignment: .leading, spacing: 13) {
                    Text("YOUR CHAIN").font(.machine(10)).tracking(1.5).foregroundStyle(Ink.dim)
                    ForEach(Array(words.enumerated()), id: \.offset) { index, accepted in
                        HStack(spacing: 13) {
                            Text(String(format: "%02d", index + 1)).font(.machine(12)).foregroundStyle(gold).frame(width: 26)
                            Text(accepted.uppercased()).font(.ui(19, .semibold)).foregroundStyle(paper)
                            Spacer(minLength: 4)
                            Image(systemName: "checkmark").font(.ui(13, .semibold)).foregroundStyle(gold)
                        }.accessibilityElement(children: .ignore).accessibilityLabel("Word \(index + 1), \(accepted)")
                    }
                }.padding(.top, 3)
            }
        }
        .onAppear { if word.isEmpty { word = next } }
        .onChange(of: words) { old, new in
            if let submitted, new.count > old.count, new.last == submitted {
                if word == submitted { word = next; notice = nil }
                self.submitted = nil
            } else if let undoDraft, new.count < old.count {
                if word == undoDraft { word = next; notice = nil }
                self.undoDraft = nil
            } else if word == (old.last.map { String($0.suffix(1)) } ?? "") {
                // A spoken or another player's accepted word moves an
                // untouched automatic starter forward, never an edited draft.
                word = next; notice = nil
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: used)
    }

    @ViewBuilder private var secondaryActions: some View {
        Button { undoDraft = word; send(["undo": true]) } label: {
            Label("Undo word", systemImage: "arrow.uturn.backward").font(.ui(13)).frame(minHeight: 44)
        }.disabled(words.isEmpty).foregroundStyle(Ink.dim)
        Spacer(minLength: 10)
        Button { word = next; submitted = nil; notice = nil } label: {
            Text("Clear").font(.ui(13)).frame(minWidth: 44, minHeight: 44)
        }.disabled(word.isEmpty || word == next).foregroundStyle(Ink.dim)
        Spacer(minLength: 10)
        Button { send(["hint": true]) } label: {
            Label("Nudge", systemImage: "lightbulb").font(.ui(13)).frame(minHeight: 44)
        }.foregroundStyle(gold).accessibilityHint("Suggests the first two letters of a valid next word")
    }

    private var artwork: some View {
        GeometryReader { geometry in
            let side = geometry.size.width
            ZStack {
                Canvas { context, size in
                    let box = CGRect(x: size.width * 0.14, y: size.height * 0.14, width: size.width * 0.72, height: size.height * 0.72)
                    context.stroke(Path(box), with: .color(game.over ? gold : Color(hex: 0x433C2F)), lineWidth: max(1, side * 0.006))
                    for (index, accepted) in words.enumerated() {
                        draw(accepted, in: &context, side: side, colour: index == words.count - 1 ? gold : Color(hex: 0x635026), width: side * 0.013)
                    }
                    if !word.isEmpty && !game.over {
                        draw(word, in: &context, side: side, colour: paper, width: side * 0.008, dashed: true)
                    }
                }.accessibilityHidden(true)
                ForEach(Array(letters.enumerated()), id: \.offset) { index, letter in
                    let selected = word.contains(letter) && !game.over
                    let isUsed = used.contains(letter)
                    let ring = next == letter || hint.contains(letter) || selected
                    Button { append(letter) } label: {
                        VStack(spacing: 0) {
                            Text(letter.uppercased()).font(.custom(Face.uiMedium, fixedSize: side * 0.065))
                            Rectangle().fill(isUsed ? Color(hex: 0x0F0C08) : .clear).frame(width: side * 0.042, height: max(1, side * 0.004))
                        }
                        .foregroundStyle(isUsed ? Color(hex: 0x0F0C08) : paper)
                        .frame(width: side * 0.112, height: side * 0.112)
                        .background(isUsed ? gold : Color(hex: 0x1F1C17), in: Circle())
                        .overlay { if ring { Circle().stroke(paper, lineWidth: max(1, side * 0.006)).padding(-side * 0.012) } }
                        .frame(width: max(44, side * 0.14), height: max(44, side * 0.14)).contentShape(Circle())
                    }.buttonStyle(PressStyle(scale: reduceMotion ? 1 : 0.92)).allowsHitTesting(!game.over)
                        .accessibilityRemoveTraits(game.over ? .isButton : [])
                        .accessibilityAddTraits(game.over ? .isStaticText : .isButton)
                        .position(point(index, side: side))
                        .accessibilityLabel("\(letter.uppercased()), \(["top", "right", "bottom", "left"][min(3, index / 3)]) side\(isUsed ? ", used" : ", unused")")
                        .accessibilityHint(next == letter ? "Start the next word here" : "Adds this letter to your word")
                }
            }.background(Color(hex: 0x0B0A09))
                .overlay { if game.over { Rectangle().strokeBorder(gold, lineWidth: 2) } }
        }.aspectRatio(1, contentMode: .fit)
            .accessibilityElement(children: .contain).accessibilityLabel("Letter Boxed puzzle")
    }

    private func point(_ index: Int, side: CGFloat) -> CGPoint {
        let low = side * 0.14, high = side * 0.86
        let along = low + side * 0.72 * CGFloat(index % 3 + 1) / 4
        switch index / 3 {
        case 0: return CGPoint(x: along, y: low)
        case 1: return CGPoint(x: high, y: along)
        case 2: return CGPoint(x: along, y: high)
        default: return CGPoint(x: low, y: along)
        }
    }
    private func draw(_ text: String, in context: inout GraphicsContext, side: CGFloat, colour: Color, width: CGFloat, dashed: Bool = false) {
        let points = text.compactMap { letters.firstIndex(of: String($0)).map { point($0, side: side) } }
        guard let first = points.first else { return }
        var path = Path(); path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        context.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: max(1, width), lineCap: .round, lineJoin: .round, dash: dashed ? [5, 5] : []))
    }
    private func append(_ letter: String) {
        guard !game.over, word.count < 12, let index = letters.firstIndex(of: letter) else { return }
        if word.isEmpty, !next.isEmpty, letter != next { notice = "Begin with \(next.uppercased()), where your last word ended."; return }
        if let last = word.last, let previous = letters.firstIndex(of: String(last)), previous / 3 == index / 3 {
            notice = "Choose a letter on a different side."; return
        }
        word += letter; notice = nil; Taps.detent(intensity: 0.22)
    }
}
