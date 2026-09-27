import SwiftUI

/// One semantic-distance dial, shared with the wall's normalized composition.
struct ContextoBoard: View {
    let game: GameStatus.Game
    let accent: Color
    let send: ([String: Any]) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var word = ""
    @State private var submitted: (word: String, receipt: Int)?
    @State private var recentFirst = false
    @State private var historyLimit = 6
    @State private var confirmingReveal = false
    @FocusState private var typing: Bool

    private let paper = Color(hex: 0xF0E7D3)
    private let track = Color(hex: 0x2F2C26)
    private let close = Color(hex: 0x91BF97)
    private let near = Color(hex: 0xDFB965)
    private let far = Color(hex: 0xD55043)
    private var guesses: [JSONValue] { game.state["guesses"].array }
    private var count: Int { game.state["count"].int ?? guesses.count }
    private var receipt: Int { game.state["receipt"].int ?? game.seq }
    private var last: JSONValue { game.state["last"] }
    private var revealed: Bool { game.over && !game.won }
    private var rank: Int? { game.over ? 1 : last["rank"].int }
    private var best: Int? { game.state["best"].int }
    private var vocabulary: Int { max(2, game.state["vocabulary"].int ?? 20_000) }
    private var displayedWord: String { game.over ? game.state["secret"].string ?? "" : last["word"].string ?? "First word" }
    private var dialColour: Color { revealed ? paper : rank.map(colour) ?? Ink.dim }
    private var dialBand: String { revealed ? "Revealed" : rank.map(band) ?? "Explore" }
    private var history: [JSONValue] {
        recentFirst ? guesses.sorted { ($0["order"].int ?? 0) > ($1["order"].int ?? 0) } : guesses
    }
    private var validDraft: Bool { !word.isEmpty && word.count <= 32 && word.allSatisfy { $0.isASCII && $0.isLetter } }
    private var draft: Binding<String> {
        Binding(get: { word }, set: { word = String($0.lowercased().prefix(32)) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            artwork.frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : 320).frame(maxWidth: .infinity)
            if !game.over { composer }
            if last["again"].bool == true && !game.over {
                Label("Already explored. Your guess count stays the same.", systemImage: "arrow.counterclockwise")
                    .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
            if guesses.isEmpty {
                Text(game.over ? "This round ended before your first guess." : "Start with any familiar idea. Follow the meaning of your closest words; spelling does not determine the rank.")
                    .font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            } else { wordHistory }
            if !game.over { revealControl }
        }
        .onChange(of: receipt) { _, acknowledged in
            guard let submitted, acknowledged > submitted.receipt,
                  last["word"].string == submitted.word else { return }
            if word == submitted.word { word = "" }
            self.submitted = nil
        }
        .onChange(of: game.over) { _, finished in
            if finished { typing = false; confirmingReveal = false; historyLimit = 6 }
        }
    }

    private var artwork: some View {
        GeometryReader { geometry in
            let side = geometry.size.width
            ZStack {
                Canvas { context, _ in
                    let progress = proximity(rank)
                    for tick in 0...40 {
                        let angle = (150 + 240 * Double(tick) / 40) * .pi / 180
                        var path = Path()
                        path.move(to: CGPoint(x: side * (0.5 + 0.292 * cos(angle)), y: side * (0.39 + 0.292 * sin(angle))))
                        path.addLine(to: CGPoint(x: side * (0.5 + 0.325 * cos(angle)), y: side * (0.39 + 0.325 * sin(angle))))
                        context.stroke(path, with: .color(rank != nil && tick <= Int((progress * 40).rounded()) ? dialColour : track), style: StrokeStyle(lineWidth: max(1, side * 0.009), lineCap: .round))
                    }
                }
                Text(rank == nil ? "FIND" : "RANK")
                    .font(.custom(Face.monoMedium, fixedSize: side * 0.027)).tracking(1.5).foregroundStyle(Ink.dim)
                    .position(x: side * 0.5, y: side * 0.22)
                Text(rank.map(String.init) ?? "?")
                    .font(.custom(Face.display, fixedSize: side * 0.22)).foregroundStyle(dialColour)
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6).frame(width: side * 0.56)
                    .contentTransition(.numericText()).position(x: side * 0.5, y: side * 0.37)
                Text(dialBand.uppercased())
                    .font(.custom(Face.monoMedium, fixedSize: side * 0.032)).tracking(1).foregroundStyle(dialColour)
                    .position(x: side * 0.5, y: side * 0.525)
                Text(displayedWord.uppercased())
                    .font(.custom(Face.uiSemibold, fixedSize: side * 0.066)).foregroundStyle(paper)
                    .lineLimit(1).minimumScaleFactor(0.48).frame(width: side * 0.84)
                    .position(x: side * 0.5, y: side * 0.72)
                Rectangle().fill(track).frame(width: side * 0.84, height: max(1, side * 0.003))
                    .position(x: side * 0.5, y: side * 0.835)
                Text(best.map { "BEST \($0)  /  \(count) \(count == 1 ? "TRY" : "TRIES")" } ?? "RANK 1 IS THE WORD")
                    .font(.custom(Face.mono, fixedSize: side * 0.029)).foregroundStyle(Ink.dim)
                    .lineLimit(1).minimumScaleFactor(0.65).frame(width: side * 0.84)
                    .position(x: side * 0.5, y: side * 0.92)
            }.background(Ink.ground)
        }.aspectRatio(1, contentMode: .fit)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(dialAccessibility)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: receipt)
    }
    private var dialAccessibility: String {
        if game.over {
            return "\(game.won ? "Found" : "Revealed"), \(displayedWord). Rank one. \(count) unique guesses."
        }
        guard let rank else { return "Find the secret word by meaning. Lower ranks are closer; rank one is the answer." }
        return "\(displayedWord), rank \(rank), \(dialBand). Best rank \(best ?? rank). \(count) unique guesses. Lower is closer."
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if typeSize.isAccessibilitySize {
                wordField
                enterButton
            } else {
                HStack(spacing: 9) { wordField; enterButton.frame(width: 86) }
            }
            Text(!word.isEmpty && !validDraft ? "Use one word with letters A–Z." : "Lower is closer. Rank 1 is the word.")
                .font(.ui(12)).foregroundStyle(!word.isEmpty && !validDraft ? near : Ink.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private var wordField: some View {
        TextField("A word, any word", text: draft, prompt: Text("A word, any word").foregroundStyle(Ink.dim))
            .font(.ui(19, .medium)).foregroundStyle(paper)
            .autocorrectionDisabled().textInputAutocapitalization(.never)
            .focused($typing).submitLabel(.send).onSubmit(submit)
            .padding(.horizontal, 14).frame(minHeight: 54).background(Ink.plaster, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityLabel("Your Contexto guess")
            .accessibilityHint("A single word. Rank measures meaning, not spelling.")
    }
    private var enterButton: some View {
        Button(action: submit) {
            HStack(spacing: 6) { Text("Enter"); Image(systemName: "arrow.up") }
                .font(.ui(15, .semibold)).frame(maxWidth: .infinity, minHeight: 54)
                .foregroundStyle(validDraft ? Ink.ground : Ink.dim)
                .background(validDraft ? close : Ink.plaster, in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(PressStyle(scale: reduceMotion ? 1 : 0.98)).disabled(!validDraft)
    }
    private var wordHistory: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack { historyTitle; Spacer(minLength: 8); orderButton }
                VStack(alignment: .leading, spacing: 3) { historyTitle; orderButton }
            }
            ForEach(Array(history.prefix(historyLimit).enumerated()), id: \.offset) { _, guess in
                guessRow(guess)
            }
            if guesses.count > 6 {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { historyControls }
                    VStack(alignment: .leading, spacing: 0) { historyControls }
                }
            }
        }.padding(.top, 3)
    }
    private var historyTitle: some View { Text("Your trail · \(count)").font(.ui(19, .semibold)).foregroundStyle(paper) }
    private var orderButton: some View {
        Button { recentFirst.toggle() } label: {
            Label(recentFirst ? "Recent first" : "Closest first", systemImage: "arrow.up.arrow.down")
                .font(.ui(12)).frame(minHeight: 44)
        }.buttonStyle(.plain).foregroundStyle(close)
            .accessibilityLabel("Sort guesses, \(recentFirst ? "recent first" : "closest first")")
    }
    @ViewBuilder private var historyControls: some View {
        if historyLimit < guesses.count {
            Button { historyLimit = min(guesses.count, historyLimit + 20) } label: {
                Text("Show \(min(20, guesses.count - historyLimit)) more").font(.ui(13, .semibold)).frame(minHeight: 44)
            }.buttonStyle(.plain).foregroundStyle(close)
        }
        if historyLimit > 6 {
            Button { historyLimit = 6 } label: { Text("Show fewer").font(.ui(13)).frame(minHeight: 44) }
                .buttonStyle(.plain).foregroundStyle(Ink.dim)
        }
    }
    private func guessRow(_ guess: JSONValue) -> some View {
        let text = guess["word"].string ?? ""
        let value = max(1, guess["rank"].int ?? vocabulary)
        return VStack(spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(text.uppercased()).font(.ui(16, .semibold)).foregroundStyle(paper)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(String(value)).font(.machine(14)).foregroundStyle(colour(value)).fixedSize()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(track)
                    Capsule().fill(colour(value)).frame(width: max(3, geometry.size.width * proximity(value)))
                }
            }.frame(height: 3).accessibilityHidden(true)
        }.padding(.vertical, 7)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(text), rank \(value), \(band(value)). Guess \(guess["order"].int ?? 0).")
    }
    private var revealControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            if confirmingReveal {
                Text("Reveal the word and end this round?").font(.ui(15, .semibold)).foregroundStyle(paper)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { revealActions }
                    VStack(alignment: .leading, spacing: 4) { revealActions }
                }
            } else {
                Button { confirmingReveal = true; typing = false } label: {
                    Label("Reveal the word", systemImage: "eye").font(.ui(13)).frame(minHeight: 44)
                }.buttonStyle(.plain).foregroundStyle(Ink.dim)
            }
        }
    }
    @ViewBuilder private var revealActions: some View {
        Button { confirmingReveal = false } label: {
            Text("Keep guessing").font(.ui(14, .semibold)).frame(minHeight: 44)
        }.buttonStyle(.plain).foregroundStyle(close)
        Button { send(["give_up": true]) } label: {
            Text("Reveal & end round").font(.ui(14, .semibold)).frame(minHeight: 44)
        }.buttonStyle(.plain).foregroundStyle(near)
    }
    private func submit() {
        guard validDraft, !game.over else { return }
        submitted = (word, receipt)
        typing = false
        send(["word": word])
    }
    private func colour(_ rank: Int) -> Color { rank <= 300 ? close : rank <= 1500 ? near : far }
    private func band(_ rank: Int) -> String { rank == 1 ? "Found" : rank <= 300 ? "Close" : rank <= 1500 ? "Nearer" : "Far away" }
    private func proximity(_ rank: Int?) -> Double {
        guard let rank else { return 0 }
        return 1 - min(1, max(0, log(Double(max(1, rank))) / log(Double(vocabulary))))
    }
}
