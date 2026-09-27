import SwiftUI

struct PictionaryBoard: View {
    let game: GameStatus.Game
    let accent: Color
    let send: ([String: Any]) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.gameCanInteract) private var canInteract
    @State private var draft = ""
    @State private var submitted: (text: String, receipt: Int)?
    @FocusState private var writing: Bool
    private let honey = Color(hex: 0xDFB965)
    private let paper = Color(hex: 0xF0E7D3)
    private var ready: Bool { game.state["picture_ready"].bool == true }
    private var drawing: Bool { game.state["drawing"].bool == true }
    private var duration: Double { max(1, min(300, game.state["seconds"].double ?? 60)) }
    private var remaining: Int { max(0, Int(ceil(min(duration, max(0, game.state["remaining"].double ?? duration))))) }
    private var receipt: Int { game.state["receipt"].int ?? 0 }
    private var guesses: [JSONValue] { game.state["guesses"].array }
    private var count: Int { game.state["guess_count"].int ?? guesses.count }
    private var guess: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canGuess: Bool { canInteract && !game.over && ready && remaining > 0 && !guess.isEmpty && guess.count <= 120 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) { heading; Spacer(minLength: 10); countdown }
                VStack(alignment: .leading, spacing: 10) { heading; countdown }
            }
            GameArtworkCanvas(game: game).frame(maxWidth: typeSize.isAccessibilitySize ? 260 : 300).frame(maxWidth: .infinity)
            if game.over {
                VStack(alignment: .leading, spacing: 8) {
                    Label(game.won ? "You saw it." : "The answer", systemImage: game.won ? "checkmark.circle" : "eye")
                        .font(.ui(14, .semibold)).foregroundStyle(honey)
                    Text((game.state["word"].string ?? "The picture").capitalized)
                        .font(typeSize.isAccessibilitySize ? .custom(Face.uiSemibold, size: 17, relativeTo: .body) : .display(36)).foregroundStyle(paper)
                        .fixedSize(horizontal: false, vertical: true)
                    if let winner = game.winner { Text("Found by \(winner)").font(.ui(14)).foregroundStyle(Ink.dim) }
                }
            } else {
                if ready {
                    composer
                    if drawing {
                        Label("The sketch is still taking shape. You can guess now.", systemImage: "pencil.tip")
                            .font(.ui(12)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    }
                } else if drawing {
                    HStack(alignment: .center, spacing: 12) {
                        ProgressView().tint(honey)
                        Text("The first lines are on their way. Your \(Int(duration)) seconds begin when the picture appears.")
                            .font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    }.accessibilityElement(children: .combine)
                }
                if let problem = game.state["problem"].string {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(problem).font(.ui(14)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                        if game.state["can_retry"].bool == true {
                            Button { if canInteract { send(["retry": true]) } } label: {
                                Label("Try drawing again", systemImage: "arrow.clockwise")
                                    .font(.ui(15, .semibold)).frame(minHeight: 48)
                            }.buttonStyle(.plain).foregroundStyle(honey).disabled(!canInteract)
                        }
                    }
                }
            }
            if !guesses.isEmpty { guessTrail }
        }
        .onChange(of: receipt) { _, acknowledged in
            guard let submitted, acknowledged > submitted.receipt,
                  game.state["last_guess"]["text"].string == submitted.text else { return }
            if guess == submitted.text { draft = "" }
            self.submitted = nil
        }
        .onChange(of: game.over) { _, over in if over { writing = false; submitted = nil } }
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(typeSize.isAccessibilitySize ? (game.over ? "Revealed." : ready ? "Name it." : "Drawing…") : (game.over ? "The whole picture." : ready ? "What do you see?" : "A little mystery."))
                .font(typeSize.isAccessibilitySize ? .custom(Face.uiMedium, size: 17, relativeTo: .body) : .display(31)).foregroundStyle(paper)
                .fixedSize(horizontal: false, vertical: true)
            if !typeSize.isAccessibilitySize {
                Text(game.over ? "Every detail, revealed." : ready ? "Name the thing in the drawing." : "A new picture, made for this round.")
                    .font(.ui(13)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    @ViewBuilder private var countdown: some View {
        if !game.over && ready {
            if typeSize.isAccessibilitySize {
                Text("\(remaining)s").font(.custom(Face.monoMedium, size: 13, relativeTo: .caption)).foregroundStyle(honey)
                    .accessibilityLabel("\(remaining) seconds remaining")
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(remaining)).font(.display(39)).monospacedDigit().foregroundStyle(honey)
                        .contentTransition(.numericText())
                    Text("SECONDS").font(.machine(9)).foregroundStyle(Ink.dim)
                }.accessibilityElement(children: .ignore).accessibilityLabel("\(remaining) seconds remaining")
            }
        }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if typeSize.isAccessibilitySize {
                guessField
                enterButton
            } else {
                HStack(spacing: 9) { guessField; enterButton.frame(width: 86) }
            }
            Text("A complete name wins. You can keep trying.").font(.ui(12)).foregroundStyle(Ink.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private var guessField: some View {
        TextField("Your guess", text: $draft, axis: .vertical)
            .font(typeSize.isAccessibilitySize ? .custom(Face.uiMedium, size: 17, relativeTo: .body) : .ui(19, .medium)).foregroundStyle(paper).textInputAutocapitalization(.sentences).autocorrectionDisabled()
            .focused($writing).lineLimit(1...3).submitLabel(.send).onSubmit(submit)
            .padding(.horizontal, 14).padding(.vertical, 12).frame(minHeight: 54)
            .background(Ink.plaster, in: RoundedRectangle(cornerRadius: 14))
            .onChange(of: draft) { _, new in if new.count > 120 { draft = String(new.prefix(120)) } }
            .accessibilityLabel("Your Pictionary guess")
    }
    private var enterButton: some View {
        Button(action: submit) {
            HStack(spacing: 6) { Text("Enter"); Image(systemName: "arrow.up") }
                .font(.ui(15, .semibold)).frame(maxWidth: .infinity, minHeight: 54)
                .foregroundStyle(canGuess ? Ink.ground : Ink.dim)
                .background(canGuess ? honey : Ink.plaster, in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(PressStyle(scale: reduceMotion ? 1 : 0.98)).disabled(!canGuess)
    }
    private var guessTrail: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Your guesses").font(.ui(18, .semibold)).foregroundStyle(paper)
                Spacer(minLength: 8)
                Text(String(count)).font(.machine(12)).foregroundStyle(honey)
            }
            ForEach(Array(guesses.suffix(5).reversed().enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item["text"].string ?? "").font(.ui(15)).foregroundStyle(paper).fixedSize(horizontal: false, vertical: true)
                    if game.players.count > 1 { Text(item["who"].string ?? "").font(.ui(12)).foregroundStyle(Ink.dim) }
                }.accessibilityElement(children: .combine)
            }
        }.padding(.top, 4)
    }
    private func submit() {
        guard canGuess else { return }
        submitted = (guess, receipt)
        writing = false
        send(["guess": guess])
    }
}
